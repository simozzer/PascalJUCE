/*
    PascalJUCE plug-in wrapper: a JUCE AudioProcessor that forwards everything
    to a plug-in library (written in Pascal) loaded from next to this binary.
    Compiled once per plug-in by pascaljuce_add_plugin(), which defines:

        PASCALJUCE_PLUGIN_LIBRARY  file name of the library ("X_pascal.dll")
        PASCALJUCE_PLUGIN_KIND     JCP_KIND_INSTRUMENT / _EFFECT / _MIDI_EFFECT
        PASCALJUCE_PLUGIN_SHA256   optional: expected SHA-256 (hex) of the library
*/
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_cryptography/juce_cryptography.h>
#include <juce_gui_basics/juce_gui_basics.h>

#include "juce_c_plugin.h"
#include "../src/pascaljuce_utf8.h"
#include "pascaljuce_state.h"
#include "pascaljuce_image_check.h"

#if defined(PASCALJUCE_HAS_LIBRARY_HASH)
    #include "pascaljuce_library_hash.h" // generated: #define PASCALJUCE_PLUGIN_SHA256 "..."
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cfenv>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <type_traits>
#include <vector>

#if JUCE_INTEL
    #include <xmmintrin.h>
    #include <float.h>
#endif

#if JUCE_WINDOWS
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #ifndef WIN32_LEAN_AND_MEAN
        #define WIN32_LEAN_AND_MEAN
    #endif
    #include <windows.h>
#else
    #include <dlfcn.h>
    #include <sys/stat.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <sys/wait.h>
    #if JUCE_MAC
        #include <CoreServices/CoreServices.h> // LSOpenCFURLRef (open_url)
    #endif
#endif

#ifndef PASCALJUCE_PLUGIN_LIBRARY
    #error "PASCALJUCE_PLUGIN_LIBRARY must be defined (see pascaljuce_add_plugin)"
#endif
#ifndef PASCALJUCE_PLUGIN_KIND
    #define PASCALJUCE_PLUGIN_KIND JCP_KIND_INSTRUMENT
#endif

// The Pascal side (JucePlugin.pas) mirrors these; tests/pascal/test_plugin_unit checks the same numbers.
#if defined(_WIN64) || defined(__x86_64__) || defined(__aarch64__)
static_assert(sizeof(jcp_parameter_info) == 64, "jcp_parameter_info layout");
static_assert(offsetof(jcp_parameter_info, min_value) == 40, "jcp_parameter_info layout");
static_assert(offsetof(jcp_parameter_info, version_hint) == 60, "jcp_parameter_info layout");
static_assert(sizeof(jcp_midi_event) == 16, "jcp_midi_event layout");
static_assert(sizeof(jcp_transport) == 72, "jcp_transport layout");
static_assert(offsetof(jcp_transport, time_in_samples) == 32, "jcp_transport layout");
static_assert(offsetof(jcp_transport, time_sig_denominator) == 64, "jcp_transport layout");
static_assert(sizeof(jcp_process_context) == 72, "jcp_process_context layout");
static_assert(offsetof(jcp_process_context, num_channels) == 40, "jcp_process_context layout");
static_assert(offsetof(jcp_process_context, is_non_realtime) == 68, "jcp_process_context layout");
static_assert(sizeof(jcp_host_api) == 88, "jcp_host_api layout");
static_assert(offsetof(jcp_host_api, get_extension) == 72, "jcp_host_api layout");
static_assert(offsetof(jcp_host_api, set_meter) == 80, "jcp_host_api layout");
static_assert(sizeof(jcp_plugin_vtable) == 96, "jcp_plugin_vtable layout");
static_assert(offsetof(jcp_plugin_vtable, get_parameter_text) == 72, "jcp_plugin_vtable layout");
static_assert(offsetof(jcp_plugin_vtable, create_editor) == 88, "jcp_plugin_vtable layout");
static_assert(sizeof(jcp_mouse_event) == 32, "jcp_mouse_event layout");
static_assert(offsetof(jcp_mouse_event, wheel_dy) == 28, "jcp_mouse_event layout");
static_assert(sizeof(jcp_editor_vtable) == 64, "jcp_editor_vtable layout");
static_assert(offsetof(jcp_editor_vtable, popup_result) == 56, "jcp_editor_vtable layout");
static_assert(sizeof(jcp_menu_item) == 16, "jcp_menu_item layout");
static_assert(sizeof(jcp_editor_api) == 424, "jcp_editor_api layout");
static_assert(offsetof(jcp_editor_api, set_design_size) == 392, "jcp_editor_api layout");
static_assert(offsetof(jcp_editor_api, set_look) == 416, "jcp_editor_api layout");
static_assert(sizeof(jcp_editor_look) == 56, "jcp_editor_look layout");
static_assert(offsetof(jcp_editor_look, tooltip_font_height) == 40, "jcp_editor_look layout");
static_assert(offsetof(jcp_editor_look, font_name) == 48, "jcp_editor_look layout");
static_assert(offsetof(jcp_editor_api, get_meter) == 144, "jcp_editor_api layout");
static_assert(offsetof(jcp_editor_api, set_colour) == 184, "jcp_editor_api layout");
static_assert(offsetof(jcp_editor_api, translate) == 384, "jcp_editor_api layout");
static_assert(sizeof(jcp_plugin_factory) == 48, "jcp_plugin_factory layout");
static_assert(offsetof(jcp_plugin_factory, error_message) == 40, "jcp_plugin_factory layout");
#endif

#define JCP_HAS_FIELD(structPtr, field) \
    ((structPtr)->struct_size >= (int32_t) (offsetof(std::remove_pointer_t<decltype(structPtr)>, field) + sizeof((structPtr)->field)))

namespace pascaljuce
{
// Limits on untrusted input (project state, library declarations).
constexpr size_t maxStateBytes = 64u * 1024u * 1024u;
constexpr int maxParameters = 4096;
constexpr int maxMidiEventsPerBlock = 16384;
constexpr int midiOutBytes = 65536;

// Text from outside (the Pascal library, project files) becomes a juce::String only if it is
// well-formed UTF-8 - JUCE trusts its input (see pascaljuce_utf8.h).
static juce::String safeText(const char* s, size_t maxBytes)
{
    if (s == nullptr)
        return {};
    const size_t n = strnlen(s, maxBytes);
    return isStrictUtf8(s, n) ? juce::String::fromUTF8(s, (int) n) : juce::String();
}

static bool isSafeText(const char* s, size_t maxBytes)
{
    return s == nullptr || isStrictUtf8(s, strnlen(s, maxBytes));
}


//==============================================================================
/* Pascal code must never run with unmasked FP exceptions on a host thread,
   and must never leave its own FP settings behind. Every call into the
   library masks exceptions and restores the caller's state afterwards
   (FTZ/DAZ bits are preserved). */
struct ScopedFpState
{
#if JUCE_INTEL
    ScopedFpState() noexcept : saved(_mm_getcsr())
    {
        _mm_setcsr(saved | 0x1F80u);
       #if defined(_M_IX86)
        _controlfp_s(&saved87, 0, 0); // 32-bit x86: the x87 unit has its own exception mask
        unsigned int ignored;
        _controlfp_s(&ignored, _MCW_EM, _MCW_EM);
       #endif
    }
    ~ScopedFpState() noexcept
    {
       #if defined(_M_IX86)
        unsigned int ignored;
        _controlfp_s(&ignored, saved87, _MCW_EM);
       #endif
        _mm_setcsr(saved);
    }
    unsigned int saved;
   #if defined(_M_IX86)
    unsigned int saved87 = 0;
   #endif
#endif
};

//==============================================================================
struct ParamSpec
{
    juce::String id, name, label;
    juce::StringArray choices;
    int kind = JCP_PARAM_FLOAT;
    bool automatable = true;
    int versionHint = 1;
    float minValue = 0, maxValue = 1, defaultValue = 0, step = 0;
};

static juce::File ownModuleFile()
{
#if JUCE_WINDOWS
    HMODULE module = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&ownModuleFile), &module);
    std::vector<wchar_t> path(32768);
    const DWORD length = GetModuleFileNameW(module, path.data(), (DWORD) path.size());
    return juce::File(juce::String(path.data(), (size_t) length));
#else
    Dl_info info {};
    dladdr(reinterpret_cast<void*>(&ownModuleFile), &info);
    return juce::File(juce::String::fromUTF8(info.dli_fname != nullptr ? info.dli_fname : ""));
#endif
}

static juce::String lastOsError()
{
#if JUCE_WINDOWS
    const DWORD code = GetLastError();
    wchar_t* text = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr,
                   code, 0, reinterpret_cast<LPWSTR>(&text), 0, nullptr);
    juce::String message = text != nullptr ? juce::String(text).trim() : juce::String();
    if (text != nullptr)
        LocalFree(text);
    return "error " + juce::String((int) code) + (message.isNotEmpty() ? ": " + message : juce::String());
#else
    const char* message = dlerror();
    return message != nullptr ? juce::String::fromUTF8(message) : juce::String("unknown error");
#endif
}

static bool isValidParameterId(const juce::String& id)
{
    if (id.isEmpty() || id.length() > 128)
        return false;
    for (auto c : id)
        if (! (juce::CharacterFunctions::isLetterOrDigit(c) && c < 128) && c != '_' && c != '-' && c != '.')
            return false;
    return true;
}

static bool isValidMidiMessage(const uint8_t* data, int size)
{
    if (data == nullptr || size <= 0 || (data[0] & 0x80) == 0)
        return false;
    if (data[0] == 0xF0)
    {
        if (size < 2 || data[size - 1] != 0xF7)
            return false;
        for (int i = 1; i < size - 1; ++i)
            if ((data[i] & 0x80) != 0)
                return false;
        return true;
    }
    if (data[0] == 0xF7 || data[0] == 0xFF)
        return false;
    if (size != juce::MidiMessage::getMessageLengthFromFirstByte(data[0]))
        return false;
    for (int i = 1; i < size; ++i)
        if ((data[i] & 0x80) != 0)
            return false;
    return true;
}

/* The plug-in library, loaded once per process and never unloaded (unloading
   a language runtime during host shutdown is a classic source of crashes). */
class PascalLibrary
{
public:
    static PascalLibrary& get()
    {
        static PascalLibrary instance;
        return instance;
    }

    bool ok() const noexcept { return factory.create != nullptr; }

    jcp_plugin_factory factory {};
    std::vector<ParamSpec> params;
    juce::String error;
    juce::File path;

private:
    PascalLibrary()
    {
        path = ownModuleFile().getSiblingFile(PASCALJUCE_PLUGIN_LIBRARY);
        void* entryAddress = load();
        if (entryAddress == nullptr)
            return;
        initialise(reinterpret_cast<jcp_plugin_entry_fn>(entryAddress));
        if (error.isNotEmpty())
            factory = {};
    }

