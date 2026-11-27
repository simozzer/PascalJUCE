// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// mz950_editor_test - the Mz950_Pascal panel (Mz950Editor.pas and its pages, built in code),
// driven offscreen through the real PascalJUCE wrapper, which loads Mz950_pascal_lib.dll from
// next to the executable (a ctest of the PascalJUCE build):
//
//   - the SYNTH tab: a preset chosen from its box renders (on the plug-in's own thread) and
//     becomes the disk, PWM STRGS as in the C++ screenshots; the three tabs are then compared
//     with verify/ui/mz950_program.png, mz950_perform.png and mz950_synth.png (small per-pixel
//     tolerance for font rasterisation);
//   - the PROGRAM tab: its six pages, a keygroup chosen from the strip and from the box, an edit
//     through a knob reaching the disk and the state, the cyan "sounding" readout following a
//     Perform offset, the strip lighting as a note plays;
//   - Load disk... and Save disk as... through the wrapper's file dialog hooks: a real disk from
//     VirtualS950\disks (%VS950_SRC%, default %USERPROFILE%\src\VirtualS950) opened, its
//     programmes reaching the host (getNumPrograms / getProgramName), a programme chosen by the
//     host and the panel following; the edited disk saved, reloaded and saved again, the same
//     bytes;
//   - the PERFORM tab: a knob drag in one gesture, double-click back to zero, the envelope's
//     corner dragged, MIDI learn end to end;
//   - the panel scales; many panels open and close without leaking a session.
//
// MZ950_SCREENSHOT_DIR set: renders of every tab and page go there. Set
// PASCALJUCE_UPDATE_UI_REFERENCES=1 to rewrite the references (after a deliberate change to the
// look; check the new PNGs first).
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>

#include <cstdio>
#include <string>

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter();
int pascaljuce_live_editor_sessions();
bool pascaljuce_test_file_request(int* mode, std::string* title, std::string* patterns, std::string* initial);
bool pascaljuce_test_answer_file_request(const char* path);

