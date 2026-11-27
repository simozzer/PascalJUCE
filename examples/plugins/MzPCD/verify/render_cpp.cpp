// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Equivalence harness, C++ side: renders scenarios.txt through the ORIGINAL engine,
// compiled straight from the MzPCD repository's Source/PCD and the MzPCF repository's
// Source/PCF, as MzPCD's own build compiles them (see build_verify.cmd). render_pas.dpr
// renders the same scenarios through the Pascal port; the two outputs must be the same,
// bit for bit.
//
//     render_cpp <scenarios.txt> <outdir>
//
// The scenario language is described at the top of scenarios.txt. The parameters are read
// into Settings as the C++ params::Reader does it (the pattern 1..32 less one, the rate
// rounded), and the host's timeline is given to the engine at the top of every block, as
// PluginProcessor::processBlock does.

#define _CRT_SECURE_NO_WARNINGS

#include "Pcd.h"
#include "RebirthDist.h"

#include <xmmintrin.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <locale>
#include <sstream>
#include <string>
#include <vector>

using namespace pcd;

namespace
{

// juce::roundToInt
int roundToInt(double v)
{
    union { int asInt[2]; double asDouble; } n;
    n.asDouble = v + 6755399441055744.0;
    return n.asInt[0];
}

bool setField(Settings& s, const std::string& id, double v)
{
    const float f = (float) v;
    if (id == "pattern")             s.pattern = roundToInt(f) - 1;
    else if (id == "rate")           s.rate = roundToInt(f);
    else if (id == "drive")          s.drive = f;
    else if (id == "shape")          s.shape = f;
    else if (id == "tone")           s.tone = f;
    else if (id == "feedback")       s.feedback = f;
    else if (id == "driveAmount")    s.driveAmount = f;
    else if (id == "toneAmount")     s.toneAmount = f;
    else if (id == "feedbackAmount") s.feedbackAmount = f;
    else if (id == "decay")          s.decay = f;
    else if (id == "mix")            s.mix = f;
    else if (id == "level")          s.level = f;
    else return false;
    return true;
}

double number(const std::string& s)
{
    if (s == "nan") return std::nan("");
    if (s == "inf") return HUGE_VAL;
    if (s == "-inf") return -HUGE_VAL;
    return std::stod(s);
}

float fromBits(uint32_t b)
{
    float f;
    std::memcpy(&f, &b, sizeof f);
    return f;
}

// What goes into the effect: one generator a channel.
struct Source
{
    std::string kind = "saw";
    float inc = 0.0f, phase = 0.0f, value = 0.0f, gain = 1.0f;
    uint32_t state = 0x2545F491u;
    int period = 1, count = 0;
    bool negative = false;

    void start(const std::string& k, double arg, double rate, int channel)
    {
        kind = k;
        phase = channel == 0 ? 0.0f : 0.5f;
        state = channel == 0 ? 0x2545F491u : 0x9E3779B9u;
        count = 0;
        negative = false;
        if (kind == "saw") inc = (float) (arg * (channel == 0 ? 1.0 : 1.5) / rate);
        else if (kind == "impulse") period = arg >= 1.0 ? (int) arg : 1;
        else if (kind == "dc") value = (float) arg;
    }

    float next()
    {
        float x = 0.0f;
        if (kind == "saw")
        {
            x = 2.0f * phase - 1.0f;
            phase += inc;
            if (phase >= 1.0f) phase -= 1.0f;
        }
        else if (kind == "noise")
        {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            x = (float) (int32_t) state * (1.0f / 2147483648.0f);
        }
        else if (kind == "impulse")
        {
            x = count == 0 ? 1.0f : 0.0f;
            if (++count >= period) count = 0;
        }
        else if (kind == "dc") x = value;
        else if (kind == "tiny")
        {
            // a denormal, alternating in sign
            x = fromBits(negative ? 0x800AE398u : 0x000AE398u);
            negative = ! negative;
            return x;
        }
        return x * gain;
    }
};

void setFtz(bool on)
{
    const unsigned int bits = 0x8040;   // FTZ | DAZ, as juce::ScopedNoDenormals sets them
    _mm_setcsr(on ? (_mm_getcsr() | bits) : (_mm_getcsr() & ~bits));
}

// juce::String (double, places): an ostream, fixed, in the classic locale.
std::string fixed(double v, int places)
{
    std::ostringstream o;
    o.imbue(std::locale::classic());
    o.setf(std::ios_base::fixed);
    o.precision(places);
    o << v;
    return o.str();
}

// Params.cpp's text(), unit by unit, as the parameter shows a value.
enum class Unit { Plain, Percent, Decibels, Drive, Push, Tone, Bipolar, Decay };

std::string text(Unit unit, float v)
{
    switch (unit)
    {
        case Unit::Decibels: return (v > 0.0f ? "+" : "") + fixed(v, 1) + " dB";
        case Unit::Percent:  return std::to_string(roundToInt(v * 100.0f)) + "%";
        case Unit::Drive:    return std::to_string(roundToInt(v * 127.0f));
        case Unit::Push:     return "+" + std::to_string(roundToInt(v * 127.0f));
        case Unit::Tone:
        {
            const double hz = 500.0 * std::pow(24.0, (double) v);
            return hz < 1000.0 ? std::to_string(roundToInt(hz)) + " Hz" : fixed(hz / 1000.0, 1) + " kHz";
        }
        case Unit::Bipolar:
        {
            const int p = roundToInt(v * 100.0f);
            return (p > 0 ? "+" : "") + std::to_string(p);
        }
        case Unit::Decay:
        {
            const double s = 0.015 * std::pow(100.0, (double) v);
            return s < 1.0 ? std::to_string(roundToInt(s * 1000.0)) + " ms" : fixed(s, 2) + " s";
        }
        default: return std::to_string(roundToInt(v * 100.0f));
    }
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: render_cpp <scenarios.txt> <outdir>\n");
        return 2;
    }

