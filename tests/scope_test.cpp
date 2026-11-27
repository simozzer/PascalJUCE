/*
    scope_test - the Scope example (examples/plugins/Scope), its window
    rendered offscreen.

    Links the real wrapper, configured as Scope (an effect), and loads
    Scope_pascal.dll from next to the executable:
      - the audio passes through unchanged; there are no parameters;
      - with a sine playing, the window shows it as a trace;
      - TIME and TRIGGER, changed with the mouse, are saved with the state
        and come back in a new instance (and its window);
      - damaged state is ignored.
    Writes scope_window.png to the working directory, to look at.
*/
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>
#include "pascaljuce_state.h"

#include <cmath>
#include <cstdio>
#include <cstring>

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter();

namespace
{
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

void pump(int ms)
{
    juce::MessageManager::getInstance()->runDispatchLoopUntil(ms);
}

juce::Image render(juce::Component& c)
{
    juce::Image image(juce::Image::ARGB, c.getWidth(), c.getHeight(), true, juce::SoftwareImageType());
    juce::Graphics g(image);
    c.paintEntireComponent(g, true);
    return image;
}

// Pixels of the trace (the default theme's accent, $F0A030) inside the scope's screen.
int tracePixels(const juce::Image& image)
{
    int n = 0;
    for (int y = 40; y < 340; ++y)
        for (int x = 20; x < 525; ++x)
        {
            const auto c = image.getPixelAt(x, y);
            if (std::abs(c.getRed() - 0xF0) < 30 && std::abs(c.getGreen() - 0xA0) < 30 && std::abs(c.getBlue() - 0x30) < 40)
                ++n;
        }
    return n;
}

juce::MouseEvent mouseEvent(juce::Component& c, juce::Point<float> pos, juce::ModifierKeys mods, juce::Point<float> downAt)
{
    const auto now = juce::Time::getCurrentTime();
    return juce::MouseEvent(juce::Desktop::getInstance().getMainMouseSource(), pos, mods,
                            juce::MouseInputSource::defaultPressure, 0.0f, 0.0f, 0.0f, 0.0f, &c, &c, now, downAt, now, 1,
                            false);
}

void drag(juce::Component& c, juce::Point<float> from, juce::Point<float> to)
{
    const juce::ModifierKeys left { juce::ModifierKeys::leftButtonModifier };
    c.mouseDown(mouseEvent(c, from, left, from));
    c.mouseDrag(mouseEvent(c, (from + to) * 0.5f, left, from));
    c.mouseDrag(mouseEvent(c, to, left, from));
    c.mouseUp(mouseEvent(c, to, juce::ModifierKeys(), from));
}

std::unique_ptr<juce::AudioProcessor> make()
{
    std::unique_ptr<juce::AudioProcessor> p(createPluginFilter());
    p->setPlayConfigDetails(2, 2, 48000.0, 512);
    p->prepareToPlay(48000.0, 512);
    return p;
}

// A 375 Hz sine (period 128 samples), the same in both channels.
void fill(juce::AudioBuffer<float>& b)
{
    for (int ch = 0; ch < b.getNumChannels(); ++ch)
        for (int s = 0; s < b.getNumSamples(); ++s)
            b.setSample(ch, s, 0.8f * std::sin(juce::MathConstants<float>::twoPi * (float) s / 128.0f));
}

// The plug-in's own bytes in the wrapper's state (pascaljuce_state.h): version 1,
// TIME as a little-endian float, the trigger.
bool readState(const juce::MemoryBlock& state, float& timeMs, int& trigger)
{
    pascaljuce::state::Decoded d;
    if (! pascaljuce::state::decode(state.getData(), state.getSize(), 64, 1024, d) || ! d.hasCustom
        || d.custom.size() != 6 || d.custom[0] != 1)
        return false;
    std::memcpy(&timeMs, d.custom.data() + 1, sizeof(float));
    trigger = d.custom[5];
    return true;
}

// A state carrying these bytes as the plug-in's own.
void loadCustom(juce::AudioProcessor& p, const std::vector<uint8_t>& bytes)
{
    const auto blob = pascaljuce::state::encode({}, bytes.data(), bytes.size());
    p.setStateInformation(blob.data(), (int) blob.size());
}
} // namespace

