// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// mz808_editor_test - the Mz808_Pascal panel (Mz808Editor.pas, built from
// Mz808EditorForm.lfm), driven offscreen through the real PascalJUCE wrapper, which loads
// Mz808_pascal_lib.dll from next to the executable (a ctest of the PascalJUCE build):
//
//   - renders the panel and compares it with verify/ui/mz808_default.png (small per-pixel
//     tolerance for font rasterisation);
//   - mouse: a knob drag moves the right parameter by the right amount in one gesture,
//     double-click restores the default, the kit menu chooses a kit;
//   - MIDI learn end to end: right-click a knob, choose MIDI Learn from the menu, the red
//     outline and the hint show it, a CC through processBlock is learned (and does nothing
//     else), then moves the knob; Restore default from the menu; the map survives the
//     plug-in state;
//   - the pads: a click plays its sound and lights it, a note from the host lights it too,
//     and the light goes out; shift-click, or ACCENT lit, plays an accented hit;
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

juce::File referenceDir() { return juce::File(MZ808_VERIFY_DIR).getChildFile("ui"); }

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

// Every sound stopped (CC 120), and silence until the output's coupling capacitor has
// settled (its time constant is 20 ms; 40 blocks are 427 ms): the next hit starts from rest,
// and sounds the same each time.
void silence(juce::AudioProcessor& p)
{
    juce::MidiBuffer midi;
    midi.addEvent(juce::MidiMessage::allSoundOff(1), 0);
    block(p, midi);
    for (int i = 0; i < 40; ++i) block(p, midi);
}

bool isAccentRed(juce::Colour c) { return c.getRed() > 170 && c.getGreen() < 90 && c.getBlue() < 90; }

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

// MZ808_SCREENSHOT_DIR set: renders of the panel go there.
void screenshot(const juce::Image& image, const juce::String& name)
{
    const auto dir = juce::SystemStats::getEnvironmentVariable("MZ808_SCREENSHOT_DIR", {});
    if (dir.isEmpty())
        return;
    const auto file = juce::File(dir).getChildFile(name + ".png");
    file.deleteFile();
    juce::FileOutputStream out(file);
    juce::PNGImageFormat().writeImageToStream(image, out);
}

// A red LED, lit (a pad's: red brightened; ACCENT's: 0xffe3685e) or dark (about 0xff3c100c).
bool isLit(juce::Colour c) { return c.getRed() > 150; }

