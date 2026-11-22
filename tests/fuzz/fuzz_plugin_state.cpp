/*
    Fuzz target: hostile plug-in state, as found in a downloaded DAW project.

    Links the ProbeEffect wrapper (its JUCE AudioProcessor, compiled into the
    shared-code target) directly, so mutated bytes reach the wrapper's
    XML/base64/validation code and then the Pascal LoadState, exactly as a
    host's setStateInformation would deliver them. Each state is followed by
    a processed block, so a corrupt state that "loads" is also exercised.

        fuzz_plugin_state [iterations] [seed]

    The probe's Pascal library must sit next to this executable (CMake copies
    it). Build with AddressSanitizer to turn memory errors into failures.
*/
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>

#include <clocale>
#include <cstdio>
#include <cstring>
#include <random>

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter();

static void mutate(juce::MemoryBlock& block, std::mt19937& rng)
{
    std::vector<uint8_t> b(static_cast<const uint8_t*>(block.getData()),
                           static_cast<const uint8_t*>(block.getData()) + block.getSize());
    auto pick = [&](size_t n) { return n == 0 ? 0 : (size_t) (rng() % n); };
    const int rounds = 1 + (int) (rng() % 6);
    for (int r = 0; r < rounds; ++r)
    {
        switch (rng() % 6)
        {
            case 0: if (! b.empty()) b[pick(b.size())] ^= (uint8_t) (1u << (rng() % 8)); break;
            case 1: if (! b.empty()) b[pick(b.size())] = "<>\"=&/0-9.eE+naninf"[rng() % 19]; break; // XML-ish
            case 2: b.insert(b.begin() + (long) pick(b.size() + 1), (uint8_t) rng()); break;
            case 3: if (! b.empty()) b.erase(b.begin() + (long) pick(b.size())); break;
            case 4: if (! b.empty()) b.resize(pick(b.size())); break;
            case 5: if (b.size() > 16) { const auto from = pick(b.size() - 16);
                        const std::vector<uint8_t> chunk(b.begin() + (long) from, b.begin() + (long) from + 16); // copy: self-insert is UB
                        b.insert(b.begin() + (long) pick(b.size()), chunk.begin(), chunk.end()); } break;
        }
    }
    block.replaceAll(b.data(), b.size());
}

