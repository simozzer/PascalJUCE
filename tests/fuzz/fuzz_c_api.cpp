/*
    Fuzz targets for the juce_c_audio C API - the inputs an attacker controls:

      midi   raw bytes from devices/hosts -> every MIDI-accepting function
      file   malformed audio files -> JUCE's WAV/AIFF/FLAC/Ogg parsers

    Two ways to run:
      * libFuzzer (-DPASCALJUCE_LIBFUZZER, link -fsanitize=fuzzer): one
        target per binary, chosen by PASCALJUCE_FUZZ_TARGET.
      * Built-in driver (default): deterministic mutation of seed inputs for a
        fixed number of iterations, so ctest runs a reproducible fuzz budget:
            fuzz_c_api <midi|file> [iterations] [seed]
    Build with AddressSanitizer (-DPASCALJUCE_SANITIZE=address) so memory
    errors abort instead of passing silently.
*/
#include "juce_c_audio.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#if defined(_WIN32)
    #include <process.h>
    #define getpid _getpid
#else
    #include <unistd.h>
#endif

using Bytes = std::vector<uint8_t>;

//==============================================================================
static void fuzzMidi(const uint8_t* data, size_t size)
{
    juce_c_midi_buffer* buffer = nullptr;
    if (juce_c_midi_buffer_create(&buffer) != JUCE_C_OK)
        return;

    // Treat the input as a sequence of [len][bytes...] records, plus the whole thing.
    size_t pos = 0;
    while (pos < size)
    {
        const size_t len = std::min<size_t>(data[pos] % 40, size - pos - 1);
        const uint8_t* msg = data + pos + 1;
        juce_c_midi_buffer_add_event(buffer, msg, len, (int32_t) (pos * 7) - 50);
        char text[64];
        size_t textSize = sizeof(text);
        juce_c_midi_message_get_description(msg, len, text, &textSize);
        pos += len + 1;
    }
    juce_c_midi_buffer_add_event(buffer, data, size, 0);

    // Read everything back through both access paths.
    const int count = juce_c_midi_buffer_get_event_count(buffer);
    for (int i = 0; i < count; ++i)
    {
        uint8_t out[8];
        size_t outSize = sizeof(out);
        int32_t at = 0;
        if (juce_c_midi_buffer_get_event(buffer, i, out, &outSize, &at) == JUCE_C_BUFFER_TOO_SMALL)
        {
            std::vector<uint8_t> big(outSize);
            juce_c_midi_buffer_get_event(buffer, i, big.data(), &outSize, &at);
        }
    }
    juce_c_midi_buffer_for_each(buffer, [](void*, const uint8_t* m, int32_t n, int32_t) -> int32_t
    {
        volatile uint8_t sink = 0;
        for (int32_t i = 0; i < n; ++i)
            sink ^= m[i]; // touch every byte: ASan flags any overread
        return 0;
    }, nullptr);
    juce_c_midi_buffer_destroy(buffer);
}

//==============================================================================
static std::string tempFile(const char* extension)
{
    const char* dir = std::getenv("TEMP");
    if (dir == nullptr)
        dir = std::getenv("TMPDIR");
    if (dir == nullptr)
        dir = "/tmp";
    return std::string(dir) + "/pascaljuce_fuzz_" + std::to_string(getpid()) + extension;
}

