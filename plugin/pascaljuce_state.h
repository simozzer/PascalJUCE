/*
    pascaljuce_state.h - the plug-in wrapper's state format: an exact writer
    and a strict parser that accepts only what the writer produces.

    Why not juce::XmlDocument / MemoryBlock::fromBase64Encoding: plug-in state
    comes from project files, i.e. attackers, so it is parsed by a flat,
    bounded, allocation-limited parser that accepts only what the writer
    produces, instead of a general XML/base64 parser. An earlier pre-scan in
    front of JUCE's parser was bypassed, so untrusted state never reaches it.

    Wire format (same container as AudioProcessor::copyXmlToBinary, so hosts
    see ordinary JUCE state):

        'VC2!'  uint32le(length of text + 1)  text  NUL

        text = <?xml version="1.0" encoding="UTF-8"?>\n
               <PascalJUCE version="2">\n
               (  <PARAM id="ID" value="NUMBER"/>\n )*
               [  <CUSTOM>BASE64</CUSTOM>\n ]
               </PascalJUCE>\n

    ID: 1-128 of [A-Za-z0-9_.-]; NUMBER: 1-40 of [0-9eE+-.], a finite double;
    BASE64: RFC 4648 standard alphabet with '=' padding.
*/
#pragma once

#include <charconv>
#include <clocale>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#if ! (defined(__cpp_lib_to_chars) && __cpp_lib_to_chars >= 201611L) && ! defined(_WIN32)
    #include <locale.h>
    #if defined(__APPLE__)
        #include <xlocale.h>
    #endif
#endif

namespace pascaljuce
{
namespace state
{
constexpr uint32_t magic = 0x21324356; // 'VC2!' little-endian, as JUCE writes it

struct Decoded
{
    std::vector<std::pair<std::string, double>> params;
    std::vector<uint8_t> custom;
    bool hasCustom = false;
};

inline bool isIdChar(char c) noexcept
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
}

inline bool isNumberChar(char c) noexcept
{
    return (c >= '0' && c <= '9') || c == 'e' || c == 'E' || c == '+' || c == '-' || c == '.';
}

inline int base64Value(char c) noexcept
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

/* Numbers are written and read in the "C" locale whatever the host has set:
   glibc's locale is process-wide, and Qt/GTK hosts set it from the user's
   environment, so plain snprintf/strtod would write "0,5" under a German
   locale and refuse every state saved elsewhere. */
#if defined(__cpp_lib_to_chars) && __cpp_lib_to_chars >= 201611L
inline bool formatNumber(double value, char* out, size_t capacity) noexcept
{
    const auto r = std::to_chars(out, out + capacity - 1, value, std::chars_format::general, 17);
    if (r.ec != std::errc())
        return false;
    *r.ptr = '\0';
    return true;
}

inline bool parseNumber(const char* text, size_t length, double& value) noexcept
{
    const auto r = std::from_chars(text, text + length, value, std::chars_format::general);
    return r.ec == std::errc() && r.ptr == text + length;
}
#else
    #if defined(_WIN32)
inline _locale_t cLocale() noexcept
{
    static const _locale_t locale = _create_locale(LC_NUMERIC, "C");
    return locale;
}
inline bool formatNumber(double value, char* out, size_t capacity) noexcept
{
    const int n = _snprintf_l(out, capacity, "%.17g", cLocale(), value);
    return n > 0 && (size_t) n < capacity;
}
inline bool parseNumber(const char* text, size_t length, double& value) noexcept
{
    char copy[64];
    if (length == 0 || length >= sizeof(copy))
        return false;
    std::memcpy(copy, text, length);
    copy[length] = '\0';
    char* end = nullptr;
    value = _strtod_l(copy, &end, cLocale());
    return end == copy + length;
}
    #else
inline locale_t cLocale() noexcept
{
    static const locale_t locale = newlocale(LC_NUMERIC_MASK, "C", (locale_t) 0);
    return locale;
}
struct ScopedCLocale
{
    ScopedCLocale() noexcept : previous(cLocale() != (locale_t) 0 ? uselocale(cLocale()) : (locale_t) 0) {}
    ~ScopedCLocale() noexcept
    {
        if (previous != (locale_t) 0)
            uselocale(previous);
    }
    locale_t previous;
};
inline bool formatNumber(double value, char* out, size_t capacity) noexcept
{
    if (cLocale() == (locale_t) 0)
        return false;
    ScopedCLocale scope;
    const int n = std::snprintf(out, capacity, "%.17g", value);
    return n > 0 && (size_t) n < capacity;
}
inline bool parseNumber(const char* text, size_t length, double& value) noexcept
{
    char copy[64];
    if (cLocale() == (locale_t) 0 || length == 0 || length >= sizeof(copy))
        return false;
    std::memcpy(copy, text, length);
    copy[length] = '\0';
    ScopedCLocale scope;
    char* end = nullptr;
    value = std::strtod(copy, &end);
    return end == copy + length;
}
    #endif
#endif

inline void base64Append(std::vector<uint8_t>& out, const uint8_t* data, size_t size)
{
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t i = 0; i < size; i += 3)
    {
        const uint32_t b0 = data[i], b1 = i + 1 < size ? data[i + 1] : 0, b2 = i + 2 < size ? data[i + 2] : 0;
        const uint32_t v = (b0 << 16) | (b1 << 8) | b2;
        out.push_back((uint8_t) alphabet[(v >> 18) & 63]);
        out.push_back((uint8_t) alphabet[(v >> 12) & 63]);
        out.push_back((uint8_t) (i + 1 < size ? alphabet[(v >> 6) & 63] : '='));
        out.push_back((uint8_t) (i + 2 < size ? alphabet[v & 63] : '='));
    }
}