    /* Reads the library through a handle that denies writers, verifies its
       hash (if configured), and loads it while the handle is still held, so
       the file cannot be swapped between the check and the load. Only System32
       is searched for its dependencies (never the bundle folder). */
    void* load()
    {
        const auto fullPath = path.getFullPathName();
        void* entryAddress = nullptr;
        std::fenv_t env;
        std::fegetenv(&env);
        ScopedFpState fpGuard;

#if JUCE_WINDOWS
        HANDLE file = CreateFileW(fullPath.toWideCharPointer(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            error = "Cannot open " + fullPath + " (" + lastOsError() + ")";
            return nullptr;
        }

       #ifdef PASCALJUCE_PLUGIN_SHA256
        if (! verifyHash(file))
        {
            CloseHandle(file);
            return nullptr;
        }
       #endif

        // Load through the final path of the handle we hashed (junctions and
        // symlinks resolved), resolving the library's own dependencies from
        // System32 only - never from the (possibly user-writable) bundle folder.
        std::vector<wchar_t> finalPath(32768);
        const DWORD finalLength = GetFinalPathNameByHandleW(file, finalPath.data(), (DWORD) finalPath.size(),
                                                           FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (finalLength == 0 || finalLength >= finalPath.size())
        {
            error = "Cannot resolve " + fullPath + " (" + lastOsError() + ")";
            CloseHandle(file);
            return nullptr;
        }
        auto* module = LoadLibraryExW(finalPath.data(), nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (module == nullptr)
        {
            error = "Cannot load " + fullPath + " (" + lastOsError() + ")";
        }
        else if (! isSameFile(file, module))
        {
            // The file mapped as the module is not the one we hashed: refuse it.
            FreeLibrary(module);
            error = path.getFileName() + " changed while it was being loaded; refusing to use it";
        }
        else
        {
            entryAddress = reinterpret_cast<void*>(GetProcAddress(module, JCP_ENTRY_NAME));
        }
        CloseHandle(file);
#else
        const int fd = open(fullPath.toRawUTF8(), O_RDONLY | O_CLOEXEC);
        if (fd < 0)
        {
            error = "Cannot open " + fullPath;
            return nullptr;
        }
       #ifdef PASCALJUCE_PLUGIN_SHA256
        if (! verifyHash(fd))
        {
            close(fd);
            return nullptr;
        }
       #endif
        dlerror();
       #if defined(__linux__)
        // Load the very file descriptor we hashed: no window to swap the file.
        // glibc reuses an already-loaded object with the same name string, so the
        // "/proc/self/fd/N" name must be unique in this process: move the descriptor
        // to a number no loaded object uses, and keep it open for ever (the library is
        // never unloaded, so the name stays unique).
        int loadFd = fd;
        for (int attempt = 0; attempt < 64; ++attempt)
        {
            const auto candidate = "/proc/self/fd/" + std::to_string(loadFd);
            void* existing = dlopen(candidate.c_str(), RTLD_NOW | RTLD_NOLOAD);
            if (existing == nullptr)
                break;
            dlclose(existing);
            const int moved = fcntl(fd, F_DUPFD_CLOEXEC, 1000 + attempt * 37);
            if (loadFd != fd)
                close(loadFd);
            loadFd = moved;
            if (loadFd < 0)
                break;
        }
        void* module = nullptr;
        if (loadFd >= 0)
        {
            const auto viaFd = "/proc/self/fd/" + std::to_string(loadFd);
            module = dlopen(viaFd.c_str(), RTLD_NOW | RTLD_LOCAL);
        }
        if (module == nullptr)
        {
            if (loadFd >= 0 && loadFd != fd)
                close(loadFd); // fd itself is closed below
        }
        else if (loadFd == fd)
        {
            fd = -1; // keep the loaded descriptor open for ever (its name must stay unique)
        }
        // else: loadFd stays open for ever; the original fd is closed below
       #else
        // No load-from-descriptor on macOS: dlopen by path, then confirm the
        // loaded image is the file we hashed (same device and inode).
        auto* module = dlopen(fullPath.toRawUTF8(), RTLD_NOW | RTLD_LOCAL);
        if (module != nullptr && ! isSameFile(fd, dlsym(module, JCP_ENTRY_NAME)))
        {
            dlclose(module);
            module = nullptr;
            error = path.getFileName() + " changed while it was being loaded; refusing to use it";
        }
       #endif
        if (fd >= 0)
            close(fd);
        if (module == nullptr && error.isEmpty())
            error = "Cannot load " + fullPath + " (" + lastOsError() + ")";
        else if (module != nullptr)
            entryAddress = dlsym(module, JCP_ENTRY_NAME);
#endif
        std::fesetenv(&env); // the language runtime may have changed FP settings while loading

        if (error.isEmpty() && entryAddress == nullptr)
            error = path.getFileName() + " does not export " JCP_ENTRY_NAME;
        return error.isEmpty() ? entryAddress : nullptr;
    }

#if JUCE_WINDOWS
    // True if the module's image file is the same file object as `hashed`.
    static bool isSameFile(HANDLE hashed, HMODULE module)
    {
        std::vector<wchar_t> modulePath(32768);
        const DWORD n = GetModuleFileNameW(module, modulePath.data(), (DWORD) modulePath.size());
        if (n == 0 || n >= modulePath.size())
            return false;
        HANDLE mapped = CreateFileW(modulePath.data(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (mapped == INVALID_HANDLE_VALUE)
            return false;
        BY_HANDLE_FILE_INFORMATION a {}, b {};
        const bool same = GetFileInformationByHandle(hashed, &a) && GetFileInformationByHandle(mapped, &b)
                       && a.dwVolumeSerialNumber == b.dwVolumeSerialNumber
                       && a.nFileIndexHigh == b.nFileIndexHigh && a.nFileIndexLow == b.nFileIndexLow;
        CloseHandle(mapped);
        return same;
    }
#elif ! defined(__linux__)
    static bool isSameFile(int hashed, void* symbolInModule)
    {
        Dl_info info {};
        struct stat a {}, b {};
        return symbolInModule != nullptr && dladdr(symbolInModule, &info) != 0 && info.dli_fname != nullptr
            && fstat(hashed, &a) == 0 && stat(info.dli_fname, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino;
    }
#endif

#ifdef PASCALJUCE_PLUGIN_SHA256
    bool checkDigest(const juce::MemoryBlock& contents)
    {
        const auto actual = juce::SHA256(contents.getData(), contents.getSize()).toHexString();
        const juce::String expected(PASCALJUCE_PLUGIN_SHA256);
        if (! actual.equalsIgnoreCase(expected))
        {
            error = path.getFileName() + " failed its integrity check (it was modified or replaced after the build). "
                    "Reinstall the plug-in.";
            return false;
        }
        return true;
    }

   #if JUCE_WINDOWS
    bool verifyHash(HANDLE file)
    {
        LARGE_INTEGER size {};
        if (! GetFileSizeEx(file, &size) || size.QuadPart <= 0 || size.QuadPart > 512 * 1024 * 1024)
        {
            error = "Unexpected size for " + path.getFullPathName();
            return false;
        }
        juce::MemoryBlock contents((size_t) size.QuadPart);
        DWORD read = 0;
        if (! ReadFile(file, contents.getData(), (DWORD) contents.getSize(), &read, nullptr) || read != contents.getSize())
        {
            error = "Cannot read " + path.getFullPathName() + " (" + lastOsError() + ")";
            return false;
        }
        return checkDigest(contents);
    }
   #else
    bool verifyHash(int fd)
    {
        juce::MemoryOutputStream contents;
        char chunk[65536];
        for (;;)
        {
            const auto n = read(fd, chunk, sizeof(chunk));
            if (n < 0)
            {
                error = "Cannot read " + path.getFullPathName();
                return false;
            }
            if (n == 0)
                break;
            contents.write(chunk, (size_t) n);
            if (contents.getDataSize() > 512u * 1024u * 1024u)
            {
                error = "Unexpected size for " + path.getFullPathName();
                return false;
            }
        }
        return checkDigest(contents.getMemoryBlock());
    }
   #endif
#endif

    void initialise(jcp_plugin_entry_fn entry)
    {
        jcp_plugin_factory candidate {};
        candidate.struct_size = (int32_t) sizeof(candidate);
        int32_t result = -1;
        {
            ScopedFpState fpGuard;
            result = entry(JCP_ABI_VERSION, &candidate);
        }

        if (result != 0)
        {
            error = path.getFileName() + " refused to load";
            if (JCP_HAS_FIELD(&candidate, error_message) && candidate.error_message != nullptr)
                error << ": " << safeText(candidate.error_message, 4096);
            return;
        }
        if (candidate.abi_version != JCP_ABI_VERSION || ! JCP_HAS_FIELD(&candidate, create)
            || candidate.create == nullptr || candidate.get_parameter_count == nullptr
            || candidate.get_parameter_info == nullptr)
        {
            error = path.getFileName() + " has an incompatible ABI (library " + juce::String(candidate.abi_version)
                  + ", wrapper " + juce::String(JCP_ABI_VERSION) + ")";
            return;
        }
        if (JCP_HAS_FIELD(&candidate, kind) && candidate.kind != PASCALJUCE_PLUGIN_KIND)
        {
            static const char* names[] = { "instrument", "effect", "midi_effect" };
            const auto name = [](int k) { return juce::isPositiveAndBelow(k, 3) ? names[k] : "unknown"; };
            error = path.getFileName() + " declares kind '" + name(candidate.kind) + "' but the plug-in was built as '"
                  + name(PASCALJUCE_PLUGIN_KIND) + "' (KIND in CMake)";
            return;
        }

        ScopedFpState fpGuard;
        const int count = candidate.get_parameter_count();
        if (count < 0 || count > maxParameters)
        {
            error = "Unreasonable parameter count " + juce::String(count);
            return;
        }

        std::set<juce::String> ids;
        for (int i = 0; i < count; ++i)
        {
            jcp_parameter_info info {};
            info.struct_size = (int32_t) sizeof(info);
            if (candidate.get_parameter_info(i, &info) != 0)
            {
                error = "Parameter " + juce::String(i) + " could not be described";
                return;
            }

            if (! isSafeText(info.id, 4096) || ! isSafeText(info.name, 4096) || ! isSafeText(info.label, 4096)
                || ! isSafeText(info.choices, 4096))
            {
                error = "Parameter " + juce::String(i) + " has text that is not valid UTF-8";
                return;
            }
            const auto text = [](const char* s) { return safeText(s, 4096); };
            ParamSpec spec;
            spec.id = text(info.id);
            spec.name = text(info.name);
            spec.label = text(info.label);
            if (info.kind == JCP_PARAM_CHOICE)
                spec.choices = juce::StringArray::fromTokens(text(info.choices), "|", {});
            spec.kind = info.kind;
            spec.automatable = (info.flags & JCP_PARAM_FLAG_AUTOMATABLE) != 0;
            spec.versionHint = std::max(1, (int) info.version_hint);
            spec.minValue = info.min_value;
            spec.maxValue = info.max_value;
            spec.defaultValue = info.default_value;
            spec.step = info.step;

            const auto problem = validate(spec);
            if (problem.isNotEmpty())
            {
                error = "Parameter " + juce::String(i) + " ('" + spec.id + "'): " + problem;
                return;
            }
            if (! ids.insert(spec.id).second)
            {
                error = "Duplicate parameter id '" + spec.id + "'";
                return;
            }
            if (spec.name.isEmpty())
                spec.name = spec.id;
            params.push_back(spec);
        }

        factory = candidate;
    }

    static juce::String validate(const ParamSpec& s)
    {
        if (! isValidParameterId(s.id))
            return "id must be 1-128 characters of A-Z a-z 0-9 _ - .";
        const auto finite = [](float v) { return std::isfinite(v) && std::abs(v) <= 1.0e30f; };
        if (! finite(s.minValue) || ! finite(s.maxValue) || ! finite(s.defaultValue) || ! finite(s.step))
            return "range values must be finite (|v| <= 1e30)";
        // Integer kinds are converted with (int): keep them whole and well inside int range.
        const auto whole = [](float v) { return std::abs(v) <= 16777216.0f && std::floor(v) == v; };
        switch (s.kind)
        {
            case JCP_PARAM_FLOAT:
                if (! (s.minValue < s.maxValue)) return "min must be < max";
                if (s.step < 0) return "step must be >= 0";
                break;
            case JCP_PARAM_INT:
                if (! whole(s.minValue) || ! whole(s.maxValue) || ! whole(s.defaultValue))
                    return "integer parameter values must be whole numbers within +-2^24";
                if (! (s.minValue < s.maxValue)) return "min must be < max";
                break;
            case JCP_PARAM_BOOL:
                break;
            case JCP_PARAM_CHOICE:
                if (s.choices.size() < 2) return "a choice needs at least 2 options";
                if (s.choices.size() > 4096) return "a choice may have at most 4096 options";
                if (! whole(s.defaultValue)) return "choice default must be a whole index";
                break;
            default:
                return "unknown kind " + juce::String(s.kind);
        }
        return {};
    }
};

//==============================================================================
class ErrorEditor final : public juce::AudioProcessorEditor
{
public:
    ErrorEditor(juce::AudioProcessor& p, juce::String text) : AudioProcessorEditor(p), message(std::move(text))
    {
        setSize(520, 180);
    }

    void paint(juce::Graphics& g) override
    {
        g.fillAll(juce::Colours::darkred.darker(0.6f));
        g.setColour(juce::Colours::white);
        g.setFont(15.0f);
        g.drawFittedText(message, getLocalBounds().reduced(16), juce::Justification::centred, 8);
    }

private:
    juce::String message;
};

//==============================================================================
// Library calls in progress on this thread, innermost last (see LibraryCall).
constexpr int maxLibraryCallDepth = 8;
thread_local const void* libraryCallStack[maxLibraryCallDepth] {};
thread_local int libraryCallDepth = 0;

// Custom editors (defined after the processor).
struct EditorSession;
struct EditorApi;
class PascalEditor;
static void finishSession(const std::shared_ptr<EditorSession>& s) noexcept;

class PascalPluginProcessor final : public juce::AudioProcessor, private juce::AsyncUpdater
{
    friend struct EditorSession;
    friend struct EditorApi;
    friend class PascalEditor;
    friend void finishSession(const std::shared_ptr<EditorSession>& s) noexcept;

public:
    PascalPluginProcessor() : AudioProcessor(makeBuses())
    {
        auto& library = PascalLibrary::get();

        for (size_t i = 0; i < library.params.size(); ++i)
        {
            auto* parameter = makeParameter(library.params[i], (int) i);
            parameters.push_back(parameter);
            addParameter(parameter);
        }
        parameterValues.resize(parameters.size(), 0.0f);
        gestureActive = std::make_unique<std::atomic<bool>[]>(std::max<size_t>(1, parameters.size()));
        pendingValue = std::make_unique<std::atomic<float>[]>(std::max<size_t>(1, parameters.size()));
        pendingDirty = std::make_unique<std::atomic<bool>[]>(std::max<size_t>(1, parameters.size()));
        hostGestureOpen = std::make_unique<bool[]>(std::max<size_t>(1, parameters.size()));
        midiEvents.reserve(maxMidiEventsPerBlock);
        chunkEvents.reserve(maxMidiEventsPerBlock);
        midiOut.ensureSize(midiOutBytes);

        if (! library.ok())
        {
            juce::Logger::writeToLog("PascalJUCE: " + library.error);
            return;
        }

        vtable.struct_size = (int32_t) sizeof(vtable);
        ScopedFpState fpGuard;
        void* created = nullptr;
        {
            LibraryCall inLibrary(*this);
            created = library.factory.create(&hostApi(), reinterpret_cast<jcp_host*>(this), &vtable);
        }
        if (created != nullptr && vtable.destroy != nullptr && vtable.process != nullptr)
            instance = created;
        else
            creationFailed = true; // an instance without destroy/process is leaked by design
    }

    ~PascalPluginProcessor() override
    {
        // Hosts must close the editor first; if one is still open, its library
        // object goes now (or is abandoned, never called again), before the
        // instance it belongs to.
        detachEditors();
        destroying.store(true, std::memory_order_release);
        delivery->alive.store(false, std::memory_order_release); // a delivery in progress stops touching us
        cancelPendingUpdate();
        const auto keepDelivery = delivery;
        const std::lock_guard<std::recursive_mutex> waitForDelivery(keepDelivery->mutex); // one may be running on the message thread
        if (instance != nullptr)
        {
            const juce::ScopedLock lock(getCallbackLock()); // a misbehaving host may still be in process()
            prepared.store(false, std::memory_order_release);
            if (insideLibraryCall())
            {
                // Destroyed from inside one of its own library calls (e.g. a host
                // reacting synchronously to an editor callback): freeing it now
                // would pull the object out from under the Pascal code still
                // running on this stack. Leak it instead.
                juce::Logger::writeToLog("PascalJUCE: plug-in destroyed from inside its own callback; instance leaked");
            }
            else
            {
                ScopedFpState fpGuard;
                LibraryCall inLibrary(*this);
                vtable.destroy(instance);
            }
            instance = nullptr;
        }
        cancelPendingUpdate(); // destroy may have requested one
    }

    //==========================================================================
    const juce::String getName() const override { return JucePlugin_Name; }
    bool acceptsMidi() const override { return JucePlugin_WantsMidiInput != 0; }
    bool producesMidi() const override { return JucePlugin_ProducesMidiOutput != 0; }
    bool isMidiEffect() const override { return JucePlugin_IsMidiEffect != 0; }

    double getTailLengthSeconds() const override
    {
        if (instance == nullptr || vtable.get_tail_seconds == nullptr)
            return 0.0;
        ScopedFpState fpGuard;
        LibraryCall inLibrary(*this);
        const double tail = vtable.get_tail_seconds(instance);
        return std::isfinite(tail) ? juce::jlimit(0.0, 3600.0, tail) : 0.0;
    }

    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram(int) override {}
    const juce::String getProgramName(int) override { return "Default"; }
    void changeProgramName(int, const juce::String&) override {}

    bool isBusesLayoutSupported(const BusesLayout& layouts) const override
    {
       #if PASCALJUCE_PLUGIN_KIND == JCP_KIND_MIDI_EFFECT
        return layouts.getMainOutputChannels() == 0 || layouts.getMainOutputChannelSet() == juce::AudioChannelSet::stereo();
       #else
        const auto out = layouts.getMainOutputChannelSet();
        if (out != juce::AudioChannelSet::mono() && out != juce::AudioChannelSet::stereo())
            return false;
        #if PASCALJUCE_PLUGIN_KIND == JCP_KIND_EFFECT
        return layouts.getMainInputChannelSet() == out;
        #else
        return true;
        #endif
       #endif
    }

    //==========================================================================
    void prepareToPlay(double sampleRate, int maximumExpectedSamplesPerBlock) override
    {
        if (insideLibraryCall())
            return; // re-entered from inside a library call (see LibraryCall)
        midiOut.ensureSize(midiOutBytes);
        // Host values: Pascal code divides by the rate and sizes buffers from the block size.
        if (! std::isfinite(sampleRate) || sampleRate < 1.0 || sampleRate > 10.0e6)
            sampleRate = 44100.0;
        maximumExpectedSamplesPerBlock =
            juce::jlimit(1, 1 << 20, maximumExpectedSamplesPerBlock > 0 ? maximumExpectedSamplesPerBlock : 512);
        // Everything under the lock, so a block can never see the new library state
        // with the old size (a re-prepare to a smaller size without a release).
        const juce::ScopedLock lock(getCallbackLock()); // never concurrently with process()
        prepared.store(false, std::memory_order_release);
        if (instance != nullptr && vtable.prepare != nullptr)
        {
            ScopedFpState fpGuard;
            LibraryCall inLibrary(*this);
            vtable.prepare(instance, sampleRate, maximumExpectedSamplesPerBlock);
        }
        preparedSampleRate.store(sampleRate, std::memory_order_release);
        preparedBlockSize.store(maximumExpectedSamplesPerBlock, std::memory_order_release);
        prepared.store(true, std::memory_order_release);
        // Latency set in Prepare must be visible when the host asks right after
        // activation (offline renders do not pump messages first). Safe here: the
        // library call has returned. requestDelivery defers if not on the message thread.
        requestDelivery();
    }

    // Bypassed blocks never reach the library, but their MIDI goes to the host: give
    // it the same validation, position clamping and size cap as normal output.
    void processBlockBypassed(juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi) override
    {
        AudioProcessor::processBlockBypassed(buffer, midi);
        if (! producesMidi())
        {
            midi.clear();
            return;
        }
        midiOut.clear();
        const int last = std::max(0, buffer.getNumSamples() - 1);
        for (const auto metadata : midi)
        {
            if (! isValidMidiMessage(metadata.data, metadata.numBytes)
                || (int64_t) midiOut.data.size() + metadata.numBytes + 8 > (int64_t) midiOutBytes)
                continue;
            midiOut.addEvent(metadata.data, metadata.numBytes, juce::jlimit(0, last, metadata.samplePosition));
        }
        midi.clear();
        midi.addEvents(midiOut, 0, -1, 0);
    }

    void releaseResources() override
    {
        if (insideLibraryCall())
            return;
        // Under the callback lock: some hosts (FL Studio's Patcher, per JUCE) call
        // process() during deactivation, and Release frees what Process uses.
        const juce::ScopedLock lock(getCallbackLock());
        prepared.store(false, std::memory_order_release);
        if (instance != nullptr && vtable.release != nullptr)
        {
            ScopedFpState fpGuard;
            LibraryCall inLibrary(*this);
            vtable.release(instance);
        }
    }

    void reset() override
    {
        if (insideLibraryCall())
            return;
        if (instance != nullptr && vtable.reset != nullptr)
        {
            // AU hosts call Reset from non-render threads during playback, and some
            // VST3 hosts from the UI thread: never at the same time as process().
            const juce::ScopedLock lock(getCallbackLock());
            if (! prepared.load(std::memory_order_acquire)) // checked under the lock: Release may just have run
                return;
            ScopedFpState fpGuard;
            LibraryCall inLibrary(*this);
            vtable.reset(instance);
        }
    }

    void processBlock(juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi) override
    {
        juce::ScopedNoDenormals noDenormals;
        const int numSamples = buffer.getNumSamples();
        if (numSamples < 0)
            return; // negative sample count from the host: nothing to do
        if (insideLibraryCall())
        {
            buffer.clear();
            midi.clear();
            return;
        }
        const int numIn = getTotalNumInputChannels();
        const int numOut = getTotalNumOutputChannels();

        for (int ch = numIn; ch < std::min(numOut, buffer.getNumChannels()); ++ch)
            buffer.clear(ch, 0, numSamples);

        if (instance == nullptr || ! prepared.load(std::memory_order_acquire)) // never Process before Prepare
        {
            buffer.clear();
            midi.clear();
            return;
        }

        for (size_t i = 0; i < parameters.size(); ++i)
            parameterValues[i] = plainValue(*parameters[i]);

        int dropped = 0;
        midiEvents.clear();
        for (const auto metadata : midi)
        {
            // The ABI promises one complete message per event; hosts' MidiBuffers
            // can hold truncated, meta or unterminated SysEx data. Drop those.
            if ((int) midiEvents.size() >= maxMidiEventsPerBlock // never allocate on the audio thread
                || ! isValidMidiMessage(metadata.data, metadata.numBytes))
            {
                ++dropped;
                continue;
            }
            midiEvents.push_back({ metadata.data, metadata.numBytes,
                                   juce::jlimit(0, std::max(0, numSamples - 1), metadata.samplePosition) });
        }

        fillTransport();
        midiOut.clear();

        // Process never gets more samples than Prepare promised: a larger host block
        // is processed in chunks (channel pointers offset, MIDI split and re-based),
        // so Pascal buffers sized from MaxBlockSize can never be overrun.
        const int numChannels = std::min(buffer.getNumChannels(), (int) maxChannels);
        const int chunkLimit = std::max(1, preparedBlockSize.load(std::memory_order_acquire));
        float* const* channels = buffer.getArrayOfWritePointers();
        size_t nextEvent = 0;
        int start = 0;
        do
        {
            const int length = std::min(chunkLimit, numSamples - start);
            for (int ch = 0; ch < numChannels; ++ch)
                chunkChannels[ch] = channels[ch] + start;

            chunkEvents.clear();
            while (nextEvent < midiEvents.size()
                   && (midiEvents[nextEvent].sample_position < start + length || start + length >= numSamples))
            {
                auto event = midiEvents[nextEvent++];
                event.sample_position = juce::jlimit(0, std::max(0, length - 1), event.sample_position - start);
                chunkEvents.push_back(event);
            }

            currentBlockSize = length;
            currentChunkStart = start;

            jcp_process_context context {};
            context.struct_size = (int32_t) sizeof(context);
            context.num_samples = length;
            context.channels = chunkChannels;
            context.midi_events = chunkEvents.data();
            context.parameters = parameterValues.data();
            // Each chunk gets the transport at its own start, not the host block's.
            chunkTransport = transport;
            if (start > 0)
            {
                const double rate = preparedSampleRate.load(std::memory_order_acquire);
                chunkTransport.time_in_samples += start;
                chunkTransport.time_in_seconds += start / rate;
                chunkTransport.ppq_position += start * chunkTransport.bpm / (60.0 * rate);
            }
            context.transport = &chunkTransport;
            context.num_channels = numChannels;
            context.num_input_channels = std::min(numIn, numChannels);
            context.num_output_channels = std::min(numOut, numChannels);
            context.num_midi_events = (int32_t) chunkEvents.size();
            context.num_parameters = (int32_t) parameterValues.size();
            context.midi_event_size = (int32_t) sizeof(jcp_midi_event);
            context.midi_events_dropped = start == 0 ? dropped : 0;
            context.is_non_realtime = isNonRealtime() ? 1 : 0;

            processThread.store(juce::Thread::getCurrentThreadId(), std::memory_order_release);
            {
                ScopedFpState fpGuard;
                LibraryCall inLibrary(*this);
                vtable.process(instance, &context);
            }
            processThread.store(nullptr, std::memory_order_release);

            start += length;
        } while (start < numSamples);
        currentChunkStart = 0;

        // A buggy library must not push NaN/Inf into the host's mix.
        for (int ch = 0; ch < numChannels; ++ch)
            for (int i = 0; i < numSamples; ++i)
                if (! std::isfinite(channels[ch][i]))
                    channels[ch][i] = 0.0f;

        // Copy (not swap) so our pre-sized buffer stays ours. -1: everything, also
        // for zero-length (parameter-flush) blocks.
        midi.clear();
        if (producesMidi() && ! midiOut.isEmpty())
            midi.addEvents(midiOut, 0, -1, 0);
    }

    using AudioProcessor::processBlock;

    //==========================================================================
    bool hasEditor() const override { return true; }

    juce::AudioProcessorEditor* createEditor() override
    {
        auto& library = PascalLibrary::get();
        if (! library.ok())
            return new ErrorEditor(*this, "PascalJUCE could not load the plug-in library:\n" + library.error
                                              + "\n\nYour settings are kept unchanged until it loads again.");
        if (instance == nullptr)
            return new ErrorEditor(*this, library.path.getFileName() + " failed to create a plug-in instance.");
        if (auto* custom = createCustomEditor())
            return custom;
        return new juce::GenericAudioProcessorEditor(*this);
    }

    // The library's own editor, or nullptr if it has none (defined after PascalEditor).
    juce::AudioProcessorEditor* createCustomEditor();
    void detachEditors() noexcept;

    //==========================================================================
    void getStateInformation(juce::MemoryBlock& destData) override
    {
        if (insideLibraryCall())
            return;
        // Never let an exception (e.g. bad_alloc) escape into the host.
        try
        {
            // Not operational: hand back exactly what we were given, so saving a
            // project while the library is missing does not wipe the user's patch.
            if (instance == nullptr)
            {
                const juce::ScopedLock lock(preservedLock); // hosts may save and restore on different threads
                destData = preservedState;
                return;
            }

            std::vector<std::pair<std::string, double>> values;
            values.reserve(parameters.size() + 1);
            for (auto* parameter : parameters)
                values.emplace_back(parameter->getParameterID().toStdString(),
                                    (double) plainValue(*parameter));
            // The editor's scale, as one more value under a reserved id: older
            // wrappers read it as an unknown parameter and ignore it.
            const float scale = editorScale.load(std::memory_order_relaxed);
            if (scale > 0.0f && ! hasParameterId(editorScaleStateId))
                values.emplace_back(editorScaleStateId, (double) scale);

            StateWriter writer;
            if (vtable.get_state != nullptr)
            {
                const juce::ScopedLock lock(getCallbackLock()); // never concurrently with process()
                ScopedFpState fpGuard;
                // The handle is the processor, which outlives the call; it points at the
                // writer only while get_state runs, so a library that keeps it and writes
                // later (or from another thread) is ignored instead of hitting a dead stack.
                openWriter = &writer;
                openWriterThread = juce::Thread::getCurrentThreadId();
                LibraryCall inLibrary(*this);
                vtable.get_state(instance, &writeState, this);
                openWriter = nullptr;
                openWriterThread = nullptr;
            }
            if (writer.overflow)
            {
                juce::Logger::writeToLog("PascalJUCE: custom state larger than 64 MB was discarded");
                writer.data.reset();
            }

            try
            {
                const auto encoded = state::encode(values, static_cast<const uint8_t*>(writer.data.getData()),
                                                   writer.data.getSize());
                destData.replaceAll(encoded.data(), encoded.size());
            }
            catch (...)
            {
                // Out of memory with a large custom blob: keep at least the parameters
                // rather than handing the host an empty state that wipes the patch.
                writer.data.reset();
                juce::Logger::writeToLog("PascalJUCE: could not save custom state; saved parameters only");
                const auto encoded = state::encode(values, nullptr, 0);
                destData.replaceAll(encoded.data(), encoded.size());
            }
        }
        catch (...)
        {
            destData.reset();
        }
    }

    void setStateInformation(const void* data, int sizeInBytes) override
    {
        if (insideLibraryCall())
            return;
        try
        {
            if (data == nullptr || sizeInBytes <= 0 || (size_t) sizeInBytes > maxStateBytes * 2)
                return;

            if (instance == nullptr)
            {
                const juce::ScopedLock lock(preservedLock);
                preservedState.replaceAll(data, (size_t) sizeInBytes);
                return;
            }

            // Strict parser for exactly what getStateInformation writes; JUCE's XML and
            // base64 readers never see untrusted state (see pascaljuce_state.h).
            state::Decoded decoded;
            if (! state::decode(data, (size_t) sizeInBytes, (size_t) maxParameters * 2, maxStateBytes, decoded))
                return;

            std::map<std::string, double> stored; // first occurrence of an id wins
            for (const auto& [id, value] : decoded.params)
                stored.emplace(id, value);

            // The editor's scale (untrusted like the rest: finite, clamped).
            const auto scale = stored.find(editorScaleStateId);
            if (scale != stored.end() && std::isfinite(scale->second) && ! hasParameterId(editorScaleStateId))
                editorScale.store((float) juce::jlimit((double) JCP_EDITOR_MIN_SCALE, (double) JCP_EDITOR_MAX_SCALE,
                                                       scale->second),
                                  std::memory_order_relaxed);

            for (auto* parameter : parameters)
            {
                float value = parameter->convertFrom0to1(parameter->getDefaultValue()); // missing -> default
                const auto found = stored.find(parameter->getParameterID().toStdString());
                if (found != stored.end())
                    value = (float) juce::jlimit(-1.0e30, 1.0e30, found->second);
                const auto& range = parameter->getNormalisableRange();
                value = juce::jlimit(range.start, range.end, value);
                parameter->setValueNotifyingHost(parameter->convertTo0to1(value));
            }

            if (vtable.set_state != nullptr)
            {
                const juce::ScopedLock lock(getCallbackLock()); // never concurrently with process()
                ScopedFpState fpGuard;
                LibraryCall inLibrary(*this);
                vtable.set_state(instance, decoded.custom.empty() ? nullptr : decoded.custom.data(),
                                 (int32_t) decoded.custom.size());
            }
        }
        catch (...)
        {
            // Hostile or corrupt state is ignored; the host must never see an exception.
        }
    }

private:
    // Reserved state id for the editor's scale; a library parameter of that id wins.
    static constexpr const char* editorScaleStateId = "pascaljuce.editor.scale";

    bool hasParameterId(const char* id) const
    {
        for (auto* parameter : parameters)
            if (parameter->getParameterID() == id)
                return true;
        return false;
    }

    struct StateWriter
    {
        juce::MemoryBlock data;
        bool overflow = false;
    };

    static BusesProperties makeBuses()
    {
       #if PASCALJUCE_PLUGIN_KIND == JCP_KIND_MIDI_EFFECT
        return BusesProperties();
       #elif PASCALJUCE_PLUGIN_KIND == JCP_KIND_EFFECT
        return BusesProperties().withInput("Input", juce::AudioChannelSet::stereo(), true)
                                .withOutput("Output", juce::AudioChannelSet::stereo(), true);
       #else
        return BusesProperties().withOutput("Output", juce::AudioChannelSet::stereo(), true);
       #endif
    }

    juce::String parameterText(int index, float value, int maximumLength) const
    {
        if (instance == nullptr || vtable.get_parameter_text == nullptr)
            return {};
        // The value comes from the host (VST3 getParamStringByValue, AU
        // ParameterStringFromValue) or a stored NaN: finite and in range only.
        if (index >= 0 && (size_t) index < parameters.size() && parameters[(size_t) index] != nullptr)
        {
            auto& parameter = *parameters[(size_t) index];
            const auto& range = parameter.getNormalisableRange();
            if (! std::isfinite(value))
                value = parameter.convertFrom0to1(juce::jlimit(0.0f, 1.0f, parameter.getDefaultValue()));
            value = std::isfinite(value) ? juce::jlimit(range.start, range.end, value) : range.start;
        }
        else if (! std::isfinite(value))
        {
            return {};
        }
        char buffer[256] = {};
        int32_t provided = 0;
        {
            ScopedFpState fpGuard;
            LibraryCall inLibrary(*this);
            provided = vtable.get_parameter_text(instance, index, value, buffer, (int32_t) sizeof(buffer));
        }
        if (provided == 0)
            return {};
        buffer[sizeof(buffer) - 1] = '\0';
        auto text = safeText(buffer, sizeof(buffer));
        return maximumLength > 0 ? text.substring(0, maximumLength) : text;
    }

    juce::RangedAudioParameter* makeParameter(const ParamSpec& spec, int index)
    {
        const juce::ParameterID id { spec.id, spec.versionHint };
        auto custom = [this, index](float value, int maximumLength) { return parameterText(index, value, maximumLength); };

        switch (spec.kind)
        {
            case JCP_PARAM_INT:
                return new juce::AudioParameterInt(id, spec.name, (int) spec.minValue, (int) spec.maxValue,
                                                   juce::jlimit((int) spec.minValue, (int) spec.maxValue, (int) spec.defaultValue),
                                                   juce::AudioParameterIntAttributes()
                                                       .withLabel(spec.label)
                                                       .withAutomatable(spec.automatable)
                                                       .withStringFromValueFunction([custom](int v, int len)
                                                       {
                                                           const auto t = custom((float) v, len);
                                                           return t.isNotEmpty() ? t : juce::String(v);
                                                       }));
            case JCP_PARAM_BOOL:
                return new juce::AudioParameterBool(id, spec.name, spec.defaultValue >= 0.5f,
                                                    juce::AudioParameterBoolAttributes()
                                                        .withLabel(spec.label)
                                                        .withAutomatable(spec.automatable));
            case JCP_PARAM_CHOICE:
                return new juce::AudioParameterChoice(id, spec.name, spec.choices,
                                                      juce::jlimit(0, spec.choices.size() - 1, (int) spec.defaultValue),
                                                      juce::AudioParameterChoiceAttributes()
                                                          .withLabel(spec.label)
                                                          .withAutomatable(spec.automatable));
            default:
                return new juce::AudioParameterFloat(id, spec.name,
                                                     juce::NormalisableRange<float>(spec.minValue, spec.maxValue, spec.step),
                                                     juce::jlimit(spec.minValue, spec.maxValue, spec.defaultValue),
                                                     juce::AudioParameterFloatAttributes()
                                                         .withLabel(spec.label)
                                                         .withAutomatable(spec.automatable)
                                                         .withStringFromValueFunction([custom](float v, int len)
                                                         {
                                                             const auto t = custom(v, len);
                                                             return t.isNotEmpty() ? t : juce::String(v, 2);
                                                         }));
        }
    }

    // A parameter's plain value, always finite and inside its declared range.
    // Hosts can deliver NaN (VST3 parameter changes, LV2 patch:Set) and JUCE's
    // clamps let it through; Pascal code indexing a table by a Choice value must
    // never see it.
    // The same for the normalised value (what editors see).
    static float sanitisedNormalised(const juce::RangedAudioParameter& parameter) noexcept
    {
        float normalised = parameter.getValue();
        if (! std::isfinite(normalised))
            normalised = parameter.getDefaultValue();
        return std::isfinite(normalised) ? juce::jlimit(0.0f, 1.0f, normalised) : 0.0f;
    }

    static float plainValue(juce::RangedAudioParameter& parameter) noexcept
    {
        float normalised = parameter.getValue();
        if (! std::isfinite(normalised))
            normalised = parameter.getDefaultValue();
        normalised = std::isfinite(normalised) ? juce::jlimit(0.0f, 1.0f, normalised) : 0.0f;
        const auto& range = parameter.getNormalisableRange();
        const float plain = parameter.convertFrom0to1(normalised);
        return std::isfinite(plain) ? juce::jlimit(range.start, range.end, plain) : range.start;
    }

    void fillTransport() noexcept

    {
        transport = {};
        transport.struct_size = (int32_t) sizeof(transport);
        transport.bpm = 120.0;
        transport.time_sig_numerator = 4;
        transport.time_sig_denominator = 4;

        if (auto* playHead = getPlayHead())
        {
            if (const auto position = playHead->getPosition())
            {
                transport.has_info = 1;
                transport.bpm = position->getBpm().orFallback(120.0);
                transport.ppq_position = position->getPpqPosition().orFallback(0.0);
                transport.ppq_bar_start = position->getPpqPositionOfLastBarStart().orFallback(0.0);
                transport.time_in_samples = position->getTimeInSamples().orFallback(0);
                transport.time_in_seconds = position->getTimeInSeconds().orFallback(0.0);
                transport.is_playing = position->getIsPlaying() ? 1 : 0;
                transport.is_recording = position->getIsRecording() ? 1 : 0;
                transport.is_looping = position->getIsLooping() ? 1 : 0;
                if (const auto sig = position->getTimeSignature())
                {
                    transport.time_sig_numerator = sig->numerator;
                    transport.time_sig_denominator = sig->denominator;
                }
            }
        }
        // Host (and, in LV2 graphs, upstream plug-in) data: keep it usable. A zero
        // denominator would be an integer division fault in Pascal code; NaN tempo
        // would become NaN audio.
        // Bounded so Pascal Trunc/Round of positions and 60 * rate / bpm stay far
        // inside Int64: 2^40 quarter notes or seconds is tens of thousands of years.
        constexpr double maxPosition = 1099511627776.0; // 2^40
        auto sanePosition = [](double v) { return std::isfinite(v) && std::abs(v) <= maxPosition ? v : 0.0; };
        if (! std::isfinite(transport.bpm) || transport.bpm < 1.0 || transport.bpm > 1000.0)
            transport.bpm = 120.0;
        transport.ppq_position = sanePosition(transport.ppq_position);
        transport.ppq_bar_start = sanePosition(transport.ppq_bar_start);
        if (transport.ppq_bar_start > transport.ppq_position)
            transport.ppq_bar_start = transport.ppq_position;
        transport.time_in_seconds = sanePosition(transport.time_in_seconds);
        constexpr int64_t maxSamples = int64_t{1} << 53;
        transport.time_in_samples = juce::jlimit(-maxSamples, maxSamples, (int64_t) transport.time_in_samples);
        const auto denominator = transport.time_sig_denominator;
        if (transport.time_sig_numerator < 1 || transport.time_sig_numerator > 64 || denominator < 1 || denominator > 64
            || (denominator & (denominator - 1)) != 0)
        {
            transport.time_sig_numerator = 4;
            transport.time_sig_denominator = 4;
        }
    }

    //==========================================================================
    // Host services. Every one is noexcept: a C++ exception must never unwind
    // through the Pascal frames that called us.
    static PascalPluginProcessor* self(jcp_host* host) noexcept
    {
        return reinterpret_cast<PascalPluginProcessor*>(host);
    }

    juce::RangedAudioParameter* parameterAt(int32_t index) const noexcept
    {
        return juce::isPositiveAndBelow(index, (int) parameters.size()) ? parameters[(size_t) index] : nullptr;
    }

    static void JCP_CALL writeState(void* writer, const void* data, int32_t size) noexcept
    {
        auto* p = static_cast<PascalPluginProcessor*>(writer);
        auto* w = p != nullptr && p->openWriterThread == juce::Thread::getCurrentThreadId() ? p->openWriter : nullptr;
        if (w == nullptr || data == nullptr || size <= 0 || w->overflow)
            return;
        if (w->data.getSize() + (size_t) size > maxStateBytes)
        {
            w->overflow = true;
            return;
        }
        try { w->data.append(data, (size_t) size); }
        catch (...) { w->overflow = true; }
    }

    static void JCP_CALL hostAddMidiOutput(jcp_host* host, const uint8_t* data, int32_t size, int32_t samplePosition) noexcept
    {
        auto* p = self(host);
        // Only the thread currently inside process() may add output (midiOut is not
        // thread-safe): calls from anywhere else are ignored.
        if (p == nullptr || p->processThread.load(std::memory_order_acquire) != juce::Thread::getCurrentThreadId()
            || ! isValidMidiMessage(data, size))
            return;
        try
        {
            // Bounded: a plug-in emitting in a loop must not grow memory on the audio thread.
            if ((int64_t) p->midiOut.data.size() + (int64_t) size + 8 > (int64_t) midiOutBytes)
                return;
            p->midiOut.addEvent(data, size, p->currentChunkStart
                                                + juce::jlimit(0, std::max(0, p->currentBlockSize - 1), (int) samplePosition));
        }
        catch (...)
        {
        }
    }

    static void JCP_CALL hostSetParameter(jcp_host* host, int32_t index, float value) noexcept
    {
        auto* p = self(host);
        auto* parameter = p != nullptr ? p->parameterAt(index) : nullptr;
        if (parameter == nullptr || ! std::isfinite(value))
            return;
        p->pendingValue[(size_t) index].store(value, std::memory_order_release);
        p->pendingDirty[(size_t) index].store(true, std::memory_order_release);
        p->requestDelivery();
    }

    static float JCP_CALL hostGetParameter(jcp_host* host, int32_t index) noexcept
    {
        auto* p = self(host);
        auto* parameter = p != nullptr ? p->parameterAt(index) : nullptr;
        return parameter != nullptr ? plainValue(*parameter) : 0.0f;
    }

    static void JCP_CALL hostSetLatency(jcp_host* host, int32_t samples) noexcept
    {
        if (auto* p = self(host))
        {
            p->pendingLatency.store(juce::jlimit(0, 1 << 24, (int) samples), std::memory_order_release);
            p->requestDelivery();
        }
    }

    static void JCP_CALL hostLog(jcp_host*, const char* message) noexcept
    {
        if (message == nullptr)
            return;
        try { juce::Logger::writeToLog(safeText(message, 4096)); }
        catch (...) {}
    }

    static double JCP_CALL hostGetSampleRate(jcp_host* host) noexcept
    {
        auto* p = self(host);
        return p != nullptr ? p->preparedSampleRate.load(std::memory_order_acquire) : 0.0; // the sanitised rate Prepare got
    }

    static void JCP_CALL hostBeginGesture(jcp_host* host, int32_t index) noexcept
    {
        auto* p = self(host);
        auto* parameter = p != nullptr ? p->parameterAt(index) : nullptr;
        if (parameter == nullptr || p->gestureActive[(size_t) index].exchange(true))
            return;
        p->requestDelivery();
    }

    static void JCP_CALL hostEndGesture(jcp_host* host, int32_t index) noexcept
    {
        auto* p = self(host);
        auto* parameter = p != nullptr ? p->parameterAt(index) : nullptr;
        if (parameter == nullptr || ! p->gestureActive[(size_t) index].exchange(false))
            return;
        p->requestDelivery();
    }

    static void* JCP_CALL hostGetExtension(jcp_host*, const char*) noexcept
    {
        return nullptr;
    }

    // Any thread, including the audio thread: one relaxed atomic store.
    static void JCP_CALL hostSetMeter(jcp_host* host, int32_t index, float value) noexcept
    {
        auto* p = self(host);
        if (p == nullptr || ! juce::isPositiveAndBelow(index, (int32_t) JCP_MAX_METERS))
            return;
        p->meters[(size_t) index].store(std::isfinite(value) ? juce::jlimit(-1.0e9f, 1.0e9f, value) : 0.0f,
                                        std::memory_order_relaxed);
    }

    static const jcp_host_api& hostApi()
    {
        static const jcp_host_api api {
            (int32_t) sizeof(jcp_host_api), JCP_ABI_VERSION,
            &hostAddMidiOutput, &hostSetParameter, &hostGetParameter,
            &hostSetLatency, &hostLog, &hostGetSampleRate,
            &hostBeginGesture, &hostEndGesture, &hostGetExtension,
            &hostSetMeter
        };
        return api;
    }

    //==========================================================================
    void* instance = nullptr;
    bool creationFailed = false;
    jcp_plugin_vtable vtable {};
    std::vector<juce::RangedAudioParameter*> parameters; // owned by AudioProcessor
    std::vector<float> parameterValues;
    std::unique_ptr<std::atomic<bool>[]> gestureActive;
    std::vector<jcp_midi_event> midiEvents;
    juce::MidiBuffer midiOut;
    jcp_transport transport {};
    jcp_transport chunkTransport {};
    //==========================================================================
    // Re-entrancy. Hosts may react synchronously to a latency or parameter
    // change notification, re-entering the library from inside Prepare or Process.
    //
    // So host notifications are not sent from inside a library call, nor from
    // any thread but the message thread. They are recorded per parameter
    // (latest value, whether the library wants a gesture open) and delivered on
    // the message thread: coalesced, so nothing is lost or left unbalanced, and
    // a gesture is always closed before the host is told it has ended. Lifecycle
    // calls re-entering from inside a library call on the same thread are ignored.
    struct LibraryCall
    {
        explicit LibraryCall(const PascalPluginProcessor& owner) noexcept
        {
            if (libraryCallDepth < maxLibraryCallDepth)
                libraryCallStack[libraryCallDepth] = &owner;
            ++libraryCallDepth;
        }
        ~LibraryCall() noexcept { --libraryCallDepth; }
        LibraryCall(const LibraryCall&) = delete;
        LibraryCall& operator=(const LibraryCall&) = delete;
    };

    bool insideLibraryCall() const noexcept { return insideLibraryCallFor(this); }

    // Compares pointers only: safe to ask about an instance that may be gone.
    static bool insideLibraryCallFor(const void* owner) noexcept
    {
        if (libraryCallDepth > maxLibraryCallDepth)
            return true; // deeper than we track: assume the worst
        for (int i = 0; i < libraryCallDepth; ++i)
            if (libraryCallStack[i] == owner)
                return true;
        return false;
    }

    // Deliver now when that is safe (message thread, not inside this instance's
    // library code), otherwise from the message loop.
    void requestDelivery() noexcept
    {
        if (juce::MessageManager::existsAndIsCurrentThread() && ! insideLibraryCall())
            deliverHostNotifications();
        else
            triggerAsyncUpdate();
    }

    void handleAsyncUpdate() override { deliverHostNotifications(); }

    /* The delivery lock and an "alive" flag live outside the processor: a
       host may destroy the processor synchronously from inside one of the
       notifications we send it (or on another thread right after an editor
       callback). Delivery holds its own reference, checks the flag after
       every host call, and touches nothing of the processor once it is
       cleared. The destructor clears it, then takes the lock: it waits for a
       delivery running on another thread. */
    struct DeliveryState
    {
        std::recursive_mutex mutex;
        std::atomic<bool> alive { true };
    };

    void deliverHostNotifications() noexcept { deliverVia(delivery, this); }

    static void deliverVia(const std::shared_ptr<DeliveryState>& shared, PascalPluginProcessor* p) noexcept
    {
        const std::shared_ptr<DeliveryState> d = shared; // outlives `p` if the host destroys it meanwhile
        if (d == nullptr || p == nullptr)
            return;
        const std::lock_guard<std::recursive_mutex> lock(d->mutex);
        if (! d->alive.load(std::memory_order_acquire))
            return;
        // A host reacting synchronously (e.g. closing the editor, which ends its
        // gestures) can ask for a delivery while one is in progress on this
        // thread: never nest (the outer loop holds per-parameter state across
        // host calls); go round again instead.
        if (p->delivering)
        {
            p->redeliver = true;
            return;
        }
        p->delivering = true;
        for (;;)
        {
            p->redeliver = false;
            if (! p->deliverOnce(*d))
                return; // destroyed by the host during delivery: touch nothing
            if (! p->redeliver)
                break;
        }
        p->delivering = false;
    }

    // False if the processor was destroyed by a host call made here.
    bool deliverOnce(DeliveryState& d) noexcept
    {
        const auto alive = [&d] { return d.alive.load(std::memory_order_acquire); };
        try
        {
            const int latency = pendingLatency.exchange(-1, std::memory_order_acq_rel);
            if (latency >= 0)
            {
                setLatencySamples(latency);
                if (! alive())
                    return false;
            }

            for (size_t i = 0; i < parameters.size(); ++i)
            {
                const bool dirty = pendingDirty[i].exchange(false, std::memory_order_acq_rel);
                const bool wanted = gestureActive[i].load(std::memory_order_acquire);
                bool open = hostGestureOpen[i];
                if (! dirty && wanted == open)
                    continue;
                auto* parameter = parameters[i];
                if (! open && (wanted || dirty))
                {
                    hostGestureOpen[i] = open = true;
                    parameter->beginChangeGesture();
                    if (! alive())
                        return false;
                }
                if (dirty)
                {
                    const auto& range = parameter->getNormalisableRange();
                    const float value = pendingValue[i].load(std::memory_order_acquire);
                    parameter->setValueNotifyingHost(parameter->convertTo0to1(juce::jlimit(range.start, range.end, value)));
                    if (! alive())
                        return false;
                }
                if (! gestureActive[i].load(std::memory_order_acquire) && open)
                {
                    hostGestureOpen[i] = open = false;
                    parameter->endChangeGesture();
                    if (! alive())
                        return false;
                }
            }
        }
        catch (...)
        {
            return alive();
        }
        return alive();
    }

    std::atomic<int> pendingLatency { -1 };
    std::unique_ptr<std::atomic<float>[]> pendingValue;
    std::unique_ptr<std::atomic<bool>[]> pendingDirty;
    std::unique_ptr<bool[]> hostGestureOpen; // what the host has been told (message thread only)
    std::shared_ptr<DeliveryState> delivery = std::make_shared<DeliveryState>();
    bool delivering = false, redeliver = false; // under delivery->mutex
    std::atomic<bool> destroying { false };

    std::atomic<juce::Thread::ThreadID> processThread { nullptr };
    std::atomic<bool> prepared { false };
    int currentBlockSize = 0;   // samples in the chunk being processed
    StateWriter* openWriter = nullptr;             // set only during get_state (under the callback lock)
    juce::Thread::ThreadID openWriterThread = nullptr;
    int currentChunkStart = 0;  // its offset in the host's block (for MIDI output positions)
    std::atomic<double> preparedSampleRate { 44100.0 };
    std::atomic<int> preparedBlockSize { 0 }; // what Prepare promised: Process never gets more
    std::vector<jcp_midi_event> chunkEvents;   // midiEvents re-based to the current chunk
    static constexpr int maxChannels = 64;
    float* chunkChannels[maxChannels] = {};
    juce::MemoryBlock preservedState;
    juce::CriticalSection preservedLock;

    // Editor support: values published by the library (any thread), and the
    // editors open on this instance (message thread, under editorMutex()).
    std::array<std::atomic<float>, JCP_MAX_METERS> meters {};
    std::vector<std::shared_ptr<EditorSession>> editorSessions;
    // The scale of this instance's scaled editor (set_design_size) when it was
    // last resized; 0 = never. Kept for the next editor and saved with the state.
    std::atomic<float> editorScale { 0.0f };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PascalPluginProcessor)
};

//==============================================================================
/* Custom editors (see "Custom editors" in juce_c_plugin.h).

   The library's editor object lives in an EditorSession, shared by the JUCE
   component (the window), the registry that validates handles, and every
   call in progress, so neither the window closing nor the processor going
   away can free it while library code runs:

   - every library editor callback goes through callEditor(): message thread
     only, never re-entrant (one callback at a time per editor, none while the
     instance is inside another library call on this thread), FP exceptions
     masked, exceptions contained, under editorMutex() (which the processor's
     destructor takes, so a host destroying it on another thread waits);
   - a window closed during a callback marks the session; the library's
     destroy() runs when that callback has returned;
   - jcp_editor / jcp_graphics values are tokens looked up in the registry or
     compared with the paint in progress, never dereferenced;
   - parameter changes the library makes are queued (as for host services)
     and delivered once its callback has returned. */

constexpr int maxPathElements = 65536;
constexpr int maxSaveDepth = 64;
constexpr float maxCoord = JCP_EDITOR_MAX_COORD;
constexpr int64_t maxEditorPixels = 64ll * 1024 * 1024; // all images of one editor

static bool onMessageThread() noexcept
{
    return juce::MessageManager::existsAndIsCurrentThread();
}

static std::recursive_mutex& editorMutex() noexcept
{
    static std::recursive_mutex m;
    return m;
}

// What set_look asked for (validated copies); 0 / empty = JUCE's default.
struct LookSettings
{
    uint32_t tooltipBackground = 0, tooltipText = 0, tooltipOutline = 0;
    uint32_t menuBackground = 0, menuText = 0, menuHighlight = 0, menuHighlightText = 0, menuHeaderText = 0;
    float tooltipFontHeight = 0.0f, menuFontHeight = 0.0f;
    juce::String fontName;
};

/* The look of the wrapper's own windows for one editor: its tooltips and its
   popup menus. Shared: a menu still open keeps it alive after the editor
   closes (the menu's callback holds a reference). Message thread only. */
class PascalLook final : public juce::LookAndFeel_V4
{
public:
    PascalLook()
    {
        for (size_t i = 0; i < colourIds.size(); ++i)
            defaults[i] = findColour(colourIds[i]);
    }

    void apply(const LookSettings& s)
    {
        settings = s;
        const uint32_t values[] = { s.tooltipBackground, s.tooltipText, s.tooltipOutline, s.menuBackground, s.menuText,
                                    s.menuHighlight, s.menuHighlightText, s.menuHeaderText };
        for (size_t i = 0; i < colourIds.size(); ++i)
            setColour(colourIds[i], values[i] != 0 ? juce::Colour(values[i]) : defaults[i]);
    }

    juce::Font getPopupMenuFont() override
    {
        if (settings.menuFontHeight <= 0.0f && settings.fontName.isEmpty())
            return LookAndFeel_V4::getPopupMenuFont();
        return juce::Font(withDefaultMetrics(withName(juce::FontOptions(settings.menuFontHeight > 0.0f ? settings.menuFontHeight
                                                                                                        : 17.0f))));
    }

    // JUCE's tooltip layout (LookAndFeelHelpers::layoutTooltipText) with this look's font.
    juce::Rectangle<int> getTooltipBounds(const juce::String& text, juce::Point<int> screenPos,
                                          juce::Rectangle<int> parentArea) override
    {
        if (! customTooltipFont())
            return LookAndFeel_V4::getTooltipBounds(text, screenPos, parentArea);
        const auto tl = layoutTooltip(text, juce::Colours::black);
        const auto w = (int) (tl.getWidth() + 14.0f), h = (int) (tl.getHeight() + 6.0f);
        return juce::Rectangle<int>(screenPos.x > parentArea.getCentreX() ? screenPos.x - (w + 12) : screenPos.x + 24,
                                    screenPos.y > parentArea.getCentreY() ? screenPos.y - (h + 6) : screenPos.y + 6, w, h)
            .constrainedWithin(parentArea);
    }

    void drawTooltip(juce::Graphics& g, const juce::String& text, int width, int height) override
    {
        if (! customTooltipFont())
        {
            LookAndFeel_V4::drawTooltip(g, text, width, height);
            return;
        }
        const juce::Rectangle<float> bounds((float) width, (float) height);
        g.setColour(findColour(juce::TooltipWindow::backgroundColourId));
        g.fillRoundedRectangle(bounds, 5.0f);
        g.setColour(findColour(juce::TooltipWindow::outlineColourId));
        g.drawRoundedRectangle(bounds.reduced(0.5f), 5.0f, 1.0f);
        layoutTooltip(text, findColour(juce::TooltipWindow::textColourId)).draw(g, bounds);
    }

private:
    bool customTooltipFont() const noexcept { return settings.tooltipFontHeight > 0.0f || settings.fontName.isNotEmpty(); }

    juce::FontOptions withName(juce::FontOptions options) const
    {
        return settings.fontName.isNotEmpty() ? options.withName(settings.fontName) : options;
    }

    juce::TextLayout layoutTooltip(const juce::String& text, juce::Colour colour) const
    {
        juce::AttributedString s;
        s.setWordWrap(juce::AttributedString::WordWrap::byChar);
        s.setJustification(juce::Justification::centred);
        s.append(text, withDefaultMetrics(withName(juce::FontOptions(settings.tooltipFontHeight > 0.0f ? settings.tooltipFontHeight
                                                                                                         : 13.0f,
                                                                     juce::Font::bold))),
                 colour);
        juce::TextLayout tl;
        tl.createLayoutWithBalancedLineLengths(s, 400.0f);
        return tl;
    }

    static constexpr std::array<int, 8> colourIds {
        juce::TooltipWindow::backgroundColourId, juce::TooltipWindow::textColourId, juce::TooltipWindow::outlineColourId,
        juce::PopupMenu::backgroundColourId, juce::PopupMenu::textColourId, juce::PopupMenu::highlightedBackgroundColourId,
        juce::PopupMenu::highlightedTextColourId, juce::PopupMenu::headerTextColourId
    };
    std::array<juce::Colour, 8> defaults;
    LookSettings settings;
};

/* open_url: only https:// pages on a DNS host, from a small set of printable
   ASCII characters. Returns the URL to open, or an empty string. */
static std::string validatedUrl(const char* text) noexcept
{
    try
    {
        if (text == nullptr)
            return {};
        size_t n = 0;
        while (n <= (size_t) JCP_MAX_URL && text[n] != '\0')
            ++n;
        if (n == 0 || n > (size_t) JCP_MAX_URL)
            return {};
        const auto isAlpha = [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); };
        const auto isDigit = [](char c) { return c >= '0' && c <= '9'; };
        const auto isHex = [&](char c) { return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); };
        const auto hexValue = [&](char c) { return isDigit(c) ? c - '0' : (c | 0x20) - 'a' + 10; };
        std::string url(text, n);
        static const char scheme[] = "https://";
        if (n <= 8)
            return {};
        for (size_t i = 0; i < 8; ++i)
            if ((char) (url[i] | (isAlpha(url[i]) ? 0x20 : 0)) != scheme[i])
                return {};
        url.replace(0, 8, scheme);
        for (size_t i = 0; i < n; ++i)
        {
            const char c = url[i];
            if (! (isAlpha(c) || isDigit(c) || std::strchr("-._~:/?#@&+,=%", c) != nullptr) || c == '\0')
                return {};
            if (c == '%')
            {
                if (i + 2 >= n || ! isHex(url[i + 1]) || ! isHex(url[i + 2]))
                    return {};
                const int v = hexValue(url[i + 1]) * 16 + hexValue(url[i + 2]);
                if (v < 0x20 || v == 0x7F)
                    return {};
            }
        }
        // host[:port], up to the first '/', '?' or '#'
        const size_t end = std::min(n, url.find_first_of("/?#", 8));
        std::string host = url.substr(8, end - 8);
        if (host.find_first_of("@%") != std::string::npos)
            return {};
        const auto colon = host.find(':');
        if (colon != std::string::npos)
        {
            const std::string port = host.substr(colon + 1);
            if (port.empty() || port.size() > 5 || port.find_first_not_of("0123456789") != std::string::npos
                || std::atoi(port.c_str()) < 1 || std::atoi(port.c_str()) > 65535)
                return {};
            host.resize(colon);
        }
        if (host.empty() || host.size() > 253)
            return {};
        // labels of letters, digits and '-' (not first or last), at least two;
        // the last starts with a letter (so no IP address and no "localhost")
        size_t start = 0, labels = 0;
        while (true)
        {
            const size_t dot = host.find('.', start);
            const std::string label = host.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
            if (label.empty() || label.size() > 63 || label.front() == '-' || label.back() == '-')
                return {};
            for (const char c : label)
                if (! (isAlpha(c) || isDigit(c) || c == '-'))
                    return {};
            ++labels;
            if (dot == std::string::npos)
            {
                // a top-level domain: letters only, or an IDN one (xn--...)
                if (labels < 2)
                    return {};
                const bool idn = label.size() > 4 && (label.compare(0, 4, "xn--") == 0 || label.compare(0, 4, "XN--") == 0);
                if (! idn)
                    for (const char c : label)
                        if (! isAlpha(c))
                            return {};
                break;
            }
            start = dot + 1;
        }
        return url;
    }
    catch (...)
    {
        return {};
    }
}

#if defined(PASCALJUCE_EDITOR_TEST_HOOKS)
// Test executables never start a browser: accepted URLs are recorded instead.
static std::vector<std::string>& testOpenedUrls()
{
    static std::vector<std::string> urls;
    return urls;
}
#endif

static void launchUrl(const std::string& url) noexcept
{
    try
    {
       #if defined(PASCALJUCE_EDITOR_TEST_HOOKS)
        testOpenedUrls().push_back(url);
       #elif JUCE_WINDOWS
        // Without parsing: juce::URL would re-encode the query part.
        juce::URL::createWithoutParsing(juce::String::fromUTF8(url.c_str(), (int) url.size())).launchInDefaultBrowser();
       #elif JUCE_MAC
        if (auto ref = CFURLCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(url.data()), (CFIndex) url.size(),
                                            kCFStringEncodingASCII, nullptr))
        {
            LSOpenCFURLRef(ref, nullptr);
            CFRelease(ref);
        }
       #else
        // The intermediate child exits at once (no zombie); the grandchild
        // is re-parented.
        const pid_t child = fork();
        if (child == 0)
        {
            setsid();
            if (fork() == 0)
            {
                const char* const argv[] = { "xdg-open", url.c_str(), nullptr };
                execvp(argv[0], const_cast<char* const*>(argv));
            }
            _exit(0);
        }
        if (child > 0)
            waitpid(child, nullptr, 0);
       #endif
    }
    catch (...)
    {
    }
}

struct EditorSession
{
    uintptr_t id = 0;
    PascalPluginProcessor* processor = nullptr; // null once the processor is gone
    PascalEditor* component = nullptr;          // null once the window is gone
    void* libEditor = nullptr;
    jcp_editor_vtable vtable {};
    int callDepth = 0;        // library editor calls on the stack (0 or 1, plus destroy)
    bool closed = false;      // no further library calls of any kind
    bool destroyPending = false;

    // Requested before the window exists (during create_editor). In a scaled
    // editor width x height is the window, designW x designH what the library sees.
    int width = 400, height = 300;
    bool sizeSet = false;     // set_size was called during create_editor
    int minW = 0, minH = 0, maxW = 0, maxH = 0;
    int timerHz = 0;
    juce::String tooltip;

    // Scaling (set_design_size).
    bool scaled = false;
    int designW = 0, designH = 0;
    float minScale = 1.0f, maxScale = 1.0f; // effective limits (window limits included)
    float askedMinScale = 1.0f, askedMaxScale = 1.0f; // as set_design_size asked
    int scaleFlags = 0;
    float scaleX = 1.0f, scaleY = 1.0f;     // window pixels per design unit, as laid out now
    bool letterboxed = false;               // the window's aspect ratio is not the design's
    int notifiedW = 0, notifiedH = 0;       // the size resized() last reported
    float lastScale = 1.0f;                 // the scale last remembered for the instance

    LookSettings look;

    // open_url: a user's click is being delivered (mouse press, release,
    // double click, or a menu choice), and whether it has opened a page yet.
    bool userClick = false;
    bool urlOpenedThisClick = false;

    // The paint in progress.
    juce::Graphics* graphics = nullptr;
    uintptr_t graphicsToken = 0;
    int saveDepth = 0;
    juce::Path path;
    int pathElements = 0;
    juce::Point<float> origin;                 // total translation (bounded, not just each call)
    std::vector<juce::Point<float>> origins;   // saved with save_state

    std::map<int32_t, juce::Image> images;
    int32_t nextImage = 1;
    int64_t imagePixels = 0;

    std::set<int32_t> openGestures; // begun by this editor and not yet ended
    bool menuOpen = false;
};

// Live editors by handle (message thread; also touched under editorMutex() by
// a processor destroyed elsewhere). Handles are never reused.
static std::map<uintptr_t, std::shared_ptr<EditorSession>>& editorRegistry()
{
    static std::map<uintptr_t, std::shared_ptr<EditorSession>> registry;
    return registry;
}

static uintptr_t nextEditorToken() noexcept
{
    static std::atomic<uintptr_t> counter { 0 };
    return (uintptr_t) 0x5000 + (counter.fetch_add(1) + 1) * 16; // never 0, never a small integer
}

static EditorSession* currentPaint = nullptr; // message thread only

static float finiteOr(float v, float fallback) noexcept { return std::isfinite(v) ? v : fallback; }

static bool coordArg(float& v) noexcept
{
    if (! std::isfinite(v))
        return false;
    v = juce::jlimit(-maxCoord, maxCoord, v);
    return true;
}

static bool extentArg(float& v) noexcept
{
    if (! std::isfinite(v))
        return false;
    v = juce::jlimit(0.0f, 2.0f * maxCoord, v);
    return true;
}

static bool rectArgs(float& x, float& y, float& w, float& h) noexcept
{
    return coordArg(x) && coordArg(y) && extentArg(w) && extentArg(h);
}

static bool thicknessArg(float& t) noexcept
{
    if (! std::isfinite(t))
        return false;
    t = juce::jlimit(0.0f, 1000.0f, t);
    return true;
}

static void finishSession(const std::shared_ptr<EditorSession>& s) noexcept;

//==============================================================================
class PascalEditor final : public juce::AudioProcessorEditor,
                           public juce::SettableTooltipClient,
                           private juce::Timer,
                           private juce::AsyncUpdater,
                           private juce::AudioProcessorParameter::Listener
{
public:
    PascalEditor(PascalPluginProcessor& p, std::shared_ptr<EditorSession> s)
        : AudioProcessorEditor(p), session(std::move(s))
    {
        session->component = this;
        params = p.parameters;
        dirty = std::make_unique<std::atomic<bool>[]>(std::max<size_t>(1, params.size()));
        for (auto* parameter : params)
            parameter->addListener(this);
        listening = true;
        setOpaque(false);
        look->apply(session->look);
        setLookAndFeel(look.get()); // the tooltip window (a child) and the resize corner follow it
        if (session->scaled)
        {
            // A scaled editor opens at the scale this instance last had.
            const float remembered = p.editorScale.load(std::memory_order_relaxed);
            session->lastScale = std::isfinite(remembered) && remembered > 0.0f ? remembered : 1.0f;
            windowSizeFor(*session, session->lastScale, session->width, session->height);
        }
        applyResizeLimits();
        setSize(session->width, session->height);
        updateScale();
        session->lastScale = std::min(session->scaleX, session->scaleY);
        session->notifiedW = session->scaled ? session->designW : getWidth();
        session->notifiedH = session->scaled ? session->designH : getHeight();
        if (session->timerHz > 0)
            startTimerHz(session->timerHz);
        if (session->tooltip.isNotEmpty())
            setTooltip(session->tooltip);
        constructed = true;
    }

    ~PascalEditor() override
    {
        setLookAndFeel(nullptr);
        stopTimer();
        cancelPendingUpdate();
        const std::lock_guard<std::recursive_mutex> lock(editorMutex());
        if (listening && session->processor != nullptr)
            for (auto* parameter : params)
                parameter->removeListener(this);
        session->component = nullptr;
        if (session->callDepth > 0)
            session->destroyPending = true; // closed from inside a library callback: finish when it returns
        else
            finishSession(session);
    }

    // The window size of a scaled editor at a scale (clamped to its limits).
    static void windowSizeFor(const EditorSession& s, float scale, int& w, int& h) noexcept
    {
        scale = juce::jlimit(s.minScale, s.maxScale, std::isfinite(scale) ? scale : 1.0f);
        w = juce::jlimit(JCP_EDITOR_MIN_SIZE, JCP_EDITOR_MAX_SIZE, juce::roundToInt((float) s.designW * scale));
        h = juce::jlimit(JCP_EDITOR_MIN_SIZE, JCP_EDITOR_MAX_SIZE, juce::roundToInt((float) s.designH * scale));
    }

    // Returns false if the window was closed meanwhile (the host may react to
    // a resize by closing it): then `this` is gone and must not be touched.
    bool applyResizeLimits()
    {
        juce::Component::SafePointer<PascalEditor> alive(this);
        if (session->scaled)
        {
            int minW = 0, minH = 0, maxW = 0, maxH = 0;
            windowSizeFor(*session, session->minScale, minW, minH);
            windowSizeFor(*session, session->maxScale, maxW, maxH);
            const double ratio = (double) session->designW / (double) session->designH;
            // the ratio first, so that setResizeLimits constrains with the new one
            if (auto* c = getConstrainer())
                c->setFixedAspectRatio(ratio);
            setResizable(true, (session->scaleFlags & JCP_SCALE_CORNER_RESIZER) != 0);
            if (alive == nullptr)
                return false;
            setResizeLimits(minW, minH, maxW, maxH);
            if (alive == nullptr)
                return false;
            if (auto* c = getConstrainer())
                c->setFixedAspectRatio(ratio);
        }
        else if (session->maxW > 0 && session->maxH > 0)
        {
            if (auto* c = getConstrainer())
                c->setFixedAspectRatio(0.0);
            setResizable(true, false);
            if (alive == nullptr)
                return false;
            setResizeLimits(session->minW, session->minH, session->maxW, session->maxH);
        }
        else
        {
            if (auto* c = getConstrainer())
                c->setFixedAspectRatio(0.0);
            setResizable(false, false);
        }
        return alive != nullptr;
    }

    // set_design_size / set_size of a scaled editor / set_resize_limits: the
    // limits, then the size the session asks for (each step may close the window).
    void applyScaling()
    {
        juce::Component::SafePointer<PascalEditor> alive(this);
        if (! applyResizeLimits())
            return;
        const auto s = session;
        setSize(s->width, s->height);
        if (alive != nullptr)
            updateScale();
    }

    void applyLook()
    {
        look->apply(session->look);
    }

    std::shared_ptr<PascalLook> getLook() const noexcept { return look; }

    // Window pixels per design unit, from the window's size. A window whose
    // aspect ratio is off by more than 1% (a host ignoring the limits) is
    // drawn at the smaller scale, the rest filled black.
    void updateScale() noexcept
    {
        auto& s = *session;
        s.scaleX = s.scaleY = 1.0f;
        s.letterboxed = false;
        if (! s.scaled || s.designW <= 0 || s.designH <= 0 || getWidth() <= 0 || getHeight() <= 0)
            return;
        float sx = (float) getWidth() / (float) s.designW, sy = (float) getHeight() / (float) s.designH;
        if (std::abs(sx - sy) > 0.01f * std::max(sx, sy))
        {
            sx = sy = std::min(sx, sy);
            s.letterboxed = true;
        }
        s.scaleX = sx;
        s.scaleY = sy;
    }

    void startLibraryTimer(int hz) { startTimerHz(hz); }
    void stopLibraryTimer() { stopTimer(); }

    // The processor is being destroyed while this window is still open.
    void processorGone()
    {
        stopTimer();
        cancelPendingUpdate();
        if (listening)
            for (auto* parameter : params)
                parameter->removeListener(this);
        listening = false;
    }

    template <typename Fn>
    static bool call(const std::shared_ptr<EditorSession>& s, Fn&& fn, bool deliverNow = true) noexcept;

    //==========================================================================
    void paint(juce::Graphics& g) override
    {
        auto s = session;
        if (s->closed || s->libEditor == nullptr || s->vtable.paint == nullptr)
            return;
        if (s->callDepth > 0)
        {
            repaint(); // never paint inside another callback of this editor: try again later
            return;
        }
        EditorSession* const outer = currentPaint;
        s->graphics = &g;
        s->graphicsToken = nextEditorToken();
        s->saveDepth = 0;
        s->origin = {};
        s->origins.clear();
        s->path.clear();
        s->pathElements = 0;
        currentPaint = s.get();
        g.saveState();
        if (s->scaled)
        {
            // The whole drawing is scaled (not a bitmap stretched afterwards):
            // text, paths and images are rendered at the window's resolution.
            if (s->letterboxed)
            {
                g.setColour(juce::Colours::black);
                g.fillAll();
                g.reduceClipRegion(juce::Rectangle<float>(0.0f, 0.0f, (float) s->designW * s->scaleX,
                                                          (float) s->designH * s->scaleY).getSmallestIntegerContainer());
            }
            if (s->scaleX != 1.0f || s->scaleY != 1.0f)
                g.addTransform(juce::AffineTransform::scale(s->scaleX, s->scaleY));
        }
        g.setFont(juce::Font(juce::FontOptions(14.0f)));
        const auto token = s->graphicsToken;
        call(s, [token](void* lib, const jcp_editor_vtable& vt) { vt.paint(lib, reinterpret_cast<jcp_graphics*>(token)); },
             false); // host notifications from paint go out later, never inside JUCE's paint
        while (s->saveDepth > 0)
        {
            g.restoreState();
            --s->saveDepth;
        }
        g.restoreState();
        currentPaint = outer;
        s->graphics = nullptr;
        s->graphicsToken = 0;
        s->path.clear();
    }

    void resized() override
    {
        if (! constructed)
            return;
        session->width = getWidth();
        session->height = getHeight();
        updateScale();
        if (session->scaled)
        {
            // The library keeps its design size; the scale (within its limits,
            // and not from a window of the wrong shape) is remembered for the instance.
            const float scale = juce::jlimit(session->minScale, session->maxScale, std::min(session->scaleX, session->scaleY));
            if (scale != session->lastScale && ! session->letterboxed)
            {
                session->lastScale = scale;
                const std::lock_guard<std::recursive_mutex> lock(editorMutex());
                if (session->processor != nullptr)
                    session->processor->editorScale.store(scale, std::memory_order_relaxed);
            }
            repaint();
        }
        notifyLibrarySize();
    }

    // Tells the library its size if it changed: the design size when scaled,
    // else the window's. A notification refused now (inside another callback
    // of this editor) is retried from the message loop, never lost.
    void notifyLibrarySize()
    {
        const auto s = session;
        const int w = s->scaled ? s->designW : getWidth(), h = s->scaled ? s->designH : getHeight();
        if (w == s->notifiedW && h == s->notifiedH)
            return;
        s->notifiedW = w;
        s->notifiedH = h;
        juce::Component::SafePointer<PascalEditor> alive(this);
        if (call(s, [w, h](void* lib, const jcp_editor_vtable& vt) { if (vt.resized != nullptr) vt.resized(lib, w, h); }))
        {
            if (alive != nullptr)
                resizeRetries = 0;
            return;
        }
        if (alive == nullptr || ++resizeRetries > 10000)
            return;
        {
            const std::lock_guard<std::recursive_mutex> lock(editorMutex());
            if (s->closed || s->component != this || s->processor == nullptr)
                return;
        }
        s->notifiedW = s->notifiedH = -1; // not delivered
        juce::MessageManager::callAsync([alive]
        {
            if (auto* editor = alive.getComponent())
                editor->notifyLibrarySize();
        });
    }

    void mouseMove(const juce::MouseEvent& e) override        { sendMouse(JCP_MOUSE_MOVE, e); }
    void mouseEnter(const juce::MouseEvent& e) override       { sendMouse(JCP_MOUSE_ENTER, e); }
    void mouseExit(const juce::MouseEvent& e) override        { sendMouse(JCP_MOUSE_EXIT, e); }
    void mouseDown(const juce::MouseEvent& e) override        { sendMouse(JCP_MOUSE_DOWN, e); }
    void mouseDrag(const juce::MouseEvent& e) override        { sendMouse(JCP_MOUSE_DRAG, e); }
    void mouseUp(const juce::MouseEvent& e) override          { sendMouse(JCP_MOUSE_UP, e); }
    void mouseDoubleClick(const juce::MouseEvent& e) override { sendMouse(JCP_MOUSE_DOUBLE_CLICK, e); }
    void mouseWheelMove(const juce::MouseEvent& e, const juce::MouseWheelDetails& wheel) override
    {
        const float sign = wheel.isReversed ? -1.0f : 1.0f;
        sendMouse(JCP_MOUSE_WHEEL, e, sign * wheel.deltaX, sign * wheel.deltaY);
    }

private:
    void sendMouse(int32_t type, const juce::MouseEvent& e, float dx = 0.0f, float dy = 0.0f)
    {
        jcp_mouse_event event {};
        event.struct_size = (int32_t) sizeof(event);
        event.type = type;
        // design units in a scaled editor (scaleX, scaleY > 0: the window is at least 16 pixels)
        event.x = juce::jlimit(-maxCoord, maxCoord, finiteOr(e.position.x / session->scaleX, 0.0f));
        event.y = juce::jlimit(-maxCoord, maxCoord, finiteOr(e.position.y / session->scaleY, 0.0f));
        const auto& m = e.mods;
        event.modifiers = (m.isShiftDown() ? JCP_MOD_SHIFT : 0) | (m.isCtrlDown() ? JCP_MOD_CTRL : 0)
                        | (m.isAltDown() ? JCP_MOD_ALT : 0) | (m.isCommandDown() ? JCP_MOD_CMD : 0)
                        | (m.isLeftButtonDown() ? JCP_MOD_LEFT : 0) | (m.isRightButtonDown() ? JCP_MOD_RIGHT : 0)
                        | (m.isMiddleButtonDown() ? JCP_MOD_MIDDLE : 0) | (m.isPopupMenu() ? JCP_MOD_POPUP : 0);
        event.click_count = juce::jlimit(0, 16, e.getNumberOfClicks());
        event.wheel_dx = juce::jlimit(-64.0f, 64.0f, finiteOr(dx, 0.0f));
        event.wheel_dy = juce::jlimit(-64.0f, 64.0f, finiteOr(dy, 0.0f));
        // A press, release or double click is a user's click: open_url is allowed during it.
        // Set only while the library's own mouse callback runs (not while the
        // host is notified afterwards, when a nested callback could run).
        const auto s = session;
        const bool click = type == JCP_MOUSE_DOWN || type == JCP_MOUSE_UP || type == JCP_MOUSE_DOUBLE_CLICK;
        call(s, [&event, &s, click](void* lib, const jcp_editor_vtable& vt)
        {
            if (vt.mouse == nullptr)
                return;
            s->userClick = click;
            s->urlOpenedThisClick = false;
            vt.mouse(lib, &event);
            s->userClick = false;
        });
        s->userClick = false; // also if the callback did not return normally
        // `this` may be gone now (a host closing the window in reaction): touch nothing.
    }

    void timerCallback() override
    {
        call(session, [](void* lib, const jcp_editor_vtable& vt) { if (vt.timer != nullptr) vt.timer(lib); });
    }

    // Any thread (host automation arrives on the audio thread in some hosts).
    void parameterValueChanged(int index, float) override
    {
        if (juce::isPositiveAndBelow(index, (int) params.size()))
        {
            dirty[(size_t) index].store(true, std::memory_order_release);
            triggerAsyncUpdate();
        }
    }

    void parameterGestureChanged(int, bool) override {}

    void handleAsyncUpdate() override
    {
        auto s = session;
        {
            const std::lock_guard<std::recursive_mutex> lock(editorMutex());
            if (s->closed || s->processor == nullptr)
                return;
            if (s->callDepth > 0)
            {
                triggerAsyncUpdate(); // inside a callback of this editor (nested message loop): later
                return;
            }
        }
        const auto count = params.size();
        for (size_t i = 0; i < count; ++i)
        {
            if (! dirty[i].exchange(false, std::memory_order_acq_rel))
                continue;
            float value = 0.0f;
            {
                // The parameters belong to the processor, which another thread may be destroying.
                const std::lock_guard<std::recursive_mutex> lock(editorMutex());
                if (s->closed || s->processor == nullptr)
                    return;
                value = PascalPluginProcessor::sanitisedNormalised(*params[i]);
            }
            const auto index = (int32_t) i;
            call(s, [index, value](void* lib, const jcp_editor_vtable& vt)
            {
                if (vt.parameter_changed != nullptr)
                    vt.parameter_changed(lib, index, value);
            });
            if (s->component == nullptr || s->closed)
                return; // closed in reaction: `this` is gone
        }
    }

    std::shared_ptr<EditorSession> session;
    std::vector<juce::RangedAudioParameter*> params;
    std::unique_ptr<std::atomic<bool>[]> dirty;
    bool listening = false;
    bool constructed = false;
    int resizeRetries = 0;
    std::shared_ptr<PascalLook> look = std::make_shared<PascalLook>(); // before the tooltip window: outlives it
    juce::TooltipWindow tooltipWindow { this, 700 };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PascalEditor)
};

/* The one way into the library's editor code. Returns false if the call was
   refused (closed editor, re-entrant, wrong thread). */
template <typename Fn>
bool PascalEditor::call(const std::shared_ptr<EditorSession>& sp, Fn&& fn, bool deliverNow) noexcept
{
    const std::shared_ptr<EditorSession> s = sp; // the session outlives this call, whatever happens to the window
    PascalPluginProcessor* processor = nullptr;
    std::shared_ptr<PascalPluginProcessor::DeliveryState> delivery;
    {
        const std::lock_guard<std::recursive_mutex> lock(editorMutex());
        processor = s->processor;
        if (! onMessageThread() || s->closed || s->libEditor == nullptr || processor == nullptr || s->callDepth > 0
            || processor->insideLibraryCall())
            return false;
        ++s->callDepth;
        {
            ScopedFpState fpGuard;
            PascalPluginProcessor::LibraryCall inLibrary(*processor);
            try { fn(s->libEditor, s->vtable); }
            catch (...) {}
        }
        --s->callDepth;
        processor = s->processor; // null if it was destroyed during the call
        if (s->destroyPending && s->callDepth == 0)
        {
            s->destroyPending = false;
            finishSession(s);
        }
        if (processor != nullptr)
        {
            delivery = processor->delivery; // taken while the processor is certainly alive
            if (! deliverNow)
                processor->triggerAsyncUpdate(); // e.g. after paint: never notify the host inside JUCE's paint
        }
    }
    // Parameter changes and gestures the callback made reach the host now that
    // it has returned (the host may react synchronously; nothing below uses
    // the window or the session's library object). deliverVia checks, under
    // the delivery lock, that the processor still exists.
    if (deliverNow && delivery != nullptr && ! PascalPluginProcessor::insideLibraryCallFor(processor))
        PascalPluginProcessor::deliverVia(delivery, processor);
    return true;
}

/* Ends a session: closes the gestures it left open, calls the library's
   destroy() (once), frees its images and forgets its handle. */
static void finishSession(const std::shared_ptr<EditorSession>& s) noexcept
{
    const std::lock_guard<std::recursive_mutex> lock(editorMutex());
    try
    {
        auto* p = s->processor;
        if (p != nullptr && s->libEditor != nullptr && p->insideLibraryCall())
        {
            // The window closed while this instance is inside another library
            // call on this thread: destroy the library editor when that is over.
            auto keep = s;
            juce::MessageManager::callAsync([keep] { finishSession(keep); });
            return;
        }
        const auto endOpenGestures = [&s, p]
        {
            if (p == nullptr)
                return;
            for (const auto index : s->openGestures)
                if (juce::isPositiveAndBelow(index, (int) p->parameters.size()))
                    p->gestureActive[(size_t) index].store(false, std::memory_order_release);
            s->openGestures.clear();
        };
        endOpenGestures();
        void* lib = s->libEditor;
        s->libEditor = nullptr;
        if (lib != nullptr && ! s->closed && p != nullptr && s->vtable.destroy != nullptr)
        {
            ++s->callDepth; // API calls from destroy() are allowed, callbacks are not
            {
                ScopedFpState fpGuard;
                PascalPluginProcessor::LibraryCall inLibrary(*p);
                try { s->vtable.destroy(lib); }
                catch (...) {}
            }
            --s->callDepth;
        }
        endOpenGestures(); // also any begun inside destroy()
        s->closed = true;
        s->images.clear();
        s->imagePixels = 0;
        editorRegistry().erase(s->id);
        if (p != nullptr)
        {
            auto& list = p->editorSessions;
            list.erase(std::remove(list.begin(), list.end(), s), list.end());
            // The closed gestures reach the host from the message loop: never
            // call the host while holding editorMutex().
            p->triggerAsyncUpdate();
        }
    }
    catch (...)
    {
    }
}

//==============================================================================
// jcp_editor_api: every function is noexcept, checks its thread and handles,
// and validates every argument before JUCE sees it.
struct EditorApi
{
    // The live session for a handle, held under editorMutex() for the call.
    struct Access
    {
        explicit Access(jcp_editor* e) noexcept
        {
            if (e == nullptr || ! onMessageThread())
                return;
            lock = std::unique_lock<std::recursive_mutex>(editorMutex());
            auto& registry = editorRegistry();
            const auto found = registry.find(reinterpret_cast<uintptr_t>(e));
            if (found != registry.end() && ! found->second->closed)
                session = found->second;
        }
        explicit operator bool() const noexcept { return session != nullptr; }
        EditorSession* operator->() const noexcept { return session.get(); }
        std::unique_lock<std::recursive_mutex> lock;
        std::shared_ptr<EditorSession> session;
    };