int main()
{
    juce::ScopedJuceInitialiser_GUI juceInit;
    {
        auto scope = make();
        check(scope->getParameters().isEmpty(), "Scope library loaded; no parameters (TIME and TRIGGER are the view's)");

        juce::AudioBuffer<float> buffer(2, 512), expect(2, 512);
        juce::MidiBuffer midi;
        fill(buffer);
        fill(expect);
        scope->processBlock(buffer, midi);
        bool same = true;
        for (int ch = 0; ch < 2; ++ch)
            for (int s = 0; s < 512; ++s)
                same = same && buffer.getSample(ch, s) == expect.getSample(ch, s);
        check(same, "the audio passes through unchanged");

        float timeMs = 0;
        int trigger = -1;
        juce::MemoryBlock state;
        scope->getStateInformation(state);
        check(readState(state, timeMs, trigger) && std::abs(timeMs - 20.0f) < 1.0e-4f && trigger == 0,
              "defaults saved: 20 ms, rising trigger");

        EditorPtr view(scope->createEditorAndMakeActive());
        check(view != nullptr && view->getWidth() == 640 && view->getHeight() == 360, "window 640 x 360");
        if (view == nullptr)
            return 1;
        pump(100);
        check(tracePixels(render(*view)) < 600, "no audio yet: a flat line");
        for (int i = 0; i < 8; ++i)
        {
            fill(buffer);
            scope->processBlock(buffer, midi);
        }
        pump(300);
        const auto shot = render(*view);
        const juce::File png = juce::File::getCurrentWorkingDirectory().getChildFile("scope_window.png");
        png.deleteFile();
        {
            juce::FileOutputStream out(png);
            juce::PNGImageFormat().writeImageToStream(shot, out);
        }
        check(tracePixels(shot) > 1500, "a sine playing: the trace (" + juce::String(tracePixels(shot)) + " px)");

        // TIME up (drag the knob upwards), TRIGGER to Free (drag the switch to its top)
        drag(*view, { 582.0f, 100.0f }, { 582.0f, 20.0f });
        drag(*view, { 560.0f, 270.0f }, { 560.0f, 175.0f });
        pump(100);
        scope->getStateInformation(state);
        const bool readBack = readState(state, timeMs, trigger);
        check(readBack && timeMs > 40.0f && timeMs <= 170.0f,
              "TIME turned up is saved (" + juce::String(timeMs, 1) + " ms)");
        check(trigger == 2, "TRIGGER moved to Free is saved (" + juce::String(trigger) + ")");
        view.reset();

        // a new instance (a project reopened): the view comes back
        auto reopened = make();
        reopened->setStateInformation(state.getData(), (int) state.getSize());
        juce::MemoryBlock again;
        float time2 = 0;
        int trigger2 = -1;
        reopened->getStateInformation(again);
        check(readState(again, time2, trigger2) && time2 == timeMs && trigger2 == trigger,
              "a new instance restores TIME and TRIGGER");
        EditorPtr view2(reopened->createEditorAndMakeActive());
        pump(100);
        check(view2 != nullptr, "and its window opens with them");
        view2.reset();

        // damaged state: ignored, the view kept
        loadCustom(*reopened, { 1, 0xff, 0xff, 0xff, 0xff, 0 }); // NaN time
        loadCustom(*reopened, { 1, 0, 0, 0xa0, 0x41, 7 });       // 20 ms, trigger 7
        loadCustom(*reopened, { 9, 0, 0, 0xa0, 0x41, 0 });       // another version
        loadCustom(*reopened, { 1, 0, 0 });                      // too short
        loadCustom(*reopened, { 1, 0, 0, 0, 0x3f, 0 });          // 0.5 ms: too short a time
        reopened->getStateInformation(again);
        check(readState(again, time2, trigger2) && time2 == timeMs && trigger2 == trigger,
              "NaN time, a bad trigger, another version, a short block, a tiny time: all ignored");
        loadCustom(*reopened, { 1, 0, 0, 0xa0, 0x41, 1 });       // 20 ms, falling: fine
        reopened->getStateInformation(again);
        check(readState(again, time2, trigger2) && time2 == 20.0f && trigger2 == 1, "a valid state is taken");

        scope->releaseResources();
        reopened->releaseResources();
    }
    std::printf(failures == 0 ? "All checks passed\n" : "%d check(s) FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