// Strict: length a multiple of 4, padding only at the very end, alphabet only.
inline bool base64Decode(const char* text, size_t length, std::vector<uint8_t>& out)
{
    out.clear();
    if (length % 4 != 0)
        return false;
    out.reserve(length / 4 * 3);
    for (size_t i = 0; i < length; i += 4)
    {
        int v[4];
        int padding = 0;
        for (int k = 0; k < 4; ++k)
        {
            const char c = text[i + (size_t) k];
            if (c == '=')
            {
                if (i + 4 != length || k < 2) // '=' only in the last two positions of the last quad
                    return false;
                v[k] = 0;
                ++padding;
            }
            else
            {
                if (padding > 0)
                    return false; // data after padding
                v[k] = base64Value(c);
                if (v[k] < 0)
                    return false;
            }
        }
        const uint32_t triple = ((uint32_t) v[0] << 18) | ((uint32_t) v[1] << 12) | ((uint32_t) v[2] << 6) | (uint32_t) v[3];
        out.push_back((uint8_t) (triple >> 16));
        if (padding < 2)
            out.push_back((uint8_t) (triple >> 8));
        if (padding < 1)
            out.push_back((uint8_t) triple);
    }
    return true;
}

inline std::vector<uint8_t> encode(const std::vector<std::pair<std::string, double>>& params,
                                   const uint8_t* custom, size_t customSize)
{
    // Written straight into the result (one allocation): a 64 MB custom blob
    // must not need several copies of itself at once.
    if (custom == nullptr)
        customSize = 0;
    size_t estimate = 128 + (customSize + 2) / 3 * 4;
    for (const auto& p : params)
        estimate += p.first.size() + 48;

    std::vector<uint8_t> out;
    out.reserve(estimate);
    out.resize(8); // magic and length, filled in below
    auto append = [&out](const char* s) { out.insert(out.end(), s, s + std::strlen(s)); };

    append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<PascalJUCE version=\"2\">\n");
    for (const auto& p : params)
    {
        char number[64];
        if (! formatNumber(std::isfinite(p.second) ? p.second : 0.0, number, sizeof(number)))
            std::memcpy(number, "0", 2);
        append("  <PARAM id=\"");
        out.insert(out.end(), p.first.begin(), p.first.end());
        append("\" value=\"");
        append(number);
        append("\"/>\n");
    }
    if (customSize > 0)
    {
        append("  <CUSTOM>");
        base64Append(out, custom, customSize);
        append("</CUSTOM>\n");
    }
    append("</PascalJUCE>\n");
    out.push_back(0);

    const uint32_t length = (uint32_t) (out.size() - 8);
    for (int k = 0; k < 4; ++k)
    {
        out[(size_t) k] = (uint8_t) (magic >> (8 * k));
        out[(size_t) k + 4] = (uint8_t) (length >> (8 * k));
    }
    return out;
}

