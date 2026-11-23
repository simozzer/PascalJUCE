/*
    plugin_host_test <scenario> <VST3|LV2> <bundle path> [replacement library]

    Loads PascalJUCE plug-ins through JUCE's own plug-in hosting (the same
    code paths a DAW exercises). Scenarios:

      synth     the PascalSynth example: notes, sample accuracy, release,
                state round-trip, editor
      probe     the ProbeEffect test plug-in: in-place effect processing,
                parameters, MIDI output, exception containment, latency,
                tail, custom state blob
      missing   a copy of the bundle without its Pascal library: must load,
                stay silent, show the error editor and preserve state
      tampered  a copy of the bundle whose Pascal library was modified after
                the build: the integrity check must refuse to load it
      replaced  a copy of the bundle whose Pascal library was replaced by
                another, valid, plug-in library (the 4th argument): refused
                the same way

    "Loaded in the process" is checked by file identity on every platform:
    the loaded modules (Windows), the mappings in /proc/self/maps (Linux) or
    dyld's image list (macOS) are compared with the file's device and inode.
*/
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

#if JUCE_WINDOWS
    #include <windows.h>
#else
    #include <sys/stat.h>
    #if JUCE_MAC
        #include <mach-o/dyld.h>
    #else
        #include <sys/sysmacros.h>
    #endif
#endif

namespace
{
int failures = 0;

void check(bool condition, const juce::String& what)
{
    std::printf("  %s  %s\n", condition ? "ok  " : "FAIL", what.toRawUTF8());
    if (! condition)
        ++failures;
}

juce::AudioProcessorParameter* findParameter(juce::AudioProcessor& p, const juce::String& name)
{
    for (auto* param : p.getParameters())
        if (param->getName(64) == name)
            return param;
    return nullptr;
}

constexpr double sampleRate = 48000.0;
constexpr int blockSize = 512;

std::unique_ptr<juce::AudioPluginInstance> load(juce::AudioPluginFormatManager& manager,
                                                const juce::String& formatName, const juce::String& path)
{
    for (auto* format : manager.getFormats())
    {
        if (format->getName() != formatName)
            continue;

        juce::OwnedArray<juce::PluginDescription> types;
        format->findAllTypesForFile(types, path);
        if (types.isEmpty())
            return nullptr;

        juce::String error;
        auto instance = manager.createPluginInstance(*types[0], sampleRate, blockSize, error);
        if (instance == nullptr)
            std::printf("  load error: %s\n", error.toRawUTF8());
        return instance;
    }
    return nullptr;
}

void prepare(juce::AudioPluginInstance& plugin, int numIn, int numOut)
{
    plugin.enableAllBuses();
    plugin.setPlayConfigDetails(numIn, numOut, sampleRate, blockSize);
    plugin.prepareToPlay(sampleRate, blockSize);
}

void runBlocks(juce::AudioPluginInstance& plugin, juce::AudioBuffer<float>& buffer, int count, float input = 0.0f)
{
    juce::MidiBuffer midi;
    for (int i = 0; i < count; ++i)
    {
        for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
            juce::FloatVectorOperations::fill(buffer.getWritePointer(ch), input, buffer.getNumSamples());
        midi.clear();
        plugin.processBlock(buffer, midi);
    }
}

juce::File pascalLibraryIn(const juce::File& bundle)
{
    for (const auto& entry : juce::RangedDirectoryIterator(bundle, true, "*_pascal.*"))
        return entry.getFile();
    return {};
}

bool isModuleLoaded(const juce::File& file)
{
#if JUCE_WINDOWS
    return GetModuleHandleW(file.getFullPathName().toWideCharPointer()) != nullptr;
#else
    struct stat target {};
    if (stat(file.getFullPathName().toRawUTF8(), &target) != 0)
        return false;
   #if JUCE_MAC
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; ++i)
    {
        struct stat image {};
        const char* name = _dyld_get_image_name(i);
        if (name != nullptr && stat(name, &image) == 0 && image.st_dev == target.st_dev && image.st_ino == target.st_ino)
            return true;
    }
    return false;
   #else
    // Every line: address perms offset major:minor inode path. The wrapper maps the
    // library through /proc/self/fd/N; the kernel reports the file itself.
    std::ifstream maps("/proc/self/maps");
    std::string line;
    while (std::getline(maps, line))
    {
        std::istringstream fields(line);
        std::string address, perms, offset, device;
        unsigned long long inode = 0;
        if (! (fields >> address >> perms >> offset >> device >> inode) || inode == 0)
            continue;
        if (inode != (unsigned long long) target.st_ino)
            continue;
        unsigned int devMajor = 0, devMinor = 0;
        const bool sameDevice = std::sscanf(device.c_str(), "%x:%x", &devMajor, &devMinor) == 2
                             && devMajor == major(target.st_dev) && devMinor == minor(target.st_dev);
        // Overlay file systems report another device here than stat() does: then the path decides.
        std::string mappedPath;
        std::getline(fields >> std::ws, mappedPath);
        if (sameDevice || mappedPath == file.getFullPathName().toStdString())
            return true;
    }
    return false;
   #endif
#endif
}

