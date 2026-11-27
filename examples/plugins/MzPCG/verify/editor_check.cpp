// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// mzpcg_editor_test - the MzPCG_Pascal panel (MzPcgEditor.pas, built from
// MzPcgEditorForm.lfm), driven offscreen through the real PascalJUCE wrapper, built as an
// effect, which loads MzPCG_pascal_lib.dll from next to the executable (a ctest of the
// PascalJUCE build):
//
//   - renders the panel and compares it with verify/ui/mzpcg_default.png (small per-pixel
//     tolerance for font rasterisation);
//   - every knob's value text against what the C++ Params.cpp makes of the same value with
//     JUCE's own juce::String (the ms, s, dB and % texts);
//   - the knobs: a drag up or to the right turns one (180 px for the whole turn, as the
//     C++ Knob) in one gesture, the value in a bubble while dragged, double-click for the
//     default, the wheel; PATTERN dragged (4 px a pattern) and wheeled, double-clicked;
//     MODE clicked round GATE and DUCK, RATE round 1/8, 1/16 and 1/32;
//   - the gain's picture: the pattern's bars, the gain's curve redrawn when a knob moves,
//     the step lit while the host plays (through processBlock, with a play head) - dark
//     when it stops - and the meter showing the gain now;
//   - the audio goes through (stereo and mono, as the C++ isBusesLayoutSupported);
//   - tooltips in the C++ Look's colours, the project link; many editors open and close
//     without leaking a session.
//
// Set PASCALJUCE_UPDATE_UI_REFERENCES=1 to rewrite the reference (after a deliberate change
// to the look; check the new PNG first). MZPCG_SCREENSHOT_DIR set: renders go there.
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>

#include <cmath>
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

juce::File referenceDir() { return juce::File(MZPCG_VERIFY_DIR).getChildFile("ui"); }

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

