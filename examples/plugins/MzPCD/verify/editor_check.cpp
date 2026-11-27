// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// mzpcd_editor_test - the MzPCD_Pascal panel (MzPcdEditor.pas, built from
// MzPcdEditorForm.lfm), driven offscreen through the real PascalJUCE wrapper, built as an
// effect, which loads MzPCD_pascal_lib.dll from next to the executable (a ctest of the
// PascalJUCE build):
//
//   - renders the panel and compares it with verify/ui/mzpcd_default.png (small per-pixel
//     tolerance for font rasterisation);
//   - the knobs: a drag up or to the right turns one (180 px for the whole turn, as the
//     C++ Knob) in one gesture, the value in a bubble while dragged, double-click for the
//     default, the wheel; PATTERN dragged (4 px a pattern) and wheeled, double-clicked;
//     RATE clicked round 1/16, 1/32, 1/8;
//   - the pattern's picture: the pattern chosen, the step lit while the host plays
//     (through processBlock, with a play head) - dark when it stops - and the push meter
//     beside it, risen on a strike and fallen when stopped;
//   - the latency (the oversampler's 31 samples) and the tail (1.5 s) the host is told;
//   - the audio goes through (stereo and mono, as the C++ isBusesLayoutSupported);
//   - tooltips in the C++ Look's colours, the project link; many editors open and close
//     without leaking a session.
//
// Set PASCALJUCE_UPDATE_UI_REFERENCES=1 to rewrite the reference (after a deliberate change
// to the look; check the new PNG first). MZPCD_SCREENSHOT_DIR set: renders go there.
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

juce::File referenceDir() { return juce::File(MZPCD_VERIFY_DIR).getChildFile("ui"); }

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
    const auto dir = juce::SystemStats::getEnvironmentVariable("MZPCD_SCREENSHOT_DIR", {});
    if (dir.isEmpty())
        return;
    const auto file = juce::File(dir).getChildFile(name + ".png");
    file.deleteFile();
    juce::FileOutputStream out(file);
    juce::PNGImageFormat().writeImageToStream(image, out);
}

// The panel's layout (MzPcdEditorForm.lfm: the C++ MzPcdEditor::resized()), in editor
// coordinates.
const juce::Point<float> driveKnob { 318 + 27, 86 + 12 + 27 };        // DRIVE: 54 x 76, its slider under 12 px
const juce::Rectangle<int> driveBounds { 318, 86, 54, 76 };
const juce::Point<float> levelKnob { 880 + 28, 86 + 12 + 28 };
const juce::Point<float> patternNumber { 28 + 22, 94 + 16 };
const juce::Point<float> ratePad { 252 + 27, 82 + 30 };
const juce::Point<float> display { 80 + 60, 80 + 39 };
const juce::Point<float> projectLink { 850, 18 + 14 };
const juce::Point<float> away { 5, 180 };

// The pattern parameter (1 to 32) as the host holds it, 0 to 1.
float patternValue(float number) { return (number - 1.0f) / 31.0f; }

// The middle of a step's bar, near its foot: the display's inside is 154 x 68 from (85, 85),
// the bars 141 of it, the push meter the last 8.
juce::Point<int> barFoot(int step) { return { 85 + (int) (8.8125f * (float) step + 4.40625f), 85 + 68 - 2 }; }
const int barTop = 88;
const int meterX = 235;