//==============================================================================
int synth(juce::AudioPluginFormatManager& manager, const juce::String& format, const juce::String& path)
{
    auto plugin = load(manager, format, path);
    check(plugin != nullptr, "plug-in loads");
    if (plugin == nullptr)
        return 1;

    check(plugin->getName() == "Pascal Synth", "name = \"" + plugin->getName() + "\"");
    check(plugin->acceptsMidi(), "accepts MIDI");
    auto* wave = findParameter(*plugin, "Waveform");
    auto* gain = findParameter(*plugin, "Gain");
    check(wave != nullptr && gain != nullptr && findParameter(*plugin, "Release") != nullptr
              && findParameter(*plugin, "Attack") != nullptr,
          "Pascal parameters visible");
    if (wave == nullptr || gain == nullptr)
        return 1;
    check(wave->getCurrentValueAsText() == "Saw", "Waveform default = " + wave->getCurrentValueAsText());

    prepare(*plugin, 0, 2);
    juce::AudioBuffer<float> buffer(2, blockSize);
    juce::MidiBuffer midi;

    buffer.clear();
    midi.addEvent(juce::MidiMessage::noteOn(1, 60, (juce::uint8) 100), 200);
    plugin->processBlock(buffer, midi);
    check(buffer.getMagnitude(0, 0, 200) == 0.0f, "silent before the note-on sample");
    check(buffer.getRMSLevel(0, 200, blockSize - 200) > 0.005f, "sound after note-on");

    runBlocks(*plugin, buffer, 20);
    check(buffer.getRMSLevel(0, 0, blockSize) > 0.01f, "sustains while held");

    buffer.clear();
    midi.clear();
    midi.addEvent(juce::MidiMessage::noteOff(1, 60), 0);
    plugin->processBlock(buffer, midi);
    runBlocks(*plugin, buffer, 60);
    check(buffer.getMagnitude(0, 0, blockSize) == 0.0f, "silent after release");

    wave->setValueNotifyingHost(1.0f); // Square
    gain->setValueNotifyingHost(0.25f);
    runBlocks(*plugin, buffer, 1); // LV2 delivers parameter changes inside run()
    juce::MemoryBlock state;
    plugin->getStateInformation(state);
    check(state.getSize() > 0, "state saved (" + juce::String((int) state.getSize()) + " bytes)");

    auto second = load(manager, format, path);
    check(second != nullptr, "second instance loads");
    if (second != nullptr)
    {
        second->setStateInformation(state.getData(), (int) state.getSize());
        prepare(*second, 0, 2);
        runBlocks(*second, buffer, 1);
        auto* wave2 = findParameter(*second, "Waveform");
        auto* gain2 = findParameter(*second, "Gain");
        check(wave2 != nullptr && wave2->getCurrentValueAsText() == "Square", "Waveform restored");
        check(gain2 != nullptr && std::abs(gain2->getValue() - 0.25f) < 1.0e-4f, "Gain restored");

        // Hostile state must be rejected without crashing or changing anything.
        juce::MemoryBlock junk;
        for (int i = 0; i < 4096; ++i)
            junk.append(&i, 1);
        second->setStateInformation(junk.getData(), (int) junk.getSize());
        const char* forged = "VC2!\x10\x00\x00\x00<PascalJUCE version=\"1\"><PARAM id=\"gain\" value=\"nan\"/>"
                             "<PARAM id=\"wave\" value=\"1e30\"/><CUSTOM>!!!not base64!!!</CUSTOM></PascalJUCE>";
        second->setStateInformation(forged, (int) std::strlen(forged));
        runBlocks(*second, buffer, 1);
        check(gain2 != nullptr && std::isfinite(gain2->getValue()), "garbage / forged state ignored safely");

#ifdef PASCALJUCE_PRIVATE_TESTS
        #include "private/host_1.inc"
#endif
    }

    {
        std::unique_ptr<juce::AudioProcessorEditor> editor(plugin->createEditorAndMakeActive());
        check(editor != nullptr && editor->getWidth() > 0, "editor created");
    }
    plugin->releaseResources();
    return 0;
}

