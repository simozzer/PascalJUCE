// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Equivalence harness, C++ side: renders scenarios.txt through the ORIGINAL engine,
// compiled straight from the MzPCF repository's Source/PCF (see build_verify.cmd).
// render_pas.dpr renders the same scenarios through the Pascal port; the two outputs must
// be the same, bit for bit.
//
//     render_cpp <scenarios.txt> <outdir>
//
// The scenario language is described at the top of scenarios.txt. The parameters are read
// into Settings as the C++ params::Reader does it (the pattern 1..32 less one, the mode
// rounded), and the host's timeline is given to the engine at the top of every block, as
// PluginProcessor::processBlock does.

#define _CRT_SECURE_NO_WARNINGS

#include "Pcf.h"

#include <xmmintrin.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace pcf;

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
    if (id == "pattern")     s.pattern = roundToInt(f) - 1;
    else if (id == "freq")   s.freq = f;
    else if (id == "q")      s.q = f;
    else if (id == "amount") s.amount = f;
    else if (id == "decay")  s.decay = f;
    else if (id == "mode")   s.mode = roundToInt(f);
    else if (id == "mix")    s.mix = f;
    else if (id == "level")  s.level = f;
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

// What goes into the filter: one generator a channel.
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

    Pcf* e = nullptr;
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
            e = new Pcf();
            e->prepare(rate);
            pending = Settings();
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
        else if (cmd == "levels")
        {
            for (int p = -2; p <= patterns + 1; ++p)
                for (int s = -40; s <= 40; ++s)
                    out.push_back(level(p, s));
        }
        else if (cmd == "clock")
        {
            // the StepClock alone, as MzPCG and MzPCD run it: every step struck, and where
            std::string p, q, b, r;
            int perQuarter = 4, samples = 0, blockSize = 0;
            ls >> p >> q >> b >> perQuarter >> samples >> blockSize >> r;
            const double clockRate = number(r);
            StepClock clock;
            clock.prepare(clockRate);
            double pos = number(q);
            const double tempo = number(b);
            for (int done = 0; done < samples; )
            {
                const int n = std::min(blockSize, samples - done);
                clock.set(p == "1", pos, tempo, perQuarter);
                out.push_back(clock.isPlaying() ? 1.0f : 0.0f);
                out.push_back((float) clock.samplesPerStep());
                for (int i = 0; i < n; ++i)
                {
                    long long st = 0;
                    if (clock.stepAt(i, st))
                    {
                        out.push_back((float) (done + i));
                        out.push_back((float) st);
                    }
                }
                pos += n * tempo / (60.0 * clockRate);
                done += n;
            }
        }
        else if (cmd == "envelope")
        {
            // the Envelope alone, as MzPCD plays it
            std::string d, l, r;
            int samples = 0, every = 0;
            ls >> d >> l >> samples >> every >> r;
            Envelope env;
            env.prepare(number(r));
            env.setDecay((float) number(d));
            const float lv = (float) number(l);
            for (int i = 0; i < samples; ++i)
            {
                if (every > 0 && i % every == 0) env.strike(lv);
                out.push_back(env.next());
            }
            out.push_back(env.value());
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
