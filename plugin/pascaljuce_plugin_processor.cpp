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

#if defined(PASCALJUCE_HAS_LIBRARY_HASH)
    #include "pascaljuce_library_hash.h" // generated: #define PASCALJUCE_PLUGIN_SHA256 "..."
#endif

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
static_assert(sizeof(jcp_host_api) == 80, "jcp_host_api layout");
static_assert(offsetof(jcp_host_api, get_extension) == 72, "jcp_host_api layout");
static_assert(sizeof(jcp_plugin_vtable) == 88, "jcp_plugin_vtable layout");
static_assert(offsetof(jcp_plugin_vtable, get_parameter_text) == 72, "jcp_plugin_vtable layout");
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

class PascalPluginProcessor final : public juce::AudioProcessor, private juce::AsyncUpdater
{
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
        destroying.store(true, std::memory_order_release);
        cancelPendingUpdate();
        const std::lock_guard<std::recursive_mutex> waitForDelivery(deliveryMutex); // one may be running on the message thread
        if (instance != nullptr)
        {
            const juce::ScopedLock lock(getCallbackLock()); // a misbehaving host may still be in process()
            prepared.store(false, std::memory_order_release);
            ScopedFpState fpGuard;
            LibraryCall inLibrary(*this);
            vtable.destroy(instance);
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
        return new juce::GenericAudioProcessorEditor(*this);
    }

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
            values.reserve(parameters.size());
            for (auto* parameter : parameters)
                values.emplace_back(parameter->getParameterID().toStdString(),
                                    (double) plainValue(*parameter));

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

    static const jcp_host_api& hostApi()
    {
        static const jcp_host_api api {
            (int32_t) sizeof(jcp_host_api), JCP_ABI_VERSION,
            &hostAddMidiOutput, &hostSetParameter, &hostGetParameter,
            &hostSetLatency, &hostLog, &hostGetSampleRate,
            &hostBeginGesture, &hostEndGesture, &hostGetExtension
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

    bool insideLibraryCall() const noexcept
    {
        if (libraryCallDepth > maxLibraryCallDepth)
            return true; // deeper than we track: assume the worst
        for (int i = 0; i < libraryCallDepth; ++i)
            if (libraryCallStack[i] == this)
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

    void deliverHostNotifications() noexcept
    {
        const std::lock_guard<std::recursive_mutex> lock(deliveryMutex); // the destructor waits for us
        if (destroying.load(std::memory_order_acquire))
            return;
        try
        {
            const int latency = pendingLatency.exchange(-1, std::memory_order_acq_rel);
            if (latency >= 0)
                setLatencySamples(latency);

            for (size_t i = 0; i < parameters.size(); ++i)
            {
                if (destroying.load(std::memory_order_acquire))
                    return;
                const bool dirty = pendingDirty[i].exchange(false, std::memory_order_acq_rel);
                const bool wanted = gestureActive[i].load(std::memory_order_acquire);
                bool open = hostGestureOpen[i];
                if (! dirty && wanted == open)
                    continue;
                auto* parameter = parameters[i];
                if (! open && (wanted || dirty))
                {
                    parameter->beginChangeGesture();
                    open = true;
                }
                if (dirty)
                {
                    const auto& range = parameter->getNormalisableRange();
                    const float value = pendingValue[i].load(std::memory_order_acquire);
                    parameter->setValueNotifyingHost(parameter->convertTo0to1(juce::jlimit(range.start, range.end, value)));
                }
                if (! gestureActive[i].load(std::memory_order_acquire) && open)
                {
                    parameter->endChangeGesture();
                    open = false;
                }
                hostGestureOpen[i] = open;
            }
        }
        catch (...)
        {
        }
    }

    std::atomic<int> pendingLatency { -1 };
    std::unique_ptr<std::atomic<float>[]> pendingValue;
    std::unique_ptr<std::atomic<bool>[]> pendingDirty;
    std::unique_ptr<bool[]> hostGestureOpen; // what the host has been told (message thread only)
    std::recursive_mutex deliveryMutex;
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

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(PascalPluginProcessor)
};
} // namespace pascaljuce

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new pascaljuce::PascalPluginProcessor();
}