//==============================================================================
int probe(juce::AudioPluginFormatManager& manager, const juce::String& format, const juce::String& path)
{
    auto plugin = load(manager, format, path);
    check(plugin != nullptr, "plug-in loads");
    if (plugin == nullptr)
        return 1;

    check(plugin->getName() == "Probe Effect", "name = \"" + plugin->getName() + "\"");
    check(plugin->acceptsMidi() && plugin->producesMidi(), "MIDI in and out");
    auto* gain = findParameter(*plugin, "Gain");
    auto* thr = findParameter(*plugin, "Throw");
    auto* latency = findParameter(*plugin, "Latency");
    auto* restored = findParameter(*plugin, "Restored");
    check(gain != nullptr && thr != nullptr && latency != nullptr && restored != nullptr, "Pascal parameters visible");
    if (gain == nullptr || thr == nullptr || latency == nullptr || restored == nullptr)
        return 1;
    if (format == "VST3") // LV2 has no notion of non-automatable parameters (JUCE reports true)
        check(restored->isAutomatable() == false, "non-automatable flag passed through");

    prepare(*plugin, 2, 2);
    juce::AudioBuffer<float> buffer(2, blockSize);
    int blocks = 0;

    runBlocks(*plugin, buffer, 1, 0.5f);
    ++blocks;
    check(std::abs(buffer.getSample(1, 100) - 0.5f) < 1.0e-6f, "effect passes input through at gain 1");

    gain->setValueNotifyingHost(0.5f / 2.0f); // Gain range 0..2
    runBlocks(*plugin, buffer, 2, 0.5f);
    blocks += 2;
    check(std::abs(buffer.getSample(0, 7) - 0.25f) < 1.0e-6f, "gain parameter applied in place (0.5 -> 0.25)");

    // Regression (review round 4): a NaN from the host reached Pascal as the
    // parameter value (NaN audio; for Int/Choice parameters an out-of-range index).
    gain->setValueNotifyingHost(std::numeric_limits<float>::quiet_NaN());
    runBlocks(*plugin, buffer, 2, 0.5f);
    blocks += 2;
    check(std::isfinite(buffer.getSample(0, 7)) && std::abs(buffer.getSample(0, 7)) <= 1.0f,
          "NaN parameter from the host never reaches Pascal (output " + juce::String(buffer.getSample(0, 7)) + ")");
    gain->setValueNotifyingHost(0.5f / 2.0f);
    runBlocks(*plugin, buffer, 2, 0.5f);
    blocks += 2;

#ifdef PASCALJUCE_PRIVATE_TESTS
    #include "private/host_2.inc"
#endif

    // Review round 5: the text path (VST3 getParamStringByValue) also passed NaN to Pascal.
    // (LV2 has no text callback: JUCE's LV2 host formats values itself.)
    if (format == "VST3")
    {
        const auto normalText = gain->getText(0.25f, 64);
        const auto nanText = gain->getText(std::numeric_limits<float>::quiet_NaN(), 64);
        check(normalText.endsWith(" x"), "Pascal ParameterToText used (\"" + normalText + "\")");
        check(! nanText.containsIgnoreCase("nan") && ! nanText.containsIgnoreCase("inf"),
              "NaN asked for as text never reaches Pascal (\"" + nanText + "\")");
    }

    // MIDI out: each note-on is echoed an octave up at the same position.
    {
        juce::MidiBuffer midi;
        midi.addEvent(juce::MidiMessage::noteOn(1, 60, (juce::uint8) 90), 37);
        plugin->processBlock(buffer, midi);
        ++blocks;
        int found = 0, note = -1, position = -1;
        for (const auto m : midi)
        {
            const auto msg = m.getMessage();
            if (msg.isNoteOn())
            {
                ++found;
                note = msg.getNoteNumber();
                position = m.samplePosition;
            }
        }
        check(found == 1 && note == 72 && position == 37,
              "MIDI output: note " + juce::String(note) + " at " + juce::String(position));
    }

    // An exception in Pascal Process silences the block and the plug-in keeps working.
    thr->setValueNotifyingHost(1.0f);
    runBlocks(*plugin, buffer, 2, 0.5f);
    check(buffer.getMagnitude(0, 0, blockSize) == 0.0f, "exception in Process -> silent block, host unaffected");
    thr->setValueNotifyingHost(0.0f);
    runBlocks(*plugin, buffer, 2, 0.5f);
    blocks += 1; // the first of these may still see throw=1 under LV2 (parameter delivered in run())
    check(std::abs(buffer.getSample(0, 7) - 0.25f) < 1.0e-6f, "recovers when the exception stops");

    if (format == "VST3")
    {
        latency->setValueNotifyingHost(256.0f / 4096.0f); // Latency range 0..4096
        runBlocks(*plugin, buffer, 1, 0.5f); // VST3 delivers parameter changes inside process()
        ++blocks;
        plugin->releaseResources(); // hosts skip a re-prepare with unchanged settings
        plugin->prepareToPlay(sampleRate, blockSize);
        // The new latency reaches the host via an asynchronous restartComponent(kLatencyChanged)
        // handled on the message thread, as in a DAW: pump messages.
        juce::MessageManager::getInstance()->runDispatchLoopUntil(300);
        check(plugin->getLatencySamples() == 256, "latency reported: " + juce::String(plugin->getLatencySamples()));
        check(std::abs(plugin->getTailLengthSeconds() - 1.5) < 1.0e-9, "tail length reported");
    }

    // Custom state blob (block counter) survives save/restore into a new instance.
    juce::MemoryBlock state;
    plugin->getStateInformation(state);
    auto second = load(manager, format, path);
    check(second != nullptr, "second instance loads");
    if (second != nullptr)
    {
        second->setStateInformation(state.getData(), (int) state.getSize());
        prepare(*second, 2, 2);
        runBlocks(*second, buffer, 3, 0.0f); // LV2 may apply restored state around run()
        // The probe writes (restored block count / 1e6) into the first output sample.
        const double value = std::round((double) buffer.getSample(0, 0) * 1.0e6);
        check(value >= blocks && value <= blocks + 1,
              "custom state restored (block count " + juce::String(value) + ", expected ~" + juce::String(blocks) + ")");
    }

    {
        std::unique_ptr<juce::AudioProcessorEditor> editor(plugin->createEditorAndMakeActive());
        check(editor != nullptr, "editor created");
    }
    check(isModuleLoaded(pascalLibraryIn(juce::File(path))), "Pascal library is loaded in the process");
    plugin->releaseResources();
    return 0;
}