namespace
{
struct EditorCloser
{
    void operator()(juce::AudioProcessorEditor* editor) const
    {
        if (editor == nullptr) return;
        if (auto* processor = editor->getAudioProcessor()) processor->editorBeingDeleted(editor);
        delete editor;
    }
};
using EditorPtr = std::unique_ptr<juce::AudioProcessorEditor, EditorCloser>;

int failures = 0;

void check(bool condition, const juce::String& what)
{
    std::printf("  %s  %s\n", condition ? "ok  " : "FAIL", what.toRawUTF8());
    if (! condition) ++failures;
}

void pump(int ms = 60) { juce::MessageManager::getInstance()->runDispatchLoopUntil(ms); }

juce::Image render(juce::Component& c)
{
    juce::Image image(juce::Image::ARGB, c.getWidth(), c.getHeight(), true, juce::SoftwareImageType());
    juce::Graphics g(image);
    c.paintEntireComponent(g, true);
    return image;
}

juce::File referenceDir() { return juce::File(MZ950_VERIFY_DIR).getChildFile("ui"); }

// Same size, and at most 0.5% of pixels differ by more than 24 in any channel.
void compareWithReference(const juce::Image& actual, const juce::String& name)
{
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
    if (! expected.isValid() || expected.getWidth() != actual.getWidth() || expected.getHeight() != actual.getHeight())
    {
        check(false, name + ": reference size differs");
        return;
    }
    int bad = 0, worst = 0;
    juce::Image diff(juce::Image::ARGB, actual.getWidth(), actual.getHeight(), true, juce::SoftwareImageType());
    for (int y = 0; y < actual.getHeight(); ++y)
        for (int x = 0; x < actual.getWidth(); ++x)
        {
            const auto a = actual.getPixelAt(x, y), e = expected.getPixelAt(x, y);
            const int d = std::max({ std::abs(a.getRed() - e.getRed()), std::abs(a.getGreen() - e.getGreen()),
                                     std::abs(a.getBlue() - e.getBlue()), std::abs(a.getAlpha() - e.getAlpha()) });
            worst = std::max(worst, d);
            if (d > 24)
            {
                ++bad;
                diff.setPixelAt(x, y, juce::Colours::red);
            }
        }
    const int allowed = actual.getWidth() * actual.getHeight() / 200;
    if (bad > allowed)
        for (const auto& [img, suffix] : { std::pair<const juce::Image*, const char*> { &actual, ".actual.png" }, { &diff, ".diff.png" } })
        {
            const auto f = juce::File::getCurrentWorkingDirectory().getChildFile(name + suffix);
            f.deleteFile();
            juce::FileOutputStream out(f);
            juce::PNGImageFormat().writeImageToStream(*img, out);
        }
    check(bad <= allowed, name + " matches its reference (" + juce::String(bad) + " pixels off, worst channel difference "
                              + juce::String(worst) + ")");
}

// MZ950_SCREENSHOT_DIR set: renders of the panel go there.
void screenshot(const juce::Image& image, const juce::String& name)
{
    const auto dir = juce::SystemStats::getEnvironmentVariable("MZ950_SCREENSHOT_DIR", {});
    if (dir.isEmpty())
        return;
    juce::File(dir).createDirectory();
    const auto file = juce::File(dir).getChildFile(name + ".png");
    file.deleteFile();
    juce::FileOutputStream out(file);
    juce::PNGImageFormat().writeImageToStream(image, out);
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
const juce::ModifierKeys right { juce::ModifierKeys::rightButtonModifier };

void drag(juce::Component& c, juce::Point<float> from, juce::Point<float> to)
{
    c.mouseDown(mouseEvent(c, from, left, 1, from));
    c.mouseDrag(mouseEvent(c, (from + to) * 0.5f, left, 1, from));
    c.mouseDrag(mouseEvent(c, to, left, 1, from));
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

void hover(juce::Component& c, juce::Point<float> at)
{
    c.mouseMove(mouseEvent(c, at, juce::ModifierKeys(), 0, at));
}

juce::String tooltip(juce::Component& c)
{
    auto* client = dynamic_cast<juce::TooltipClient*>(&c);
    return client != nullptr ? client->getTooltip() : juce::String();
}

// The open popup menu: press Down n times (headers and disabled items are skipped) and
// Return. False if no menu is open.
bool chooseFromMenu(int downs)
{
    pump();
    auto* menu = juce::ModalComponentManager::getInstance()->getModalComponent(0);
    if (menu == nullptr) return false;
    for (int i = 0; i < downs; ++i)
        menu->keyPressed(juce::KeyPress(juce::KeyPress::downKey));
    menu->keyPressed(juce::KeyPress(juce::KeyPress::returnKey));
    pump(200);
    return true;
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
        if (param->getName(64) == name) return param;
    return nullptr;
}

void block(juce::AudioProcessor& p, juce::MidiBuffer& midi)
{
    juce::AudioBuffer<float> buffer(2, 512);
    buffer.clear();
    p.processBlock(buffer, midi);
    midi.clear();
}

// Blocks, and the message loop, for a while: the plug-in's housekeeping thread hands patches
// over, and the panel's timer follows.
void run(juce::AudioProcessor& p, int ms)
{
    juce::MidiBuffer none;
    const auto until = juce::Time::getMillisecondCounter() + (juce::uint32) ms;
    while (juce::Time::getMillisecondCounter() < until)
    {
        block(p, none);
        pump(10);
    }
}

void cc(juce::AudioProcessor& p, int number, int value)
{
    juce::MidiBuffer midi;
    midi.addEvent(juce::MidiMessage::controllerEvent(1, number, value), 10);
    block(p, midi);
    pump();
}

// Pixels that differ (by more than 24 in a channel) between two renders, inside an area.
int differingPixels(const juce::Image& a, const juce::Image& b, juce::Rectangle<int> area)
{
    int n = 0;
    area = area.getIntersection(a.getBounds()).getIntersection(b.getBounds());
    for (int y = area.getY(); y < area.getBottom(); ++y)
        for (int x = area.getX(); x < area.getRight(); ++x)
        {
            const auto p = a.getPixelAt(x, y), q = b.getPixelAt(x, y);
            if (std::abs(p.getRed() - q.getRed()) > 24 || std::abs(p.getGreen() - q.getGreen()) > 24
                || std::abs(p.getBlue() - q.getBlue()) > 24)
                ++n;
        }
    return n;
}

// How many pixels of an area are near a colour.
int pixelsNear(const juce::Image& img, juce::Rectangle<int> area, juce::Colour c, int tolerance = 40)
{
    int n = 0;
    area = area.getIntersection(img.getBounds());
    for (int y = area.getY(); y < area.getBottom(); ++y)
        for (int x = area.getX(); x < area.getRight(); ++x)
        {
            const auto p = img.getPixelAt(x, y);
            if (std::abs(p.getRed() - c.getRed()) <= tolerance && std::abs(p.getGreen() - c.getGreen()) <= tolerance
                && std::abs(p.getBlue() - c.getBlue()) <= tolerance)
                ++n;
        }
    return n;
}

// A trim's plain value: they all run -99..99.
float trimOf(juce::AudioProcessorParameter* p) { return p->getValue() * 198.0f - 99.0f; }

juce::File diskFolder()
{
    auto src = juce::SystemStats::getEnvironmentVariable("VS950_SRC", {});
    if (src.isEmpty())
        src = juce::File::getSpecialLocation(juce::File::userHomeDirectory).getChildFile("src/VirtualS950").getFullPathName();
    return juce::File(src).getChildFile("disks");
}

juce::String programNames(juce::AudioProcessor& p)
{
    juce::StringArray names;
    for (int i = 0; i < p.getNumPrograms(); ++i)
        if (p.getProgramName(i).trim().isNotEmpty() && p.getProgramName(i).trim() != "-") names.add(p.getProgramName(i).trim());
    return names.joinIntoString(", ");
}

int namedPrograms(juce::AudioProcessor& p)
{
    int n = 0;
    for (int i = 0; i < p.getNumPrograms(); ++i)
        if (p.getProgramName(i).trim().isNotEmpty() && p.getProgramName(i).trim() != "-") ++n;
    return n;
}

// The panel's layout (Mz950Editor.Arrange and the pages' Layout, the C++ resized), in editor
// coordinates at 100%.
const juce::Point<float> loadButton { 16 + 52, 60 + 13 };
const juce::Point<float> programBox { 128 + 206, 60 + 13 };
const juce::Rectangle<int> programBoxArea { 128, 60, 412, 26 };
const juce::Point<float> tabProgram { 16 + 40, 94 + 16 };
const juce::Point<float> tabPerform { 16 + 113, 94 + 16 };
const juce::Point<float> tabSynth { 16 + 180, 94 + 16 };
const juce::Rectangle<int> pageArea { 16, 132, 608, 476 };
const juce::Point<float> away { 5, 640 };
// PROGRAM: the keygroups panel at (16, 156), its content from (24, 184)
const juce::Point<float> keygroupBox { 16 + 38 + 115, 132 + 52 + 13 };
const juce::Point<float> nextButton { 16 + 272 + 13, 132 + 52 + 13 };
const juce::Point<float> saveButton { 16 + 488 + 56, 132 + 52 + 13 };
const juce::Rectangle<int> stripArea { 24, 216, 592, 112 };
// the six pages' tabs along the top of the settings panel, at (24, 348)
const juce::Point<float> pageEnvelopes { 24 + 40, 348 + 16 };
const juce::Point<float> pageFilter { 24 + 120, 348 + 16 };
const juce::Point<float> pageLfo { 24 + 166, 348 + 16 };
const juce::Point<float> pageVelocity { 24 + 222, 348 + 16 };
const juce::Point<float> pageTuning { 24 + 290, 348 + 16 };
const juce::Point<float> pageKeys { 24 + 380, 348 + 16 };
// Envelopes: VCA ATTACK, the first cell of the block (155, 388), its knob's middle
const juce::Point<float> vcaAttackKnob { 155 + 2 + 34, 388 + 2 + 23 };
const juce::Rectangle<int> vcaAttackSounding { 155, 388 + 92 - 14, 72, 14 };
// PERFORM: FILTER's first knob, and the VCA envelope's area
const juce::Point<float> performFilterKnob { 16 + 40, 132 + 78 };
const juce::Rectangle<int> vcaEnvelopeArea { 24, 428, 283, 200 };
// SYNTH: the preset box, OSC 1's LEVEL
const juce::Point<float> presetBox { 16 + 110, 132 + 13 };
const juce::Point<float> osc1Level { 16 + 38, 132 + 148 };
} // namespace

int main()
{
    juce::ScopedJuceInitialiser_GUI juceInit;
    const auto temp = juce::File::getSpecialLocation(juce::File::tempDirectory).getChildFile("mz950_editor_test");
    temp.deleteRecursively();
    temp.createDirectory();
    {
        std::unique_ptr<juce::AudioProcessor> plugin(createPluginFilter());
        auto& p = *plugin;
        p.setPlayConfigDetails(0, 2, 48000.0, 512);
        p.prepareToPlay(48000.0, 512);
        auto* cutoff = find(p, "VCF Filter");
        auto* vcaAttack = find(p, "VCA Attack");
        auto* gain = find(p, "Gain");
        check(cutoff && vcaAttack && gain && p.getParameters().size() == 29, "Mz950 library loaded next to the executable");
        if (! (cutoff && vcaAttack && gain)) return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Opening\n");
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal panel created");
        if (editor == nullptr) return 1;
        check(editor->getWidth() == 640 && editor->getHeight() == 672,
              "the C++ window's size: " + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
        pump(150);
        screenshot(render(*editor), "mz950_empty");
        check(! pascaljuce_test_file_request(nullptr, nullptr, nullptr, nullptr), "no file dialog yet");
        {
            auto& look = editor->getLookAndFeel();
            check(look.findColour(juce::TooltipWindow::backgroundColourId) == juce::Colour(0xff2b3038)
                      && look.findColour(juce::PopupMenu::backgroundColourId) == juce::Colour(0xff2b3038),
                  "tooltips and menus in the C++ look's colours");
        }

        std::printf("SYNTH: a preset renders, and becomes the disk\n");
        {
            click(*editor, tabSynth);
            hover(*editor, away);
            pump(150);
            screenshot(render(*editor), "mz950_synth_before");
            click(*editor, presetBox);
            check(chooseFromMenu(4), "the preset box opens its list");
            bool rendered = false;
            for (int i = 0; i < 300 && ! rendered; ++i)
            {
                run(p, 50);
                rendered = p.getProgramName(p.getCurrentProgram()).contains("PWM STRGS");
            }
            check(rendered, "\"PWM strings\" rendered and adopted: the host's programme is "
                                + p.getProgramName(p.getCurrentProgram()));
            check(p.getNumPrograms() == 64 && namedPrograms(p) == 1, "the host sees 64 slots, one named: " + programNames(p));
            run(p, 300);
            hover(*editor, away);
            pump(100);
            const auto synth = render(*editor);
            screenshot(synth, "mz950_synth");
            compareWithReference(synth, "mz950_synth");

            // a knob turned renders again
            const auto before = p.getProgramName(0);
            juce::MemoryBlock stateBefore;
            p.getStateInformation(stateBefore);
            drag(*editor, osc1Level, osc1Level + juce::Point<float>(0, 40));
            run(p, 1500);
            for (int i = 0; i < 100; ++i) run(p, 50);
            juce::MemoryBlock stateAfter;
            p.getStateInformation(stateAfter);
            check(stateAfter != stateBefore && p.getProgramName(0) == before,
                  "OSC 1 LEVEL turned: rendered again, the same programme (" + p.getProgramName(0) + ")");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
            // and back to the preset as it was, for the references
            click(*editor, presetBox);
            chooseFromMenu(4);
            for (int i = 0; i < 100; ++i) run(p, 50);
        }

        std::printf("PROGRAM: what is on the disk\n");
        {
            click(*editor, tabProgram);
            hover(*editor, away);
            run(p, 300);
            const auto program = render(*editor);
            screenshot(program, "mz950_program_envelopes");
            compareWithReference(program, "mz950_program");
            check(pixelsNear(program, stripArea, juce::Colour(0xffe9a33a), 60) > 400, "the keygroup strip, in amber");

            const juce::Point<float> pages[] = { pageFilter, pageLfo, pageVelocity, pageTuning, pageKeys };
            const char* names[] = { "filter", "lfo", "velocity", "tuning", "keys" };
            auto previous = program;
            for (int i = 0; i < 5; ++i)
            {
                click(*editor, pages[i]);
                hover(*editor, away);
                pump(100);
                const auto shot = render(*editor);
                screenshot(shot, juce::String("mz950_program_") + names[i]);
                check(differingPixels(previous, shot, pageArea.withTrimmedTop(250)) > 300,
                      juce::String("the ") + names[i] + " page shows its own controls");
                previous = shot;
            }
            click(*editor, pageEnvelopes);
            hover(*editor, away);
            pump(100);
            check(differingPixels(program, render(*editor), editor->getLocalBounds()) < 50, "and back to the envelopes");

            // a note lights its keygroup in the strip
            const auto dark = render(*editor);
            juce::MidiBuffer midi;
            midi.addEvent(juce::MidiMessage::noteOn(1, 60, (juce::uint8) 100), 0);
            block(p, midi);
            pump(80);
            const auto lit = render(*editor);
            screenshot(lit, "mz950_program_lit");
            check(differingPixels(dark, lit, stripArea) > 40, "a note lights its keygroup in the strip");
            midi.addEvent(juce::MidiMessage::noteOff(1, 60), 0);
            block(p, midi);
            run(p, 1500);
        }

        std::printf("PERFORM: the offsets and extras\n");
        {
            click(*editor, tabPerform);
            hover(*editor, away);
            pump(150);
            const auto perform = render(*editor);
            screenshot(perform, "mz950_perform");
            compareWithReference(perform, "mz950_perform");

            const int begins = gestures.begins;
            drag(*editor, performFilterKnob, performFilterKnob - juce::Point<float>(0, 50));
            pump();
            const float plain = trimOf(cutoff);
            check(std::abs(plain - 39.6f) < 1.0f && gestures.begins == begins + 1 && gestures.ends == gestures.begins,
                  "50 px up FILTER (250 px for the whole range, as a JUCE slider) moves it +39.6 in one gesture ("
                      + juce::String(plain, 1) + ")");
            doubleClick(*editor, performFilterKnob);
            pump();
            check(std::abs(cutoff->getValue() - 0.5f) < 1.0e-4f, "double-click puts it back to zero");

            // the envelope's attack corner, dragged right: the attack trim follows
            const auto before = render(*editor);
            const juce::Point<float> corner { 24 + 9 + 265 * 0.26f * 30.0f / 99.0f, 428 + 9 };
            drag(*editor, corner, corner + juce::Point<float>(30, 0));
            pump(100);
            const float trim = trimOf(vcaAttack);
            check(trim > 30 && trim < 55, "the VCA envelope's attack corner dragged 30 px: attack +" + juce::String(trim, 1));
            screenshot(render(*editor), "mz950_perform_dragged");
            check(differingPixels(before, render(*editor), vcaEnvelopeArea) > 200, "and the shape follows");
            doubleClick(*editor, corner + juce::Point<float>(30, 0));
            pump(100);
            check(std::abs(vcaAttack->getValue() - 0.5f) < 1.0e-4f, "double-click on the corner: back to the disk's");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");

            // MIDI learn
            hover(*editor, performFilterKnob);
            check(tooltip(*editor).contains("MIDI CC 74"), "the hint names the CC: " + tooltip(*editor).replace("\n", " | "));
            click(*editor, performFilterKnob, right);
            check(chooseFromMenu(1), "right-click opens the MIDI learn menu");
            pump(100);
            hover(*editor, performFilterKnob + juce::Point<float>(0, 1));
            check(tooltip(*editor).contains("MIDI LEARN"), "\"MIDI Learn\": the hint says it waits");
            screenshot(render(*editor), "mz950_perform_learning");
            check(differingPixels(perform, render(*editor), { 16, 156, 144, 112 }) > 100, "and the control is outlined");
            cc(p, 20, 100);
            pump(100);
            check(std::abs(cutoff->getValue() - 0.5f) < 1.0e-4f, "CC 20 is learned, and moves nothing");
            cc(p, 20, 127);
            pump(100);
            check(std::abs(cutoff->getValue() - 1.0f) < 1.0e-3f, "now CC 20 moves FILTER");
            hover(*editor, performFilterKnob);
            check(tooltip(*editor).contains("MIDI CC 20, learned (default 74)"), "the hint: " + tooltip(*editor).replace("\n", " | "));
            click(*editor, performFilterKnob, right);
            check(chooseFromMenu(4), "\"Reset all CCs to defaults\"");
            cc(p, 74, 64);
            check(std::abs(cutoff->getValue() - 64.0f / 127.0f) < 1.0e-3f, "and CC 74 is FILTER's again");
            cutoff->setValueNotifyingHost(0.5f);
            hover(*editor, away);
            pump(100);
        }

        std::printf("Load disk...\n");
        const auto strings = diskFolder().getChildFile("STRINGS.hfe");
        if (! strings.existsAsFile())
            std::printf("  (no %s: the disk checks are skipped)\n", strings.getFullPathName().toRawUTF8());
        else
        {
            click(*editor, tabProgram);
            hover(*editor, away);
            pump(100);
            click(*editor, loadButton);
            int mode = -1;
            std::string title, patterns, initial;
            const bool asked = pascaljuce_test_file_request(&mode, &title, &patterns, &initial);
            check(asked && mode == 0 && patterns == "*.hfe;*.img"
                      && juce::String(title).contains("S900/S950"),
                  "Load disk... asks for a disk image: " + juce::String(title) + ", " + juce::String(patterns));
            check(pascaljuce_test_answer_file_request(strings.getFullPathName().toRawUTF8()), "answered with STRINGS.hfe");
            run(p, 400);
            const int named = namedPrograms(p);
            check(named >= 2 && p.getNumPrograms() == 64, "its programmes reach the host: " + programNames(p));
            hover(*editor, away);
            pump(100);
            const auto loaded = render(*editor);
            screenshot(loaded, "mz950_strings");

            // the host chooses a programme, and the panel follows
            int other = -1;
            for (int i = 1; i < 64 && other < 0; ++i)
                if (p.getProgramName(i).trim().isNotEmpty() && p.getProgramName(i).trim() != "-") other = i;
            p.setCurrentProgram(other);
            run(p, 400);
            const auto hostChose = render(*editor);
            screenshot(hostChose, "mz950_strings_host_program");
            check(p.getCurrentProgram() == other && differingPixels(loaded, hostChose, programBoxArea) > 20,
                  "the host chose programme " + juce::String(other) + " (" + p.getProgramName(other).trim() + "): the box follows");
            click(*editor, programBox);
            check(chooseFromMenu(1), "the programme box opens its list");
            run(p, 300);
            check(p.getCurrentProgram() == 0, "programme 0 chosen in the panel: the host's is " + juce::String(p.getCurrentProgram()));
            click(*editor, programBox);
            chooseFromMenu(other + 1);
            run(p, 300);
            check(p.getCurrentProgram() == other && differingPixels(hostChose, render(*editor), programBoxArea) == 0,
                  "and programme " + juce::String(other) + " from the panel reads as the host's choice did");

            // Save disk as..., then an edit, then again
            auto saveTo = [&] (const juce::File& f)
            {
                hover(*editor, away);
                click(*editor, saveButton);
                int m = -1;
                std::string t, pat, ini;
                const bool asked = pascaljuce_test_file_request(&m, &t, &pat, &ini);
                const bool ok = asked && m == 1 && pat == "*.img" && juce::String(ini).endsWith("STRINGS-edited.img");
                pascaljuce_test_answer_file_request(f.getFullPathName().toRawUTF8());
                pump(100);
                return ok && f.existsAsFile();
            };
            const auto a = temp.getChildFile("a.img"), b = temp.getChildFile("b.img"), c = temp.getChildFile("c.img");
            check(saveTo(a), "Save disk as... names STRINGS-edited.img beside the disk, and writes it");
            juce::MemoryBlock stateBefore;
            p.getStateInformation(stateBefore);

            click(*editor, pageEnvelopes);
            hover(*editor, away);
            pump(100);
            const auto beforeEdit = render(*editor);
            drag(*editor, vcaAttackKnob, vcaAttackKnob - juce::Point<float>(0, 40));
            run(p, 300);
            hover(*editor, away);
            pump(100);
            const auto edited = render(*editor);
            screenshot(edited, "mz950_strings_edited");
            check(differingPixels(beforeEdit, edited, { 155, 388, 72, 92 }) > 50, "VCA ATTACK turned on the PROGRAM tab");
            juce::MemoryBlock stateAfter;
            p.getStateInformation(stateAfter);
            check(stateAfter != stateBefore, "the edit is in the plug-in's state");
            check(saveTo(b), "saved again");
            juce::MemoryBlock ba, bb;
            a.loadFileAsData(ba);
            b.loadFileAsData(bb);
            int differ = 0;
            for (size_t i = 0; i < std::min(ba.getSize(), bb.getSize()); ++i)
                if (ba[i] != bb[i]) ++differ;
            check(ba.getSize() == bb.getSize() && ba.getSize() > 0 && differ >= 1 && differ <= 2,
                  "the edit is in the disk: " + juce::String(differ) + " byte(s) of " + juce::String((int) bb.getSize()) + " moved");

            // the cyan readout: what sounds, with a Perform offset on it
            const auto plainReadout = render(*editor);
            vcaAttack->setValueNotifyingHost((10.0f + 99.0f) / 198.0f);
            run(p, 300);
            const auto withOffset = render(*editor);
            screenshot(withOffset, "mz950_strings_sounding");
            check(differingPixels(plainReadout, withOffset, vcaAttackSounding) > 10
                      && pixelsNear(withOffset, vcaAttackSounding, juce::Colour(0xff45c8dc), 50) > 10,
                  "VCA Attack +10 on the Perform tab: the cyan \"-> sounding\" readout under VCA ATTACK");
            vcaAttack->setValueNotifyingHost(0.5f);
            run(p, 200);

            // "All keygroups" from the box, and the next one with the arrow
            click(*editor, keygroupBox);
            check(chooseFromMenu(1), "the keygroup box opens its list");
            pump(100);
            screenshot(render(*editor), "mz950_strings_all");
            click(*editor, nextButton);
            pump(100);

            // the saved disk opened again, and saved again: the same bytes
            click(*editor, loadButton);
            const bool askedAgain = pascaljuce_test_file_request(&mode, nullptr, nullptr, &initial);
            check(askedAgain
                      && juce::File(initial) == strings.getParentDirectory(),
                  "the dialog starts beside the disk already open (" + juce::String(initial) + ")");
            pascaljuce_test_answer_file_request(b.getFullPathName().toRawUTF8());
            run(p, 400);
            check(saveTo(c) || c.existsAsFile(), "b.img loaded and saved as c.img");
            juce::MemoryBlock bc;
            c.loadFileAsData(bc);
            check(bc == bb, "the same bytes (" + juce::String((int) bc.getSize()) + ")");

            // a file that is not a disk: refused, said in the window, the disk kept
            const auto junk = temp.getChildFile("junk.img");
            junk.replaceWithText("not a disk");
            click(*editor, loadButton);
            pascaljuce_test_answer_file_request(junk.getFullPathName().toRawUTF8());
            run(p, 300);
            const auto refused = render(*editor);
            screenshot(refused, "mz950_refused");
            check(pixelsNear(refused, { 16, 40, 400, 20 }, juce::Colour(0xffe9a33a), 50) > 30
                      && namedPrograms(p) == named,
                  "a file that is not a disk: said in amber, the disk kept");
            // Cancel changes nothing
            click(*editor, loadButton);
            pascaljuce_test_answer_file_request(nullptr);
            run(p, 100);
            check(namedPrograms(p) == named, "Cancel changes nothing");
        }

        std::printf("Scaling\n");
        {
            auto* constrainer = editor->getConstrainer();
            check(editor->isResizable() && constrainer != nullptr && constrainer->getMinimumWidth() == 320
                      && constrainer->getMinimumHeight() == 336 && constrainer->getMaximumWidth() == 1280
                      && constrainer->getMaximumHeight() == 1344
                      && std::abs(constrainer->getFixedAspectRatio() - 640.0 / 672.0) < 1.0e-9,
                  "resizable from half to twice its size, the aspect ratio kept");
            editor->setSize(960, 1008);
            pump(100);
            click(*editor, tabPerform * 1.5f);
            hover(*editor, away * 1.5f);
            pump(100);
            screenshot(render(*editor), "mz950_150");
            const int begins = gestures.begins;
            drag(*editor, performFilterKnob * 1.5f, performFilterKnob * 1.5f - juce::Point<float>(0, 50 * 1.5f));
            pump();
            const float plain = trimOf(cutoff);
            check(std::abs(plain - 39.6f) < 1.0f && gestures.begins == begins + 1,
                  "at 150% a drag works in panel units (" + juce::String(plain, 1) + ")");
            doubleClick(*editor, performFilterKnob * 1.5f);
            pump();
            hover(*editor, away);
            editor->mouseExit(mouseEvent(*editor, away, juce::ModifierKeys(), 0, away));
            editor->setSize(640, 672);
            pump(200);
            check(std::abs(cutoff->getValue() - 0.5f) < 1.0e-4f, "and back at 100%");
        }

        std::printf("Lifetime\n");
        {
            // a file dialog still open when the window closes: its answer must go nowhere
            click(*editor, loadButton);
            editor.reset();
            pump(100);
            check(pascaljuce_test_answer_file_request(diskFolder().getChildFile("BASS.hfe").getFullPathName().toRawUTF8())
                      || ! diskFolder().exists(),
                  "a dialog answered after the window closed");
            pump(100);
            check(pascaljuce_live_editor_sessions() == 0, "the answer is dropped, the session freed");
            for (int i = 0; i < 60; ++i)
            {
                editor.reset(p.createEditorAndMakeActive());
                if (i % 20 == 0) render(*editor);
                editor.reset();
            }
            pump();
            check(pascaljuce_live_editor_sessions() == 0, "60 panels opened and closed, every session freed");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        for (auto* param : p.getParameters())
            param->removeListener(&gestures);
        p.releaseResources();
    }
    juce::PopupMenu::dismissAllActiveMenus();
    temp.deleteRecursively();
    std::printf(failures == 0 ? "All checks passed\n" : "%d check(s) FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