    std::ifstream script(argv[1]);
    const std::string outDir = argv[2];
    std::string line;

    Pcd* e = nullptr;
    Settings pending;
    std::string name;
    double rate = 48000.0;
    bool mono = false;
    bool playing = false;
    double ppq = 0.0, bpm = 120.0;
    Source src[2];
    std::vector<float> out, left, right;
    double totalRendered = 0, totalSeconds = 0;
    int lineNo = 0, scenarios = 0;

    setFtz(true);

    auto block = [&] (int n)
    {
        left.assign((size_t) n, 0.0f);
        right.assign((size_t) n, 0.0f);
        for (int i = 0; i < n; ++i)
        {
            left[(size_t) i] = src[0].next();
            right[(size_t) i] = src[1].next();
        }
        const auto t0 = std::chrono::steady_clock::now();
        e->setHostClock(playing, ppq, bpm);
        e->process(left.data(), mono ? nullptr : right.data(), n);
        totalSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        totalRendered += n / rate;
        if (playing) ppq += n * bpm / (60.0 * rate);
        out.insert(out.end(), left.begin(), left.end());
        if (! mono) out.insert(out.end(), right.begin(), right.end());
        out.push_back((float) e->step());
        out.push_back(e->envelope());
    };

    auto render = [&] (int samples, int blockSize)
    {
        if (blockSize <= 0) blockSize = samples;
        for (int done = 0; done < samples; )
        {
            const int n = std::min(blockSize, samples - done);
            block(n);
            done += n;
        }
    };

    auto pushDouble = [&] (double d)
    {
        // a double, as two floats of its bits
        uint64_t b;
        std::memcpy(&b, &d, 8);
        out.push_back(fromBits((uint32_t) b));
        out.push_back(fromBits((uint32_t) (b >> 32)));
    };