//==============================================================================
int broken(juce::AudioPluginFormatManager& manager, const juce::String& format, const juce::String& path,
           const juce::String& mode, const juce::File& replacement)
{
    // Work on a private copy of the bundle so the build output stays intact.
    const auto source = juce::File(path);
    const auto copy = juce::File::getSpecialLocation(juce::File::tempDirectory)
                          .getChildFile("pascaljuce_" + mode + "_"
                                        + juce::String(juce::Time::currentTimeMillis()))
                          .getChildFile(source.getFileName());
    copy.getParentDirectory().createDirectory();
    check(source.copyDirectoryTo(copy), "bundle copied to " + copy.getFullPathName());

    const auto library = pascalLibraryIn(copy);
    check(library.existsAsFile(), "Pascal library present in the copy");
    if (mode == "tampered")
    {
        juce::MemoryBlock bytes;
        library.loadFileAsData(bytes);
        static_cast<char*>(bytes.getData())[bytes.getSize() / 2] ^= 0x5A; // one flipped byte
        check(library.replaceWithData(bytes.getData(), bytes.getSize()), "one byte of the library modified");
    }
    else if (mode == "replaced")
    {
        // Another plug-in's library: well-formed, exports the entry point, but not the one that was built.
        check(replacement.existsAsFile() && replacement.copyFileTo(library), "library replaced by " + replacement.getFileName());
    }
    else
    {
        check(library.deleteFile(), "library deleted");
    }

    auto plugin = load(manager, format, copy.getFullPathName());
    check(plugin != nullptr, "the wrapper itself still loads (host does not crash)");
    if (plugin != nullptr)
    {
        check(findParameter(*plugin, "Gain") == nullptr, "no Pascal parameters (library refused)");
        check(! isModuleLoaded(library), "library was never mapped into the process");

        prepare(*plugin, 2, 2);
        juce::AudioBuffer<float> buffer(2, blockSize);
        runBlocks(*plugin, buffer, 3, 0.5f);
        check(buffer.getMagnitude(0, 0, blockSize) == 0.0f, "outputs silence");

        // A project saved while the library is unavailable must keep the user's
        // settings: working state -> broken instance -> saved -> working instance.
        juce::MemoryBlock good, passedThrough;
        if (auto working = load(manager, format, path))
        {
            auto* gain = findParameter(*working, "Gain");
            if (gain != nullptr)
                gain->setValueNotifyingHost(0.75f / 2.0f); // Gain range 0..2
            prepare(*working, 2, 2);
            runBlocks(*working, buffer, 1);
            working->getStateInformation(good);
        }
        plugin->setStateInformation(good.getData(), (int) good.getSize());
        plugin->getStateInformation(passedThrough);
        if (auto restored = load(manager, format, path))
        {
            restored->setStateInformation(passedThrough.getData(), (int) passedThrough.getSize());
            prepare(*restored, 2, 2);
            runBlocks(*restored, buffer, 1);
            auto* gain = findParameter(*restored, "Gain");
            check(gain != nullptr && std::abs(gain->getValue() * 2.0f - 0.75f) < 1.0e-3f,
                  "settings survive a save made while the library was unavailable");
        }

        std::unique_ptr<juce::AudioProcessorEditor> editor(plugin->createEditorAndMakeActive());
        check(editor != nullptr && editor->getWidth() > 0, "error editor shown");
        editor.reset();
        plugin.reset();
    }
    copy.getParentDirectory().deleteRecursively();
    return 0;
}
} // namespace

