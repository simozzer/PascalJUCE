// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
//     mz101_host_check <VST3|LV2> <bundle path>
//
// Loads the built Mz101 Pascal bundle through JUCE's own plug-in hosting (what a DAW
// does) and plays it: parameters and their text, notes, the CC map, the Patch parameter,
// the momentary buttons, the sequence in the saved state, hostile state, and that the
// editor is the custom panel.
// Built by host/CMakeLists.txt, outside the main build (see build_host_check.cmd).

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>

#include <cstdio>

namespace
{
int failures = 0;

void check(bool condition, const juce::String& what)
{
    std::printf("  %s  %s\n", condition ? "ok  " : "FAIL", what.toRawUTF8());
    if (! condition) ++failures;
}

constexpr double sampleRate = 48000.0;
constexpr int blockSize = 512;

juce::AudioProcessorParameter* param(juce::AudioProcessor& p, const juce::String& name)
{
    for (auto* q : p.getParameters())
        if (q->getName(64) == name) return q;
    return nullptr;
}

std::unique_ptr<juce::AudioPluginInstance> load(juce::AudioPluginFormatManager& manager,
                                                const juce::String& formatName, const juce::String& path)
{
    for (auto* format : manager.getFormats())
    {
        if (format->getName() != formatName) continue;
        juce::OwnedArray<juce::PluginDescription> types;
        format->findAllTypesForFile(types, path);
        if (types.isEmpty()) return nullptr;
        juce::String error;
        auto instance = manager.createPluginInstance(*types[0], sampleRate, blockSize, error);
        if (instance == nullptr) std::printf("  load error: %s\n", error.toRawUTF8());
        return instance;
    }
    return nullptr;
}

void prepare(juce::AudioPluginInstance& plugin)
{
    plugin.enableAllBuses();
    plugin.setPlayConfigDetails(0, 2, sampleRate, blockSize);
    plugin.prepareToPlay(sampleRate, blockSize);
}

// The wrapper hands SetParameter from Process to the host on the message thread.
void pump()
{
    juce::MessageManager::getInstance()->runDispatchLoopUntil(30);
}

float run(juce::AudioPluginInstance& plugin, juce::AudioBuffer<float>& buffer, int blocks, juce::MidiBuffer* first = nullptr)
{
    juce::MidiBuffer none;
    float rms = 0;
    for (int i = 0; i < blocks; ++i)
    {
        buffer.clear();
        plugin.processBlock(buffer, (i == 0 && first != nullptr) ? *first : none);
        rms = buffer.getRMSLevel(0, 0, blockSize);
    }
    return rms;
}

juce::MidiBuffer one(const juce::MidiMessage& m, int pos = 0)
{
    juce::MidiBuffer b;
    b.addEvent(m, pos);
    return b;
}

// Blocks and message loop in turn, until changes have gone both ways. LV2 carries them in
// run() as well, so it needs a few rounds where VST3 needs one.
void settle(juce::AudioPluginInstance& plugin, juce::AudioBuffer<float>& buffer)
{
    for (int i = 0; i < 6; ++i)
    {
        run(plugin, buffer, 2);
        pump();
    }
}
} // namespace

