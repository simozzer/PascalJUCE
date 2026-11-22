/*
    pascaljuce_params - writes a plug-in library's parameter list to a text
    file, for the form designer (the ParameterId drop-down and the preview
    values of the PascalJUCE design-time packages).

        pascaljuce_params <plug-in library> <output.params>

    pascaljuce_add_plugin(... PARAMETER_LIST <file>) runs it after every
    build. It loads the library (which runs its initialisation and the
    parameter declarations, nothing else: no instance is created), asks the
    factory for the parameters and writes one tab-separated line each:

        # PascalJUCE parameter list 1
        # id  kind  name  units  min  max  default  step  choices
        attack  float  Attack  ms  1  2000  10  0

    The file is only rewritten when its content changes, so designers and
    build systems watching it are not disturbed. Exit code 0 on success.
*/
#include "juce_c_plugin.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#if defined(_WIN32)
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <windows.h>
#else
    #include <dlfcn.h>
#endif

namespace
{
constexpr int maxParameters = 10000;
constexpr size_t maxText = 4096;

std::string clean(const char* s)
{
    std::string out;
    if (s == nullptr)
        return out;
    for (size_t i = 0; s[i] != '\0' && i < maxText; ++i)
    {
        const char c = s[i];
        out += (c == '\t' || c == '\r' || c == '\n') ? ' ' : c;
    }
    return out;
}

std::string number(float v)
{
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.9g", (double) v); // '.' decimal point: the "C" locale is the default
    return buffer;
}

const char* kindName(int32_t kind)
{
    switch (kind)
    {
        case JCP_PARAM_INT: return "int";
        case JCP_PARAM_BOOL: return "bool";
        case JCP_PARAM_CHOICE: return "choice";
        default: return "float";
    }
}

int fail(const std::string& message)
{
    std::fprintf(stderr, "pascaljuce_params: %s\n", message.c_str());
    return 1;
}
} // namespace

int main(int argc, char** argv)
{
    if (argc != 3)
    {
        std::fprintf(stderr, "usage: pascaljuce_params <plug-in library> <output.params>\n");
        return 2;
    }

#if defined(_WIN32)
    const int wideLength = MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, nullptr, 0);
    std::wstring widePath((size_t) (wideLength > 0 ? wideLength : 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, widePath.data(), wideLength);
    HMODULE library = LoadLibraryExW(widePath.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (library == nullptr)
        return fail(std::string("cannot load ") + argv[1]);
    auto entry = reinterpret_cast<jcp_plugin_entry_fn>(reinterpret_cast<void*>(GetProcAddress(library, JCP_ENTRY_NAME)));
#else
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == nullptr)
        return fail(std::string("cannot load ") + argv[1] + ": " + dlerror());
    auto entry = reinterpret_cast<jcp_plugin_entry_fn>(dlsym(library, JCP_ENTRY_NAME));
#endif
    if (entry == nullptr)
        return fail(std::string(argv[1]) + " does not export " JCP_ENTRY_NAME);

    jcp_plugin_factory factory;
    std::memset(&factory, 0, sizeof(factory));
    factory.struct_size = (int32_t) sizeof(factory);
    if (entry(JCP_ABI_VERSION, &factory) != 0)
        return fail(std::string("the library refused to load: ") + clean(factory.error_message));
    if (factory.get_parameter_count == nullptr || factory.get_parameter_info == nullptr)
        return fail("the library has no parameter functions");

    const int32_t count = factory.get_parameter_count();
    if (count < 0 || count > maxParameters)
        return fail("implausible parameter count " + std::to_string(count));

    std::ostringstream out;
    out << "# PascalJUCE parameter list 1 (written by pascaljuce_params; do not edit)\n";
    out << "# id\tkind\tname\tunits\tmin\tmax\tdefault\tstep\tchoices\n";
    for (int32_t i = 0; i < count; ++i)
    {
        jcp_parameter_info info;
        std::memset(&info, 0, sizeof(info));
        info.struct_size = (int32_t) sizeof(info);
        if (factory.get_parameter_info(i, &info) != 0)
            return fail("parameter " + std::to_string(i) + " has no info");
        out << clean(info.id) << '\t' << kindName(info.kind) << '\t' << clean(info.name) << '\t' << clean(info.label)
            << '\t' << number(info.min_value) << '\t' << number(info.max_value) << '\t' << number(info.default_value)
            << '\t' << number(info.step) << '\t' << (info.kind == JCP_PARAM_CHOICE ? clean(info.choices) : std::string())
            << '\n';
    }
    const std::string text = out.str();

    {
        std::ifstream existing(argv[2], std::ios::binary);
        if (existing)
        {
            std::ostringstream old;
            old << existing.rdbuf();
            if (old.str() == text)
                return 0; // unchanged
        }
    }
    std::ofstream file(argv[2], std::ios::binary | std::ios::trunc);
    if (! file)
        return fail(std::string("cannot write ") + argv[2]);
    file << text;
    if (! file)
        return fail(std::string("cannot write ") + argv[2]);
    std::printf("pascaljuce_params: %d parameters -> %s\n", (int) count, argv[2]);
    // The library stays loaded until exit: Pascal libraries do not always
    // like being unloaded by a process that never created an instance.
    return 0;
}
