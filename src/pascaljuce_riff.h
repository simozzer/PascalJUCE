/*
    pascaljuce_riff.h - re-frames WAV/RF64 and AIFF/AIFC files so that JUCE's
    readers only ever see the chunks needed to play audio.

    Why: JUCE 8.0.6's WavAudioFormatReader and AiffAudioFormatReader parse
    every metadata chunk inside their constructors (bext, smpl, inst, cue,
    LIST/adtl, iXML, axml, MARK, ...). That is a large parsing surface for
    untrusted files, and it cannot be validated after the fact, so the wrapper
    walks the chunk list itself and hands JUCE a synthesized file:

        WAV:   RIFF/RF64 header [ds64] fmt  data   (the audio bytes, in place)
        AIFF:  FORM header             COMM SSND   (the audio bytes, in place)

    This library exposes no file metadata, so nothing is lost. The planner
    only reads through a bounded callback and never allocates more than a
    copy of the fmt/COMM chunk (<= 256 bytes).
*/
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace pascaljuce
{
namespace riff
{
enum class Result
{
    notContainer, // not RIFF-WAVE / RF64-WAVE / FORM-AIFF / FORM-AIFC: let the normal readers try
    ok,
    malformed
};

struct Plan
{
    std::vector<uint8_t> header; // synthesized chunks; the audio bytes follow
    int64_t dataOffset = 0;      // where the audio bytes are in the original file
    int64_t dataLength = 0;
};

constexpr uint32_t maxFormatChunk = 256;
constexpr int maxChunks = 100000;

inline uint32_t le32(const uint8_t* p) noexcept
{
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}
inline uint64_t le64(const uint8_t* p) noexcept { return (uint64_t) le32(p) | ((uint64_t) le32(p + 4) << 32); }
inline uint32_t be32(const uint8_t* p) noexcept
{
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | (uint32_t) p[3];
}

inline void putId(std::vector<uint8_t>& v, const char* id) { v.insert(v.end(), id, id + 4); }
inline void putLe32(std::vector<uint8_t>& v, uint32_t x)
{
    for (int k = 0; k < 4; ++k)
        v.push_back((uint8_t) (x >> (8 * k)));
}
inline void putLe64(std::vector<uint8_t>& v, uint64_t x)
{
    putLe32(v, (uint32_t) x);
    putLe32(v, (uint32_t) (x >> 32));
}
inline void putBe32(std::vector<uint8_t>& v, uint32_t x)
{
    for (int k = 3; k >= 0; --k)
        v.push_back((uint8_t) (x >> (8 * k)));
}
inline void putBytes(std::vector<uint8_t>& v, const std::vector<uint8_t>& bytes)
{
    v.insert(v.end(), bytes.begin(), bytes.end());
    if (bytes.size() & 1)
        v.push_back(0); // chunks are padded to an even length
}

/* ReadAt: bool(int64_t offset, void* dest, size_t bytes), true only if all bytes were read.
   fileSize: the real size of the file; nothing past it is trusted. */
template <typename ReadAt>
Result plan(ReadAt&& readAt, int64_t fileSize, Plan& out, std::string& why)
{
    out = {};
    uint8_t head[12];
    if (fileSize < 12 || ! readAt(0, head, 12))
        return Result::notContainer;

    const bool riff = std::memcmp(head, "RIFF", 4) == 0, rf64 = std::memcmp(head, "RF64", 4) == 0;
    const bool form = std::memcmp(head, "FORM", 4) == 0;
    const bool wave = (riff || rf64) && std::memcmp(head + 8, "WAVE", 4) == 0;
    const bool aiff = form && (std::memcmp(head + 8, "AIFF", 4) == 0 || std::memcmp(head + 8, "AIFC", 4) == 0);
    if (! wave && ! aiff)
        return Result::notContainer; // JUCE's WAV/AIFF readers stop at these same magic checks

    auto fail = [&](const char* reason)
    {
        why = reason;
        out = {};
        return Result::malformed;
    };

    // The declared container size may only shrink the region we look at.
    int64_t limit = fileSize;
    if (riff || form)
    {
        const int64_t declared = 8 + (int64_t) (form ? be32(head + 4) : le32(head + 4));
        if (declared < limit)
            limit = declared;
    }

    int64_t pos = 12;
    uint64_t rf64DataSize = 0;
    if (rf64)
    {
        uint8_t ds[8 + 28];
        if (limit - pos < (int64_t) sizeof(ds) || ! readAt(pos, ds, sizeof(ds)) || std::memcmp(ds, "ds64", 4) != 0)
            return fail("RF64 file without a ds64 chunk");
        const uint32_t length = le32(ds + 4);
        if (length < 28 || (int64_t) length > limit - pos - 8)
            return fail("bad ds64 chunk");
        rf64DataSize = le64(ds + 8 + 8);
        pos += 8 + (int64_t) length + (length & 1);
    }

    std::vector<uint8_t> format;
    bool haveFormat = false, haveData = false;
    int64_t dataOffset = 0, dataLength = 0;

    for (int count = 0; limit - pos >= 8; ++count)
    {
        if (count >= maxChunks)
            return fail("too many chunks");
        uint8_t chunk[8];
        if (! readAt(pos, chunk, 8))
            return fail("read error");
        const uint32_t length = aiff ? be32(chunk + 4) : le32(chunk + 4);
        const int64_t body = pos + 8;
        const int64_t available = limit - body;

        const bool isData = wave ? std::memcmp(chunk, "data", 4) == 0 : std::memcmp(chunk, "SSND", 4) == 0;
        const bool isFormat = wave ? std::memcmp(chunk, "fmt ", 4) == 0 : std::memcmp(chunk, "COMM", 4) == 0;

        if (isData && ! haveData)
        {
            // A recording cut short keeps its audio: the data length is clamped to the file.
            int64_t length64 = rf64 && length == 0xFFFFFFFFu ? (int64_t) (rf64DataSize > (uint64_t) INT64_MAX ? INT64_MAX : rf64DataSize)
                                                             : (int64_t) length;
            if (length64 > available)
                length64 = available;
            const int64_t chunkLength = length64;
            int64_t start = body;
            if (aiff)
            {
                uint8_t ssnd[8];
                if (length64 < 8 || ! readAt(body, ssnd, 8))
                    return fail("SSND chunk too short");
                const uint32_t offset = be32(ssnd);
                if ((int64_t) offset > length64 - 8)
                    return fail("SSND offset past the end of the chunk");
                start = body + 8 + offset;
                length64 -= 8 + (int64_t) offset;
            }
            dataOffset = start;
            dataLength = length64;
            haveData = true;
            if (haveFormat)
                break;
            pos = body + chunkLength + (chunkLength & 1);
            continue;
        }

        if ((int64_t) length > available)
        {
            if (haveFormat && haveData)
                break; // trailing junk after everything we need
            return fail("chunk runs past the end of the file");
        }

        if (isFormat && ! haveFormat)
        {
            if (length < (wave ? 16u : 18u) || length > maxFormatChunk)
                return fail(wave ? "bad fmt chunk size" : "bad COMM chunk size");
            format.resize(length);
            if (! readAt(body, format.data(), length))
                return fail("read error");
            haveFormat = true;
            if (haveData)
                break;
        }
        pos = body + (int64_t) length + (length & 1);
    }

    if (! haveFormat)
        return fail(wave ? "no fmt chunk" : "no COMM chunk");

    // Validate the format fields JUCE would otherwise trust. With bits > 64 JUCE's
    // WAV reader derives the frame size as bytesPerSec / (int) sampleRate: INT_MIN
    // / -1 traps (process killed), and a wrapped 32-bit frame size later makes the
    // read loop spin forever. Real files never need more than 64 bits.
    if (wave)
    {
        const uint32_t channels = (uint32_t) format[2] | ((uint32_t) format[3] << 8);
        const uint32_t rate = le32(format.data() + 4);
        const uint32_t bits = (uint32_t) format[14] | ((uint32_t) format[15] << 8);
        if (channels < 1 || channels > 256 || rate < 1 || rate > 0x7FFFFFFFu || bits > 64)
            return fail("implausible fmt chunk (channels, sample rate or sample width)");
    }
    else
    {
        const int channels = (int16_t) (((uint32_t) format[0] << 8) | format[1]);
        const int bits = (int16_t) (((uint32_t) format[6] << 8) | format[7]);
        if (channels < 1 || channels > 256 || bits < 1 || bits > 64)
            return fail("implausible COMM chunk (channels or sample width)");
    }
    if (! haveData)
        return fail(wave ? "no data chunk" : "no SSND chunk");

    auto& h = out.header;
    if (wave)
    {
        // Decide RIFF vs RF64 on the real 64-bit size: with a long fmt chunk, data
        // just under 4 GB would otherwise wrap the 32-bit RIFF size.
        const uint64_t fmtPadded = format.size() + (format.size() & 1);
        const uint64_t plainSize = 4 + 8 + fmtPadded + 8 + (uint64_t) dataLength + (dataLength & 1);
        const bool big = plainSize > 0xFFFFFFFFu;
        const uint64_t riffSize = plainSize + (big ? 8 + 28 : 0);
        putId(h, big ? "RF64" : "RIFF");
        putLe32(h, big ? 0xFFFFFFFFu : (uint32_t) riffSize);
        putId(h, "WAVE");
        if (big)
        {
            putId(h, "ds64");
            putLe32(h, 28);
            putLe64(h, riffSize);
            putLe64(h, (uint64_t) dataLength);
            putLe64(h, 0);
            putLe32(h, 0);
        }
        putId(h, "fmt ");
        putLe32(h, (uint32_t) format.size());
        putBytes(h, format);
        putId(h, "data");
        putLe32(h, big ? 0xFFFFFFFFu : (uint32_t) dataLength);
    }
    else
    {
        // dataLength <= 2^32 - 8 here: it came from a 32-bit SSND length.
        const uint64_t commPadded = format.size() + (format.size() & 1);
        const uint64_t formSize = 4 + 8 + commPadded + 8 + 8 + (uint64_t) dataLength;
        putId(h, "FORM");
        // JUCE reads the FORM size as a signed int; COMM and SSND come first, so a
        // capped size still covers everything it needs.
        putBe32(h, formSize > 0x7FFFFFFFu ? 0x7FFFFFFFu : (uint32_t) formSize);
        h.insert(h.end(), head + 8, head + 12); // AIFF or AIFC
        putId(h, "COMM");
        putBe32(h, (uint32_t) format.size());
        putBytes(h, format);
        putId(h, "SSND");
        putBe32(h, (uint32_t) (8 + dataLength));
        putBe32(h, 0); // offset
        putBe32(h, 0); // block size
    }
    out.dataOffset = dataOffset;
    out.dataLength = dataLength;
    return Result::ok;
}
} // namespace riff
} // namespace pascaljuce