int main(int argc, char* argv[])
{
    if (argc < 3)
    {
        std::printf("usage: mz101_host_check <VST3|LV2> <bundle path>\n");
        return 2;
    }
    juce::ScopedJuceInitialiser_GUI gui;
    juce::AudioPluginFormatManager manager;
    juce::addDefaultFormatsToManager(manager);
    const juce::String format(argv[1]);
    const juce::String path = juce::File::getCurrentWorkingDirectory().getChildFile(juce::String::fromUTF8(argv[2])).getFullPathName();
    std::printf("Mz101 Pascal / %s: %s\n", format.toRawUTF8(), path.toRawUTF8());

    auto plugin = load(manager, format, path);
    check(plugin != nullptr, "plug-in loads");
    if (plugin == nullptr) return 1;

    check(plugin->getName() == "Mz101 Pascal", "name = \"" + plugin->getName() + "\"");
    check(plugin->acceptsMidi() && ! plugin->producesMidi(), "an instrument: MIDI in, none out");
    auto* cutoff = param(*plugin, "VCF Freq");
    auto* range = param(*plugin, "VCO Range");
    auto* patch = param(*plugin, "Patch");
    auto* porta = param(*plugin, "Portamento");
    auto* trans = param(*plugin, "Key Transpose / Rest");
    auto* seq = param(*plugin, "Sequencer");
    auto* hold = param(*plugin, "Hold");
    check(cutoff && range && patch && porta && trans && seq && hold && param(*plugin, "Legato") && param(*plugin, "Volume"),
          "the panel's controls, Patch and the buttons are parameters");
    if (! (cutoff && range && patch && porta && trans && seq && hold)) return 1;
    // VST3 shows the plug-in's own text for a value ("6.0", as the C++ shows it); JUCE's LV2
    // host formats numbers itself, and LV2 has no tail - so there the values are checked.
    const bool vst3 = format == "VST3";
    auto is = [vst3] (juce::AudioProcessorParameter* p, float normalised, const juce::String& text)
    {
        return vst3 ? p->getCurrentValueAsText() == text : std::abs(p->getValue() - normalised) < 1.0e-4f;
    };
    check(is(cutoff, 0.6f, "6.0") && range->getCurrentValueAsText() == "8'",
          "defaults and their text: VCF Freq " + cutoff->getCurrentValueAsText() + ", VCO Range " + range->getCurrentValueAsText());
    if (vst3) check(plugin->getTailLengthSeconds() == 10.0, "tail 10 s");

    prepare(*plugin);
    juce::AudioBuffer<float> buffer(2, blockSize);

    auto on = one(juce::MidiMessage::noteOn(1, 48, (juce::uint8) 100), 200);
    buffer.clear();
    plugin->processBlock(buffer, on);
    check(buffer.getMagnitude(0, 0, 200) == 0.0f, "silent before the note-on sample");
    const float held = run(*plugin, buffer, 10);
    check(held > 0.02f, "a note sounds (rms " + juce::String(held, 3) + ")");
    check(buffer.getMagnitude(0, 0, blockSize) == buffer.getMagnitude(1, 0, blockSize), "both channels");

    auto off = one(juce::MidiMessage::noteOff(1, 48));
    run(*plugin, buffer, 1, &off);
    const float after = run(*plugin, buffer, 300);
    check(after < 1.0e-4f, "lets go after the release (rms " + juce::String(after, 6) + ")");

    // CC 74 moves VCF Freq, and the host hears about it
    auto cc = one(juce::MidiMessage::controllerEvent(1, 74, 127));
    run(*plugin, buffer, 1, &cc);
    settle(*plugin, buffer);
    check(is(cutoff, 1.0f, "10.0"), "CC 74 moves VCF Freq: " + cutoff->getCurrentValueAsText());

    // choosing a patch sets the panel
    patch->setValueNotifyingHost(2.0f / 9.0f);     // Acid Line
    run(*plugin, buffer, 8);
    settle(*plugin, buffer);
    check(patch->getCurrentValueAsText() == "Acid Line" && is(cutoff, 0.25f, "2.5")
              && porta->getCurrentValueAsText() == "Auto",
          "Patch 'Acid Line': VCF Freq " + cutoff->getCurrentValueAsText() + ", Portamento " + porta->getCurrentValueAsText());

    // a tweak after choosing the patch belongs to the project
    cutoff->setValueNotifyingHost(0.7f);
    settle(*plugin, buffer);

    // the momentary button switches itself back off
    trans->setValueNotifyingHost(1.0f);
    settle(*plugin, buffer);
    check(trans->getValue() < 0.5f, "Key Transpose / Rest is momentary");

    // record a sequence in LOAD, save, and reopen elsewhere
    seq->setValueNotifyingHost(1.0f);   // Load (Off, Play, Load: normalised 0, 0.5, 1)
    run(*plugin, buffer, 2);
    for (int note : { 48, 51, 55, 60 })
    {
        auto n = one(juce::MidiMessage::noteOn(1, note, (juce::uint8) 100));
        run(*plugin, buffer, 4, &n);
        auto f = one(juce::MidiMessage::noteOff(1, note));
        run(*plugin, buffer, 4, &f);
    }
    seq->setValueNotifyingHost(0.0f);
    run(*plugin, buffer, 2);
    juce::MemoryBlock state;
    plugin->getStateInformation(state);
    check(state.getSize() > 0, "state saved (" + juce::String((int) state.getSize()) + " bytes)");

    auto playsSequence = [&] (juce::AudioPluginInstance& p)
    {
        // PLAY with HOLD: one key starts the sequence; without one, PLAY stays silent
        if (auto* s = param(p, "Sequencer")) s->setValueNotifyingHost(0.5f);   // Play
        if (auto* h = param(p, "Hold")) h->setValueNotifyingHost(1.0f);
        prepare(p);
        juce::AudioBuffer<float> b(2, blockSize);
        run(p, b, 2);
        auto k = one(juce::MidiMessage::noteOn(1, 60, (juce::uint8) 100));
        float level = 0;
        juce::MidiBuffer none;
        for (int i = 0; i < 100; ++i)
        {
            b.clear();
            p.processBlock(b, i == 0 ? k : none);
            level = std::max(level, b.getRMSLevel(0, 0, blockSize));
        }
        return level;
    };

    auto second = load(manager, format, path);
    auto third = load(manager, format, path);
    check(second != nullptr && third != nullptr, "more instances load");
    if (second != nullptr && third != nullptr)
    {
        second->setStateInformation(state.getData(), (int) state.getSize());
        auto* cutoff2 = param(*second, "VCF Freq");
        auto* patch2 = param(*second, "Patch");
        const float withSeq = playsSequence(*second), withoutSeq = playsSequence(*third);
        check(cutoff2 && patch2 && is(cutoff2, 0.7f, "7.0") && patch2->getCurrentValueAsText() == "Acid Line",
              "parameters restored: VCF Freq " + cutoff2->getCurrentValueAsText() + ", Patch " + patch2->getCurrentValueAsText());
        check(withSeq > 0.02f && withoutSeq == 0.0f,
              "the sequence comes back with the project (PLAY: rms " + juce::String(withSeq, 3) + ", a fresh one "
                  + juce::String(withoutSeq, 3) + ")");
        settle(*second, buffer);
        check(is(cutoff2, 0.7f, "7.0"), "reopening does not re-apply the patch over the tweak: " + cutoff2->getCurrentValueAsText());

        juce::MemoryBlock junk;
        for (int i = 0; i < 4096; ++i) junk.append(&i, 1);
        second->setStateInformation(junk.getData(), (int) junk.getSize());
        juce::AudioBuffer<float> b(2, blockSize);
        run(*second, b, 2);
        check(std::isfinite(b.getRMSLevel(0, 0, blockSize)), "garbage state ignored safely");
    }

    {
        // The panel (Mz101Editor, 1490 x 610 as the C++ one), not JUCE's generic editor: the
        // host's window for it takes the plug-in's own size.
        check(plugin->hasEditor(), "the plug-in has an editor");
        std::unique_ptr<juce::AudioProcessorEditor> editor(plugin->createEditorAndMakeActive());
        pump();
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr
                  && editor->getWidth() == 1490 && editor->getHeight() == 610,
              "the custom panel opens: " + (editor != nullptr ? juce::String(editor->getWidth()) + " x "
                                                                    + juce::String(editor->getHeight())
                                                              : juce::String("none")));
        if (editor != nullptr)
        {
            juce::Image image(juce::Image::ARGB, editor->getWidth(), editor->getHeight(), true);
            juce::Graphics g(image);
            editor->paintEntireComponent(g, true);
        }
        editor.reset();
        pump();
    }
    plugin->releaseResources();

    std::printf("%s\n", failures == 0 ? "all host checks passed" : (juce::String(failures) + " FAILED").toRawUTF8());
    return failures == 0 ? 0 : 1;
}