    // The processor and a parameter, if both exist.
    static juce::RangedAudioParameter* parameter(const Access& a, int32_t index) noexcept
    {
        return a && a->processor != nullptr ? a->processor->parameterAt(index) : nullptr;
    }

    // The editor painting right now, if g is its graphics token.
    static EditorSession* painting(jcp_graphics* g) noexcept
    {
        if (g == nullptr || ! onMessageThread())
            return nullptr;
        auto* s = currentPaint;
        return s != nullptr && s->graphics != nullptr && s->graphicsToken == reinterpret_cast<uintptr_t>(g) ? s : nullptr;
    }

    //--------------------------------------------------------------------------
    static void JCP_CALL repaint(jcp_editor* e, float x, float y, float w, float h) noexcept
    {
        Access a(e);
        if (! a || a->component == nullptr)
            return;
        try
        {
            if (! rectArgs(x, y, w, h) || w <= 0.0f || h <= 0.0f)
                a->component->repaint();
            else
                a->component->repaint(juce::Rectangle<float>(x * a->scaleX, y * a->scaleY, w * a->scaleX, h * a->scaleY)
                                          .getSmallestIntegerContainer().expanded(a->scaled ? 1 : 0)
                                          .getIntersection(a->component->getLocalBounds()));
        }
        catch (...) {}
    }