    while (std::getline(script, line))
    {
        ++lineNo;
        std::istringstream ls(line);
        std::string cmd;
        if (! (ls >> cmd) || cmd[0] == '#') continue;

        if (cmd == "scenario")
        {
            std::string r, m;
            ls >> name >> r >> m;
            rate = number(r);
            mono = m == "mono";
            delete e;
            e = new Pcd();
            e->prepare(rate);
            pending = Settings();
            e->setSettings(pending);
            playing = false;
            ppq = 0.0;
            bpm = 120.0;
            for (int c = 0; c < 2; ++c) src[c] = Source(), src[c].start("saw", 110.0, rate, c);
            out.clear();
        }
        else if (cmd == "set")
        {
            std::string id, v;
            ls >> id >> v;
            if (! setField(pending, id, number(v))) { std::fprintf(stderr, "line %d: unknown id %s\n", lineNo, id.c_str()); return 1; }
        }
        else if (cmd == "apply") e->setSettings(pending);
        else if (cmd == "input")
        {
            std::string kind, a;
            ls >> kind >> a;
            const double arg = a.empty() ? 0.0 : number(a);
            for (int c = 0; c < 2; ++c) src[c].start(kind, arg, rate, c);
        }
        else if (cmd == "gain")
        {
            std::string g;
            ls >> g;
            src[0].gain = src[1].gain = (float) number(g);
        }
        else if (cmd == "transport")
        {
            std::string p, q, b;
            ls >> p >> q >> b;
            playing = p == "1";
            ppq = number(q);
            bpm = number(b);
        }
        else if (cmd == "tempo") { std::string b; ls >> b; bpm = number(b); }
        else if (cmd == "seek") { std::string q; ls >> q; ppq = number(q); }
        else if (cmd == "notimeline") { playing = false; ppq = 0.0; bpm = 120.0; }
        else if (cmd == "render")
        {
            int samples = 0, blockSize = 0;
            ls >> samples >> blockSize;
            render(samples, blockSize);
        }
        else if (cmd == "sweep")
        {
            std::string id, f, t;
            int samples = 0, blockSize = 0;
            ls >> id >> f >> t >> samples >> blockSize;
            const double from = number(f), to = number(t);
            const int blocks = (samples + blockSize - 1) / blockSize;
            for (int k = 0, done = 0; k < blocks; ++k)
            {
                const double v = blocks > 1 ? from + (to - from) * (double) k / (double) (blocks - 1) : to;
                setField(pending, id, v);
                e->setSettings(pending);
                const int n = std::min(blockSize, samples - done);
                block(n);
                done += n;
            }
        }
        else if (cmd == "prepare")
        {
            std::string r;
            ls >> r;
            rate = number(r);
            e->prepare(rate);
        }
        else if (cmd == "reset") e->reset();
        else if (cmd == "ftz")
        {
            int on = 1;
            ls >> on;
            setFtz(on != 0);
        }
        else if (cmd == "latency")
        {
            out.push_back((float) Pcd::latency());
            for (double hz = 100.0; hz < 20000.0; hz *= 1.37) pushDouble(Pcd::howlFrequency(hz));
        }
        else if (cmd == "tables")
        {
            // ReBirth's tables, and every function of them, through its whole range and past it
            const auto& t = rbdist::Tables::get();
            out.insert(out.end(), t.level, t.level + 128);
            for (int r = 0; r < 32; ++r) out.insert(out.end(), t.shaper[r], t.shaper[r] + 256);
            for (int k = -8; k <= 520; ++k)
            {
                const double a = k * 0.25 + (k % 3) * 0.0123;
                pushDouble(rbdist::level(a));
                pushDouble(rbdist::inGain(a));
                pushDouble(rbdist::clipGain(a));
                pushDouble(rbdist::clipThreshold(a));
                for (int s = -2; s <= 130; s += 3)
                    pushDouble(rbdist::outGain(s, a));
            }
            for (int s = -3; s <= 131; ++s)
            {
                const float* row = rbdist::row(s);
                for (int k = -20; k <= 280; ++k)
                    pushDouble(rbdist::shape(row, k * 0.93 + 0.01));
            }
        }
        else if (cmd == "oversampler")
        {
            // the oversampler alone, up and down, on the left channel's source
            int samples = 0;
            ls >> samples;
            Oversampler os;
            for (int i = 0; i < samples; ++i)
            {
                double a, b;
                os.upsample((double) src[0].next(), a, b);
                pushDouble(a);
                pushDouble(b);
                pushDouble(os.downsample(a, b * 0.5 - a * 0.25));
            }
        }
        else if (cmd == "rbdist")
        {
            // ReBirth's own unit (rbdist::Distortion), its knobs in whole steps, on the left source
            int amount = 0, shapeKnob = 0, samples = 0, blockSize = 0;
            std::string r;
            ls >> amount >> shapeKnob >> samples >> blockSize >> r;
            rbdist::Distortion d;
            d.prepare(number(r));
            for (int done = 0; done < samples; )
            {
                const int n = std::min(blockSize, samples - done);
                left.assign((size_t) n, 0.0f);
                for (int i = 0; i < n; ++i) left[(size_t) i] = src[0].next();
                d.process(left.data(), n, amount, shapeKnob);
                out.insert(out.end(), left.begin(), left.end());
                done += n;
                amount += 7;   // and the knobs moved between blocks, as far as past their ends
                shapeKnob += 5;
                if (amount > 140) amount = -9;
                if (shapeKnob > 140) shapeKnob = -6;
            }
        }
        else if (cmd == "texts")
        {
            // every knob's value text (Params.cpp), across its range, as the character codes
            static const Unit units[] = { Unit::Plain, Unit::Percent, Unit::Decibels, Unit::Drive, Unit::Push,
                                          Unit::Tone, Unit::Bipolar, Unit::Decay };
            int steps = 0;
            ls >> steps;
            for (const Unit u : units)
            {
                const float lo = u == Unit::Decibels ? -24.0f : u == Unit::Bipolar ? -1.0f : 0.0f;
                const float hi = u == Unit::Decibels ? 12.0f : 1.0f;
                for (int k = 0; k <= steps; ++k)
                {
                    const float v = lo + (hi - lo) * (float) k / (float) steps;
                    for (const char ch : text(u, v)) out.push_back((float) (unsigned char) ch);
                    out.push_back(-1.0f);
                }
            }
        }
        else if (cmd == "end")
        {
            const std::string path = outDir + "/" + name + ".f32";
            FILE* f = std::fopen(path.c_str(), "wb");
            if (! f) { std::fprintf(stderr, "cannot write %s\n", path.c_str()); return 1; }
            std::fwrite(out.data(), sizeof(float), out.size(), f);
            std::fclose(f);
            ++scenarios;
        }
        else
        {
            std::fprintf(stderr, "line %d: unknown command %s\n", lineNo, cmd.c_str());
            return 1;
        }
    }
    delete e;

    std::printf("C++ engine: %d scenarios, %.1f s of audio rendered in %.3f s (%.0fx realtime)\n",
                scenarios, totalRendered, totalSeconds, totalSeconds > 0 ? totalRendered / totalSeconds : 0.0);
    return 0;
}