static void fuzzFile(const uint8_t* data, size_t size)
{
    if (size < 1)
        return;
    static const char* extensions[] = { ".wav", ".aiff", ".flac", ".ogg" };
    const auto path = tempFile(extensions[data[0] % 4]);

    if (FILE* f = std::fopen(path.c_str(), "wb"))
    {
        std::fwrite(data + 1, 1, size - 1, f);
        std::fclose(f);
    }

    juce_c_audio_file_reader* reader = nullptr;
    if (juce_c_audio_file_reader_open(path.c_str(), &reader) == JUCE_C_OK)
    {
        const int64_t length = juce_c_audio_file_reader_get_length(reader);
        juce_c_audio_buffer* dest = nullptr;
        if (juce_c_audio_buffer_create(2, 1024, &dest) == JUCE_C_OK)
        {
            // Bounded reads at the start, the end, and past the end.
            juce_c_audio_file_reader_read(reader, dest, 0, 1024, 0);
            if (length > 0)
                juce_c_audio_file_reader_read(reader, dest, 0, 512, length > 512 ? length - 512 : 0);
            juce_c_audio_file_reader_read(reader, dest, 0, 256, length + 1000);
            juce_c_audio_buffer_destroy(dest);
        }
        juce_c_audio_file_reader_destroy(reader);
    }

    // Whole-file load only when the claimed size is modest (a hostile header
    // can claim billions of frames; the API caps that, but don't make the
    // fuzzer allocate gigabytes on every iteration).
    juce_c_audio_buffer* loaded = nullptr;
    if (juce_c_audio_file_reader_open(path.c_str(), &reader) == JUCE_C_OK)
    {
        const bool small = juce_c_audio_file_reader_get_length(reader) < (1 << 20);
        juce_c_audio_file_reader_destroy(reader);
        if (small && juce_c_audio_file_load(path.c_str(), &loaded, nullptr) == JUCE_C_OK)
            juce_c_audio_buffer_destroy(loaded);
    }
    std::remove(path.c_str());
}

//==============================================================================
static Bytes makeSeedFile(const char* format, int bits, int channels)
{
    const auto path = tempFile(".seed");
    juce_c_audio_file_writer* writer = nullptr;
    if (juce_c_audio_file_writer_create(path.c_str(), format, 48000, channels, bits, 3, &writer) != JUCE_C_OK)
        return {};
    juce_c_audio_buffer* buffer = nullptr;
    juce_c_audio_buffer_create(channels, 300, &buffer);
    for (int ch = 0; ch < channels; ++ch)
    {
        float* w = nullptr;
        juce_c_audio_buffer_get_write_pointer(buffer, ch, &w);
        for (int i = 0; i < 300; ++i)
            w[i] = (float) ((i * 37 + ch * 11) % 200 - 100) / 128.0f;
    }
    juce_c_audio_file_writer_write_buffer(writer, buffer, 0, 300);
    juce_c_audio_file_writer_destroy(writer);
    juce_c_audio_buffer_destroy(buffer);

    Bytes bytes;
    if (FILE* f = std::fopen(path.c_str(), "rb"))
    {
        uint8_t chunk[4096];
        size_t n;
        while ((n = std::fread(chunk, 1, sizeof(chunk), f)) > 0)
            bytes.insert(bytes.end(), chunk, chunk + n);
        std::fclose(f);
    }
    std::remove(path.c_str());
    return bytes;
}

static void mutate(Bytes& b, std::mt19937& rng)
{
    auto pick = [&](size_t n) { return n == 0 ? 0 : (size_t) (rng() % n); };
    const int rounds = 1 + (int) (rng() % 8);
    for (int r = 0; r < rounds; ++r)
    {
        switch (rng() % 7)
        {
            case 0: if (! b.empty()) b[pick(b.size())] ^= (uint8_t) (1u << (rng() % 8)); break;            // bit flip
            case 1: if (! b.empty()) b[pick(b.size())] = (uint8_t) rng(); break;                          // byte set
            case 2: b.insert(b.begin() + (long) pick(b.size() + 1), (uint8_t) rng()); break;               // insert
            case 3: if (! b.empty()) b.erase(b.begin() + (long) pick(b.size())); break;                    // delete
            case 4: if (! b.empty()) b.resize(pick(b.size())); break;                                      // truncate
            case 5: if (b.size() >= 4) { const auto at = pick(b.size() - 3);                               // 32-bit
                        const uint32_t v[] = { 0, 0xFFFFFFFFu, 0x7FFFFFFFu, 0x80000000u, (uint32_t) rng() }; // boundary
                        std::memcpy(&b[at], &v[rng() % 5], 4); } break;
            case 6: if (b.size() > 8) { const auto from = pick(b.size() - 8), len = 1 + pick(8);             // duplicate
                        const Bytes chunk(b.begin() + (long) from, b.begin() + (long) (from + len)); // copy first: inserting
                        b.insert(b.begin() + (long) pick(b.size()), chunk.begin(), chunk.end()); } break; // a self-range is UB
        }
        if (b.size() > (1u << 20))
            b.resize(1u << 20);
    }
}