class Cursor
{
public:
    Cursor(const char* text, size_t length) noexcept : t(text), n(length) {}

    void skipWhitespace() noexcept
    {
        while (i < n && (t[i] == ' ' || t[i] == '\t' || t[i] == '\r' || t[i] == '\n'))
            ++i;
    }

    bool literal(const char* s) noexcept
    {
        const size_t len = std::strlen(s);
        if (n - i < len || std::memcmp(t + i, s, len) != 0)
            return false;
        i += len;
        return true;
    }

    template <typename Predicate>
    bool token(Predicate accept, size_t minLength, size_t maxLength, const char*& start, size_t& length) noexcept
    {
        start = t + i;
        length = 0;
        while (i < n && accept(t[i]))
        {
            if (++length > maxLength)
                return false;
            ++i;
        }
        return length >= minLength;
    }

    bool atEnd() const noexcept { return i == n; }

private:
    const char* t;
    size_t n;
    size_t i = 0;
};

/* Parses state produced by encode(). Rejects everything else, including
   other XML that would mean the same thing. Never recurses; allocations are
   bounded by maxParams and maxCustomBytes. */
inline bool decode(const void* data, size_t size, size_t maxParams, size_t maxCustomBytes, Decoded& out)
{
    out = {};
    if (data == nullptr || size <= 8)
        return false;
    const auto* bytes = static_cast<const uint8_t*>(data);
    const uint32_t m = (uint32_t) bytes[0] | ((uint32_t) bytes[1] << 8) | ((uint32_t) bytes[2] << 16) | ((uint32_t) bytes[3] << 24);
    const uint32_t declared = (uint32_t) bytes[4] | ((uint32_t) bytes[5] << 8) | ((uint32_t) bytes[6] << 16) | ((uint32_t) bytes[7] << 24);
    if (m != magic || declared < 2 || declared > size - 8)
        return false;

    const char* text = reinterpret_cast<const char*>(bytes + 8);
    size_t length = declared;
    if (text[length - 1] != '\0')
        return false; // the writer always terminates
    --length;

    Cursor c(text, length);
    c.skipWhitespace();
    if (c.literal("<?xml"))
    {
        if (! c.literal(" version=\"1.0\" encoding=\"UTF-8\"?>"))
            return false;
        c.skipWhitespace();
    }
    if (! c.literal("<PascalJUCE version=\"2\">"))
        return false;

    for (;;)
    {
        c.skipWhitespace();
        if (c.literal("<PARAM id=\""))
        {
            const char* id;
            const char* number;
            size_t idLength, numberLength;
            if (! c.token(isIdChar, 1, 128, id, idLength) || ! c.literal("\" value=\"")
                || ! c.token(isNumberChar, 1, 40, number, numberLength) || ! c.literal("\"/>"))
                return false;
            if (out.params.size() >= maxParams)
                return false;

            double value = 0.0;
            if (! parseNumber(number, numberLength, value) || ! std::isfinite(value))
                return false;
            out.params.emplace_back(std::string(id, idLength), value);
        }
        else if (c.literal("<CUSTOM>"))
        {
            if (out.hasCustom)
                return false; // at most one
            const char* b64;
            size_t b64Length;
            const size_t maxChars = (maxCustomBytes + 2) / 3 * 4;
            if (! c.token([](char ch) { return base64Value(ch) >= 0 || ch == '='; }, 0, maxChars, b64, b64Length)
                || ! c.literal("</CUSTOM>"))
                return false;
            if (! base64Decode(b64, b64Length, out.custom) || out.custom.size() > maxCustomBytes)
                return false;
            out.hasCustom = true;
        }
        else if (c.literal("</PascalJUCE>"))
        {
            c.skipWhitespace();
            return c.atEnd();
        }
        else
        {
            return false;
        }
    }
}
} // namespace state
} // namespace pascaljuce