int main(int argc, char* argv[])
{
    if (argc < 4)
    {
        std::printf("usage: plugin_host_test <synth|probe|missing|tampered|replaced> <VST3|LV2> <bundle path> [replacement library]\n");
        return 2;
    }

    juce::ScopedJuceInitialiser_GUI juceInit;
    const juce::String scenario(argv[1]);
    const juce::String formatName(argv[2]);
    const juce::String path = juce::File::getCurrentWorkingDirectory().getChildFile(juce::String::fromUTF8(argv[3]))
                                  .getFullPathName();

    juce::AudioPluginFormatManager manager;
    juce::addDefaultFormatsToManager(manager);

    std::printf("%s / %s: %s\n", scenario.toRawUTF8(), formatName.toRawUTF8(), path.toRawUTF8());
    int result = 2;
    if (scenario == "synth")
        result = synth(manager, formatName, path);
    else if (scenario == "probe")
        result = probe(manager, formatName, path);
    else if (scenario == "missing" || scenario == "tampered" || scenario == "replaced")
        result = broken(manager, formatName, path, scenario,
                        argc > 4 ? juce::File::getCurrentWorkingDirectory().getChildFile(juce::String::fromUTF8(argv[4]))
                                 : juce::File());
    else
        std::printf("unknown scenario\n");

    std::printf(failures == 0 && result == 0 ? "All checks passed\n" : "%d check(s) FAILED\n", failures);
    return failures == 0 && result == 0 ? 0 : 1;
}