// The step playing is drawn in ledRed.brighter(0.3) - (255, 104, 85) - the others in
// ledRed at 50 or 75% over the dark display.
bool isLitBar(juce::Colour c) { return c.getRed() > 230 && c.getGreen() > 85 && c.getBlue() > 65; }
bool isBar(juce::Colour c) { return c.getRed() > 120 && c.getGreen() < 70; }
// The push meter's fill: the pointer's orange (239, 125, 34); empty, black.
bool isPush(juce::Colour c) { return c.getRed() > 200 && c.getGreen() > 90 && c.getGreen() < 160 && c.getBlue() < 80; }
bool isBlack(juce::Colour c) { return c.getRed() < 20 && c.getGreen() < 20 && c.getBlue() < 20; }
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
        pump();
        auto* pattern = find(p, "Pattern");
        auto* rate = find(p, "Rate");
        auto* drive = find(p, "Drive");
        auto* shape = find(p, "Shape");
        auto* tone = find(p, "Tone");
        auto* level = find(p, "Level");
        check(pattern && rate && drive && shape && tone && level && p.getParameters().size() == 12,
              "MzPCD library loaded next to the executable, its 12 parameters");
        if (! (pattern && rate && drive && shape && tone && level)) return 1;
        GestureCounter gestures;
        for (auto* param : p.getParameters())
            param->addListener(&gestures);

        std::printf("Latency, tail, buses and audio\n");
        {
            check(p.getLatencySamples() == 31, "the host is told the oversampler's delay: "
                                                   + juce::String(p.getLatencySamples()) + " samples");
            check(std::abs(p.getTailLengthSeconds() - 1.5) < 1.0e-9, "and a tail of 1.5 s, the feedback ringing on");
            using Set = juce::AudioChannelSet;
            auto layout = [] (Set in, Set out) { juce::AudioProcessor::BusesLayout l; l.inputBuses.add(in); l.outputBuses.add(out); return l; };
            check(p.checkBusesLayoutSupported(layout(Set::stereo(), Set::stereo()))
                      && p.checkBusesLayoutSupported(layout(Set::mono(), Set::mono()))
                      && ! p.checkBusesLayoutSupported(layout(Set::mono(), Set::stereo()))
                      && ! p.checkBusesLayoutSupported(layout(Set::create5point1(), Set::create5point1())),
                  "stereo or mono, in = out (the C++ isBusesLayoutSupported)");
            float peak = 0.0f;
            for (int i = 0; i < 20; ++i) peak = std::max(peak, block(p, head));
            check(peak > 0.05f && peak < 2.0f, "a sine goes through, distorted (peak " + juce::String(peak, 3) + ")");
        }

        std::printf("Rendering\n");
        pattern->setValueNotifyingHost(patternValue(9.0f));   // as the C++ screenshot
        pump();
        EditorPtr editor(p.createEditorAndMakeActive());
        check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
              "custom Pascal panel created");
        if (editor == nullptr) return 1;
        check(editor->getWidth() == 966 && editor->getHeight() == 186,
              "the C++ editor's size: " + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()));
        check(! editor->isResizable(), "a fixed size, as the C++ editor");
        pump(150);
        compareWithReference(render(*editor), "mzpcd_default");
        screenshot(render(*editor), "mzpcd_100");

        std::printf("Tooltips, the project link\n");
        {
            auto& look = editor->getLookAndFeel();
            check(look.findColour(juce::TooltipWindow::backgroundColourId) == juce::Colour(0xff111214)
                      && look.findColour(juce::TooltipWindow::textColourId) == juce::Colour(0xffe9e9e6)
                      && look.findColour(juce::TooltipWindow::outlineColourId) == juce::Colour(0xffd8321f),
                  "tooltips in the C++ Look's colours (dark, red outline)");
            hover(*editor, driveKnob);
            check(tooltip(*editor).startsWith("DRIVE\nHow hard the sound is driven"), "a knob's hint: " + tooltip(*editor).replace("\n", " | "));
            hover(*editor, { 558 + 27, 86 + 12 + 27 });
            check(tooltip(*editor).startsWith("PATTERN DRIVE\nHow far a full-level step pushes the drive"), "a push's hint");
            hover(*editor, patternNumber);
            check(tooltip(*editor).startsWith("PATTERN\nWhich of the 32 patterns plays the distortion"), "PATTERN's hint");
            hover(*editor, ratePad);
            check(tooltip(*editor).startsWith("RATE\nHow long a step is"), "RATE's hint");
            hover(*editor, display);
            check(tooltip(*editor).startsWith("The pattern: on each step it pushes the drive"), "the picture's hint");
            hover(*editor, projectLink);
            check(tooltip(*editor).contains("project's page"), "the project line has the C++ hint");
            const int opened = pascaljuce_test_opened_url_count();
            click(*editor, projectLink);
            pump(50);
            check(pascaljuce_test_opened_url_count() == opened + 1
                      && pascaljuce_test_opened_url(opened) == "https://github.com/simozzer/MzPCD",
                  "a click on it opens the project's page (in tests: recorded, no browser)");
            hover(*editor, away);
            pump(50);
        }

        std::printf("Knobs\n");
        {
            const float before = drive->getValue();
            drag(*editor, driveKnob, driveKnob - juce::Point<float>(0, 45));
            pump();
            check(std::abs(drive->getValue() - (before + 0.25f)) < 0.01f,
                  "45 px up turns DRIVE a quarter (180 px for the whole turn) (" + juce::String(before, 3) + " -> "
                      + juce::String(drive->getValue(), 3) + ")");
            check(gestures.begins == 1 && gestures.ends == 1 && shape->getValue() == shape->getDefaultValue(),
                  "one gesture, nothing else moved");
            const float mid = drive->getValue();
            drag(*editor, driveKnob, driveKnob - juce::Point<float>(36, 0));
            pump();
            check(std::abs(drive->getValue() - (mid - 0.2f)) < 0.01f,
                  "36 px to the left turns it back a fifth (RotaryHorizontalVerticalDrag)");
            doubleClick(*editor, driveKnob);
            pump();
            check(std::abs(drive->getValue() - drive->getDefaultValue()) < 1.0e-4f && drive->getCurrentValueAsText() == "70",
                  "double-click restores the default: " + drive->getCurrentValueAsText());
            wheel(*editor, driveKnob, 1.0f);
            pump();
            check(std::abs(drive->getValue() - (drive->getDefaultValue() + 0.15f)) < 1.0e-3f, "the wheel: 0.15 a step, as JUCE's slider");
            doubleClick(*editor, driveKnob);
            pump();

            // the value in a bubble while dragging, as the C++ popup display
            const auto bubbleArea = driveBounds.expanded(40, 20).getIntersection({ 0, 0, 966, 186 });
            hover(*editor, away);
            pump(80);
            const auto plain = render(*editor);
            editor->mouseDown(mouseEvent(*editor, driveKnob, left, 1, driveKnob));
            pump(80);
            const auto bubbled = render(*editor);
            check(differingPixels(plain, bubbled, bubbleArea) > 100,
                  "dragging shows the value in a bubble (" + juce::String(differingPixels(plain, bubbled, bubbleArea))
                      + " pixels)");
            screenshot(bubbled, "mzpcd_bubble");
            editor->mouseUp(mouseEvent(*editor, driveKnob, juce::ModifierKeys(), 1, driveKnob));
            hover(*editor, away);
            pump(80);

            drag(*editor, levelKnob, levelKnob - juce::Point<float>(0, 18));
            pump();
            check(level->getCurrentValueAsText() == "+3.6 dB", "LEVEL reads in dB: " + level->getCurrentValueAsText());
            doubleClick(*editor, levelKnob);
            pump();
            check(level->getCurrentValueAsText() == "0.0 dB", "and back to 0.0 dB");
            check(tone->getCurrentValueAsText() == "2.4 kHz", "TONE reads in Hz: " + tone->getCurrentValueAsText());
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        std::printf("PATTERN and RATE\n");
        {
            auto patternNow = [&] { return juce::roundToInt(1.0f + 31.0f * pattern->getValue()); };
            check(patternNow() == 9, "PATTERN shows 9");
            drag(*editor, patternNumber, patternNumber - juce::Point<float>(0, 21));
            pump();
            check(patternNow() == 14, "21 px up: five patterns on (four pixels each), " + juce::String(patternNow()));
            drag(*editor, patternNumber, patternNumber + juce::Point<float>(0, 400));
            pump();
            check(patternNow() == 1, "and down as far as it goes: 1");
            wheel(*editor, patternNumber, 0.25f);
            pump();
            check(patternNow() == 3, "the wheel: eight patterns a unit, " + juce::String(patternNow()));
            doubleClick(*editor, patternNumber);
            pump();
            check(patternNow() == 1, "double-click: the default, 1");
            pattern->setValueNotifyingHost(patternValue(9.0f));
            pump();

            check(rate->getCurrentValueAsText() == "1/16", "RATE: 1/16");
            const auto sixteenth = render(*editor);
            click(*editor, ratePad);
            pump();
            check(rate->getCurrentValueAsText() == "1/32", "a click: 1/32");
            check(differingPixels(sixteenth, render(*editor), { 252, 82, 54, 46 }) > 10, "and the pad says so");
            screenshot(render(*editor), "mzpcd_rate");
            click(*editor, ratePad);
            pump();
            check(rate->getCurrentValueAsText() == "1/8", "another: 1/8");
            click(*editor, ratePad);
            pump();
            check(rate->getCurrentValueAsText() == "1/16", "and round to 1/16 again");
            check(gestures.begins == gestures.ends, "gestures balanced (" + juce::String(gestures.begins) + ")");
        }

        std::printf("The pattern, the step playing and the push\n");
        {
            const auto img = render(*editor);
            // pattern 9 is fc84fc84...: a full bar on step 0, a quarter of one on step 3
            check(isBar(img.getPixelAt(barFoot(0).x, barTop)) && ! isBar(img.getPixelAt(barFoot(3).x, 110))
                      && isBar(img.getPixelAt(barFoot(3).x, barFoot(3).y)),
                  "pattern 9 drawn: bars as tall as the steps' levels");
            bool anyLit = false;
            for (int s = 0; s < 16; ++s) anyLit = anyLit || isLitBar(img.getPixelAt(barFoot(s).x, barFoot(s).y));
            check(! anyLit, "stopped: no step lit");
            check(isBlack(img.getPixelAt(meterX, 150)) && isBlack(img.getPixelAt(meterX, 90)), "and the push meter empty");

            head.playing = true;
            head.ppq = 1.25;         // the top of the sixth sixteenth: step 5
            head.bpm = 120.0;
            block(p, head);
            pump(120);
            auto lit = render(*editor);
            screenshot(lit, "mzpcd_playing");
            int litStep = -1, litCount = 0;
            for (int s = 0; s < 16; ++s)
                if (isLitBar(lit.getPixelAt(barFoot(s).x, barFoot(s).y))) { litStep = s; ++litCount; }
            check(litCount == 1 && litStep == 5, "playing: the step struck is lit (" + juce::String(litStep) + ")");

            head.ppq = 0.0;          // a loop back to the bar: step 0, full
            block(p, head);
            pump(120);
            lit = render(*editor);
            check(isLitBar(lit.getPixelAt(barFoot(0).x, barFoot(0).y)), "a loop back to the bar lights step 0");
            check(isPush(lit.getPixelAt(meterX, 150)) && isPush(lit.getPixelAt(meterX, 100)) && isBlack(lit.getPixelAt(meterX, 87)),
                  "the push meter risen on its strike, most of the way");
            screenshot(lit, "mzpcd_push");

            head.playing = false;
            for (int i = 0; i < 30; ++i) block(p, head);   // a third of a second: the push gone
            pump(120);
            lit = render(*editor);
            anyLit = false;
            for (int s = 0; s < 16; ++s) anyLit = anyLit || isLitBar(lit.getPixelAt(barFoot(s).x, barFoot(s).y));
            check(! anyLit, "stopped again: dark");
            check(isBlack(lit.getPixelAt(meterX, 150)), "and the push fallen away");

            pattern->setValueNotifyingHost(patternValue(3.0f));   // every step full
            pump(120);
            const auto three = render(*editor);
            int full = 0;
            for (int s = 0; s < 16; ++s) full += isBar(three.getPixelAt(barFoot(s).x, barTop)) ? 1 : 0;
            check(full == 16, "pattern 3 (every step): sixteen full bars");
            pattern->setValueNotifyingHost(patternValue(9.0f));
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
            for (int i = 0; i < 30; ++i) block(p, head);
            pump(120);
            compareWithReference(render(*editor), "mzpcd_default"); // as it opened
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
