/*
    pascaljuce_image_check.h - structural checks on PNG and JPEG data before
    JUCE's decoders see it (custom editors' create_image).

    Image decoders are a large attack surface, so a file is accepted only if
    it is complete and well-formed, and only in a conservative subset:
      - PNG: signature, IHDR first with valid fields, every chunk inside the
        buffer with a correct CRC, at least one IDAT, IEND present;
      - JPEG: sequential Huffman only (SOF0/SOF1, 8-bit, 3 components with
        integral sampling ratios, one scan holding all three), every
        DQT/DHT/DRI/SOF/SOS segment validated, every
        table a scan uses defined, entropy-coded data walked to an EOI inside
        the buffer.
    Corrupt compressed data inside a valid structure only makes the decoders
    fail cleanly or fill in zeros.
*/
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace pascaljuce::image
{
enum class Kind { none, png, jpeg };

inline uint32_t be32(const uint8_t* p) noexcept
{
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | p[3];
}

inline uint32_t be16(const uint8_t* p) noexcept
{
    return ((uint32_t) p[0] << 8) | p[1];
}

inline uint32_t crc32(const uint8_t* p, size_t n) noexcept
{
    struct Table
    {
        uint32_t v[256];
        Table() noexcept
        {
            for (uint32_t i = 0; i < 256; ++i)
            {
                uint32_t c = i;
                for (int k = 0; k < 8; ++k)
                    c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                v[i] = c;
            }
        }
    };
    static const Table table;
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i)
        c = table.v[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

inline bool isLetter(uint8_t c) noexcept
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

//==============================================================================
inline bool checkPng(const uint8_t* d, size_t n, uint32_t maxSide, int& width, int& height) noexcept
{
    static const uint8_t signature[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    if (n < 8 + 25 + 12 || std::memcmp(d, signature, 8) != 0)
        return false;

    size_t pos = 8;
    bool first = true, idat = false, plte = false, afterIdat = false;
    uint8_t colourType = 0;
    for (;;)
    {
        if (n - pos < 12)
            return false; // every chunk needs length, type and CRC inside the buffer
        const uint32_t length = be32(d + pos);
        if (length > 0x7FFFFFFFu || length > n - pos - 12)
            return false;
        const uint8_t* type = d + pos + 4;
        const uint8_t* data = d + pos + 8;
        for (int i = 0; i < 4; ++i)
            if (! isLetter(type[i]))
                return false;
        if (crc32(type, (size_t) length + 4) != be32(data + length))
            return false;

        const bool isIhdr = std::memcmp(type, "IHDR", 4) == 0;
        if (first != isIhdr)
            return false; // IHDR first, and only first
        if (isIhdr)
        {
            if (length != 13)
                return false;
            const uint32_t w = be32(data), h = be32(data + 4);
            const uint8_t depth = data[8];
            colourType = data[9];
            if (w == 0 || h == 0 || w > maxSide || h > maxSide)
                return false;
            bool depthOk = false;
            switch (colourType)
            {
                case 0: depthOk = depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16; break;
                case 3: depthOk = depth == 1 || depth == 2 || depth == 4 || depth == 8; break;
                case 2: case 4: case 6: depthOk = depth == 8 || depth == 16; break;
                default: return false;
            }
            if (! depthOk || data[10] != 0 || data[11] != 0 || data[12] > 1)
                return false;
            width = (int) w;
            height = (int) h;
        }
        else if (std::memcmp(type, "PLTE", 4) == 0)
        {
            if (plte || idat || length == 0 || length % 3 != 0 || length > 768)
                return false;
            plte = true;
        }
        else if (std::memcmp(type, "IDAT", 4) == 0)
        {
            if (afterIdat)
                return false; // IDAT chunks must be consecutive
            if (colourType == 3 && ! plte)
                return false;
            idat = true;
        }
        else if (std::memcmp(type, "IEND", 4) == 0)
        {
            return length == 0 && idat;
        }
        else
        {
            if (idat)
                afterIdat = true;
            if ((type[0] & 0x20) == 0)
                return false; // an unknown critical chunk: libpng refuses it anyway
        }
        first = false;
        pos += 12 + (size_t) length;
    }
}

//==============================================================================
// Canonical Huffman table check.
inline bool huffmanCodesValid(const uint8_t* counts) noexcept
{
    uint32_t code = 0;
    for (int len = 1; len <= 16; ++len)
    {
        code += counts[len - 1];
        if (code >= (1u << len) && code != 0) // the all-ones code is invalid too
            return false;
        code <<= 1;
    }
    return true;
}

inline bool checkJpeg(const uint8_t* d, size_t n, uint32_t maxSide, int& width, int& height) noexcept
{
    if (n < 4 || d[0] != 0xFF || d[1] != 0xD8)
        return false;

    bool quantDefined[4] = {}, dcDefined[4] = {}, acDefined[4] = {};
    bool frame = false, scanned = false;
    int numComponents = 0;
    uint8_t componentId[3] = {}, sampling[3] = {}, quantTable[3] = {};
    size_t pos = 2;

    for (;;)
    {
        // Next marker: 0xFF, optional fill bytes, the code.
        if (pos >= n || d[pos] != 0xFF)
            return false;
        while (pos < n && d[pos] == 0xFF)
            ++pos;
        if (pos >= n)
            return false;
        const uint8_t marker = d[pos++];
        if (marker == 0xD9) // EOI
            return frame && scanned;
        if (marker == 0x00 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8))
            return false; // stuffing, TEM, RST or a second SOI outside a scan
        if (n - pos < 2)
            return false;
        const size_t length = be16(d + pos);
        if (length < 2 || length > n - pos)
            return false;
        const uint8_t* s = d + pos + 2;
        const size_t len = length - 2;

        if ((marker >= 0xE0 && marker <= 0xEF) || marker == 0xFE)
        {
            // APPn, COM: skipped
        }
        else if (marker == 0xDB) // DQT
        {
            if (len == 0)
                return false;
            size_t i = 0;
            while (i < len)
            {
                const uint8_t pq = s[i] >> 4, tq = s[i] & 15;
                const size_t size = pq == 0 ? 65 : 129;
                if (pq > 1 || tq > 3 || len - i < size)
                    return false;
                quantDefined[tq] = true;
                i += size;
            }
        }
        else if (marker == 0xC4) // DHT
        {
            if (len == 0)
                return false;
            size_t i = 0;
            while (i < len)
            {
                if (len - i < 17)
                    return false;
                const uint8_t tc = s[i] >> 4, th = s[i] & 15;
                if (tc > 1 || th > 3)
                    return false;
                const uint8_t* counts = s + i + 1;
                size_t total = 0;
                for (int k = 0; k < 16; ++k)
                    total += counts[k];
                if (total == 0 || total > 256 || len - i - 17 < total || ! huffmanCodesValid(counts))
                    return false;
                const uint8_t* symbols = s + i + 17;
                if (tc == 0)
                    for (size_t k = 0; k < total; ++k)
                        if (symbols[k] > 15)
                            return false; // a DC table codes magnitudes 0..15 (11 for 8-bit)
                (tc == 0 ? dcDefined : acDefined)[th] = true;
                i += 17 + total;
            }
        }
        else if (marker == 0xDD) // DRI
        {
            if (len != 2)
                return false;
        }
        else if (marker == 0xC0 || marker == 0xC1) // SOF0 / SOF1: sequential Huffman
        {
            if (frame || len != 6 + 3 * 3)
                return false;
            const uint32_t h = be16(s + 1), w = be16(s + 3);
            if (s[0] != 8 || s[5] != 3 || w == 0 || h == 0 || w > maxSide || h > maxSide)
                return false;
            numComponents = 3;
            int blocks = 0;
            for (int c = 0; c < 3; ++c)
            {
                componentId[c] = s[6 + 3 * c];
                sampling[c] = s[7 + 3 * c];
                quantTable[c] = s[8 + 3 * c];
                const int hs = sampling[c] >> 4, vs = sampling[c] & 15;
                if (hs < 1 || hs > 4 || vs < 1 || vs > 4 || quantTable[c] > 3)
                    return false;
                for (int k = 0; k < c; ++k)
                    if (componentId[k] == componentId[c])
                        return false;
                blocks += hs * vs;
            }
            if (blocks > 10)
                return false; // too many blocks per MCU
            int maxH = 1, maxV = 1;
            for (int c = 0; c < 3; ++c)
            {
                maxH = std::max(maxH, sampling[c] >> 4);
                maxV = std::max(maxV, sampling[c] & 15);
            }
            for (int c = 0; c < 3; ++c)
                if (maxH % (sampling[c] >> 4) != 0 || maxV % (sampling[c] & 15) != 0)
                    return false; // only integral sampling ratios

            width = (int) w;
            height = (int) h;
            frame = true;
        }
        else if (marker == 0xDA) // SOS
        {
            // Exactly one scan, holding every component: a multi-scan file makes
            // libjpeg buffer the whole image and replay it per scan (a few
            // bytes per scan header could keep the UI thread busy for hours).
            if (! frame || scanned || len < 1)
                return false;
            const int ns = s[0];
            if (ns != numComponents || len != (size_t) (4 + 2 * ns))
                return false;
            bool used[3] = {};
            int blocks = 0;
            for (int k = 0; k < ns; ++k)
            {
                const uint8_t id = s[1 + 2 * k], tables = s[2 + 2 * k];
                int c = 0;
                while (c < numComponents && componentId[c] != id)
                    ++c;
                if (c == numComponents || used[c])
                    return false;
                used[c] = true;
                const int td = tables >> 4, ta = tables & 15;
                if (td > 3 || ta > 3 || ! dcDefined[td] || ! acDefined[ta] || ! quantDefined[quantTable[c]])
                    return false;
                blocks += (sampling[c] >> 4) * (sampling[c] & 15);
            }
            if (ns > 1 && blocks > 10)
                return false;
            const uint8_t* tail = s + 1 + 2 * ns;
            if (tail[0] != 0 || tail[1] != 63 || tail[2] != 0)
                return false; // Ss = 0, Se = 63, Ah = Al = 0: sequential
            scanned = true;
            // Entropy-coded data up to the next marker (FF00 = stuffed byte, FFD0-D7 = restart).
            pos += length;
            for (;;)
            {
                while (pos < n && d[pos] != 0xFF)
                    ++pos;
                if (pos + 1 >= n)
                    return false; // no EOI inside the buffer
                size_t next = pos + 1;
                while (next < n && d[next] == 0xFF)
                    ++next;
                if (next >= n)
                    return false;
                if (d[next] == 0x00 || (d[next] >= 0xD0 && d[next] <= 0xD7))
                {
                    pos = next + 1;
                    continue;
                }
                break; // a real marker: handled by the outer loop
            }
            continue;
        }
        else
        {
            return false; // progressive, lossless, arithmetic, DNL, hierarchical...: not decoded
        }
        pos += length;
    }
}

// Which decoder may see these bytes, and the image size their header gives.
inline Kind check(const void* data, size_t size, uint32_t maxSide, int& width, int& height) noexcept
{
    const auto* d = static_cast<const uint8_t*>(data);
    width = height = 0;
    if (checkPng(d, size, maxSide, width, height))
        return Kind::png;
    width = height = 0;
    if (checkJpeg(d, size, maxSide, width, height))
        return Kind::jpeg;
    width = height = 0;
    return Kind::none;
}
} // namespace pascaljuce::image