    static int clampSize(int32_t v) noexcept { return juce::jlimit(JCP_EDITOR_MIN_SIZE, JCP_EDITOR_MAX_SIZE, (int) v); }

    // Changes to the window asked for during paint() are applied after it, from
    // the message loop: a host reacting to a resize (even by closing the
    // window) must never do so inside JUCE's own paint of that window.
    static bool deferWhilePainting(const Access& a, void (*apply)(EditorSession&)) noexcept
    {
        if (a->graphics == nullptr)
            return false;
        try
        {
            const std::weak_ptr<EditorSession> weak = a.session;
            juce::MessageManager::callAsync([weak, apply]
            {
                const auto s = weak.lock();
                {
                    const std::lock_guard<std::recursive_mutex> lock(editorMutex());
                    if (s == nullptr || s->component == nullptr || s->closed || s->graphics != nullptr)
                        return;
                }
                try { apply(*s); } // outside the lock: the host may be called
                catch (...) {}
            });
        }
        catch (...) {}
        return true;
    }

    static void applySize(EditorSession& s)
    {
        if (s.component != nullptr)
            s.component->setSize(s.width, s.height);
    }

    static void applyResizeLimits(EditorSession& s)
    {
        if (s.component != nullptr)
            s.component->applyResizeLimits();
    }

