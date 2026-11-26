/*
    editor_test - the PascalSynth template's custom editor (Pascal controls
    from pascal/JuceUI.pas and JuceControls.pas), driven offscreen.

    Links the real wrapper, configured as PascalSynth, and loads
    PascalSynth_pascal.dll from next to the executable:
      - renders the editor into a software image and compares it with the
        reference PNGs in tests/data/ui (small per-pixel tolerance for font
        rasterisation);
      - simulates mouse input: knob drags (normal and fine), double-click to
        default, wheel, the waveform switch, right-click menu;
      - checks host gestures stay balanced, host automation reaches the
        controls, the window closing inside a callback, and 1000 editors.

    Set PASCALJUCE_UPDATE_UI_REFERENCES=1 to rewrite the references (after a
    deliberate change to the look; check the new PNGs before committing).
*/
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>
#include "test_foreground.h"

#include <cstdio>
#include <thread>

#if JUCE_WINDOWS
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <windows.h>
    #include <psapi.h>
#endif
#if JUCE_MAC
    #include <mach/mach.h>
#endif
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter();
int pascaljuce_live_editor_sessions();
void pascaljuce_test_skip_text(bool skip);

namespace
{
// Closes an editor the way JUCE's format wrappers do: tell the processor, then delete.
struct EditorCloser
{
    void operator()(juce::AudioProcessorEditor* editor) const
    {
        if (editor == nullptr)
            return;
        if (auto* processor = editor->getAudioProcessor())
            processor->editorBeingDeleted(editor);
        delete editor;
    }
};
using EditorPtr = std::unique_ptr<juce::AudioProcessorEditor, EditorCloser>;

int failures = 0;

void check(bool condition, const juce::String& what)
{
    std::printf("  %s  %s\n", condition ? "ok  " : "FAIL", what.toRawUTF8());
    if (! condition)
        ++failures;
}

void pump(int ms = 60)
{
    juce::MessageManager::getInstance()->runDispatchLoopUntil(ms);
}

// Layout of SynthEditor.pas (panel at 6,6), in editor coordinates.
const juce::Point<float> attackKnob { 224.0f, 102.0f };
const juce::Point<float> gainKnob { 388.0f, 102.0f };
const juce::Point<float> switchSine { 45.0f, 93.0f };
const juce::Point<float> switchSquare { 150.0f, 93.0f };

juce::Image render(juce::Component& c)
{
    juce::Image image(juce::Image::ARGB, c.getWidth(), c.getHeight(), true, juce::SoftwareImageType());
    juce::Graphics g(image);
    c.paintEntireComponent(g, true);
    return image;
}

juce::File referenceDir() { return juce::File(PASCALJUCE_TEST_DATA).getChildFile("ui"); }

// The references were rendered on Windows. Text is the one part that differs
// between platforms: JUCE draws it with the platform's default sans-serif face
// (Verdana on Windows; on Linux whatever Fontconfig offers, e.g. DejaVu Sans;
// on macOS its own) and its own rasteriser. So the comparison finds the text
// pixels (the editor rendered again with text left out, grown by 3 pixels)
// and holds the rest of the panel to the same standard everywhere:
//   outside text: at most 0.2% of those pixels off by more than 24 in a channel;
//   text areas:   Windows at most 0.5% of all pixels (as the panel as a whole),
//                 elsewhere at most 60% of the text pixels (other glyph shapes).
void compareWithReference(juce::Component& c, const juce::String& name)
{
    const auto actual = render(c);
    pascaljuce_test_skip_text(true);
    const auto noText = render(c);
    pascaljuce_test_skip_text(false);

    const auto file = referenceDir().getChildFile(name + ".png");
    const bool update = juce::SystemStats::getEnvironmentVariable("PASCALJUCE_UPDATE_UI_REFERENCES", {}) == "1";
    if (update || ! file.existsAsFile())
    {
        const auto target = update ? file : juce::File::getCurrentWorkingDirectory().getChildFile(name + ".actual.png");
        target.getParentDirectory().createDirectory();
        target.deleteFile();
        juce::FileOutputStream out(target);
        juce::PNGImageFormat().writeImageToStream(actual, out);
        check(update, name + ": reference " + (update ? "written to " : "missing; actual image in ") + target.getFullPathName());
        return;
    }
    const auto expected = juce::ImageFileFormat::loadFrom(file);
    const int w = actual.getWidth(), h = actual.getHeight();
    if (! expected.isValid() || expected.getWidth() != w || expected.getHeight() != h)
    {
        check(false, name + ": reference size differs");
        return;
    }
    const auto channelDiff = [](juce::Colour a, juce::Colour e)
    {
        return std::max({ std::abs(a.getRed() - e.getRed()), std::abs(a.getGreen() - e.getGreen()),
                          std::abs(a.getBlue() - e.getBlue()), std::abs(a.getAlpha() - e.getAlpha()) });
    };
    std::vector<char> isText((size_t) (w * h), 0);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            if (channelDiff(actual.getPixelAt(x, y), noText.getPixelAt(x, y)) > 0)
                for (int dy = -3; dy <= 3; ++dy)
                    for (int dx = -3; dx <= 3; ++dx)
                        if (x + dx >= 0 && y + dy >= 0 && x + dx < w && y + dy < h)
                            isText[(size_t) ((y + dy) * w + x + dx)] = 1;

    int bad = 0, worst = 0, textPixels = 0, textBad = 0, outsideBad = 0, outsideWorst = 0;
    juce::Image diff(juce::Image::ARGB, w, h, true, juce::SoftwareImageType());
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
        {
            const int d = channelDiff(actual.getPixelAt(x, y), expected.getPixelAt(x, y));
            const bool text = isText[(size_t) (y * w + x)] != 0;
            textPixels += text ? 1 : 0;
            worst = std::max(worst, d);
            if (! text)
                outsideWorst = std::max(outsideWorst, d);
            if (d > 24)
            {
                ++bad;
                ++(text ? textBad : outsideBad);
                diff.setPixelAt(x, y, text ? juce::Colours::orange : juce::Colours::red);
            }
        }
    const int outsidePixels = w * h - textPixels;
    const bool outsideOk = outsideBad <= outsidePixels / 500;
   #if JUCE_WINDOWS
    const bool textOk = bad <= w * h / 200;
    const juce::String textRule = "whole panel at most 0.5%";
   #else
    const bool textOk = textBad <= textPixels * 35 / 100;
    const juce::String textRule = "text areas at most 35%";
   #endif
    if (! outsideOk || ! textOk)
    {
        for (const auto& [img, suffix] : { std::pair<const juce::Image*, const char*> { &actual, ".actual.png" }, { &diff, ".diff.png" } })
        {
            const auto f = juce::File::getCurrentWorkingDirectory().getChildFile(name + suffix);
            f.deleteFile();
            juce::FileOutputStream out(f);
            juce::PNGImageFormat().writeImageToStream(*img, out);
        }
    }
    const auto pct = [](int n, int of) { return juce::String(100.0 * n / std::max(1, of), 2) + "%"; };
    check(outsideOk, name + " matches its reference outside text (" + juce::String(outsideBad) + " of "
                         + juce::String(outsidePixels) + " pixels off = " + pct(outsideBad, outsidePixels)
                         + ", limit 0.2%; worst channel difference " + juce::String(outsideWorst) + ")");
    check(textOk, name + " matches its reference in text areas (" + juce::String(textBad) + " of "
                      + juce::String(textPixels) + " text pixels off = " + pct(textBad, textPixels) + "; "
                      + juce::String(bad) + " in all = " + pct(bad, w * h) + "; " + textRule
                      + "; worst " + juce::String(worst) + ")");
}

juce::MouseEvent mouseEvent(juce::Component& c, juce::Point<float> pos, juce::ModifierKeys mods, int clicks,
                            juce::Point<float> downAt)
{
    const auto now = juce::Time::getCurrentTime();
    return juce::MouseEvent(juce::Desktop::getInstance().getMainMouseSource(), pos, mods,
                            juce::MouseInputSource::defaultPressure, 0.0f, 0.0f, 0.0f, 0.0f, &c, &c, now, downAt, now,
                            clicks, false);
}

const juce::ModifierKeys left { juce::ModifierKeys::leftButtonModifier };
const juce::ModifierKeys leftShift { juce::ModifierKeys::leftButtonModifier | juce::ModifierKeys::shiftModifier };
const juce::ModifierKeys right { juce::ModifierKeys::rightButtonModifier };

void drag(juce::Component& c, juce::Point<float> from, juce::Point<float> to, juce::ModifierKeys mods = left)
{
    c.mouseDown(mouseEvent(c, from, mods, 1, from));
    c.mouseDrag(mouseEvent(c, (from + to) * 0.5f, mods, 1, from));
    c.mouseDrag(mouseEvent(c, to, mods, 1, from));
    c.mouseUp(mouseEvent(c, to, juce::ModifierKeys(), 1, from));
}

void click(juce::Component& c, juce::Point<float> at, juce::ModifierKeys mods = left)
{
    c.mouseDown(mouseEvent(c, at, mods, 1, at));
    c.mouseUp(mouseEvent(c, at, juce::ModifierKeys(), 1, at));
}

void doubleClick(juce::Component& c, juce::Point<float> at)
{
    click(c, at);
    c.mouseDown(mouseEvent(c, at, left, 2, at));
    c.mouseUp(mouseEvent(c, at, juce::ModifierKeys(), 2, at));
    c.mouseDoubleClick(mouseEvent(c, at, juce::ModifierKeys(), 2, at));
}

struct GestureCounter final : juce::AudioProcessorParameter::Listener
{
    void parameterValueChanged(int, float) override {}
    void parameterGestureChanged(int, bool starting) override { ++(starting ? begins : ends); }
    int begins = 0, ends = 0;
};

juce::AudioProcessorParameter* find(juce::AudioProcessor& p, const juce::String& name)
{
    for (auto* param : p.getParameters())
        if (param->getName(64) == name)
            return param;
    return nullptr;
}

void resetToDefaults(juce::AudioProcessor& p)
{
    for (auto* param : p.getParameters())
        param->setValueNotifyingHost(param->getDefaultValue());
    pump();
}

int64_t privateBytes()
{
#if JUCE_WINDOWS
    PROCESS_MEMORY_COUNTERS_EX counters {};
    GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters), sizeof(counters));
    return (int64_t) counters.PrivateUsage;
