// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// mz101_editor_test - the Mz101_Pascal panel (Mz101Editor.pas, built from
// Mz101EditorForm.lfm), driven offscreen through the real PascalJUCE wrapper, which loads
// Mz101_pascal.dll from next to the executable (a ctest of the PascalJUCE build):
//
//   - renders the panel and compares it with verify/ui/mz101_default.png (small per-pixel
//     tolerance for font rasterisation);
//   - mouse: a fader drag moves the right parameter by the right amount in one gesture,
//     double-click restores the default, slide switches by click and drag, HOLD toggles,
//     the patch menu chooses a patch;
//   - MIDI learn end to end: right-click a fader, choose MIDI Learn from the menu, the
//     red outline and the hint show it, a CC through processBlock is learned (and does
//     nothing else), then moves the fader; the hint names it; Restore default from the
//     menu; the learned map survives the plug-in state;
//   - TRANS/REST lights its LED once the engine is armed; the keyboard plays a note;
//   - gestures stay balanced; a menu answer after the window closed goes nowhere; many
//     editors open and close without leaking a session.
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

juce::File referenceDir() { return juce::File(MZ101_VERIFY_DIR).getChildFile("ui"); }

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

// The panel's layout (Mz101EditorForm.lfm, the C++ Panel's), in editor coordinates.
constexpr float trackTop = 54 + 24 + 30 + 9, trackBottom = 54 + 24 + 268 - 4 - 9;   // a top-row fader's travel
juce::Point<float> topCap(float centreX, float normalised)
{
    return { centreX, trackBottom - (trackBottom - trackTop) * normalised };
}
constexpr float freqX = 878 + 8 + 21;             // VCF FREQ fader's centre
constexpr float rangeX = 356 + 8 + 42 + 18;       // VCO RANGE switch's slot
const juce::Rectangle<int> freqBounds { 878 + 8, 54 + 24, 42, 268 };
const juce::Point<float> holdButton { 374 + 24, 426 + 20 };
const juce::Point<float> transRest { 520 + 36, 426 + 20 };
const juce::Point<int> transRestLed { 520 + 36, 426 + 8 };
const juce::Point<float> patchBox { 1256 + 110, 12 + 13 };
const juce::Point<float> keyC4 { 818 + 11 * (650.0f / 19.0f) + 17.0f, 390 + 180 };
constexpr float rateX = 14 + 8 + 21;              // MODULATOR RATE fader's centre
constexpr float syncX = 14 + 50 + 18;             // SYNC switch's slot
const juce::Point<float> projectLink { 1230, 12 + 13 };
const juce::Point<int> legatoLed { 520 + 36, 476 + 8 };
const juce::Point<float> legato { 520 + 36, 476 + 20 };

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