    static void applyScaling(EditorSession& s)
    {
        if (s.component != nullptr)
            s.component->applyScaling();
    }

    // The scale limits of a design size: as asked, within the window limits.
    static void setScaleLimits(EditorSession& s, float minScale, float maxScale) noexcept
    {
        minScale = juce::jlimit(JCP_EDITOR_MIN_SCALE, JCP_EDITOR_MAX_SCALE, minScale);
        maxScale = juce::jlimit(minScale, JCP_EDITOR_MAX_SCALE, maxScale);
        s.askedMinScale = minScale;
        s.askedMaxScale = maxScale;
        const float lo = std::max((float) JCP_EDITOR_MIN_SIZE / (float) s.designW, (float) JCP_EDITOR_MIN_SIZE / (float) s.designH);
        const float hi = std::min((float) JCP_EDITOR_MAX_SIZE / (float) s.designW, (float) JCP_EDITOR_MAX_SIZE / (float) s.designH);
        s.maxScale = juce::jlimit(lo, hi, maxScale);
        s.minScale = juce::jlimit(lo, s.maxScale, minScale);
    }

    // A scaled editor's design size changed (or scaling began): the window
    // follows at the current scale.
    static void scaledSizeChanged(Access& a) noexcept
    {
        PascalEditor::windowSizeFor(*a.session, a->component != nullptr ? a->lastScale : 1.0f, a->width, a->height);
        if (a->component != nullptr && ! deferWhilePainting(a, &applyScaling))
        {
            const auto session = a.session;
            a.lock.unlock(); // the host may be called: never under editorMutex() (only this thread deletes the window)
            try { applyScaling(*session); }
            catch (...) {}
        }
    }