int main(int argc, char* argv[])
{
    const long iterations = argc > 1 ? std::strtol(argv[1], nullptr, 10) : 3000;
    const unsigned seed = argc > 2 ? (unsigned) std::strtoul(argv[2], nullptr, 10) : 4242u;

    juce::ScopedJuceInitialiser_GUI juceInit;
    std::unique_ptr<juce::AudioProcessor> plugin(createPluginFilter());
    plugin->setPlayConfigDetails(2, 2, 48000.0, 256);
    plugin->prepareToPlay(48000.0, 256);

    if (plugin->getParameters().isEmpty())
    {
        std::printf("the Pascal library did not load next to the fuzz executable\n");
        return 1;
    }

    juce::AudioBuffer<float> buffer(2, 256);
    juce::MidiBuffer midi;
    buffer.clear();
    plugin->processBlock(buffer, midi);

    // Seeds: genuine states, including one with a custom (Pascal) blob.
    std::vector<juce::MemoryBlock> seeds;
    juce::MemoryBlock state;
    plugin->getStateInformation(state);
    seeds.push_back(state);
    for (auto* p : plugin->getParameters())
        p->setValueNotifyingHost(0.7f);
    plugin->processBlock(buffer, midi);
    plugin->getStateInformation(state);
    seeds.push_back(state);
    if (auto xml = juce::AudioProcessor::getXmlFromBinary(state.getData(), (int) state.getSize()))
    {
        seeds.push_back(juce::MemoryBlock(xml->toString().toRawUTF8(), xml->toString().getNumBytesAsUTF8()));
        // Raw XML without JUCE's binary header, and with absurd values.
        auto hostile = xml->toString().replace("value=\"", "value=\"1e308");
        seeds.push_back(juce::MemoryBlock(hostile.toRawUTF8(), hostile.getNumBytesAsUTF8()));
    }

    // Regression seeds: JUCE's XML parser overran the heap on these (truncated
    // UTF-8 sequences) before the wrapper started validating state text.
    for (const char* tail : { "\xF0", "\xE2\x82", "\xC3", "<PARAM id=\"gain\" value=\"1\xF0", "\xED\xA0\x80</PascalJUCE>" })
    {
        juce::MemoryOutputStream forged;
        const juce::String head("<PascalJUCE version=\"1\">");
        const auto body = head.toStdString() + tail;
        forged.writeInt(0x21324356);
        forged.writeInt((int) body.size() + 1);
        forged.write(body.data(), body.size());
        forged.writeByte(0);
        seeds.push_back(forged.getMemoryBlock());
    }

    // Regression (review round 1): structural attacks a byte mutator never builds.
    //  - 100k nested elements: JUCE's XML parser recurses per level (stack overflow)
    //  - 500k PARAM elements: DOM blow-up and per-parameter scans (host hangs)
    {
        auto wrap = [](const std::string& body)
        {
            juce::MemoryOutputStream out;
            out.writeInt(0x21324356);
            out.writeInt((int) body.size() + 1);
            out.write(body.data(), body.size());
            out.writeByte(0);
            return out.getMemoryBlock();
        };
        std::string deep = "<PascalJUCE version=\"1\">";
        for (int i = 0; i < 100000; ++i)
            deep += "<a>";
        for (int i = 0; i < 100000; ++i)
            deep += "</a>";
        deep += "</PascalJUCE>";
        std::string wide = "<PascalJUCE version=\"1\">";
        for (int i = 0; i < 500000; ++i)
            wide += "<PARAM id=\"gain\" value=\"0.5\"/>";
        wide += "</PascalJUCE>";

        // Round 2: inputs the old pre-scanner let through (markup inside attribute
        // values of closing tags, quotes outside any tag) and other malformed state.
        // The strict codec must refuse all of them.
        std::string nested200k;
        for (int i = 0; i < 200000; ++i)
            nested200k += "<b>";
        const std::string bypassClose = "<PascalJUCE version=\"2\"><a></a x=\"" + nested200k + "\"></PascalJUCE>";
        const std::string bypassQuote = "<PascalJUCE version=\"2\"><a \"" + nested200k + "\"/></PascalJUCE>";
        std::string attributes = "<PascalJUCE version=\"2\"><PARAM";
        for (int i = 0; i < 200000; ++i)
            attributes += " a" + std::to_string(i) + "=\"1\"";
        attributes += "/></PascalJUCE>";
        const std::string negativeCustom = "<PascalJUCE version=\"2\">\n  <CUSTOM>not base64 at all</CUSTOM>\n</PascalJUCE>\n";
        std::string manyParams = "<PascalJUCE version=\"2\">\n";
        for (int i = 0; i < 1000000; ++i)
            manyParams += "  <PARAM id=\"gain\" value=\"0.5\"/>\n";
        manyParams += "</PascalJUCE>\n";

        const std::pair<const char*, juce::MemoryBlock> attacks[] = {
            { "100k-deep nesting", wrap(deep) },
            { "500k PARAM elements (v1)", wrap(wide) },
            { "scanner bypass: markup in a closing tag's attribute", wrap(bypassClose) },
            { "scanner bypass: quote outside a value", wrap(bypassQuote) },
            { "many attributes", wrap(attributes) },
            { "malformed CUSTOM", wrap(negativeCustom) },
            { "1M PARAM elements (v2 syntax)", wrap(manyParams) },
        };
        for (const auto& [name, blob] : attacks)
        {
            const auto start = juce::Time::getMillisecondCounterHiRes();
            plugin->setStateInformation(blob.getData(), (int) blob.getSize());
            const auto elapsed = juce::Time::getMillisecondCounterHiRes() - start;
            std::printf("  %s: rejected in %.1f ms\n", name, elapsed);
            if (elapsed > 2000.0)
            {
                std::printf("hostile state '%s' took %.0f ms (should be rejected quickly)\n", name, elapsed);
                return 1;
            }
        }
    }

    // The codec must round-trip exactly what it wrote.
    {
        juce::MemoryBlock saved;
        for (auto* p : plugin->getParameters())
            p->setValueNotifyingHost(0.25f);
        plugin->processBlock(buffer, midi);
        plugin->getStateInformation(saved);
        for (auto* p : plugin->getParameters())
            p->setValueNotifyingHost(0.9f);
        plugin->setStateInformation(saved.getData(), (int) saved.getSize());
        for (auto* p : plugin->getParameters())
        {
            const float back = p->getValue();
            auto* ranged = dynamic_cast<juce::RangedAudioParameter*>(p);
            const float expected = ranged != nullptr ? ranged->convertTo0to1(ranged->convertFrom0to1(0.25f)) : 0.25f;
            if (std::abs(back - expected) > 1.0e-4f)
            {
                std::printf("state round trip: '%s' came back as %f, expected %f\n", p->getName(64).toRawUTF8(),
                            (double) back, (double) expected);
                return 1;
            }
        }
        std::printf("  state round trip: ok (%d bytes)\n", (int) saved.getSize());

        // Regression (review round 3): numbers went through the C locale, so under a
        // comma-decimal locale state was written as "0,5" and nothing could be loaded.
        const char* const commaLocales[] = { "de-DE", "de_DE.UTF-8", "German_Germany.1252", "de_DE" };
        const char* used = nullptr;
        for (const char* name : commaLocales)
            if (std::setlocale(LC_ALL, name) != nullptr)
            {
                used = name;
                break;
            }
        if (used == nullptr)
        {
            std::printf("  locale round trip: skipped (no comma-decimal locale installed)\n");
        }
        else
        {
            juce::MemoryBlock local;
            plugin->getStateInformation(local);
            const bool noComma = std::memchr(local.getData(), ',', local.getSize()) == nullptr;
            for (auto* p : plugin->getParameters())
                p->setValueNotifyingHost(0.9f);
            plugin->setStateInformation(saved.getData(), (int) saved.getSize()); // saved under "C"
            bool restored = true;
            for (auto* p : plugin->getParameters())
            {
                auto* ranged = dynamic_cast<juce::RangedAudioParameter*>(p);
                const float expected = ranged != nullptr ? ranged->convertTo0to1(ranged->convertFrom0to1(0.25f)) : 0.25f;
                restored = restored && std::abs(p->getValue() - expected) <= 1.0e-4f;
            }
            std::setlocale(LC_ALL, "C");
            if (! noComma || ! restored || local.getSize() != saved.getSize())
            {
                std::printf("locale round trip under %s failed (comma written: %d, restored: %d)\n", used,
                            noComma ? 0 : 1, restored ? 1 : 0);
                return 1;
            }
            std::printf("  locale round trip under %s: ok\n", used);
        }
    }

    std::mt19937 rng(seed);
    for (long i = 0; i < iterations; ++i)
    {
        auto input = seeds[(size_t) (rng() % seeds.size())];
        if (i >= (long) seeds.size())
            mutate(input, rng);
        plugin->setStateInformation(input.getData(), (int) input.getSize());

        for (auto* p : plugin->getParameters())
        {
            const float v = p->getValue();
            if (! std::isfinite(v) || v < 0.0f || v > 1.0f)
            {
                std::printf("iteration %ld: parameter '%s' left at invalid value %f\n", i,
                            p->getName(64).toRawUTF8(), (double) v);
                return 1;
            }
        }
        midi.clear();
        plugin->processBlock(buffer, midi);
        juce::MemoryBlock back;
        plugin->getStateInformation(back);
    }

    // A library without create_editor (built before custom editors existed, or
    // not wanting one) keeps JUCE's generic editor.
    {
        std::unique_ptr<juce::AudioProcessorEditor> editor(plugin->createEditorAndMakeActive());
        const bool generic = dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) != nullptr;
        plugin->editorBeingDeleted(editor.get());
        editor.reset();
        if (! generic)
        {
            std::printf("a library without an editor must get the generic editor\n");
            return 1;
        }
    }

    plugin->releaseResources();
    std::printf("fuzz plugin state: %ld iterations (seed %u) completed without memory errors\n", iterations, seed);
    return 0;
}