#elif JUCE_MAC
    task_vm_info_data_t info {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
        return 0;
    return (int64_t) info.phys_footprint; // what Activity Monitor calls Memory
#else
    // Resident anonymous memory (heap, stacks): the closest to Windows' private bytes.
    std::ifstream status("/proc/self/status");
    std::string line;
    while (std::getline(status, line))
        if (line.rfind("RssAnon:", 0) == 0)
            return (int64_t) std::strtoll(line.c_str() + 8, nullptr, 10) * 1024;
    return 0;
#endif
}

// Closes (deletes) the editor when a parameter changes: a host reacting
// synchronously to an edit made from the editor.
struct CloseOnChange final : juce::AudioProcessorParameter::Listener
{
    explicit CloseOnChange(EditorPtr& e) : editor(e) {}
    void parameterValueChanged(int, float) override
    {
        if (editor != nullptr && juce::MessageManager::existsAndIsCurrentThread())
        {
            editor.reset();
            ++closed;
        }
    }
    void parameterGestureChanged(int, bool) override {}
    EditorPtr& editor;
    int closed = 0;
};
} // namespace

int main()
{
    juce::ScopedJuceInitialiser_GUI juceInit;
    {
        std::unique_ptr<juce::AudioProcessor> plugin(createPluginFilter());
        auto& p = *plugin;
        p.setPlayConfigDetails(0, 2, 48000.0, 512);
        p.prepareToPlay(48000.0, 512);
        auto* attack = find(p, "Attack");
        auto* gain = find(p, "Gain");
        auto* wave = find(p, "Waveform");
        auto* release = find(p, "Release");
        check(attack != nullptr && gain != nullptr && wave != nullptr && release != nullptr,
              "PascalSynth library loaded next to the executable");
        if (attack == nullptr || gain == nullptr || wave == nullptr || release == nullptr)
            return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Rendering\n");
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal editor created");
        if (editor == nullptr)
            return 1;
        check(editor->getWidth() == 480 && editor->getHeight() == 300, "size set by the Pascal editor: "
                                                                          + juce::String(editor->getWidth()) + " x "
                                                                          + juce::String(editor->getHeight()));
        pump();
        compareWithReference(*editor, "pascalsynth_default");

        std::printf("Host automation reaches the controls\n");
        std::thread host([&]
        {
            // as a VST3 host delivers automation: on its own thread
            for (auto [param, value] : { std::pair<juce::AudioProcessorParameter*, float> { attack, 0.5f }, { release, 0.25f },
                                         { gain, 1.0f }, { wave, 1.0f } })
            {
                param->setValue(value);
                param->sendValueChangedMessageToListeners(value);
            }
        });
        host.join();
        pump(150);
        compareWithReference(*editor, "pascalsynth_automated");
        resetToDefaults(p);
        compareWithReference(*editor, "pascalsynth_default"); // and back
        gestures.begins = gestures.ends = 0;

        std::printf("Mouse\n");
        const float attackDefault = attack->getDefaultValue();
        drag(*editor, attackKnob, attackKnob - juce::Point<float>(0.0f, 50.0f));
        pump();
        check(std::abs(attack->getValue() - (attackDefault + 0.25f)) < 0.01f,
              "50 px drag up moves the knob a quarter (" + juce::String(attack->getValue(), 3) + ")");
        check(gestures.begins == 1 && gestures.ends == 1, "one gesture for the drag (" + juce::String(gestures.begins)
                                                              + " begin, " + juce::String(gestures.ends) + " end)");
        const float afterDrag = attack->getValue();
        drag(*editor, attackKnob, attackKnob - juce::Point<float>(0.0f, 100.0f), leftShift);
        pump();
        check(std::abs(attack->getValue() - (afterDrag + 0.05f)) < 0.005f, "Shift drags ten times finer");
        doubleClick(*editor, attackKnob);
        pump();
        check(std::abs(attack->getValue() - attackDefault) < 1.0e-4f, "double-click restores the default");
        check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        {
            juce::MouseWheelDetails wheel {};
            wheel.deltaY = 0.25f;
            editor->mouseWheelMove(mouseEvent(*editor, gainKnob, juce::ModifierKeys(), 1, gainKnob), wheel);
            pump();
            check(std::abs(gain->getValue() - (gain->getDefaultValue() + 0.05f)) < 0.002f, "wheel turns the knob");
        }
        click(*editor, switchSquare);
        pump();
        check(wave->getCurrentValueAsText() == "Square", "switch click selects Square");
        click(*editor, switchSine);
        pump();
        check(wave->getCurrentValueAsText() == "Sine", "switch click selects Sine");
        check(gestures.begins == gestures.ends, "gestures balanced after all edits (" + juce::String(gestures.begins) + ")");

        std::printf("Right-click menu\n");
        pascaljuceTestBringToFront(*editor);
        drag(*editor, attackKnob, attackKnob - juce::Point<float>(0.0f, 40.0f));
        pump();
        click(*editor, attackKnob, right);
        pump();
        auto* menu = juce::ModalComponentManager::getInstance()->getModalComponent(0);
        check(menu != nullptr, "context menu opened by the Pascal control");
        if (menu != nullptr)
        {
            menu->keyPressed(juce::KeyPress(juce::KeyPress::downKey));
            menu->keyPressed(juce::KeyPress(juce::KeyPress::returnKey));
        }
        pump(200);
        check(std::abs(attack->getValue() - attackDefault) < 1.0e-4f, "\"Reset to default\" chosen through the menu");
        // A menu still open when the window closes: its answer must go nowhere.
        drag(*editor, attackKnob, attackKnob - juce::Point<float>(0.0f, 40.0f));
        click(*editor, attackKnob, right);
        pump();
        const float beforeClose = attack->getValue();
        editor.reset();
        pump(100);
        juce::PopupMenu::dismissAllActiveMenus();
        pump(100);
        check(std::abs(attack->getValue() - beforeClose) < 1.0e-6f && pascaljuce_live_editor_sessions() == 0,
              "menu answer after the window closed is dropped");

        std::printf("Meter\n");
        editor.reset(p.createEditorAndMakeActive());
        {
            juce::AudioBuffer<float> buffer(2, 512);
            juce::MidiBuffer midi;
            midi.addEvent(juce::MidiMessage::noteOn(1, 60, (juce::uint8) 127), 0);
            for (int i = 0; i < 20; ++i)
            {
                p.processBlock(buffer, midi);
                midi.clear();
                pump(5);
            }
            pump(150);
            const auto image = render(*editor);
            const auto lit = image.getPixelAt(449, 166);
            check(lit.getGreen() > 120 && lit.getGreen() > lit.getBlue(),
                  "output meter lit by the level Process published (" + lit.toDisplayString(true) + ")");
            midi.addEvent(juce::MidiMessage::allNotesOff(1), 0);
            p.processBlock(buffer, midi);
        }

        std::printf("Window closed by the host inside an edit\n");
        resetToDefaults(p);
        gestures.begins = gestures.ends = 0;
        {
            CloseOnChange closer(editor);
            attack->addListener(&closer);
            auto* raw = editor.get();
            raw->mouseDown(mouseEvent(*raw, attackKnob, left, 1, attackKnob));
            raw->mouseDrag(mouseEvent(*raw, attackKnob - juce::Point<float>(0, 30), left, 1, attackKnob));
            // (raw is gone now: the host deleted it while delivering the change)
            attack->removeListener(&closer);
            check(closer.closed == 1 && editor == nullptr, "host closed the window while delivering the edit");
        }
        pump(100);
        check(gestures.begins == gestures.ends && gestures.begins >= 1,
              "the drag's gesture was ended for the host (" + juce::String(gestures.begins) + " begin, "
                  + juce::String(gestures.ends) + " end)");
        check(pascaljuce_live_editor_sessions() == 0, "session freed");

        std::printf("1000 editors\n");
        resetToDefaults(p);
        for (int i = 0; i < 50; ++i) // warm up caches (fonts, glyphs)
        {
            editor.reset(p.createEditorAndMakeActive());
            render(*editor);
            editor.reset();
        }
        pump();
        const auto before = privateBytes();
        for (int i = 0; i < 1000; ++i)
        {
            editor.reset(p.createEditorAndMakeActive());
            if (i % 10 == 0)
                render(*editor);
            if (i % 100 == 0)
                drag(*editor, attackKnob, attackKnob - juce::Point<float>(0, 5));
            editor.reset();
        }
        pump();
        const auto grown = privateBytes() - before;
        check(pascaljuce_live_editor_sessions() == 0, "every editor session freed");
       #if defined(__has_feature)
        #if __has_feature(address_sanitizer)
         #define PASCALJUCE_ASAN 1
        #endif
       #endif
       #if defined(PASCALJUCE_ASAN) || defined(__SANITIZE_ADDRESS__)
        // ASan keeps freed memory in quarantine: process size says nothing here.
        std::printf("  skip  memory growth under AddressSanitizer (%d KB)\n", (int) (grown / 1024));
       #else
        check(grown < 8 * 1024 * 1024, "memory stable over 1000 editors (" + juce::String(grown / 1024) + " KB)");
       #endif
        check(gestures.begins == gestures.ends, "gestures balanced");

        for (auto* param : p.getParameters())
            param->removeListener(&gestures);
        p.releaseResources();
    }
    juce::PopupMenu::dismissAllActiveMenus();
    std::printf(failures == 0 ? "All checks passed\n" : "%d check(s) FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