    static void JCP_CALL setSize(jcp_editor* e, int32_t width, int32_t height) noexcept
    {
        Access a(e);
        if (! a)
            return;
        a->sizeSet = true;
        if (a->scaled)
        {
            // In design units: the window keeps its scale.
            a->designW = clampSize(width);
            a->designH = clampSize(height);
            setScaleLimits(*a.session, a->askedMinScale, a->askedMaxScale);
            scaledSizeChanged(a);
            return;
        }
        a->width = clampSize(width);
        a->height = clampSize(height);
        if (a->component != nullptr && ! deferWhilePainting(a, &applySize))
        {
            const auto session = a.session;
            a.lock.unlock(); // the host may be called: never under editorMutex() (only this thread deletes the window)
            try { applySize(*session); }
            catch (...) {}
        }
    }

    static void JCP_CALL setResizeLimits(jcp_editor* e, int32_t minW, int32_t minH, int32_t maxW, int32_t maxH) noexcept
    {
        Access a(e);
        if (! a)
            return;
        if (maxW <= 0 || maxH <= 0)
        {
            a->minW = a->minH = a->maxW = a->maxH = 0;
        }
        else
        {
            a->minW = clampSize(minW);
            a->minH = clampSize(minH);
            a->maxW = std::max(a->minW, clampSize(maxW));
            a->maxH = std::max(a->minH, clampSize(maxH));
        }
        if (a->scaled)
        {
            // Scaling ends: back to the design size, unscaled.
            a->scaled = false;
            a->width = a->designW;
            a->height = a->designH;
            if (a->component != nullptr && ! deferWhilePainting(a, &applyScaling))
            {
                const auto session = a.session;
                a.lock.unlock();
                try { applyScaling(*session); }
                catch (...) {}
            }
            return;
        }
        if (a->component != nullptr && ! deferWhilePainting(a, &applyResizeLimits))
        {
            const auto session = a.session;
            a.lock.unlock(); // the host may be called: never under editorMutex() (only this thread deletes the window)
            try { applyResizeLimits(*session); }
            catch (...) {}
        }
    }

