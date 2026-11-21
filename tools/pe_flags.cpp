/*
    pe_flags - set or verify exploit-mitigation flags in a Windows PE image.

        pe_flags set   <file>   turn on DYNAMICBASE (ASLR), NX_COMPAT (DEP) and,
                                for 64-bit images, HIGH_ENTROPY_VA
        pe_flags check <file>   exit 1 unless those flags are on

    Free Pascal (3.2) can only set these with {$SETPEOPTFLAGS} in the main
    program/library file, which plug-in authors would have to remember; the
    PascalJUCE build runs `set` on every Pascal library instead. ASLR is only
    enabled if the image has base relocations (otherwise it could not load at
    a random address), and the tool refuses rather than produce a broken DLL.
*/
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace
{
constexpr uint16_t dynamicBase = 0x0040, nxCompat = 0x0100, highEntropyVa = 0x0020;

uint32_t le32(const std::vector<uint8_t>& b, size_t at) { return b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | ((uint32_t) b[at + 3] << 24); }
uint16_t le16(const std::vector<uint8_t>& b, size_t at) { return (uint16_t) (b[at] | (b[at + 1] << 8)); }

int fail(const char* what, const char* file)
{
    std::fprintf(stderr, "pe_flags: %s: %s\n", file, what);
    return 1;
}
}

int main(int argc, char* argv[])
{
    if (argc != 3 || (std::strcmp(argv[1], "set") != 0 && std::strcmp(argv[1], "check") != 0))
    {
        std::fprintf(stderr, "usage: pe_flags <set|check> <file>\n");
        return 2;
    }
    const bool set = std::strcmp(argv[1], "set") == 0;
    const char* file = argv[2];

    std::vector<uint8_t> b;
    if (FILE* f = std::fopen(file, "rb"))
    {
        uint8_t chunk[65536];
        size_t n;
        while ((n = std::fread(chunk, 1, sizeof(chunk), f)) > 0)
            b.insert(b.end(), chunk, chunk + n);
        std::fclose(f);
    }
    else
        return fail("cannot open", file);

    if (b.size() < 0x40 || b[0] != 'M' || b[1] != 'Z')
        return fail("not a PE image (no MZ header)", file);
    // 64-bit arithmetic: e_lfanew is file data and must not wrap a 32-bit size_t.
    const uint64_t peOffset = le32(b, 0x3C);
    if (peOffset + 24 + 112 + 6 * 8 > (uint64_t) b.size())
        return fail("not a PE image (no PE signature)", file);
    const size_t pe = (size_t) peOffset;
    if (std::memcmp(&b[pe], "PE\0\0", 4) != 0)
        return fail("not a PE image (no PE signature)", file);

    const size_t opt = pe + 24;
    const uint16_t magic = le16(b, opt);
    const bool is64 = magic == 0x20B;
    if (magic != 0x10B && ! is64)
        return fail("unknown optional-header magic", file);

    const size_t characteristicsAt = opt + 70; // same offset in PE32 and PE32+
    const size_t dataDirsAt = opt + (is64 ? 112 : 96);
    const size_t numDirsAt = opt + (is64 ? 108 : 92);
    if ((uint64_t) dataDirsAt + 6 * 8 > (uint64_t) b.size()) // already implied by the check above
        return fail("truncated optional header", file);
    const bool hasRelocations = le32(b, numDirsAt) > 5 && le32(b, dataDirsAt + 5 * 8 + 4) != 0;

    uint16_t wanted = (uint16_t) (dynamicBase | nxCompat | (is64 ? highEntropyVa : 0));
    uint16_t current = le16(b, characteristicsAt);

    if (! set)
    {
        if ((current & wanted) != wanted)
        {
            std::fprintf(stderr, "pe_flags: %s: DllCharacteristics 0x%04X lacks 0x%04X (ASLR/DEP)\n", file, current,
                         (unsigned) (wanted & ~current));
            return 1;
        }
        std::printf("pe_flags: %s: DllCharacteristics 0x%04X - ASLR and DEP on\n", file, current);
        return 0;
    }

    if (! hasRelocations)
        return fail("no base relocations: cannot enable ASLR safely (compile with -WR)", file);
    if ((current & wanted) == wanted)
        return 0; // already hardened; don't touch the file (keeps timestamps stable)
    // Data directory 4 is the Authenticode certificate table: changing the header
    // would silently invalidate the signature, so ask for a properly built DLL.
    if (le32(b, numDirsAt) > 4 && le32(b, dataDirsAt + 4 * 8 + 4) != 0)
        return fail("signed DLL lacks ASLR/DEP: rebuild it with those flags (patching would break the signature)", file);

    current = (uint16_t) (current | wanted);
    b[characteristicsAt] = (uint8_t) (current & 0xFF);
    b[characteristicsAt + 1] = (uint8_t) (current >> 8);

    if (FILE* f = std::fopen(file, "wb"))
    {
        const bool ok = std::fwrite(b.data(), 1, b.size(), f) == b.size();
        std::fclose(f);
        if (! ok)
            return fail("write failed", file);
    }
    else
        return fail("cannot write", file);
    return 0;
}
