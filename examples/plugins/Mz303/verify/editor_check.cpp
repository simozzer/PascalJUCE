// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// mz303_editor_test - the Mz303_Pascal panel (Mz303Editor.pas, built from
// Mz303EditorForm.lfm), driven offscreen through the real PascalJUCE wrapper, which loads
// Mz303_pascal.dll from next to the executable (a ctest of the PascalJUCE build):
//
//   - renders the panel and compares it with verify/ui/mz303_default.png (small per-pixel
//     tolerance for font rasterisation);
//   - mouse: a knob drag moves the right parameter by the right amount in one gesture,
//     double-click restores the default, WAVEFORM switches by click, the patch menu
//     chooses a patch;
//   - MIDI learn end to end: right-click a knob, choose MIDI Learn from the menu, the red
//     outline and the hint show it, a CC through processBlock is learned (and does nothing
//     else), then moves the knob; Restore default from the menu; the map survives the
//     plug-in state;
//   - the ACCENT and SLIDE lights follow the notes; the keyboard plays, plainly or with
//     ACCENT latched, accented;
//   - the panel scales; a menu answer after the window closed goes nowhere; many editors
//     open and close without leaking a session.
//
// Set PASCALJUCE_UPDATE_UI_REFERENCES=1 to rewrite the reference (after a deliberate change
// to the look; check the new PNG first).
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>

#include <cstdio>
#include <string>

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter();
int pascaljuce_live_editor_sessions();
int pascaljuce_test_opened_url_count();
std::string pascaljuce_test_opened_url(int index);

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

juce::File referenceDir() { return juce::File(MZ303_VERIFY_DIR).getChildFile("ui"); }

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

void block(juce::AudioProcessor& p, juce::MidiBuffer& midi, float* rms = nullptr)
{
    juce::AudioBuffer<float> buffer(2, 512);
    buffer.clear();
    p.processBlock(buffer, midi);
    midi.clear();
    if (rms != nullptr) *rms = buffer.getRMSLevel(0, 0, 512);
}

void cc(juce::AudioProcessor& p, int number, int value)
{
    juce::MidiBuffer midi;
    midi.addEvent(juce::MidiMessage::controllerEvent(1, number, value), 10);
    block(p, midi);
    pump();
}

bool isAccentRed(juce::Colour c) { return c.getRed() > 170 && c.getGreen() < 90 && c.getBlue() < 90; }

// The panel's layout (Mz303EditorForm.lfm, the C++ Panel's), in editor coordinates.
constexpr float knobTop = 56 + 8, knobH = 134;
const juce::Rectangle<int> cutoffBounds { 14 + 124, 56 + 8, 96, 134 };
const juce::Point<float> cutoffKnob { 14 + 124 + 48, knobTop + knobH / 2 };
const juce::Point<float> waveTop { 14 + 684 + 20, knobTop + 40 };
const juce::Point<float> waveBottom { 14 + 684 + 20, knobTop + knobH - 12 };
const juce::Point<int> accentLed { 14 + 899 + 7, 56 + 56 + 7 };
const juce::Point<int> slideLed { 14 + 899 + 7, 56 + 96 + 7 };
const juce::Point<float> patchBox { 806 + 110, 14 + 13 };
const juce::Point<float> projectLink { 700, 14 + 13 };
const juce::Point<float> accentKeys { 14 + 16 + 32, 218 + 77 + 30 };
const juce::Point<int> accentKeysLed { 14 + 16 + 32, 218 + 77 + 9 };
// the keys: 22 white ones (C1 to C4) across 908 px from x = 106
constexpr float keyW = 908.0f / 22.0f;
juce::Point<float> whiteKey(int index) { return { 106 + (index + 0.5f) * keyW, 230 + 150 }; }
const juce::Point<float> keyC2 = whiteKey(7), keyG2 = whiteKey(11);
const juce::Point<float> away { 5, 425 };

bool isLit(juce::Colour c) { return c.getRed() > 200 && c.getGreen() < 140 && c.getBlue() < 120; }

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

// MZ303_SCREENSHOT_DIR set: renders of the panel go there.
void screenshot(const juce::Image& image, const juce::String& name)
{
    const auto dir = juce::SystemStats::getEnvironmentVariable("MZ303_SCREENSHOT_DIR", {});
    if (dir.isEmpty())
        return;
    const auto file = juce::File(dir).getChildFile(name + ".png");
    file.deleteFile();
    juce::FileOutputStream out(file);
    juce::PNGImageFormat().writeImageToStream(image, out);
}