// The panel's layout (Mz808EditorForm.lfm, the C++ Panel::resized()'s), in editor
// coordinates. Columns are 92 wide from x = 14, every 98; knobs 66 x 66 at x + 13, from
// y = 62 + 44, every 84; pads 38 x 56 at y = 62 + 312 + 14, their LEDs 9 x 9 above them.
const juce::Rectangle<int> bdDecayBounds { 112 + 13, 62 + 44 + 2 * 84, 66, 66 };   // BASS DRUM DECAY
const juce::Point<float> bdDecayKnob { 112 + 13 + 33, 62 + 44 + 2 * 84 + 33 };
const juce::Point<float> patchBox { 1062 + 110, 14 + 13 };
const juce::Point<float> projectLink { 900, 14 + 13 };
const juce::Point<float> accentButton { 14 + 10 + 36, 62 + 312 + 22 + 25 };
const juce::Point<int> accentButtonLed { 14 + 10 + 36, 62 + 312 + 22 + 8 };
// a pad's centre, and the centre of the LED above it, by the pad's x
juce::Point<float> padAt(int x) { return { x + 19.0f, 62 + 312 + 14 + 28.0f }; }
juce::Point<int> ledAt(int x) { return { x + 19, 62 + 313 + 4 }; }
constexpr int bdPadX = 112 + 27, sdPadX = 210 + 27, chPadX = 1092 + 27;
const juce::Point<float> away { 5, 490 };

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
        auto* bdDecay = find(p, "Bass Drum Decay");
        auto* accent = find(p, "Accent");
        auto* ohDecay = find(p, "Open Hihat Decay");
        auto* patch = find(p, "Patch");
        check(bdDecay && accent && ohDecay && patch && p.getParameters().size() == 24, "Mz808 library loaded next to the executable");
        if (! (bdDecay && accent && ohDecay && patch)) return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Rendering\n");
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal panel created");
        if (editor == nullptr) return 1;
        check(editor->getWidth() == 1296 && editor->getHeight() == 500,
              "the C++ panel's size: " + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
        pump(150);
        compareWithReference(render(*editor), "mz808_default");
        {
            const auto img = render(*editor);
            const auto band = img.getPixelAt(100, 1), section = img.getPixelAt(20, 300), backdrop = img.getPixelAt(8, 300);
            check(isAccentRed(band) && section == juce::Colour(0xff252528) && backdrop == juce::Colour(0xff1b1b1d),
                  "the band of colour, the columns and the panel in the C++ colours ("
                      + band.toDisplayString(false) + ", " + section.toDisplayString(false) + ", " + backdrop.toDisplayString(false) + ")");
        }

        std::printf("Tooltips, menus, the project link\n");
        {
            auto& look = editor->getLookAndFeel();
            check(look.findColour(juce::TooltipWindow::backgroundColourId) == juce::Colour(0xff111214)
                      && look.findColour(juce::TooltipWindow::textColourId) == juce::Colour(0xffe8e6e0)
                      && look.findColour(juce::TooltipWindow::outlineColourId) == juce::Colour(0xffd8392b),
                  "tooltips in the C++ panel's colours (dark, red outline)");
            check(look.findColour(juce::PopupMenu::backgroundColourId) == juce::Colour(0xff252528)
                      && look.findColour(juce::PopupMenu::textColourId) == juce::Colour(0xffe8e6e0)
                      && look.findColour(juce::PopupMenu::highlightedBackgroundColourId) == juce::Colour(0xffd8392b),
                  "menus too (the columns' grey, red highlight)");
            hover(*editor, projectLink);
            check(tooltip(*editor).contains("project's page"), "the project line has the C++ hint");
            const int opened = pascaljuce_test_opened_url_count();
            editor->mouseDown(mouseEvent(*editor, projectLink, left, 1, projectLink));
            editor->mouseUp(mouseEvent(*editor, projectLink, juce::ModifierKeys(), 1, projectLink));
            pump(50);
            check(pascaljuce_test_opened_url_count() == opened + 1
                      && pascaljuce_test_opened_url(opened) == "https://github.com/simozzer/Mz808",
                  "a click on it opens the project's page (in tests: recorded, no browser)");
            hover(*editor, padAt(bdPadX));
            check(tooltip(*editor).contains("BASS DRUM") && tooltip(*editor).contains("MIDI note 36 (C1)"),
                  "a pad's hint names its sound and note: " + tooltip(*editor).replace("\n", " | "));
            hover(*editor, away);
            pump(50);
        }

        std::printf("Mouse\n");
        {
            const float before = bdDecay->getValue();
            drag(*editor, bdDecayKnob, bdDecayKnob - juce::Point<float>(0, 45));
            pump();
            check(std::abs(bdDecay->getValue() - (before + 0.25f)) < 0.01f,
                  "45 px up BASS DRUM DECAY (180 px for the whole turn, as the C++) moves it a quarter ("
                      + juce::String(before, 3) + " -> " + juce::String(bdDecay->getValue(), 3) + ")");
            check(accent->getValue() == accent->getDefaultValue() && gestures.begins == 1 && gestures.ends == 1,
                  "one gesture, nothing else moved");
            doubleClick(*editor, bdDecayKnob);
            pump();
            check(std::abs(bdDecay->getValue() - bdDecay->getDefaultValue()) < 1.0e-4f, "double-click restores the default");

            // the value bubble while dragging, as the C++ popup display
            const auto bubbleArea = bdDecayBounds.expanded(40, 20);
            hover(*editor, away);
            pump(80);
            const auto plain = render(*editor);
            editor->mouseDown(mouseEvent(*editor, bdDecayKnob, left, 1, bdDecayKnob));
            pump(80);
            const auto bubbled = render(*editor);
            check(differingPixels(plain, bubbled, bubbleArea) > 100,
                  "dragging shows the value in a bubble (" + juce::String(differingPixels(plain, bubbled, bubbleArea))
                      + " pixels)");
            editor->mouseUp(mouseEvent(*editor, bdDecayKnob, juce::ModifierKeys(), 1, bdDecayKnob));
            hover(*editor, away);
            pump(80);

            click(*editor, patchBox);
            check(chooseFromMenu(3), "the kit box opens the kit menu");
            check(patch->getCurrentValueAsText() == "Tight", "Tight chosen from it: " + patch->getCurrentValueAsText());
            juce::MidiBuffer none;
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            pump();
            check(std::abs(bdDecay->getValue() - 0.25f) < 1.0e-4f && std::abs(ohDecay->getValue() - 0.15f) < 1.0e-4f
                      && std::abs(accent->getValue() - 0.6f) < 1.0e-4f,
                  "and applied: BASS DRUM DECAY 2.5, OPEN HIHAT DECAY 1.5, ACCENT 6");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
            // back to the defaults
            for (auto* param : p.getParameters())
                param->setValueNotifyingHost(param->getDefaultValue());
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            pump();
        }

        std::printf("MIDI learn\n");
        {
            // the outline covers the knob and its legend: 84 wide, from 9 left of the knob
            const auto edge = juce::Point<int>(bdDecayBounds.getX() - 9 + 1, bdDecayBounds.getCentreY());
            hover(*editor, bdDecayKnob);
            check(tooltip(*editor).contains("BASS DRUM DECAY") && tooltip(*editor).contains("MIDI CC 17."),
                  "the hint names the CC: " + tooltip(*editor).replace("\n", " | "));
            check(! isAccentRed(render(*editor).getPixelAt(edge.x, edge.y)), "no outline yet");
            click(*editor, bdDecayKnob, right);
            check(chooseFromMenu(1), "right-click opens the MIDI learn menu");
            pump(100);
            hover(*editor, bdDecayKnob + juce::Point<float>(0, 1));
            check(tooltip(*editor).contains("MIDI LEARN"), "\"MIDI Learn\": the hint says it waits");
            const auto learning = render(*editor);
            check(isAccentRed(learning.getPixelAt(edge.x, edge.y)),
                  "and the red outline is round the knob (" + learning.getPixelAt(edge.x, edge.y).toDisplayString(false) + ")");

            const float decayBefore = bdDecay->getValue(), accentBefore = accent->getValue();
            cc(p, 14, 100);                                    // ACCENT's CC
            pump(100);
            check(bdDecay->getValue() == decayBefore && accent->getValue() == accentBefore,
                  "CC 14 through processBlock is learned, and moves nothing");
            check(! isAccentRed(render(*editor).getPixelAt(edge.x, edge.y)), "the outline goes");
            cc(p, 14, 30);
            pump(100);
            check(std::abs(bdDecay->getValue() - 30.0f / 127.0f) < 1.0e-3f && accent->getValue() == accentBefore,
                  "now CC 14 moves BASS DRUM DECAY (" + juce::String(bdDecay->getValue(), 3) + "), not ACCENT");
            cc(p, 17, 127);
            check(std::abs(bdDecay->getValue() - 30.0f / 127.0f) < 1.0e-3f, "and CC 17 no longer does");
            hover(*editor, bdDecayKnob);
            check(tooltip(*editor).contains("MIDI CC 14, learned (default 17)"),
                  "the hint: " + tooltip(*editor).replace("\n", " | "));

            // the map is part of the plug-in's state
            juce::MemoryBlock state;
            p.getStateInformation(state);
            click(*editor, bdDecayKnob, right);
            check(chooseFromMenu(3), "\"Restore default (CC 17)\" from the menu");
            cc(p, 17, 0);
            check(bdDecay->getValue() < 1.0e-4f, "CC 17 moves BASS DRUM DECAY again");
            p.setStateInformation(state.getData(), (int) state.getSize());
            pump();
            cc(p, 14, 127);
            check(std::abs(bdDecay->getValue() - 1.0f) < 1.0e-4f, "the saved state brings CC 14 back");
            click(*editor, bdDecayKnob, right);
            check(chooseFromMenu(4), "\"Reset all CCs to defaults\"");
            cc(p, 17, 64);
            check(std::abs(bdDecay->getValue() - 64.0f / 127.0f) < 1.0e-3f, "and CC 17 is BASS DRUM DECAY's again");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
            bdDecay->setValueNotifyingHost(bdDecay->getDefaultValue());
            accent->setValueNotifyingHost(accent->getDefaultValue());
            pump();
        }

        std::printf("Pads and lights\n");
        {
            juce::MidiBuffer none;
            auto lit = [&] (int padX) { const auto at = ledAt(padX); return isLit(render(*editor).getPixelAt(at.x, at.y)); };
            hover(*editor, away);
            pump(200);
            check(! lit(bdPadX) && ! lit(sdPadX) && ! lit(chPadX), "the pads' lights are dark");

            // a click plays the pad, at once (on the press, as a drum)
            float plainRms = 0, accentRms = 0, rms = 0;
            silence(p);
            editor->mouseDown(mouseEvent(*editor, padAt(bdPadX), left, 1, padAt(bdPadX)));
            block(p, none, &plainRms);
            pump(60);
            check(plainRms > 0.01f, "a click on BD plays the bass drum (rms " + juce::String(plainRms, 3) + ")");
            check(lit(bdPadX), "and lights its pad");
            screenshot(render(*editor), "mz808_pad");
            editor->mouseUp(mouseEvent(*editor, padAt(bdPadX), juce::ModifierKeys(), 1, padAt(bdPadX)));
            for (int i = 0; i < 4; ++i) block(p, none);
            pump(250);
            check(! lit(bdPadX), "the light goes out after a moment");

            // shift-click: accented - a taller trigger, so a louder, different hit
            silence(p);
            editor->mouseDown(mouseEvent(*editor, padAt(bdPadX), shiftLeft, 1, padAt(bdPadX)));
            block(p, none, &accentRms);
            editor->mouseUp(mouseEvent(*editor, padAt(bdPadX), juce::ModifierKeys(), 1, padAt(bdPadX)));
            check(accentRms > plainRms * 1.1f, "shift-click plays it accented (rms " + juce::String(accentRms, 3)
                                                   + " against " + juce::String(plainRms, 3) + ")");

            // ACCENT lit: every pad accented
            check(! isLit(render(*editor).getPixelAt(accentButtonLed.x, accentButtonLed.y)), "ACCENT: off");
            click(*editor, accentButton);
            pump(100);
            check(isLit(render(*editor).getPixelAt(accentButtonLed.x, accentButtonLed.y)), "a click lights it");
            silence(p);
            click(*editor, padAt(bdPadX));
            block(p, none, &rms);
            check(std::abs(rms - accentRms) < 1.0e-4f * accentRms, "now a plain click plays accented (rms " + juce::String(rms, 3) + ")");
            click(*editor, accentButton);
            pump(100);
            check(! isLit(render(*editor).getPixelAt(accentButtonLed.x, accentButtonLed.y)), "and another click lets it go");
            silence(p);
            click(*editor, padAt(bdPadX));
            block(p, none, &rms);
            check(std::abs(rms - plainRms) < 1.0e-4f * plainRms, "plain again (rms " + juce::String(rms, 3) + ")");

            // a note from the host lights its pad too: the closed hihat
            pump(250);
            note(p, 42, 100);
            pump(60);
            check(lit(chPadX) && ! lit(sdPadX), "a note from the host lights the pad of its sound");
            for (int i = 0; i < 4; ++i) block(p, none);
            pump(250);
            check(! lit(chPadX), "and lets it go out");

            // a right-click on a pad plays nothing
            silence(p);
            click(*editor, padAt(sdPadX), right);
            block(p, none, &rms);
            pump(60);
            check(rms < 1.0e-6f && ! lit(sdPadX), "a right-click on a pad plays nothing");
            hover(*editor, away);
            pump(80);
        }

        std::printf("Scaling\n");
        {
            auto* constrainer = editor->getConstrainer();
            check(editor->isResizable() && constrainer != nullptr && constrainer->getMinimumWidth() == 648
                      && constrainer->getMinimumHeight() == 250 && constrainer->getMaximumWidth() == 2592
                      && constrainer->getMaximumHeight() == 1000
                      && std::abs(constrainer->getFixedAspectRatio() - 1296.0 / 500.0) < 1.0e-9,
                  "resizable from half to twice its size, the aspect ratio kept (as the C++ editor)");
            editor->setSize(1944, 750);
            pump(100);
            screenshot(render(*editor), "mz808_150");
            const float before = bdDecay->getValue();
            drag(*editor, bdDecayKnob * 1.5f, bdDecayKnob * 1.5f - juce::Point<float>(0, 45 * 1.5f));
            pump();
            check(std::abs(bdDecay->getValue() - (before + 0.25f)) < 0.01f,
                  "dragging at 150% works in panel units (" + juce::String(before, 3) + " -> " + juce::String(bdDecay->getValue(), 3) + ")");
            doubleClick(*editor, bdDecayKnob * 1.5f);
            pump();
            hover(*editor, away);
            editor->mouseExit(mouseEvent(*editor, away, juce::ModifierKeys(), 0, away));
            editor->setSize(1296, 500);
            pump(100);
            compareWithReference(render(*editor), "mz808_default"); // and back at 100%, as before
        }

        std::printf("Lifetime\n");
        {
            // a menu still open when the window closes: its answer must go nowhere
            click(*editor, bdDecayKnob, right);
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