// MZ101_SCREENSHOT_DIR set: renders of the panel at several sizes go there.
void screenshot(const juce::Image& image, const juce::String& name)
{
    const auto dir = juce::SystemStats::getEnvironmentVariable("MZ101_SCREENSHOT_DIR", {});
    if (dir.isEmpty())
        return;
    const auto file = juce::File(dir).getChildFile(name + ".png");
    file.deleteFile();
    juce::FileOutputStream out(file);
    juce::PNGImageFormat().writeImageToStream(image, out);
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
        auto* cutoff = find(p, "VCF Freq");
        auto* sub = find(p, "Sub Level");
        auto* range = find(p, "VCO Range");
        auto* hold = find(p, "Hold");
        auto* patch = find(p, "Patch");
        check(cutoff && sub && range && hold && patch, "Mz101 library loaded next to the executable");
        if (! (cutoff && sub && range && hold && patch)) return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Rendering\n");
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal panel created");
        if (editor == nullptr) return 1;
        check(editor->getWidth() == 1490 && editor->getHeight() == 610,
              "the C++ panel's size: " + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
        pump(150);
        compareWithReference(render(*editor), "mz101_default");
        screenshot(render(*editor), "mz101_100");

        std::printf("Tooltips, menus, the project link\n");
        {
            auto& look = editor->getLookAndFeel();
            check(look.findColour(juce::TooltipWindow::backgroundColourId) == juce::Colour(0xff111214)
                      && look.findColour(juce::TooltipWindow::textColourId) == juce::Colour(0xffe9e9e6)
                      && look.findColour(juce::TooltipWindow::outlineColourId) == juce::Colour(0xffd2382f),
                  "tooltips in the C++ panel's colours (dark, red outline)");
            check(look.findColour(juce::PopupMenu::backgroundColourId) == juce::Colour(0xff2b2c30)
                      && look.findColour(juce::PopupMenu::textColourId) == juce::Colour(0xffe9e9e6)
                      && look.findColour(juce::PopupMenu::highlightedBackgroundColourId) == juce::Colour(0xffd2382f),
                  "menus too (section grey, red highlight)");
            hover(*editor, projectLink);
            check(tooltip(*editor).contains("project's page"), "the project line has the C++ hint");
            const int opened = pascaljuce_test_opened_url_count();
            editor->mouseDown(mouseEvent(*editor, projectLink, left, 1, projectLink));
            pump(50);
            check(pascaljuce_test_opened_url_count() == opened, "not opened on the press");
            editor->mouseUp(mouseEvent(*editor, projectLink, juce::ModifierKeys(), 1, projectLink));
            pump(50);
            check(pascaljuce_test_opened_url_count() == opened + 1
                      && pascaljuce_test_opened_url(opened) == "https://github.com/simozzer/Mz101",
                  "a click on it opens the project's page (in tests: recorded, no browser)");
            hover(*editor, { 5, 600 });
            pump(50);
        }

        std::printf("Mouse\n");
        {
            const float before = cutoff->getValue();
            const auto from = topCap(freqX, before);
            drag(*editor, from, from - juce::Point<float>(0, 54));
            pump();
            check(std::abs(cutoff->getValue() - (before + 0.25f)) < 0.01f,
                  "54 px up the 216 px FREQ fader moves VCF Freq a quarter (" + juce::String(before, 3) + " -> "
                      + juce::String(cutoff->getValue(), 3) + ")");
            check(sub->getValue() == sub->getDefaultValue() && gestures.begins == 1 && gestures.ends == 1,
                  "one gesture, nothing else moved");
            doubleClick(*editor, topCap(freqX, cutoff->getValue()));
            pump();
            check(std::abs(cutoff->getValue() - cutoff->getDefaultValue()) < 1.0e-4f, "double-click restores the default");

            click(*editor, { rangeX, trackTop });
            pump();
            check(range->getCurrentValueAsText() == "2'", "a click at the top of RANGE: " + range->getCurrentValueAsText());
            click(*editor, { rangeX + 22, trackBottom });          // on the position name
            pump();
            check(range->getCurrentValueAsText() == "16'", "a click on the name 16': " + range->getCurrentValueAsText());
            const int begins = gestures.begins;
            drag(*editor, { rangeX, trackBottom }, { rangeX, trackBottom - (trackBottom - trackTop) * 2 / 3 });
            pump();
            check(range->getCurrentValueAsText() == "4'" && gestures.begins == begins + 1,
                  "a drag slides it to 4' in one gesture: " + range->getCurrentValueAsText());

            click(*editor, holdButton);
            pump();
            const bool on = hold->getValue() > 0.5f;
            click(*editor, holdButton);
            pump();
            check(on && hold->getValue() < 0.5f, "HOLD toggles");

            // a click on a fader's track jumps the cap there (the C++ sliders do), then drags
            click(*editor, topCap(freqX, 0.9f));
            pump();
            check(std::abs(cutoff->getValue() - 0.9f) < 0.01f, "a click on the FREQ track jumps it there ("
                                                                    + juce::String(cutoff->getValue(), 3) + ")");
            doubleClick(*editor, topCap(freqX, cutoff->getValue()));
            pump();

            // the value bubble while dragging, as the C++ popup display
            const auto bubbleArea = juce::Rectangle<int>(freqBounds.getX() - 40, freqBounds.getY(), freqBounds.getWidth() + 80,
                                                         freqBounds.getHeight());
            hover(*editor, { 5, 600 });
            pump(80);
            const auto plain = render(*editor);
            const auto cap = topCap(freqX, cutoff->getValue());
            editor->mouseDown(mouseEvent(*editor, cap, left, 1, cap));
            pump(80);
            const auto bubbled = render(*editor);
            check(differingPixels(plain, bubbled, bubbleArea) > 150,
                  "dragging FREQ shows its value in a bubble (" + juce::String(differingPixels(plain, bubbled, bubbleArea))
                      + " pixels)");
            screenshot(bubbled.getClippedImage(bubbleArea.expanded(60, 0)), "mz101_bubble");
            editor->mouseUp(mouseEvent(*editor, cap, juce::ModifierKeys(), 1, cap));
            hover(*editor, { 5, 600 });
            pump(80);
            check(differingPixels(plain, render(*editor), bubbleArea) == 0, "and hides it when let go");

            // RATE: a note length while SYNC is on HOST (the C++ textFromValueFunction)
            const auto rateCap = topCap(rateX, find(p, "Mod Rate")->getValue());
            const auto rateArea = juce::Rectangle<int>((int) rateX - 60, (int) trackTop - 40, 120, (int) (trackBottom - trackTop) + 80);
            const auto rateBubble = [&]
            {
                editor->mouseDown(mouseEvent(*editor, rateCap, left, 1, rateCap));
                pump(80);
                auto image = render(*editor);
                editor->mouseUp(mouseEvent(*editor, rateCap, juce::ModifierKeys(), 1, rateCap));
                hover(*editor, { 5, 600 });
                pump(80);
                return image;
            };
            const auto rateFree = rateBubble();
            click(*editor, { syncX, trackTop });             // SYNC to HOST
            pump();
            check(find(p, "Mod Sync")->getCurrentValueAsText() == "Host", "SYNC on HOST");
            const auto rateHost = rateBubble();
            check(differingPixels(rateFree, rateHost, rateArea) > 30 && differingPixels(rateFree, plain, rateArea) > 30,
                  "RATE's bubble reads differently with SYNC on HOST (a note length, not Hz)");
            screenshot(rateHost.getClippedImage(rateArea), "mz101_rate_host");
            click(*editor, { syncX, trackBottom });          // and back to FREE
            pump();

            click(*editor, patchBox);
            check(chooseFromMenu(3), "the patch box opens the patch menu");
            check(patch->getCurrentValueAsText() == "Acid Line", "Acid Line chosen from it: " + patch->getCurrentValueAsText());
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }
        // back to the defaults (Process applies the patch; let it, then reset)
        {
            juce::MidiBuffer none;
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            for (auto* param : p.getParameters())
                param->setValueNotifyingHost(param->getDefaultValue());
            for (int i = 0; i < 10; ++i) { block(p, none); pump(5); }
            pump();
        }

        std::printf("MIDI learn\n");
        {
            hover(*editor, topCap(freqX, cutoff->getValue()));
            check(tooltip(*editor).contains("VCF FREQ") && tooltip(*editor).contains("MIDI CC 74."),
                  "the hint names the CC: " + tooltip(*editor).replace("\n", " | "));
            check(! isAccentRed(render(*editor).getPixelAt(freqBounds.getX() + 1, freqBounds.getCentreY())), "no outline yet");
            click(*editor, topCap(freqX, cutoff->getValue()), right);
            check(chooseFromMenu(1), "right-click opens the MIDI learn menu");
            pump(100);
            hover(*editor, topCap(freqX, cutoff->getValue()) + juce::Point<float>(0, 1));
            check(tooltip(*editor).contains("MIDI LEARN"), "\"MIDI Learn\": the hint says it waits");
            const auto learning = render(*editor);
            check(isAccentRed(learning.getPixelAt(freqBounds.getX() + 1, freqBounds.getCentreY())),
                  "and the red outline is round the fader (" + learning.getPixelAt(freqBounds.getX() + 1, freqBounds.getCentreY()).toDisplayString(false) + ")");

            const float cutoffBefore = cutoff->getValue(), subBefore = sub->getValue();
            cc(p, 20, 100);                                    // Sub Level's CC
            pump(100);
            check(cutoff->getValue() == cutoffBefore && sub->getValue() == subBefore,
                  "CC 20 through processBlock is learned, and moves nothing");
            check(! isAccentRed(render(*editor).getPixelAt(freqBounds.getX() + 1, freqBounds.getCentreY())), "the outline goes");
            cc(p, 20, 30);
            pump(100);
            check(std::abs(cutoff->getValue() - 30.0f / 127.0f) < 1.0e-3f && sub->getValue() == subBefore,
                  "now CC 20 moves VCF Freq (" + juce::String(cutoff->getValue(), 3) + "), not Sub Level");
            cc(p, 74, 127);
            check(std::abs(cutoff->getValue() - 30.0f / 127.0f) < 1.0e-3f, "and CC 74 no longer does");
            hover(*editor, topCap(freqX, cutoff->getValue()));
            check(tooltip(*editor).contains("MIDI CC 20, learned (default 74)"),
                  "the hint: " + tooltip(*editor).replace("\n", " | "));

            // the map is part of the plug-in's state
            juce::MemoryBlock state;
            p.getStateInformation(state);
            click(*editor, topCap(freqX, cutoff->getValue()), right);
            check(chooseFromMenu(3), "\"Restore default (CC 74)\" from the menu");
            cc(p, 74, 0);
            check(cutoff->getValue() < 1.0e-4f, "CC 74 moves VCF Freq again");
            p.setStateInformation(state.getData(), (int) state.getSize());
            pump();
            cc(p, 20, 127);
            check(std::abs(cutoff->getValue() - 1.0f) < 1.0e-4f, "the saved state brings CC 20 back");
            hover(*editor, { 5, 600 });
            hover(*editor, topCap(freqX, cutoff->getValue()));
            check(tooltip(*editor).contains("MIDI CC 20, learned"), "and the hint follows");
            click(*editor, topCap(freqX, cutoff->getValue()), right);
            check(chooseFromMenu(4), "\"Reset all CCs to defaults\"");
            cc(p, 74, 64);
            check(std::abs(cutoff->getValue() - 64.0f / 127.0f) < 1.0e-3f, "and CC 74 is VCF Freq's again");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        std::printf("Buttons, readout, keyboard\n");
        {
            juce::MidiBuffer none;
            check(! isAccentRed(render(*editor).getPixelAt(transRestLed.x, transRestLed.y)),
                  "TRANS/REST's LED off");
            click(*editor, transRest);
            pump(150);                                     // no audio block yet
            const auto litAtOnce = render(*editor).getPixelAt(transRestLed.x, transRestLed.y);
            check(litAtOnce.getRed() > 180 && litAtOnce.getRed() > litAtOnce.getBlue() + 60,
                  "pressed with no audio running: the LED answers at once (" + litAtOnce.toDisplayString(false) + ")");
            block(p, none);
            pump(150);
            const auto lit = render(*editor).getPixelAt(transRestLed.x, transRestLed.y);
            check(lit.getRed() > 180 && lit.getRed() > lit.getBlue() + 60,
                  "the engine then waits for a key, and the LED still says so (" + lit.toDisplayString(false) + ")");
            click(*editor, transRest);
            pump(150);
            check(! isAccentRed(render(*editor).getPixelAt(transRestLed.x, transRestLed.y)), "pressed again: off at once");
            block(p, none);
            pump(150);
            check(! isAccentRed(render(*editor).getPixelAt(transRestLed.x, transRestLed.y)), "and the engine agrees");

            // LEGATO arms a tie in LOAD, also without audio; then the engine confirms it
            auto* seqMode = find(p, "Sequencer");
            seqMode->setValueNotifyingHost(1.0f);          // LOAD
            block(p, none);
            pump(150);
            check(! isAccentRed(render(*editor).getPixelAt(legatoLed.x, legatoLed.y)), "LEGATO's LED off");
            click(*editor, legato);
            pump(150);
            const auto tie = render(*editor).getPixelAt(legatoLed.x, legatoLed.y);
            check(tie.getRed() > 180 && tie.getRed() > tie.getBlue() + 60,
                  "in LOAD, LEGATO lights at once (" + tie.toDisplayString(false) + ")");
            block(p, none);
            pump(150);
            const auto tied = render(*editor).getPixelAt(legatoLed.x, legatoLed.y);
            check(tied.getRed() > 180 && tied.getRed() > tied.getBlue() + 60, "and stays lit once the engine has it");
            click(*editor, legato);
            block(p, none);
            pump(150);
            seqMode->setValueNotifyingHost(0.0f);
            block(p, none);
            pump(150);

            // a key held on the panel with no audio running: lit at once (by the panel, then the meters)
            editor->mouseDown(mouseEvent(*editor, keyC4, left, 1, keyC4));
            pump(150);
            const auto keyAtOnce = render(*editor).getPixelAt((int) keyC4.x, (int) keyC4.y);
            check(keyAtOnce.getRed() > keyAtOnce.getBlue() + 40, "a panel key is lit at once, without audio");
            editor->mouseUp(mouseEvent(*editor, keyC4, juce::ModifierKeys(), 1, keyC4));
            pump(150);
            for (int i = 0; i < 300; ++i) block(p, none);
            pump(150);

            float rms = 0;
            editor->mouseDown(mouseEvent(*editor, keyC4, left, 1, keyC4));
            for (int i = 0; i < 8; ++i) block(p, none, &rms);
            pump(150);
            const auto key = render(*editor).getPixelAt((int) keyC4.x, (int) keyC4.y);
            check(rms > 0.01f, "a key of the panel's keyboard plays (rms " + juce::String(rms, 3) + ")");
            check(key.getRed() > key.getBlue() + 40, "and is lit while held (" + key.toDisplayString(false) + ")");
            editor->mouseUp(mouseEvent(*editor, keyC4, juce::ModifierKeys(), 1, keyC4));
            for (int i = 0; i < 300; ++i) block(p, none, &rms);
            check(rms < 1.0e-4f, "and lets go (rms " + juce::String(rms, 6) + ")");
        }

        std::printf("Scaling\n");
        {
            auto* constrainer = editor->getConstrainer();
            check(editor->isResizable() && constrainer != nullptr && constrainer->getMinimumWidth() == 745
                      && constrainer->getMinimumHeight() == 305 && constrainer->getMaximumWidth() == 2980
                      && constrainer->getMaximumHeight() == 1220
                      && std::abs(constrainer->getFixedAspectRatio() - 1490.0 / 610.0) < 1.0e-9,
                  "resizable from half to twice its size, the aspect ratio kept (as the C++ editor)");
            bool corner = false;
            for (auto* child : editor->getChildren())
                corner = corner || dynamic_cast<juce::ResizableCornerComponent*>(child) != nullptr;
            check(corner, "with the C++ editor's resize corner");
            hover(*editor, { 5, 600 });
            editor->mouseExit(mouseEvent(*editor, { 5, 600 }, juce::ModifierKeys(), 0, { 5, 600 }));
            pump(50);

            editor->setSize(745, 305);
            pump(100);
            const auto half = render(*editor);
            screenshot(half, "mz101_50");
            check(isAccentRed(half.getPixelAt(372, 1)) && isAccentRed(half.getPixelAt(740, 1)) && ! isAccentRed(half.getPixelAt(372, 4)),
                  "at half size the whole panel is drawn at half scale (the 4 px name strip is 2 px)");
            editor->setSize(2235, 915);
            pump(100);
            const auto big = render(*editor);
            screenshot(big, "mz101_150");
            check(big.getWidth() == 2235 && isAccentRed(big.getPixelAt(2230, 5)) && ! isAccentRed(big.getPixelAt(1000, 7)),
                  "at 150% too (the name strip is 6 px)");
            // the mouse in panel coordinates: the same drag, 1.5 times as long, moves FREQ the same
            const float before = cutoff->getValue();
            const auto from = topCap(freqX, before) * 1.5f;
            drag(*editor, from, from - juce::Point<float>(0, 54 * 1.5f));
            pump();
            check(std::abs(cutoff->getValue() - (before + 0.25f)) < 0.01f,
                  "dragging at 150% works in panel units (" + juce::String(before, 3) + " -> " + juce::String(cutoff->getValue(), 3) + ")");
            doubleClick(*editor, topCap(freqX, cutoff->getValue()) * 1.5f);
            pump();
            editor.reset();
            editor.reset(p.createEditorAndMakeActive());
            check(editor->getWidth() == 2235 && editor->getHeight() == 915, "reopened at the size it had: "
                      + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
            editor->setSize(1490, 610);
            pump(100);
            compareWithReference(render(*editor), "mz101_default"); // and back at 100%, as before
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        std::printf("Lifetime\n");
        {
            // a menu still open when the window closes: its answer must go nowhere
            click(*editor, topCap(freqX, cutoff->getValue()), right);
            pump();
            editor.reset();
            pump(100);
            juce::PopupMenu::dismissAllActiveMenus();
            pump(100);
            check(pascaljuce_live_editor_sessions() == 0, "menu answer after the window closed is dropped");
            for (int i = 0; i < 200; ++i)
            {
                editor.reset(p.createEditorAndMakeActive());
                if (i % 20 == 0) render(*editor);
                if (i % 50 == 0)
                    drag(*editor, topCap(freqX, cutoff->getValue()), topCap(freqX, cutoff->getValue()) - juce::Point<float>(0, 5));
                editor.reset();
            }
            pump();
            check(pascaljuce_live_editor_sessions() == 0, "200 panels opened and closed, every session freed");
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