    static void JCP_CALL startTimer(jcp_editor* e, int32_t hz) noexcept
    {
        Access a(e);
        if (! a)
            return;
        a->timerHz = juce::jlimit(1, 120, (int) hz);
        if (a->component != nullptr)
            a->component->startLibraryTimer(a->timerHz);
    }

    static void JCP_CALL stopTimer(jcp_editor* e) noexcept
    {
        Access a(e);
        if (! a)
            return;
        a->timerHz = 0;
        if (a->component != nullptr)
            a->component->stopLibraryTimer();
    }

    static void JCP_CALL setTooltip(jcp_editor* e, const char* text) noexcept
    {
        Access a(e);
        if (! a)
            return;
        try
        {
            a->tooltip = safeText(text, JCP_EDITOR_MAX_TEXT);
            if (a->component != nullptr)
                a->component->setTooltip(a->tooltip);
        }
        catch (...) {}
    }

    //--------------------------------------------------------------------------
    static void JCP_CALL setDesignSize(jcp_editor* e, int32_t width, int32_t height, float minScale, float maxScale,
                                       int32_t flags) noexcept
    {
        Access a(e);
        if (! a || ! std::isfinite(minScale) || ! std::isfinite(maxScale))
            return;
        a->sizeSet = true;
        a->scaled = true;
        a->designW = clampSize(width);
        a->designH = clampSize(height);
        a->scaleFlags = flags & JCP_SCALE_CORNER_RESIZER;
        setScaleLimits(*a.session, minScale, maxScale);
        a->minW = a->minH = a->maxW = a->maxH = 0;
        scaledSizeChanged(a);
    }

    static float JCP_CALL getScale(jcp_editor* e) noexcept
    {
        Access a(e);
        if (! a)
            return 0.0f;
        const float s = std::min(a->scaleX, a->scaleY);
        return std::isfinite(s) && s > 0.0f ? s : 1.0f;
    }

    static int32_t JCP_CALL openUrl(jcp_editor* e, const char* url) noexcept
    {
        Access a(e);
        // Only as the answer to a user's click on this editor: inside its own
        // mouse press / release / double click or menu-choice callback (call
        // depth 1, no paint in progress on this thread), once per click.
        if (! a || a->component == nullptr || ! a->userClick || a->urlOpenedThisClick || a->callDepth != 1
            || currentPaint != nullptr || a->graphics != nullptr || a->processor == nullptr)
            return 0;
        try
        {
            // At most one page a second in the whole process (message thread
            // only, so plain statics): reopening an editor does not reset it.
            static bool everOpened = false;
            static double lastOpenedMs = 0.0;
            const double now = juce::Time::getMillisecondCounterHiRes();
            if (everOpened && now - lastOpenedMs < 1000.0 && now >= lastOpenedMs)
                return 0;
            auto checked = validatedUrl(url);
            if (checked.empty())
                return 0;
            // Opened from the message loop: never inside the library's callback
            // or under the editor lock (the OS call may pump messages).
            if (! juce::MessageManager::callAsync([u = std::move(checked)] { launchUrl(u); }))
                return 0;
            a->urlOpenedThisClick = true;
            everOpened = true;
            lastOpenedMs = now;
            return 1;
        }
        catch (...)
        {
            return 0;
        }
    }

    static void JCP_CALL setLook(jcp_editor* e, const jcp_editor_look* look) noexcept
    {
        Access a(e);
        if (! a)
            return;
        try
        {
            LookSettings settings;
            if (look != nullptr)
            {
                if (look->struct_size < (int32_t) sizeof(jcp_editor_look) || ! std::isfinite(look->tooltip_font_height)
                    || ! std::isfinite(look->menu_font_height)
                    || (look->font_name != nullptr && strnlen(look->font_name, 257) > 256)
                    || ! isSafeText(look->font_name, 256))
                    return; // the whole look is refused: nothing of it is used
                const auto fontHeight = [](float h) { return h > 0.0f ? juce::jlimit(6.0f, 72.0f, h) : 0.0f; };
                settings.tooltipBackground = look->tooltip_background;
                settings.tooltipText = look->tooltip_text;
                settings.tooltipOutline = look->tooltip_outline;
                settings.menuBackground = look->menu_background;
                settings.menuText = look->menu_text;
                settings.menuHighlight = look->menu_highlight;
                settings.menuHighlightText = look->menu_highlight_text;
                settings.menuHeaderText = look->menu_header_text;
                settings.tooltipFontHeight = fontHeight(look->tooltip_font_height);
                settings.menuFontHeight = fontHeight(look->menu_font_height);
                settings.fontName = safeText(look->font_name, 256);
            }
            a->look = settings;
            if (a->component != nullptr)
                a->component->applyLook();
        }
        catch (...) {}
    }

    // A menu's answer, delivered once the editor can take a callback (it is
    // retried from the message loop while another callback is running), or
    // dropped if the window closed.
    static void deliverPopupResult(std::weak_ptr<EditorSession> weak, int32_t menuId, int result, int attempt) noexcept
    {
        const auto s = weak.lock();
        if (s == nullptr)
            return; // the editor is long gone
        {
            const std::lock_guard<std::recursive_mutex> lock(editorMutex());
            s->menuOpen = false;
            if (s->component == nullptr || s->closed || s->processor == nullptr)
                return; // closed while the menu was up: drop the answer
            if ((s->callDepth > 0 || s->processor->insideLibraryCall()) && attempt < 10000)
            {
                s->menuOpen = true; // still pending
                try
                {
                    juce::MessageManager::callAsync([weak, menuId, result, attempt]
                                                    { deliverPopupResult(weak, menuId, result, attempt + 1); });
                }
                catch (...) { s->menuOpen = false; }
                return;
            }
        }
        // A chosen item is a user's click (open_url may answer it); dismissing is not.
        PascalEditor::call(s, [menuId, result, &s](void* lib, const jcp_editor_vtable& vt)
        {
            if (vt.popup_result == nullptr)
                return;
            s->userClick = result != 0;
            s->urlOpenedThisClick = false;
            vt.popup_result(lib, menuId, (int32_t) result);
            s->userClick = false;
        });
        s->userClick = false;
    }

    static int32_t JCP_CALL showPopupMenu(jcp_editor* e, const jcp_menu_item* items, int32_t count, int32_t itemSize,
                                          int32_t menuId, float x, float y) noexcept
    {
        Access a(e);
        if (! a || a->component == nullptr || a->menuOpen || items == nullptr || count <= 0 || count > JCP_MAX_MENU_ITEMS
            || itemSize < (int32_t) sizeof(jcp_menu_item) || itemSize > 4096 || ! coordArg(x) || ! coordArg(y))
            return 0;
        try
        {
            juce::PopupMenu menu;
            int usable = 0;
            for (int32_t i = 0; i < count; ++i)
            {
                const auto& item = *reinterpret_cast<const jcp_menu_item*>(reinterpret_cast<const char*>(items)
                                                                           + (size_t) i * (size_t) itemSize);
                if ((item.flags & JCP_MENU_SEPARATOR) != 0)
                {
                    menu.addSeparator();
                    continue;
                }
                if (! isSafeText(item.text, 1024))
                    return 0;
                const auto text = safeText(item.text, 1024);
                if ((item.flags & JCP_MENU_HEADER) != 0)
                {
                    menu.addSectionHeader(text);
                    continue;
                }
                if (item.id <= 0)
                    return 0;
                menu.addItem(item.id, text, (item.flags & JCP_MENU_DISABLED) == 0, (item.flags & JCP_MENU_TICKED) != 0);
                ++usable;
            }
            if (usable == 0)
                return 0;

            auto* component = a->component;
            const auto screen = component->localPointToGlobal(juce::Point<float>(x * a->scaleX, y * a->scaleY)).roundToInt();
            const std::weak_ptr<EditorSession> weak = a.session;
            // The editor's look; the callback keeps it alive while the menu is up,
            // also if the editor closes first.
            auto look = component->getLook();
            menu.setLookAndFeel(look.get());
            a->menuOpen = true;
            menu.showMenuAsync(juce::PopupMenu::Options().withTargetComponent(component)
                                                         .withTargetScreenArea({ screen.x, screen.y, 1, 1 }),
                               [weak, menuId, look](int result) { (void) look; deliverPopupResult(weak, menuId, result, 0); });
            return 1;
        }
        catch (...)
        {
            a->menuOpen = false;
            return 0;
        }
    }

    //--------------------------------------------------------------------------
    static int32_t JCP_CALL getParameterCount(jcp_editor* e) noexcept
    {
        Access a(e);
        return a && a->processor != nullptr ? (int32_t) a->processor->parameters.size() : 0;
    }

    static int32_t JCP_CALL findParameter(jcp_editor* e, const char* id) noexcept
    {
        Access a(e);
        if (! a || a->processor == nullptr || ! isSafeText(id, 256))
            return -1;
        try
        {
            const auto wanted = safeText(id, 256);
            if (wanted.isEmpty())
                return -1;
            const auto& list = a->processor->parameters;
            for (size_t i = 0; i < list.size(); ++i)
                if (list[i]->getParameterID() == wanted)
                    return (int32_t) i;
        }
        catch (...) {}
        return -1;
    }

    static float JCP_CALL getParameterNormalised(jcp_editor* e, int32_t index) noexcept
    {
        Access a(e);
        auto* p = parameter(a, index);
        return p != nullptr ? PascalPluginProcessor::sanitisedNormalised(*p) : 0.0f;
    }

    static float JCP_CALL getParameterDefault(jcp_editor* e, int32_t index) noexcept
    {
        Access a(e);
        auto* p = parameter(a, index);
        if (p == nullptr)
            return 0.0f;
        const float v = p->getDefaultValue();
        return std::isfinite(v) ? juce::jlimit(0.0f, 1.0f, v) : 0.0f;
    }

    static float JCP_CALL normalisedToPlain(jcp_editor* e, int32_t index, float normalised) noexcept
    {
        Access a(e);
        auto* p = parameter(a, index);
        if (p == nullptr)
            return 0.0f;
        const auto& range = p->getNormalisableRange();
        const float plain = p->convertFrom0to1(juce::jlimit(0.0f, 1.0f, finiteOr(normalised, 0.0f)));
        return std::isfinite(plain) ? juce::jlimit(range.start, range.end, plain) : range.start;
    }

    static float JCP_CALL plainToNormalised(jcp_editor* e, int32_t index, float plain) noexcept
    {
        Access a(e);
        auto* p = parameter(a, index);
        if (p == nullptr)
            return 0.0f;
        const auto& range = p->getNormalisableRange();
        const float v = p->convertTo0to1(juce::jlimit(range.start, range.end, finiteOr(plain, range.start)));
        return std::isfinite(v) ? juce::jlimit(0.0f, 1.0f, v) : 0.0f;
    }

    static int32_t JCP_CALL getParameterText(jcp_editor* e, int32_t index, float normalised, char* buffer, int32_t size) noexcept
    {
        Access a(e);
        auto* p = parameter(a, index);
        if (p == nullptr || buffer == nullptr || size <= 0)
            return 0;
        buffer[0] = '\0';
        try
        {
            const auto text = p->getText(juce::jlimit(0.0f, 1.0f, finiteOr(normalised, 0.0f)), 1024);
            const std::string utf8 = text.toStdString();
            size_t n = std::min(utf8.size(), (size_t) size - 1);
            while (n > 0 && n < utf8.size() && (static_cast<unsigned char>(utf8[n]) & 0xC0) == 0x80)
                --n; // never split a character
            std::memcpy(buffer, utf8.data(), n);
            buffer[n] = '\0';
            return (int32_t) n;
        }
        catch (...)
        {
            buffer[0] = '\0';
            return 0;
        }
    }

    static void JCP_CALL beginGesture(jcp_editor* e, int32_t index) noexcept
    {
        Access a(e);
        if (parameter(a, index) == nullptr)
            return;
        try
        {
            if (a->openGestures.insert(index).second)
                a->processor->gestureActive[(size_t) index].store(true, std::memory_order_release);
            a->processor->triggerAsyncUpdate(); // delivered when the library callback returns, or from the message loop
        }
        catch (...) {}
    }

    static void JCP_CALL setParameterNormalised(jcp_editor* e, int32_t index, float normalised) noexcept
    {
        Access a(e);
        auto* p = parameter(a, index);
        if (p == nullptr || ! std::isfinite(normalised))
            return;
        const auto& range = p->getNormalisableRange();
        const float plain = p->convertFrom0to1(juce::jlimit(0.0f, 1.0f, normalised));
        if (! std::isfinite(plain))
            return;
        a->processor->pendingValue[(size_t) index].store(juce::jlimit(range.start, range.end, plain), std::memory_order_release);
        a->processor->pendingDirty[(size_t) index].store(true, std::memory_order_release);
        a->processor->triggerAsyncUpdate();
    }

    static void JCP_CALL endGesture(jcp_editor* e, int32_t index) noexcept
    {
        Access a(e);
        if (parameter(a, index) == nullptr)
            return;
        if (a->openGestures.erase(index) > 0)
            a->processor->gestureActive[(size_t) index].store(false, std::memory_order_release);
        a->processor->triggerAsyncUpdate();
    }

    static float JCP_CALL getMeter(jcp_editor* e, int32_t index) noexcept
    {
        Access a(e);
        if (! a || a->processor == nullptr || ! juce::isPositiveAndBelow(index, (int32_t) JCP_MAX_METERS))
            return 0.0f;
        return a->processor->meters[(size_t) index].load(std::memory_order_relaxed);
    }

    //--------------------------------------------------------------------------
    // A bounded read-only view of the image data.
    class BoundedImageStream final : public juce::InputStream
    {
    public:
        BoundedImageStream(const void* d, size_t n) noexcept : data(static_cast<const char*>(d)), size(n) {}
        juce::int64 getTotalLength() override { return (juce::int64) size; }
        bool isExhausted() override { return position >= size; }
        juce::int64 getPosition() override { return (juce::int64) position; }
        bool setPosition(juce::int64 p) override
        {
            position = (size_t) juce::jlimit((juce::int64) 0, (juce::int64) size, p);
            return true;
        }
        int read(void* dest, int bytes) override
        {
            if (dest == nullptr || bytes <= 0)
                return 0;
            const size_t available = std::min((size_t) bytes, size - position);
            std::memcpy(dest, data + position, available);
            std::memset(static_cast<char*>(dest) + available, 0, (size_t) bytes - available);
            position += available;
            return bytes;
        }

    private:
        const char* data;
        size_t size, position = 0;
    };

    static int32_t JCP_CALL createImage(jcp_editor* e, const void* data, int32_t size) noexcept
    {
        Access a(e);
        if (! a || data == nullptr || size <= 0 || size > JCP_MAX_IMAGE_BYTES
            || (int) a->images.size() >= JCP_MAX_EDITOR_IMAGES || a->nextImage >= std::numeric_limits<int32_t>::max())
            return 0;
        try
        {
            // The whole structure is checked (and the size taken from the
            // header) before a decoder sees a byte.
            int w = 0, h = 0;
            const auto kind = image::check(data, (size_t) size, JCP_MAX_IMAGE_SIDE, w, h);
            const int64_t pixels = (int64_t) w * h;
            if (kind == image::Kind::none || pixels > JCP_MAX_IMAGE_PIXELS || a->imagePixels + pixels > maxEditorPixels)
                return 0;
            juce::Image decoded;
            {
                ScopedFpState fpGuard;
                BoundedImageStream stream(data, (size_t) size);
                if (kind == image::Kind::png)
                    decoded = juce::PNGImageFormat().decodeImage(stream);
                else
                    decoded = juce::JPEGImageFormat().decodeImage(stream);

            }
            if (! decoded.isValid() || decoded.getWidth() != w || decoded.getHeight() != h)
                return 0;
            // A plain software ARGB copy: drawn the same into every kind of context.
            auto image = juce::SoftwareImageType().convert(decoded).convertedToFormat(juce::Image::ARGB);
            if (! image.isValid())
                return 0;
            const int32_t handle = a->nextImage++;
            a->images[handle] = image;
            a->imagePixels += pixels;
            return handle;
        }
        catch (...)
        {
            return 0;
        }
    }

    static void JCP_CALL destroyImage(jcp_editor* e, int32_t image) noexcept
    {
        Access a(e);
        if (! a)
            return;
        const auto found = a->images.find(image);
        if (found == a->images.end())
            return;
        a->imagePixels -= (int64_t) found->second.getWidth() * found->second.getHeight();
        a->images.erase(found); // a paint drawing it holds its own reference
    }

    static int32_t JCP_CALL getImageSize(jcp_editor* e, int32_t image, int32_t* width, int32_t* height) noexcept
    {
        Access a(e);
        if (width != nullptr)
            *width = 0;
        if (height != nullptr)
            *height = 0;
        if (! a)
            return 0;
        const auto found = a->images.find(image);
        if (found == a->images.end())
            return 0;
        if (width != nullptr)
            *width = found->second.getWidth();
        if (height != nullptr)
            *height = found->second.getHeight();
        return 1;
    }

    static juce::Font makeFont(const char* name, float height, int32_t style)
    {
        auto options = juce::FontOptions(juce::jlimit(1.0f, 1000.0f, height));
        const auto typeface = safeText(name, 256);
        if (typeface.isNotEmpty())
            options = options.withName(typeface);
        juce::Font font(options);
        font.setStyleFlags(style & (JCP_FONT_BOLD | JCP_FONT_ITALIC | JCP_FONT_UNDERLINE));
        return font;
    }

