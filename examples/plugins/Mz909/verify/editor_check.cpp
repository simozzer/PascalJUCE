// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// mz909_editor_test - the Mz909_Pascal panel (Mz909Editor.pas, built from
// Mz909EditorForm.lfm), driven offscreen through the real PascalJUCE wrapper, which loads
// Mz909_pascal_lib.dll from next to the executable (a ctest of the PascalJUCE build):
//
//   - renders the panel and compares it with verify/ui/mz909_default.png (small per-pixel
//     tolerance for font rasterisation);
//   - mouse: a knob drag moves the right parameter by the right amount in one gesture,
//     double-click restores the default, the kit menu chooses a kit;
//   - MIDI learn end to end: right-click a knob, choose MIDI Learn from the menu, the red
//     outline and the hint show it, a CC through processBlock is learned (and does nothing
//     else), then moves the knob; Restore default from the menu; the map survives the
//     plug-in state;
//   - the pads: a press plays its sound (accented with shift held, or with ACCENT lit), and
//     each pad's light follows its sound, from the pads and from MIDI;
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

juce::File referenceDir() { return juce::File(MZ909_VERIFY_DIR).getChildFile("ui"); }

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
const juce::ModifierKeys shiftLeft { juce::ModifierKeys::leftButtonModifier | juce::ModifierKeys::shiftModifier };

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

// One block; the block's peak, if asked.
void block(juce::AudioProcessor& p, juce::MidiBuffer& midi, float* peak = nullptr)
{
    juce::AudioBuffer<float> buffer(2, 512);
    buffer.clear();
    p.processBlock(buffer, midi);
    midi.clear();
    if (peak != nullptr) *peak = std::max(*peak, buffer.getMagnitude(0, 0, 512));
}

// Blocks until everything has rung out (a cymbal is under two seconds).
void silence(juce::AudioProcessor& p)
{
    juce::MidiBuffer none;
    for (int i = 0; i < 200; ++i) block(p, none);
}

// The loudest of the next n blocks: what a hit just struck sounds like.
float peakOf(juce::AudioProcessor& p, int n = 12)
{
    juce::MidiBuffer none;
    float peak = 0;
    for (int i = 0; i < n; ++i) block(p, none, &peak);
    return peak;
}

void cc(juce::AudioProcessor& p, int number, int value)
{
    juce::MidiBuffer midi;
    midi.addEvent(juce::MidiMessage::controllerEvent(1, number, value), 10);
    block(p, midi);
    pump();
}

bool isAccentRed(juce::Colour c) { return c.getRed() > 170 && c.getGreen() < 90 && c.getBlue() < 90; }
bool isLit(juce::Colour c) { return c.getRed() > 200 && c.getGreen() < 140 && c.getBlue() < 130; }

// The panel's layout (Mz909EditorForm.lfm, the C++ Panel's), in editor coordinates: twelve
// columns 92 wide from x = 14, every 98; knob rows every 76 from y = 106; pads at y = 420.
constexpr float columnX(int c) { return 14.0f + 98.0f * (float) c; }
// BASS DRUM TUNE: column 1, row 1 - the knob 66 x 58 at (125, 182), inside the C++
// PanelKnob's 84 x 76 at (116, 182).
const juce::Rectangle<int> bdTuneBounds { 116, 182, 84, 76 };
const juce::Point<float> bdTuneKnob { 125 + 33, 182 + 29 };
// the pads' keys (38 x 56 from y = 434) and their lights (centred at y = 424.5)
const juce::Point<float> padBD { columnX(1) + 27 + 19, 462 };
const juce::Point<float> padSD { columnX(2) + 27 + 19, 462 };
const juce::Point<float> padCH { columnX(8) + 5 + 19, 462 };
const juce::Point<float> padOH { columnX(8) + 49 + 19, 462 };
const juce::Point<int> ledBD { (int) columnX(1) + 27 + 19, 424 };
const juce::Point<int> ledSD { (int) columnX(2) + 27 + 19, 424 };
const juce::Point<int> ledOH { (int) columnX(8) + 49 + 19, 424 };
// ACCENT, the latching button in the ACCENT column: 72 x 40 at (24, 442), its light on top
const juce::Point<float> accentButton { 60, 470 };
const juce::Point<int> accentLed { 60, 450 };
const juce::Point<float> patchBox { 964 + 110, 14 + 13 };
const juce::Point<float> projectLink { 900, 14 + 13 };
const juce::Point<float> away { 5, 530 };

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

