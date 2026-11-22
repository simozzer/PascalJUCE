/*
    Strict UTF-8 validation for untrusted text, shared by juce_c_audio and the
    plug-in wrapper.

    Why: juce::String::fromUTF8 accepts malformed UTF-8 (debug builds only
    assert), and in JUCE 8.0.6 the CharPointer_UTF8 decoder trusted lead
    bytes - a truncated multi-byte sequence at the end of a string made it
    read past the terminator (found by fuzzing plug-in state: heap-buffer-
    overflow in XmlDocument). 8.0.16 hardened the decoder; this check stays.
    Every piece of text that crosses a trust boundary is checked
    with this before it is turned into a juce::String.
*/
#pragma once

#include <cstddef>
#include <cstdint>

namespace pascaljuce
{
/* True if bytes[0..length) is well-formed UTF-8 with no NUL bytes: every
   sequence complete, no overlong encodings, no UTF-16 surrogates, nothing
   above U+10FFFF. */
inline bool isStrictUtf8(const char* bytes, size_t length) noexcept
{
    if (bytes == nullptr)
        return length == 0;

    const auto* s = reinterpret_cast<const unsigned char*>(bytes);
    size_t i = 0;
    while (i < length)
    {
        const unsigned char c = s[i];
        if (c == 0)
            return false;
        if (c < 0x80)
        {
            ++i;
            continue;
        }

        size_t extra;
        uint32_t codePoint;
        if (c >= 0xC2 && c <= 0xDF)      { extra = 1; codePoint = c & 0x1Fu; }
        else if (c >= 0xE0 && c <= 0xEF) { extra = 2; codePoint = c & 0x0Fu; }
        else if (c >= 0xF0 && c <= 0xF4) { extra = 3; codePoint = c & 0x07u; }
        else return false; // continuation byte as lead, overlong 0xC0/0xC1, or > 0xF4

        if (length - i <= extra)
            return false; // truncated sequence
        for (size_t k = 1; k <= extra; ++k)
        {
            const unsigned char cc = s[i + k];
            if ((cc & 0xC0) != 0x80)
                return false;
            codePoint = (codePoint << 6) | (cc & 0x3Fu);
        }

        if ((extra == 2 && codePoint < 0x800) || (extra == 3 && codePoint < 0x10000)) return false; // overlong
        if (codePoint >= 0xD800 && codePoint <= 0xDFFF) return false;                               // surrogate
        if (codePoint > 0x10FFFF) return false;
        i += extra + 1;
    }
    return true;
}
} // namespace pascaljuce