#if defined(PASCALJUCE_LIBFUZZER)
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
   #if PASCALJUCE_FUZZ_TARGET == 1
    fuzzFile(data, size);
   #else
    fuzzMidi(data, size);
   #endif
    return 0;
}
#else
int main(int argc, char* argv[])
{
    const std::string target = argc > 1 ? argv[1] : "midi";
    const long iterations = argc > 2 ? std::strtol(argv[2], nullptr, 10) : 20000;
    const unsigned seed = argc > 3 ? (unsigned) std::strtoul(argv[3], nullptr, 10) : 12345u;
    std::mt19937 rng(seed);

    std::vector<Bytes> seeds;
    if (target == "midi")
    {
        seeds = { { 3, 0x90, 60, 100, 3, 0x80, 60, 0 },
                  { 6, 0xF0, 0x7D, 1, 2, 3, 0xF7 },
                  { 2, 0xC0, 5, 1, 0xF8, 3, 0xE0, 0, 64 },
                  { 0x90, 0x90, 0x90 } };
    }
    else if (target == "replay")
    {
        // fuzz_c_api replay <file-target-input>: run one saved input once.
        Bytes input;
        if (FILE* f = std::fopen(argc > 2 ? argv[2] : "", "rb"))
        {
            uint8_t chunk[4096];
            size_t n;
            while ((n = std::fread(chunk, 1, sizeof(chunk), f)) > 0)
                input.insert(input.end(), chunk, chunk + n);
            std::fclose(f);
        }
        fuzzFile(input.data(), input.size());
        std::printf("replay: %zu bytes completed without memory errors\n", input.size());
        return 0;
    }
    else if (target == "file")
    {
        const struct { const char* format; int bits; int channels; uint8_t ext; } kinds[] = {
            { "wav", 16, 1, 0 }, { "wav", 24, 2, 0 }, { "wav", 32, 2, 0 },
            { "aiff", 16, 2, 1 }, { "aiff", 24, 1, 1 }, { "flac", 16, 2, 2 }, { "flac", 24, 1, 2 }, { "ogg", 32, 2, 3 } };
        for (const auto& k : kinds)
        {
            auto file = makeSeedFile(k.format, k.bits, k.channels);
            if (file.empty())
            {
                std::printf("could not create seed %s\n", k.format);
                return 1;
            }
            file.insert(file.begin(), k.ext); // first byte selects the extension
            seeds.push_back(file);
        }
    }
    else
    {
        std::printf("usage: fuzz_c_api <midi|file> [iterations] [seed]\n");
        return 2;
    }

    // PASCALJUCE_FUZZ_SAVE=<file>: write each input there before running it,
    // so a crash leaves the offending input behind for reproduction.
    const char* savePath = std::getenv("PASCALJUCE_FUZZ_SAVE");

    for (long i = 0; i < iterations; ++i)
    {
        Bytes input = seeds[(size_t) (rng() % seeds.size())];
        if (i >= (long) seeds.size()) // run every seed unmodified first
            mutate(input, rng);
        if (savePath != nullptr)
            if (FILE* f = std::fopen(savePath, "wb"))
            {
                std::fwrite(input.data(), 1, input.size(), f);
                std::fclose(f);
            }
        if (target == "midi")
            fuzzMidi(input.data(), input.size());
        else
            fuzzFile(input.data(), input.size());
    }

    std::printf("fuzz %s: %ld iterations (seed %u) completed without memory errors\n", target.c_str(), iterations, seed);
    return 0;
}
#endif