// MZ909_SCREENSHOT_DIR set: renders of the panel go there.
void screenshot(const juce::Image& image, const juce::String& name)
{
    const auto dir = juce::SystemStats::getEnvironmentVariable("MZ909_SCREENSHOT_DIR", {});
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
    midi.addEvent(juce::MidiMessage::noteOn(10, number, (juce::uint8) velocity), 10);
    block(p, midi);
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
        auto* bdTune = find(p, "Bass Drum Tune");
        auto* bdAttack = find(p, "Bass Drum Attack");
        auto* bdDecay = find(p, "Bass Drum Decay");
        auto* patch = find(p, "Patch");
        check(bdTune && bdAttack && bdDecay && patch && p.getParameters().size() == 29,
              "Mz909 library loaded next to the executable");
        if (! (bdTune && bdAttack && bdDecay && patch)) return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Rendering\n");
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal panel created");
        if (editor == nullptr) return 1;
        check(editor->getWidth() == 1198 && editor->getHeight() == 540,
              "the C++ panel's size: " + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
        pump(150);
        compareWithReference(render(*editor), "mz909_default");
        screenshot(render(*editor), "mz909_100");

        std::printf("Tooltips, menus, the project link\n");
        {
            auto& look = editor->getLookAndFeel();
            check(look.findColour(juce::TooltipWindow::backgroundColourId) == juce::Colour(0xff111214)
                      && look.findColour(juce::TooltipWindow::textColourId) == juce::Colour(0xffe8e6e0)
                      && look.findColour(juce::TooltipWindow::outlineColourId) == juce::Colour(0xffd8392b),
                  "tooltips in the C++ PanelLook's colours (dark, red outline)");
            check(look.findColour(juce::PopupMenu::backgroundColourId) == juce::Colour(0xff252528)
                      && look.findColour(juce::PopupMenu::textColourId) == juce::Colour(0xffe8e6e0)
                      && look.findColour(juce::PopupMenu::highlightedBackgroundColourId) == juce::Colour(0xffd8392b),
                  "menus too (the section colour, red highlight)");
            hover(*editor, projectLink);
            check(tooltip(*editor).contains("project's page"), "the project line has the C++ hint");
            const int opened = pascaljuce_test_opened_url_count();
            editor->mouseDown(mouseEvent(*editor, projectLink, left, 1, projectLink));
            editor->mouseUp(mouseEvent(*editor, projectLink, juce::ModifierKeys(), 1, projectLink));
            pump(50);
            check(pascaljuce_test_opened_url_count() == opened + 1
                      && pascaljuce_test_opened_url(opened) == "https://github.com/simozzer/Mz909",
                  "a click on it opens the project's page (in tests: recorded, no browser)");
            hover(*editor, padBD);
            check(tooltip(*editor).contains("BASS DRUM") && tooltip(*editor).contains("MIDI note 36 (C1)"),
                  "a pad's hint: " + tooltip(*editor).replace("\n", " | "));
            hover(*editor, away);
            pump(50);
        }

        std::printf("Mouse\n");
        {
            const float before = bdTune->getValue();
            drag(*editor, bdTuneKnob, bdTuneKnob - juce::Point<float>(0, 45));
            pump();
            check(std::abs(bdTune->getValue() - (before + 0.25f)) < 0.01f,
                  "45 px up BASS DRUM TUNE (180 px for the whole turn, as the C++) moves it a quarter ("
                      + juce::String(before, 3) + " -> " + juce::String(bdTune->getValue(), 3) + ")");
            check(bdAttack->getValue() == bdAttack->getDefaultValue() && gestures.begins == 1 && gestures.ends == 1,
                  "one gesture, nothing else moved");
            doubleClick(*editor, bdTuneKnob);
            pump();
            check(std::abs(bdTune->getValue() - bdTune->getDefaultValue()) < 1.0e-4f, "double-click restores the default");

            // the value bubble while dragging, as the C++ popup display
            const auto bubbleArea = bdTuneBounds.expanded(40, 20);
            hover(*editor, away);
            pump(80);
            const auto plain = render(*editor);
            editor->mouseDown(mouseEvent(*editor, bdTuneKnob, left, 1, bdTuneKnob));
            pump(80);
            const auto bubbled = render(*editor);
            check(differingPixels(plain, bubbled, bubbleArea) > 100,
                  "dragging shows the value in a bubble (" + juce::String(differingPixels(plain, bubbled, bubbleArea))
                      + " pixels)");
            screenshot(bubbled.getClippedImage(bubbleArea), "mz909_bubble");
            editor->mouseUp(mouseEvent(*editor, bdTuneKnob, juce::ModifierKeys(), 1, bdTuneKnob));
            hover(*editor, away);
            pump(80);

            click(*editor, patchBox);
            check(chooseFromMenu(3), "the kit box opens the kit menu");
            check(patch->getCurrentValueAsText() == "Techno", "Techno chosen from it: " + patch->getCurrentValueAsText());
            juce::MidiBuffer none;
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            pump();
            check(std::abs(bdDecay->getValue() - 0.75f) < 1.0e-4f && std::abs(bdTune->getValue() - 0.3f) < 1.0e-4f,
                  "and applied: BASS DRUM DECAY 7.5, TUNE 3");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
            // back to the defaults
            for (auto* param : p.getParameters())
                param->setValueNotifyingHost(param->getDefaultValue());
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            pump();
        }

        std::printf("MIDI learn\n");
        {
            const auto edge = juce::Point<int>(bdTuneBounds.getX() + 1, bdTuneBounds.getCentreY());
            hover(*editor, bdTuneKnob);
            check(tooltip(*editor).contains("BASS DRUM TUNE") && tooltip(*editor).contains("MIDI CC 16."),
                  "the hint names the CC: " + tooltip(*editor).replace("\n", " | "));
            check(! isAccentRed(render(*editor).getPixelAt(edge.x, edge.y)), "no outline yet");
            click(*editor, bdTuneKnob, right);
            check(chooseFromMenu(1), "right-click opens the MIDI learn menu");
            pump(100);
            hover(*editor, bdTuneKnob + juce::Point<float>(0, 1));
            check(tooltip(*editor).contains("MIDI LEARN"), "\"MIDI Learn\": the hint says it waits");
            const auto learning = render(*editor);
            screenshot(learning, "mz909_learning");
            check(isAccentRed(learning.getPixelAt(edge.x, edge.y)),
                  "and the red outline is round the knob and its legend ("
                      + learning.getPixelAt(edge.x, edge.y).toDisplayString(false) + ")");

            const float tuneBefore = bdTune->getValue(), attackBefore = bdAttack->getValue();
            cc(p, 17, 100);                                    // BASS DRUM ATTACK's CC
            pump(100);
            check(bdTune->getValue() == tuneBefore && bdAttack->getValue() == attackBefore,
                  "CC 17 through processBlock is learned, and moves nothing");
            check(! isAccentRed(render(*editor).getPixelAt(edge.x, edge.y)), "the outline goes");
            cc(p, 17, 30);
            pump(100);
            check(std::abs(bdTune->getValue() - 30.0f / 127.0f) < 1.0e-3f && bdAttack->getValue() == attackBefore,
                  "now CC 17 moves BASS DRUM TUNE (" + juce::String(bdTune->getValue(), 3) + "), not ATTACK");
            cc(p, 16, 127);
            check(std::abs(bdTune->getValue() - 30.0f / 127.0f) < 1.0e-3f, "and CC 16 no longer does");
            hover(*editor, bdTuneKnob);
            check(tooltip(*editor).contains("MIDI CC 17, learned (default 16)"),
                  "the hint: " + tooltip(*editor).replace("\n", " | "));

            // the map is part of the plug-in's state
            juce::MemoryBlock state;
            p.getStateInformation(state);
            click(*editor, bdTuneKnob, right);
            check(chooseFromMenu(3), "\"Restore default (CC 16)\" from the menu");
            cc(p, 16, 0);
            check(bdTune->getValue() < 1.0e-4f, "CC 16 moves BASS DRUM TUNE again");
            p.setStateInformation(state.getData(), (int) state.getSize());
            pump();
            cc(p, 17, 127);
            check(std::abs(bdTune->getValue() - 1.0f) < 1.0e-4f, "the saved state brings CC 17 back");
            click(*editor, bdTuneKnob, right);
            check(chooseFromMenu(4), "\"Reset all CCs to defaults\"");
            cc(p, 16, 64);
            check(std::abs(bdTune->getValue() - 64.0f / 127.0f) < 1.0e-3f, "and CC 16 is BASS DRUM TUNE's again");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
            bdTune->setValueNotifyingHost(bdTune->getDefaultValue());
            bdAttack->setValueNotifyingHost(bdAttack->getDefaultValue());
            pump();
        }

        std::printf("Pads and lights\n");
        {
            juce::MidiBuffer none;
            silence(p);
            pump(200);
            auto litAt = [&] (juce::Point<int> at) { return isLit(render(*editor).getPixelAt(at.x, at.y)); };
            check(! litAt(ledBD) && ! litAt(ledSD) && ! litAt(ledOH), "the pads' lights are dark");

            note(p, 36, 100);                                  // the kick from MIDI
            pump(60);
            check(litAt(ledBD) && ! litAt(ledSD), "a kick from MIDI lights the BD pad, and only it");
            screenshot(render(*editor), "mz909_lit");
            pump(250);
            check(! litAt(ledBD), "and the light goes out (110 ms)");

            // a pad plays on the press; its light comes on
            silence(p);
            editor->mouseDown(mouseEvent(*editor, padSD, left, 1, padSD));
            const float plain = peakOf(p);
            pump(60);
            check(plain > 0.05f, "a press on the SD pad plays the snare (peak " + juce::String(plain, 3) + ")");
            check(litAt(ledSD), "and lights its pad");
            editor->mouseUp(mouseEvent(*editor, padSD, juce::ModifierKeys(), 1, padSD));
            check(peakOf(p, 2) < plain, "the release plays nothing more");

            // shift, or ACCENT lit: accented (velocity 127; ACCENT at 5 strikes half as hard again)
            silence(p);
            editor->mouseDown(mouseEvent(*editor, padSD, shiftLeft, 1, padSD));
            editor->mouseUp(mouseEvent(*editor, padSD, juce::ModifierKeys(), 1, padSD));
            const float shifted = peakOf(p);
            check(shifted > plain * 1.1f, "shift-click plays it accented (peak " + juce::String(shifted, 3) + ")");

            check(! isLit(render(*editor).getPixelAt(accentLed.x, accentLed.y)), "ACCENT: off");
            click(*editor, accentButton);
            pump(100);
            check(isLit(render(*editor).getPixelAt(accentLed.x, accentLed.y)), "a click lights it");
            silence(p);
            click(*editor, padSD);
            const float latched = peakOf(p);
            check(latched > plain * 1.1f && std::abs(latched - shifted) < 0.1f * shifted,
                  "with ACCENT lit the pads play accented (peak " + juce::String(latched, 3) + ")");
            click(*editor, accentButton);
            pump(100);
            check(! isLit(render(*editor).getPixelAt(accentLed.x, accentLed.y)), "and another click lets it go");

            // the hihats share a VCA: the closed pad chokes the open one. Measured 213 to 341 ms
            // after the open hit: an open hat still rings (OPEN DECAY 10), and a closed one struck 43 ms
            // after it has shut its VCA by then (CLOSED DECAY 5: about 145 ms).
            auto window = [&] { float w = 0; for (int i = 0; i < 12; ++i) block(p, none, &w); return w; };
            silence(p);
            click(*editor, padOH);
            peakOf(p, 20);
            const float tail = window();
            check(tail > 0.005f, "the OH pad rings on (" + juce::String(tail, 4) + ")");
            silence(p);
            click(*editor, padOH);
            peakOf(p, 4);
            click(*editor, padCH);
            peakOf(p, 16);
            const float choked = window();
            check(choked < 0.1f * tail, "and the CH pad cuts it off (" + juce::String(choked, 5) + " against "
                                            + juce::String(tail, 4) + ")");
            hover(*editor, away);
            pump(80);
        }

        std::printf("Scaling\n");
        {
            auto* constrainer = editor->getConstrainer();
            check(editor->isResizable() && constrainer != nullptr && constrainer->getMinimumWidth() == 599
                      && constrainer->getMinimumHeight() == 270 && constrainer->getMaximumWidth() == 2396
                      && constrainer->getMaximumHeight() == 1080
                      && std::abs(constrainer->getFixedAspectRatio() - 1198.0 / 540.0) < 1.0e-9,
                  "resizable from half to twice its size, the aspect ratio kept (as the C++ editor)");
            editor->setSize(1797, 810);
            pump(100);
            screenshot(render(*editor), "mz909_150");
            const float before = bdTune->getValue();
            drag(*editor, bdTuneKnob * 1.5f, bdTuneKnob * 1.5f - juce::Point<float>(0, 45 * 1.5f));
            pump();
            check(std::abs(bdTune->getValue() - (before + 0.25f)) < 0.01f,
                  "dragging at 150% works in panel units (" + juce::String(before, 3) + " -> " + juce::String(bdTune->getValue(), 3) + ")");
            doubleClick(*editor, bdTuneKnob * 1.5f);
            pump();
            hover(*editor, away);
            editor->mouseExit(mouseEvent(*editor, away, juce::ModifierKeys(), 0, away));
            editor->setSize(1198, 540);
            pump(400);
            compareWithReference(render(*editor), "mz909_default"); // and back at 100%, as before
        }

        std::printf("Lifetime\n");
        {
            // a menu still open when the window closes: its answer must go nowhere
            click(*editor, bdTuneKnob, right);
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