void note(juce::AudioProcessor& p, int number, int velocity)
{
    juce::MidiBuffer midi;
    midi.addEvent(velocity > 0 ? juce::MidiMessage::noteOn(1, number, (juce::uint8) velocity)
                               : juce::MidiMessage::noteOff(1, number), 10);
    block(p, midi);
    pump(120);
}
} // namespace

int main()
{
    juce::ScopedJuceInitialiser_GUI juceInit;
    {
        std::unique_ptr<juce::AudioProcessor> plugin(createPluginFilter());
        auto& p = *plugin;
        p.setPlayConfigDetails(0, 2, 48000.0, 512);
        p.prepareToPlay(48000.0, 512);
        auto* cutoff = find(p, "Cut Off Freq");
        auto* accent = find(p, "Accent");
        auto* wave = find(p, "Waveform");
        auto* patch = find(p, "Patch");
        check(cutoff && accent && wave && patch && p.getParameters().size() == 9, "Mz303 library loaded next to the executable");
        if (! (cutoff && accent && wave && patch)) return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Rendering\n");
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal panel created");
        if (editor == nullptr) return 1;
        check(editor->getWidth() == 1040 && editor->getHeight() == 430,
              "the C++ panel's size: " + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
        pump(150);
        compareWithReference(render(*editor), "mz303_default");
        screenshot(render(*editor), "mz303_100");

        std::printf("Tooltips, menus, the project link\n");
        {
            auto& look = editor->getLookAndFeel();
            check(look.findColour(juce::TooltipWindow::backgroundColourId) == juce::Colour(0xff111214)
                      && look.findColour(juce::TooltipWindow::textColourId) == juce::Colour(0xffe9e9e6)
                      && look.findColour(juce::TooltipWindow::outlineColourId) == juce::Colour(0xffd8321f),
                  "tooltips in the C++ panel's colours (dark, red outline)");
            check(look.findColour(juce::PopupMenu::backgroundColourId) == juce::Colour(0xff2a2b2d)
                      && look.findColour(juce::PopupMenu::textColourId) == juce::Colour(0xffe9e9e6)
                      && look.findColour(juce::PopupMenu::highlightedBackgroundColourId) == juce::Colour(0xffd8321f),
                  "menus too (the lower panel's dark, red highlight)");
            hover(*editor, projectLink);
            check(tooltip(*editor).contains("project's page"), "the project line has the C++ hint");
            const int opened = pascaljuce_test_opened_url_count();
            editor->mouseDown(mouseEvent(*editor, projectLink, left, 1, projectLink));
            editor->mouseUp(mouseEvent(*editor, projectLink, juce::ModifierKeys(), 1, projectLink));
            pump(50);
            check(pascaljuce_test_opened_url_count() == opened + 1
                      && pascaljuce_test_opened_url(opened) == "https://github.com/simozzer/Mz303",
                  "a click on it opens the project's page (in tests: recorded, no browser)");
            hover(*editor, away);
            pump(50);
        }

        std::printf("Mouse\n");
        {
            const float before = cutoff->getValue();
            drag(*editor, cutoffKnob, cutoffKnob - juce::Point<float>(0, 55));
            pump();
            check(std::abs(cutoff->getValue() - (before + 0.25f)) < 0.01f,
                  "55 px up CUT OFF FREQ (220 px for the whole turn, as the C++) moves it a quarter ("
                      + juce::String(before, 3) + " -> " + juce::String(cutoff->getValue(), 3) + ")");
            check(accent->getValue() == accent->getDefaultValue() && gestures.begins == 1 && gestures.ends == 1,
                  "one gesture, nothing else moved");
            doubleClick(*editor, cutoffKnob);
            pump();
            check(std::abs(cutoff->getValue() - cutoff->getDefaultValue()) < 1.0e-4f, "double-click restores the default");

            // the value bubble while dragging, as the C++ popup display
            const auto bubbleArea = cutoffBounds.expanded(40, 20);
            hover(*editor, away);
            pump(80);
            const auto plain = render(*editor);
            editor->mouseDown(mouseEvent(*editor, cutoffKnob, left, 1, cutoffKnob));
            pump(80);
            const auto bubbled = render(*editor);
            check(differingPixels(plain, bubbled, bubbleArea) > 100,
                  "dragging shows the value in a bubble (" + juce::String(differingPixels(plain, bubbled, bubbleArea))
                      + " pixels)");
            screenshot(bubbled.getClippedImage(bubbleArea), "mz303_bubble");
            editor->mouseUp(mouseEvent(*editor, cutoffKnob, juce::ModifierKeys(), 1, cutoffKnob));
            hover(*editor, away);
            pump(80);

            click(*editor, waveTop);
            pump();
            check(wave->getCurrentValueAsText() == "Square", "a click at the top of WAVEFORM: " + wave->getCurrentValueAsText());
            click(*editor, waveBottom);
            pump();
            check(wave->getCurrentValueAsText() == "Saw", "and at the bottom: " + wave->getCurrentValueAsText());

            click(*editor, patchBox);
            check(chooseFromMenu(5), "the patch box opens the patch menu");
            check(patch->getCurrentValueAsText() == "Accent Wow", "Accent Wow chosen from it: " + patch->getCurrentValueAsText());
            juce::MidiBuffer none;
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            pump();
            check(std::abs(find(p, "Resonance")->getValue() - 1.0f) < 1.0e-4f
                      && std::abs(cutoff->getValue() - 0.15f) < 1.0e-4f,
                  "and applied: RESONANCE 10, CUT OFF FREQ 1.5");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
            // back to the defaults
            for (auto* param : p.getParameters())
                param->setValueNotifyingHost(param->getDefaultValue());
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            pump();
        }

        std::printf("MIDI learn\n");
        {
            const auto edge = juce::Point<int>(cutoffBounds.getX() + 1, cutoffBounds.getCentreY());
            hover(*editor, cutoffKnob);
            check(tooltip(*editor).contains("CUT OFF FREQ") && tooltip(*editor).contains("MIDI CC 74."),
                  "the hint names the CC: " + tooltip(*editor).replace("\n", " | "));
            check(! isAccentRed(render(*editor).getPixelAt(edge.x, edge.y)), "no outline yet");
            click(*editor, cutoffKnob, right);
            check(chooseFromMenu(1), "right-click opens the MIDI learn menu");
            pump(100);
            hover(*editor, cutoffKnob + juce::Point<float>(0, 1));
            check(tooltip(*editor).contains("MIDI LEARN"), "\"MIDI Learn\": the hint says it waits");
            const auto learning = render(*editor);
            screenshot(learning, "mz303_learning");
            check(isAccentRed(learning.getPixelAt(edge.x, edge.y)),
                  "and the red outline is round the knob (" + learning.getPixelAt(edge.x, edge.y).toDisplayString(false) + ")");

            const float cutoffBefore = cutoff->getValue(), accentBefore = accent->getValue();
            cc(p, 16, 100);                                    // ACCENT's CC
            pump(100);
            check(cutoff->getValue() == cutoffBefore && accent->getValue() == accentBefore,
                  "CC 16 through processBlock is learned, and moves nothing");
            check(! isAccentRed(render(*editor).getPixelAt(edge.x, edge.y)), "the outline goes");
            cc(p, 16, 30);
            pump(100);
            check(std::abs(cutoff->getValue() - 30.0f / 127.0f) < 1.0e-3f && accent->getValue() == accentBefore,
                  "now CC 16 moves CUT OFF FREQ (" + juce::String(cutoff->getValue(), 3) + "), not ACCENT");
            cc(p, 74, 127);
            check(std::abs(cutoff->getValue() - 30.0f / 127.0f) < 1.0e-3f, "and CC 74 no longer does");
            hover(*editor, cutoffKnob);
            check(tooltip(*editor).contains("MIDI CC 16, learned (default 74)"),
                  "the hint: " + tooltip(*editor).replace("\n", " | "));

            // the map is part of the plug-in's state
            juce::MemoryBlock state;
            p.getStateInformation(state);
            click(*editor, cutoffKnob, right);
            check(chooseFromMenu(3), "\"Restore default (CC 74)\" from the menu");
            cc(p, 74, 0);
            check(cutoff->getValue() < 1.0e-4f, "CC 74 moves CUT OFF FREQ again");
            p.setStateInformation(state.getData(), (int) state.getSize());
            pump();
            cc(p, 16, 127);
            check(std::abs(cutoff->getValue() - 1.0f) < 1.0e-4f, "the saved state brings CC 16 back");
            click(*editor, cutoffKnob, right);
            check(chooseFromMenu(4), "\"Reset all CCs to defaults\"");
            cc(p, 74, 64);
            check(std::abs(cutoff->getValue() - 64.0f / 127.0f) < 1.0e-3f, "and CC 74 is CUT OFF FREQ's again");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
            cutoff->setValueNotifyingHost(cutoff->getDefaultValue());
            pump();
        }

        std::printf("Lights and keyboard\n");
        {
            juce::MidiBuffer none;
            auto lights = [&] { const auto img = render(*editor);
                                return juce::String(isLit(img.getPixelAt(accentLed.x, accentLed.y)) ? "A" : "-")
                                     + (isLit(img.getPixelAt(slideLed.x, slideLed.y)) ? "S" : "-"); };
            check(lights() == "--", "ACCENT and SLIDE dark");
            note(p, 36, 120);
            check(lights() == "A-", "an accented note lights ACCENT: " + lights());
            screenshot(render(*editor), "mz303_accent");
            note(p, 43, 80);
            check(lights() == "-S", "a plain note over it: SLIDE: " + lights());
            note(p, 43, 0);
            note(p, 36, 0);
            check(lights() == "--", "and both off when the keys are let go: " + lights());

            float rms = 0, plainRms = 0;
            editor->mouseDown(mouseEvent(*editor, keyC2, left, 1, keyC2));
            for (int i = 0; i < 8; ++i) block(p, none, &plainRms);
            pump(150);
            const auto key = render(*editor).getPixelAt((int) keyC2.x, (int) keyC2.y);
            check(plainRms > 0.01f, "a key of the panel's keyboard plays (rms " + juce::String(plainRms, 3) + ")");
            check(key.getRed() > key.getBlue() + 40, "and is lit while held (" + key.toDisplayString(false) + ")");
            check(lights() == "--", "at a plain velocity: no accent");
            editor->mouseUp(mouseEvent(*editor, keyC2, juce::ModifierKeys(), 1, keyC2));
            for (int i = 0; i < 100; ++i) block(p, none, &rms);
            check(rms < 1.0e-4f, "and lets go (rms " + juce::String(rms, 6) + ")");

            check(! isLit(render(*editor).getPixelAt(accentKeysLed.x, accentKeysLed.y)), "ACCENT beside the keys: off");
            click(*editor, accentKeys);
            pump(100);
            check(isLit(render(*editor).getPixelAt(accentKeysLed.x, accentKeysLed.y)), "a click latches it, and its LED shows it");
            editor->mouseDown(mouseEvent(*editor, keyG2, left, 1, keyG2));
            for (int i = 0; i < 8; ++i) block(p, none, &rms);
            pump(150);
            check(lights() == "A-", "now the keys play accented: " + lights());
            editor->mouseUp(mouseEvent(*editor, keyG2, juce::ModifierKeys(), 1, keyG2));
            for (int i = 0; i < 100; ++i) block(p, none);
            click(*editor, accentKeys);
            pump(100);
            check(! isLit(render(*editor).getPixelAt(accentKeysLed.x, accentKeysLed.y)), "and another click lets it go");
            hover(*editor, away);
            pump(80);
        }

        std::printf("Scaling\n");
        {
            auto* constrainer = editor->getConstrainer();
            check(editor->isResizable() && constrainer != nullptr && constrainer->getMinimumWidth() == 520
                      && constrainer->getMinimumHeight() == 215 && constrainer->getMaximumWidth() == 2080
                      && constrainer->getMaximumHeight() == 860
                      && std::abs(constrainer->getFixedAspectRatio() - 1040.0 / 430.0) < 1.0e-9,
                  "resizable from half to twice its size, the aspect ratio kept (as the C++ editor)");
            editor->setSize(1560, 645);
            pump(100);
            screenshot(render(*editor), "mz303_150");
            const float before = cutoff->getValue();
            drag(*editor, cutoffKnob * 1.5f, cutoffKnob * 1.5f - juce::Point<float>(0, 55 * 1.5f));
            pump();
            check(std::abs(cutoff->getValue() - (before + 0.25f)) < 0.01f,
                  "dragging at 150% works in panel units (" + juce::String(before, 3) + " -> " + juce::String(cutoff->getValue(), 3) + ")");
            doubleClick(*editor, cutoffKnob * 1.5f);
            pump();
            hover(*editor, away);
            editor->mouseExit(mouseEvent(*editor, away, juce::ModifierKeys(), 0, away));
            editor->setSize(1040, 430);
            pump(100);
            compareWithReference(render(*editor), "mz303_default"); // and back at 100%, as before
        }

        std::printf("Lifetime\n");
        {
            // a menu still open when the window closes: its answer must go nowhere
            click(*editor, cutoffKnob, right);
            pump();
            editor.reset();
            pump(100);
            juce::PopupMenu::dismissAllActiveMenus();
            pump(100);
            check(pascaljuce_live_editor_sessions() == 0, "menu answer after the window closed is dropped");
            for (int i = 0; i < 100; ++i)
            {
                editor.reset(p.createEditorAndMakeActive());
                if (i % 20 == 0) render(*editor);
                editor.reset();
            }
            pump();
            check(pascaljuce_live_editor_sessions() == 0, "100 panels opened and closed, every session freed");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        for (auto* param : p.getParameters())
            param->removeListener(&gestures);
        p.releaseResources();
    }
    juce::PopupMenu::dismissAllActiveMenus();
    std::printf(failures == 0 ? "All checks passed\n" : "%d check(s) FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