void wheel(juce::Component& c, juce::Point<float> at, float deltaY)
{
    juce::MouseWheelDetails w {};
    w.deltaY = deltaY;
    c.mouseWheelMove(mouseEvent(c, at, juce::ModifierKeys(), 1, at), w);
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

// The host's transport, as a play head.
struct Head final : juce::AudioPlayHead
{
    juce::Optional<PositionInfo> getPosition() const override
    {
        PositionInfo info;
        info.setIsPlaying(playing);
        info.setPpqPosition(ppq);
        info.setBpm(bpm);
        return info;
    }
    bool playing = false;
    double ppq = 0.0, bpm = 120.0;
};

// A block of a 220 Hz sine through the effect; the output's peak.
float block(juce::AudioProcessor& p, Head& head, int channels = 2, int n = 512)
{
    static double phase = 0.0;
    juce::AudioBuffer<float> buffer(channels, n);
    for (int i = 0; i < n; ++i)
    {
        const float v = (float) (0.5 * std::sin(phase));
        phase += 2.0 * juce::MathConstants<double>::pi * 220.0 / 48000.0;
        for (int c = 0; c < channels; ++c) buffer.setSample(c, i, v);
    }
    juce::MidiBuffer midi;
    p.processBlock(buffer, midi);
    if (head.playing) head.ppq += n * head.bpm / (60.0 * 48000.0);
    float peak = 0.0f;
    for (int c = 0; c < channels; ++c)
        for (int i = 0; i < n; ++i)
        {
            const float v = buffer.getSample(c, i);
            if (! std::isfinite(v)) return -1.0f;
            peak = std::max(peak, std::abs(v));
        }
    return peak;
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

void screenshot(const juce::Image& image, const juce::String& name)
{
    const auto dir = juce::SystemStats::getEnvironmentVariable("MZPCG_SCREENSHOT_DIR", {});
    if (dir.isEmpty())
        return;
    const auto file = juce::File(dir).getChildFile(name + ".png");
    file.deleteFile();
    juce::FileOutputStream out(file);
    juce::PNGImageFormat().writeImageToStream(image, out);
}

// The C++ Params.cpp's text(), word for word: what the C++ plug-in shows for a value.
enum class Unit { Plain, Percent, Decibels, Attack, Decay };

juce::String milliseconds(double seconds)
{
    return seconds < 1.0 ? juce::String(seconds * 1000.0, seconds < 0.01 ? 1 : 0) + " ms"
                         : juce::String(seconds, 2) + " s";
}

juce::String cppText(Unit unit, float v)
{
    switch (unit)
    {
        case Unit::Decibels: return (v > 0.0f ? "+" : "") + juce::String(v, 1) + " dB";
        case Unit::Percent:  return juce::String(juce::roundToInt(v * 100.0f)) + "%";
        case Unit::Attack:   return milliseconds(0.0005 * std::pow(100.0, v));
        case Unit::Decay:    return milliseconds(0.005 * std::pow(300.0, v));
        default:             return juce::String(juce::roundToInt(v * 100.0f));
    }
}

// The panel's layout (MzPcgEditorForm.lfm: the C++ MzPcgEditor::resized()), in editor
// coordinates.
const juce::Point<float> depthKnob { 438 + 27, 72 + 12 + 27 };       // DEPTH: 54 x 74, its slider under 12 px
const juce::Rectangle<int> depthBounds { 438, 72, 54, 74 };
const juce::Point<float> holdKnob { 550 + 27, 72 + 12 + 27 };
const juce::Point<float> levelKnob { 754 + 28, 72 + 12 + 28 };
const juce::Point<float> patternNumber { 28 + 22, 88 + 16 };
const juce::Point<float> modePad { 318 + 27, 76 + 30 };
const juce::Point<float> ratePad { 376 + 27, 76 + 30 };
const juce::Point<float> display { 80 + 115, 76 + 33 };
const juce::Rectangle<int> displayBounds { 80, 76, 230, 66 };
const juce::Point<float> projectLink { 750, 18 + 14 };
const juce::Point<float> away { 5, 165 };

// The pattern parameter (1 to 32) as the host holds it, 0 to 1.
float patternValue(float number) { return (number - 1.0f) / 31.0f; }

// The display's bars are 207 x 56 from (85, 81), sixteen of them; the meter 8 wide at
// (297, 81).
constexpr float barW = 207.0f / 16.0f;
int barLeft(int step) { return 85 + (int) std::ceil(barW * (float) step + 1.0f); }
int barRight(int step) { return 85 + (int) std::floor(barW * (float) (step + 1) - 1.0f); }

// The step playing is drawn in ledRed at 60% over the dark display - about (162, 38, 23) -
// the others at 28 or 18%; the gain's line in orange.
bool isLit(juce::Colour c) { return c.getRed() > 135 && c.getRed() < 195 && c.getGreen() < 60; }
bool isBar(juce::Colour c) { return c.getRed() > 50 && c.getGreen() < 60; }

// How many pixels at the foot of a step's bar (its lowest 8 rows but the last 2, where the
// gain's line may run) are drawn lit.
int litPixels(const juce::Image& img, int step)
{
    int n = 0;
    for (int y = 81 + 56 - 10; y < 81 + 56 - 3; ++y)
        for (int x = barLeft(step) + 1; x < barRight(step); ++x)
            n += isLit(img.getPixelAt(x, y)) ? 1 : 0;
    return n;
}

int litStep(const juce::Image& img, int& count)
{
    int lit = -1;
    count = 0;
    for (int s = 0; s < 16; ++s)
        if (litPixels(img, s) > 12) { lit = s; ++count; }
    return lit;
}

// The meter's fill, 0 to 1: the share of its column (at x = 301) drawn ledRed.
float meterFill(const juce::Image& img)
{
    int n = 0;
    for (int y = 81; y < 137; ++y)
    {
        const auto c = img.getPixelAt(301, y);
        n += (c.getRed() > 200 && c.getGreen() < 100) ? 1 : 0;
    }
    return (float) n / 56.0f;
}
} // namespace

int main()
{
    juce::ScopedJuceInitialiser_GUI juceInit;
    {
        std::unique_ptr<juce::AudioProcessor> plugin(createPluginFilter());
        auto& p = *plugin;
        Head head;
        p.setPlayHead(&head);
        p.setPlayConfigDetails(2, 2, 48000.0, 512);
        p.prepareToPlay(48000.0, 512);
        auto* pattern = find(p, "Pattern");
        auto* mode = find(p, "Mode");
        auto* rate = find(p, "Rate");
        auto* depth = find(p, "Depth");
        auto* attack = find(p, "Attack");
        auto* hold = find(p, "Hold");
        auto* decay = find(p, "Decay");
        auto* mix = find(p, "Mix");
        auto* level = find(p, "Level");
        check(pattern && mode && rate && depth && attack && hold && decay && mix && level && p.getParameters().size() == 9,
              "MzPCG library loaded next to the executable, its 9 parameters");
        if (! (pattern && mode && rate && depth && attack && hold && decay && mix && level)) return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Value texts, against the C++ Params.cpp with JUCE's own juce::String\n");
        {
            const std::pair<juce::AudioProcessorParameter*, Unit> knobs[] = {
                { depth, Unit::Plain }, { attack, Unit::Attack }, { hold, Unit::Percent },
                { decay, Unit::Decay }, { mix, Unit::Percent },  { level, Unit::Decibels } };
            int compared = 0, differ = 0;
            juce::String first;
            for (const auto& [param, unit] : knobs)
            {
                auto* ranged = dynamic_cast<juce::RangedAudioParameter*>(param);
                for (int k = 0; k <= 4000 && ranged != nullptr; ++k)
                {
                    // every 1/4000 of the travel, and the exact halves and quarters of a dB
                    const float norm = (float) k / 4000.0f;
                    const float v = ranged->convertFrom0to1(norm);
                    const auto pascal = param->getText(norm, 64), cpp = cppText(unit, v);
                    ++compared;
                    if (pascal != cpp)
                    {
                        if (differ++ == 0) first = param->getName(64) + " " + juce::String(v, 6) + ": \"" + pascal + "\" not \"" + cpp + "\"";
                    }
                }
            }
            check(compared == 6 * 4001 && differ == 0,
                  juce::String(compared) + " values of the six knobs read as the C++ reads them" + (differ ? " - " + first : juce::String()));
            check(mode->getCurrentValueAsText() == "GATE" && rate->getCurrentValueAsText() == "1/16"
                      && pattern->getCurrentValueAsText() == "1",
                  "the switches and the pattern: the C++ choices and number (GATE, 1/16, 1)");
        }

        std::printf("Buses and audio\n");
        {
            using Set = juce::AudioChannelSet;
            auto layout = [] (Set in, Set out) { juce::AudioProcessor::BusesLayout l; l.inputBuses.add(in); l.outputBuses.add(out); return l; };
            check(p.checkBusesLayoutSupported(layout(Set::stereo(), Set::stereo()))
                      && p.checkBusesLayoutSupported(layout(Set::mono(), Set::mono()))
                      && ! p.checkBusesLayoutSupported(layout(Set::mono(), Set::stereo()))
                      && ! p.checkBusesLayoutSupported(layout(Set::create5point1(), Set::create5point1())),
                  "stereo or mono, in = out (the C++ isBusesLayoutSupported)");
            float peak = 0.0f;
            for (int i = 0; i < 20; ++i) peak = std::max(peak, block(p, head));
            check(std::abs(peak - 0.5f) < 0.01f, "stopped, a sine goes through untouched (peak " + juce::String(peak, 3) + ")");
            head.playing = true;
            head.ppq = 0.0;
            float quietest = 1.0f;
            for (int i = 0; i < 40; ++i) quietest = std::min(quietest, block(p, head));
            check(quietest < 0.05f, "playing, GATE: the default pattern shuts it between steps (" + juce::String(quietest, 3) + ")");
            head.playing = false;
            for (int i = 0; i < 20; ++i) block(p, head);
        }

        std::printf("Rendering\n");
        pattern->setValueNotifyingHost(patternValue(17.0f));   // as the C++ screenshot
        pump();
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal panel created");
        if (editor == nullptr) return 1;
        check(editor->getWidth() == 840 && editor->getHeight() == 170,
              "the C++ editor's size: " + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
        check(! editor->isResizable(), "a fixed size, as the C++ editor");
        pump(150);
        compareWithReference(render(*editor), "mzpcg_default");
        screenshot(render(*editor), "mzpcg_100");

        std::printf("Tooltips, the project link\n");
        {
            auto& look = editor->getLookAndFeel();
            check(look.findColour(juce::TooltipWindow::backgroundColourId) == juce::Colour(0xff111214)
                      && look.findColour(juce::TooltipWindow::textColourId) == juce::Colour(0xffe9e9e6)
                      && look.findColour(juce::TooltipWindow::outlineColourId) == juce::Colour(0xffd8321f),
                  "tooltips in the C++ Look's colours (dark, red outline)");
            hover(*editor, depthKnob);
            check(tooltip(*editor).startsWith("DEPTH\nHow far the gain goes"), "a knob's hint: " + tooltip(*editor).replace("\n", " | "));
            hover(*editor, patternNumber);
            check(tooltip(*editor).startsWith("PATTERN\nWhich of the 32 patterns plays the gain"), "PATTERN's hint");
            hover(*editor, modePad);
            check(tooltip(*editor).startsWith("MODE\nGATE: each step opens the sound"), "MODE's hint");
            hover(*editor, ratePad);
            check(tooltip(*editor).startsWith("RATE\nHow long a step is"), "RATE's hint");
            hover(*editor, display);
            check(tooltip(*editor).startsWith("The pattern's sixteen steps, each as tall as its level"), "the picture's hint");
            hover(*editor, projectLink);
            check(tooltip(*editor).contains("project's page"), "the project line has the C++ hint");
            const int opened = pascaljuce_test_opened_url_count();
            click(*editor, projectLink);
            pump(50);
            check(pascaljuce_test_opened_url_count() == opened + 1
                      && pascaljuce_test_opened_url(opened) == "https://github.com/simozzer/MzPCG",
                  "a click on it opens the project's page (in tests: recorded, no browser)");
            hover(*editor, away);
            pump(50);
        }

        std::printf("Knobs\n");
        {
            depth->setValueNotifyingHost(0.5f);
            pump();
            gestures.begins = gestures.ends = 0;
            const float before = depth->getValue();
            drag(*editor, depthKnob, depthKnob - juce::Point<float>(0, 45));
            pump();
            check(std::abs(depth->getValue() - (before + 0.25f)) < 0.01f,
                  "45 px up turns DEPTH a quarter (180 px for the whole turn) (" + juce::String(before, 3) + " -> "
                      + juce::String(depth->getValue(), 3) + ")");
            check(gestures.begins == 1 && gestures.ends == 1 && hold->getValue() == hold->getDefaultValue(),
                  "one gesture, nothing else moved");
            drag(*editor, depthKnob, depthKnob + juce::Point<float>(-36, 0));
            pump();
            check(std::abs(depth->getValue() - (before + 0.05f)) < 0.01f,
                  "36 px to the left turns it a fifth back (RotaryHorizontalVerticalDrag)");
            doubleClick(*editor, depthKnob);
            pump();
            check(std::abs(depth->getValue() - depth->getDefaultValue()) < 1.0e-4f, "double-click restores the default (100)");
            wheel(*editor, holdKnob, -1.0f);
            pump();
            check(std::abs(hold->getValue() - (hold->getDefaultValue() - 0.15f)) < 1.0e-3f, "the wheel: 0.15 a step, as JUCE's slider");
            check(hold->getCurrentValueAsText() == "35%", "HOLD reads in percent: " + hold->getCurrentValueAsText());
            doubleClick(*editor, holdKnob);
            pump();

            // the value in a bubble while dragging, as the C++ popup display
            const auto bubbleArea = depthBounds.expanded(40, 20).getIntersection({ 0, 0, 840, 170 });
            hover(*editor, away);
            pump(80);
            const auto plain = render(*editor);
            editor->mouseDown(mouseEvent(*editor, depthKnob, left, 1, depthKnob));
            pump(80);
            const auto bubbled = render(*editor);
            check(differingPixels(plain, bubbled, bubbleArea) > 100,
                  "dragging shows the value in a bubble (" + juce::String(differingPixels(plain, bubbled, bubbleArea))
                      + " pixels)");
            screenshot(bubbled, "mzpcg_bubble");
            editor->mouseUp(mouseEvent(*editor, depthKnob, juce::ModifierKeys(), 1, depthKnob));
            hover(*editor, away);
            pump(80);

            drag(*editor, levelKnob, levelKnob - juce::Point<float>(0, 18));
            pump();
            check(level->getCurrentValueAsText() == "+3.6 dB", "LEVEL reads in dB: " + level->getCurrentValueAsText());
            doubleClick(*editor, levelKnob);
            pump();
            check(level->getCurrentValueAsText() == "0.0 dB", "and back to 0.0 dB");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        std::printf("PATTERN, MODE and RATE\n");
        {
            auto patternNow = [&] { return juce::roundToInt(1.0f + 31.0f * pattern->getValue()); };
            check(patternNow() == 17, "PATTERN shows 17");
            drag(*editor, patternNumber, patternNumber - juce::Point<float>(0, 21));
            pump();
            check(patternNow() == 22, "21 px up: five patterns on (four pixels each), " + juce::String(patternNow()));
            drag(*editor, patternNumber, patternNumber + juce::Point<float>(0, 400));
            pump();
            check(patternNow() == 1, "and down as far as it goes: 1");
            wheel(*editor, patternNumber, 0.25f);
            pump();
            check(patternNow() == 3, "the wheel: eight patterns a unit, " + juce::String(patternNow()));
            doubleClick(*editor, patternNumber);
            pump();
            check(patternNow() == 1, "double-click: the default, 1");
            pattern->setValueNotifyingHost(patternValue(17.0f));
            pump();

            check(mode->getCurrentValueAsText() == "GATE", "MODE: GATE");
            const auto gate = render(*editor);
            click(*editor, modePad);
            pump(120);
            const auto duck = render(*editor);
            check(mode->getCurrentValueAsText() == "DUCK", "a click: DUCK");
            check(differingPixels(gate, duck, { 318, 76, 54, 46 }) > 10, "and the pad says so");
            check(differingPixels(gate, duck, displayBounds) > 100, "the gain's curve redrawn, upside down ("
                      + juce::String(differingPixels(gate, duck, displayBounds)) + " pixels)");
            screenshot(duck, "mzpcg_duck");
            click(*editor, modePad);
            pump();
            check(mode->getCurrentValueAsText() == "GATE", "another: GATE again");

            check(rate->getCurrentValueAsText() == "1/16", "RATE: 1/16");
            click(*editor, ratePad);
            pump(120);
            check(rate->getCurrentValueAsText() == "1/32", "a click: 1/32");
            check(differingPixels(gate, render(*editor), { 376, 76, 54, 46 }) > 10, "and the pad says so");
            click(*editor, ratePad);
            pump();
            check(rate->getCurrentValueAsText() == "1/8", "another: round to 1/8");
            screenshot(render(*editor), "mzpcg_eighth");
            click(*editor, ratePad);
            pump(120);
            check(rate->getCurrentValueAsText() == "1/16", "and on to 1/16 again");

            // a knob the curve depends on redraws it; MIX does not
            const auto before = render(*editor);
            hold->setValueNotifyingHost(1.0f);
            pump(120);
            check(differingPixels(before, render(*editor), displayBounds) > 50, "HOLD moved: the curve redrawn");
            hold->setValueNotifyingHost(hold->getDefaultValue());
            pump(120);
            mix->setValueNotifyingHost(0.2f);
            pump(120);
            check(differingPixels(before, render(*editor), displayBounds) == 0, "MIX moved: the picture as it was (the C++ leaves it out)");
            mix->setValueNotifyingHost(mix->getDefaultValue());
            pump(120);
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        std::printf("The pattern, the step playing, the gain now\n");
        {
            pattern->setValueNotifyingHost(patternValue(9.0f));
            pump(120);
            const auto img = render(*editor);
            // pattern 9 is fc84fc84...: a full bar on step 0, a third of one on step 3
            // a pixel into a bar: clear of the gain's line, which rises at the step's start and
            // falls by the bar's middle
            const int mid0 = barLeft(0) + 1, mid3 = barLeft(3) + 1;
            check(isBar(img.getPixelAt(mid0, 84)) && ! isBar(img.getPixelAt(mid3, 100)) && isBar(img.getPixelAt(mid3, 130)),
                  "pattern 9 drawn: bars as tall as the steps' levels");
            int count = 0;
            litStep(img, count);
            check(count == 0, "stopped: no step lit");
            check(meterFill(img) > 0.95f, "stopped, GATE: the meter full, the sound passing (" + juce::String(meterFill(img), 2) + ")");

            head.playing = true;
            head.ppq = 1.25;         // the top of the sixth sixteenth: step 5
            head.bpm = 120.0;
            block(p, head);
            pump(120);
            auto lit = render(*editor);
            screenshot(lit, "mzpcg_playing");
            const int s = litStep(lit, count);
            check(count == 1 && s == 5, "playing: the step struck is lit (" + juce::String(s) + ")");

            head.ppq = 0.0;          // a loop back to the bar
            block(p, head);
            pump(120);
            lit = render(*editor);
            check(litStep(lit, count) == 0 && count == 1, "a loop back to the bar lights step 0");

            // DUCK on a full step: the meter pushed right down
            mode->setValueNotifyingHost(1.0f);
            pump();
            head.ppq = 0.0;
            for (int i = 0; i < 3; ++i) { head.ppq = 0.0; block(p, head, 2, 256); }
            pump(120);
            lit = render(*editor);
            check(meterFill(lit) < 0.1f, "DUCK, on a full step: the meter pushed down (" + juce::String(meterFill(lit), 2) + ")");
            screenshot(lit, "mzpcg_duck_playing");
            mode->setValueNotifyingHost(0.0f);
            pump();

            head.playing = false;
            for (int i = 0; i < 10; ++i) block(p, head);
            pump(120);
            lit = render(*editor);
            litStep(lit, count);
            check(count == 0, "stopped again: dark");
            check(meterFill(lit) > 0.95f, "and the meter full again");

            pattern->setValueNotifyingHost(patternValue(3.0f));   // every step full
            pump(120);
            const auto three = render(*editor);
            int full = 0;
            for (int st = 0; st < 16; ++st) full += isBar(three.getPixelAt(barLeft(st) + 1, 84)) ? 1 : 0;
            check(full == 16, "pattern 3 (every step): sixteen full bars (" + juce::String(full) + ")");
            screenshot(three, "mzpcg_pattern3");
            pattern->setValueNotifyingHost(patternValue(17.0f));
            pump(120);
        }

        std::printf("Mono\n");
        {
            p.releaseResources();
            p.setPlayConfigDetails(1, 1, 48000.0, 512);
            p.prepareToPlay(48000.0, 512);
            head.playing = true;
            float peak = 0.0f;
            for (int i = 0; i < 20; ++i) peak = std::max(peak, block(p, head, 1));
            check(peak > 0.05f && peak < 2.0f, "mono in, mono out (peak " + juce::String(peak, 3) + ")");
            head.playing = false;
            p.releaseResources();
            p.setPlayConfigDetails(2, 2, 48000.0, 512);
            p.prepareToPlay(48000.0, 512);
            for (int i = 0; i < 20; ++i) block(p, head);
            pump(120);
            compareWithReference(render(*editor), "mzpcg_default"); // as it opened
        }

        std::printf("Lifetime\n");
        {
            editor.reset();
            pump(100);
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
        p.setPlayHead(nullptr);
        p.releaseResources();
    }
    std::printf(failures == 0 ? "All checks passed\n" : "%d check(s) FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