    static float JCP_CALL getTextWidth(jcp_editor* e, const char* text, const char* fontName, float height, int32_t style) noexcept
    {
        Access a(e);
        if (! a || text == nullptr || ! std::isfinite(height) || ! isSafeText(text, JCP_EDITOR_MAX_TEXT)
            || ! isSafeText(fontName, 256))
            return 0.0f;
        try
        {
            ScopedFpState fpGuard;
            const float w = juce::GlyphArrangement::getStringWidth(makeFont(fontName, height, style),
                                                                   safeText(text, JCP_EDITOR_MAX_TEXT));
            return std::isfinite(w) ? juce::jlimit(0.0f, 2.0f * maxCoord, w) : 0.0f;
        }
        catch (...)
        {
            return 0.0f;
        }
    }

    //--------------------------------------------------------------------------
    // Drawing. A macro keeps every entry point identical: validate the token,
    // mask FP exceptions, contain exceptions.
#define PASCALJUCE_PAINT(body) \
        auto* s = painting(g); \
        if (s == nullptr) \
            return; \
        auto& gr = *s->graphics; \
        (void) gr; \
        try { ScopedFpState fpGuard; body } catch (...) {}

    static void JCP_CALL setColour(jcp_graphics* g, uint32_t argb) noexcept
    {
        PASCALJUCE_PAINT( gr.setColour(juce::Colour(argb)); )
    }

    static void JCP_CALL setGradient(jcp_graphics* g, uint32_t argb1, float x1, float y1, uint32_t argb2, float x2,
                                     float y2, int32_t radial) noexcept
    {
        if (! coordArg(x1) || ! coordArg(y1) || ! coordArg(x2) || ! coordArg(y2))
            return;
        PASCALJUCE_PAINT(
            // JUCE divides by the distance between the points: a degenerate
            // gradient is drawn as the end colour.
            if (juce::Point<float>(x1, y1).getDistanceFrom({ x2, y2 }) < 0.5f)
                gr.setColour(juce::Colour(argb2));
            else
                gr.setGradientFill(juce::ColourGradient(juce::Colour(argb1), x1, y1, juce::Colour(argb2), x2, y2, radial != 0));
        )
    }

    static void JCP_CALL fillAll(jcp_graphics* g) noexcept
    {
        PASCALJUCE_PAINT( gr.fillAll(); )
    }

    static void JCP_CALL fillRect(jcp_graphics* g, float x, float y, float w, float h) noexcept
    {
        if (! rectArgs(x, y, w, h))
            return;
        PASCALJUCE_PAINT( gr.fillRect(juce::Rectangle<float>(x, y, w, h)); )
    }

    static void JCP_CALL drawRect(jcp_graphics* g, float x, float y, float w, float h, float t) noexcept
    {
        if (! rectArgs(x, y, w, h) || ! thicknessArg(t))
            return;
        PASCALJUCE_PAINT( gr.drawRect(juce::Rectangle<float>(x, y, w, h), t); )
    }

    static void JCP_CALL fillRoundedRect(jcp_graphics* g, float x, float y, float w, float h, float r) noexcept
    {
        if (! rectArgs(x, y, w, h) || ! extentArg(r))
            return;
        PASCALJUCE_PAINT( gr.fillRoundedRectangle(x, y, w, h, r); )
    }

    static void JCP_CALL drawRoundedRect(jcp_graphics* g, float x, float y, float w, float h, float r, float t) noexcept
    {
        if (! rectArgs(x, y, w, h) || ! extentArg(r) || ! thicknessArg(t))
            return;
        PASCALJUCE_PAINT( gr.drawRoundedRectangle(x, y, w, h, r, t); )
    }

    static void JCP_CALL fillEllipse(jcp_graphics* g, float x, float y, float w, float h) noexcept
    {
        if (! rectArgs(x, y, w, h))
            return;
        PASCALJUCE_PAINT( gr.fillEllipse(x, y, w, h); )
    }

    static void JCP_CALL drawEllipse(jcp_graphics* g, float x, float y, float w, float h, float t) noexcept
    {
        if (! rectArgs(x, y, w, h) || ! thicknessArg(t))
            return;
        PASCALJUCE_PAINT( gr.drawEllipse(x, y, w, h, t); )
    }

    static void JCP_CALL drawLine(jcp_graphics* g, float x1, float y1, float x2, float y2, float t) noexcept
    {
        if (! coordArg(x1) || ! coordArg(y1) || ! coordArg(x2) || ! coordArg(y2) || ! thicknessArg(t))
            return;
        PASCALJUCE_PAINT( gr.drawLine(x1, y1, x2, y2, t); )
    }

    static bool pathRoom(EditorSession& s, int elements) noexcept
    {
        if (s.pathElements + elements > maxPathElements)
            return false;
        s.pathElements += elements;
        return true;
    }

    static void JCP_CALL pathBegin(jcp_graphics* g) noexcept
    {
        PASCALJUCE_PAINT( s->path.clear(); s->pathElements = 0; )
    }

    static void JCP_CALL pathMoveTo(jcp_graphics* g, float x, float y) noexcept
    {
        if (! coordArg(x) || ! coordArg(y))
            return;
        PASCALJUCE_PAINT( if (pathRoom(*s, 1)) s->path.startNewSubPath(x, y); )
    }

    static void JCP_CALL pathLineTo(jcp_graphics* g, float x, float y) noexcept
    {
        if (! coordArg(x) || ! coordArg(y))
            return;
        PASCALJUCE_PAINT( if (pathRoom(*s, 1)) s->path.lineTo(x, y); )
    }

    static void JCP_CALL pathQuadTo(jcp_graphics* g, float cx, float cy, float x, float y) noexcept
    {
        if (! coordArg(cx) || ! coordArg(cy) || ! coordArg(x) || ! coordArg(y))
            return;
        PASCALJUCE_PAINT( if (pathRoom(*s, 1)) s->path.quadraticTo(cx, cy, x, y); )
    }

    static void JCP_CALL pathCubicTo(jcp_graphics* g, float c1x, float c1y, float c2x, float c2y, float x, float y) noexcept
    {
        if (! coordArg(c1x) || ! coordArg(c1y) || ! coordArg(c2x) || ! coordArg(c2y) || ! coordArg(x) || ! coordArg(y))
            return;
        PASCALJUCE_PAINT( if (pathRoom(*s, 1)) s->path.cubicTo(c1x, c1y, c2x, c2y, x, y); )
    }

    static void JCP_CALL pathArc(jcp_graphics* g, float cx, float cy, float rx, float ry, float from, float to,
                                 int32_t startNew) noexcept
    {
        if (! coordArg(cx) || ! coordArg(cy) || ! extentArg(rx) || ! extentArg(ry) || ! std::isfinite(from)
            || ! std::isfinite(to))
            return;
        // JUCE walks the arc in small steps: bound the sweep (two turns) and the start angle.
        constexpr float twoPi = juce::MathConstants<float>::twoPi;
        from = std::fmod(from, twoPi);
        to = from + juce::jlimit(-2.0f * twoPi, 2.0f * twoPi, to - from);
        PASCALJUCE_PAINT( if (pathRoom(*s, 512)) s->path.addCentredArc(cx, cy, rx, ry, 0.0f, from, to, startNew != 0); )
    }

    static void JCP_CALL pathClose(jcp_graphics* g) noexcept
    {
        PASCALJUCE_PAINT( if (pathRoom(*s, 1)) s->path.closeSubPath(); )
    }

    static void JCP_CALL fillPath(jcp_graphics* g) noexcept
    {
        PASCALJUCE_PAINT( gr.fillPath(s->path); )
    }

    static void JCP_CALL strokePath(jcp_graphics* g, float t, int32_t join, int32_t cap) noexcept
    {
        if (! thicknessArg(t))
            return;
        const auto jointStyle = join == JCP_JOIN_ROUND ? juce::PathStrokeType::curved
                              : join == JCP_JOIN_BEVEL ? juce::PathStrokeType::beveled : juce::PathStrokeType::mitered;
        const auto capStyle = cap == JCP_CAP_ROUND ? juce::PathStrokeType::rounded
                            : cap == JCP_CAP_SQUARE ? juce::PathStrokeType::square : juce::PathStrokeType::butt;
        PASCALJUCE_PAINT( gr.strokePath(s->path, juce::PathStrokeType(t, jointStyle, capStyle)); )
    }

    static void JCP_CALL setFont(jcp_graphics* g, const char* name, float height, int32_t style) noexcept
    {
        if (! std::isfinite(height) || ! isSafeText(name, 256))
            return;
        PASCALJUCE_PAINT( gr.setFont(makeFont(name, height, style)); )
    }

    static void JCP_CALL drawText(jcp_graphics* g, const char* text, float x, float y, float w, float h,
                                  int32_t justification, int32_t ellipsis) noexcept
    {
        if (text == nullptr || ! rectArgs(x, y, w, h) || ! isSafeText(text, JCP_EDITOR_MAX_TEXT))
            return;
        PASCALJUCE_PAINT(
            const auto flags = justification & (JCP_JUSTIFY_LEFT | JCP_JUSTIFY_RIGHT | JCP_JUSTIFY_HCENTRE
                                                | JCP_JUSTIFY_TOP | JCP_JUSTIFY_BOTTOM | JCP_JUSTIFY_VCENTRE);
            const juce::Justification just(flags != 0 ? flags : juce::Justification::centredLeft);
            if (ellipsis == JCP_TEXT_FIT)
            {
                // one line, squeezed to 70% at most, then shortened (Graphics::drawFittedText)
                juce::GlyphArrangement glyphs;
                glyphs.addFittedText(gr.getCurrentFont(), safeText(text, JCP_EDITOR_MAX_TEXT), x, y, w, h, just, 1, 0.7f);
                glyphs.draw(gr);
            }
            else
                gr.drawText(safeText(text, JCP_EDITOR_MAX_TEXT), juce::Rectangle<float>(x, y, w, h), just, ellipsis != 0);
        )
    }

    static void JCP_CALL drawImage(jcp_graphics* g, int32_t image, float dx, float dy, float dw, float dh, float sx,
                                   float sy, float sw, float sh, float opacity) noexcept
    {
        if (! rectArgs(dx, dy, dw, dh) || ! rectArgs(sx, sy, sw, sh) || ! std::isfinite(opacity))
            return;
        PASCALJUCE_PAINT(
            const auto found = s->images.find(image);
            if (found == s->images.end())
                return;
            const juce::Image img = found->second; // our own reference for the draw
            const auto source = juce::Rectangle<float>(sx, sy, sw, sh).getSmallestIntegerContainer()
                                    .getIntersection(img.getBounds());
            if (source.isEmpty() || dw <= 0.0f || dh <= 0.0f)
                return;
            gr.saveState();
            gr.setOpacity(juce::jlimit(0.0f, 1.0f, opacity));
            gr.drawImageTransformed(img.getClippedImage(source),
                                    juce::AffineTransform::scale(dw / (float) source.getWidth(), dh / (float) source.getHeight())
                                        .translated(dx, dy));
            gr.restoreState();
        )
    }

    static void JCP_CALL saveState(jcp_graphics* g) noexcept
    {
        PASCALJUCE_PAINT( if (s->saveDepth < maxSaveDepth) { s->origins.push_back(s->origin); gr.saveState(); ++s->saveDepth; } )
    }

    static void JCP_CALL restoreState(jcp_graphics* g) noexcept
    {
        PASCALJUCE_PAINT( if (s->saveDepth > 0) { gr.restoreState(); --s->saveDepth; s->origin = s->origins.back(); s->origins.pop_back(); } )
    }

    static int32_t JCP_CALL clipRect(jcp_graphics* g, float x, float y, float w, float h) noexcept
    {
        auto* s = painting(g);
        if (s == nullptr || ! rectArgs(x, y, w, h))
            return 0;
        try
        {
            ScopedFpState fpGuard;
            return s->graphics->reduceClipRegion(juce::Rectangle<float>(x, y, w, h).getSmallestIntegerContainer()) ? 1 : 0;
        }
        catch (...)
        {
            return 0;
        }
    }

    static void JCP_CALL translate(jcp_graphics* g, float dx, float dy) noexcept
    {
        if (! coordArg(dx) || ! coordArg(dy))
            return;
        PASCALJUCE_PAINT(
            const juce::Point<float> target(juce::jlimit(-maxCoord, maxCoord, s->origin.x + dx),
                                            juce::jlimit(-maxCoord, maxCoord, s->origin.y + dy));
            gr.addTransform(juce::AffineTransform::translation(target.x - s->origin.x, target.y - s->origin.y));
            s->origin = target;
        )
    }
#undef PASCALJUCE_PAINT

    static const jcp_editor_api& table() noexcept
    {
        static const jcp_editor_api api {
            (int32_t) sizeof(jcp_editor_api), 0,
            &repaint, &setSize, &setResizeLimits, &startTimer, &stopTimer, &setTooltip, &showPopupMenu,
            &getParameterCount, &findParameter, &getParameterNormalised, &getParameterDefault,
            &normalisedToPlain, &plainToNormalised, &getParameterText, &beginGesture, &setParameterNormalised,
            &endGesture, &getMeter,
            &createImage, &destroyImage, &getImageSize, &getTextWidth,
            &setColour, &setGradient, &fillAll, &fillRect, &drawRect, &fillRoundedRect, &drawRoundedRect,
            &fillEllipse, &drawEllipse, &drawLine,
            &pathBegin, &pathMoveTo, &pathLineTo, &pathQuadTo, &pathCubicTo, &pathArc, &pathClose, &fillPath, &strokePath,
            &setFont, &drawText, &drawImage, &saveState, &restoreState, &clipRect, &translate,
            &setDesignSize, &getScale, &openUrl, &setLook
        };
        return api;
    }
};

juce::AudioProcessorEditor* PascalPluginProcessor::createCustomEditor()
{
    if (instance == nullptr || vtable.create_editor == nullptr || insideLibraryCall() || ! onMessageThread())
        return nullptr;
    auto s = std::make_shared<EditorSession>();
    s->id = nextEditorToken();
    s->processor = this;
    s->vtable.struct_size = (int32_t) sizeof(jcp_editor_vtable);
    void* created = nullptr;
    {
        const std::lock_guard<std::recursive_mutex> lock(editorMutex());
        editorRegistry()[s->id] = s; // the library may use the handle inside create_editor
        int32_t width = 400, height = 300;
        ++s->callDepth;
        {
            ScopedFpState fpGuard;
            LibraryCall inLibrary(*this);
            created = vtable.create_editor(instance, &EditorApi::table(), reinterpret_cast<jcp_editor*>(s->id), &s->vtable,
                                           &width, &height);
        }
        --s->callDepth;
        if (created == nullptr || s->vtable.destroy == nullptr)
        {
            // No custom editor (an object without destroy is leaked by design).
            s->closed = true;
            s->images.clear();
            editorRegistry().erase(s->id);
            for (const auto index : s->openGestures)
                gestureActive[(size_t) index].store(false, std::memory_order_release);
            triggerAsyncUpdate();
            return nullptr;
        }
        s->libEditor = created;
        if (! s->sizeSet)
        {
            s->width = EditorApi::clampSize(width);
            s->height = EditorApi::clampSize(height);
        }
        editorSessions.push_back(s);
    }
    deliverHostNotifications();
    try
    {
        return new PascalEditor(*this, s);
    }
    catch (...)
    {
        finishSession(s);
        return nullptr;
    }
}

void PascalPluginProcessor::detachEditors() noexcept
{
    const std::lock_guard<std::recursive_mutex> lock(editorMutex());
    const auto sessions = editorSessions; // finishSession edits the list
    for (const auto& s : sessions)
    {
        if (onMessageThread() && ! insideLibraryCall() && s->callDepth == 0)
        {
            if (s->component != nullptr)
                s->component->processorGone();
            finishSession(s); // the library editor is destroyed before the instance
        }
        else
        {
            // Not safe to call the library editor now: abandon it (never called again).
            s->closed = true;
            editorRegistry().erase(s->id);
        }
        s->processor = nullptr;
    }
    editorSessions.clear();
}
} // namespace pascaljuce

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new pascaljuce::PascalPluginProcessor();
}

#if defined(PASCALJUCE_EDITOR_TEST_HOOKS)
// Test executables that link the wrapper: editor sessions still registered.
int pascaljuce_live_editor_sessions()
{
    const std::lock_guard<std::recursive_mutex> lock(pascaljuce::editorMutex());
    return (int) pascaljuce::editorRegistry().size();
}
#endif

#if defined(PASCALJUCE_EDITOR_TEST_HOOKS)
// URLs open_url accepted (test builds record them instead of starting a browser).
int pascaljuce_test_opened_url_count()
{
    return (int) pascaljuce::testOpenedUrls().size();
}

std::string pascaljuce_test_opened_url(int index)
{
    const auto& urls = pascaljuce::testOpenedUrls();
    return index >= 0 && (size_t) index < urls.size() ? urls[(size_t) index] : std::string();
}

// The validator itself: what open_url would open for a string ("" = refused).
std::string pascaljuce_test_validated_url(const char* url)
{
    return pascaljuce::validatedUrl(url);
}
#endif
