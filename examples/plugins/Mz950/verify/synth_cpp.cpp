// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Equivalence check, C++ side: runs the ORIGINAL Synth.cpp and SynthPatch.cpp (with Disk.cpp)
// through a fixed list of cases and writes one line per result. synth_pas.dpr runs the same
// list through S950Synth / S950SynthPatch and compares the two files line for line.
//
//     synth_cpp <out.txt>
//
// Words and disk images are compared by length and 64-bit FNV-1a hash, doubles by their
// bits. The random cases come from a small LCG both sides share, one draw a statement.

#include "Synth.h"
#include "SynthPatch.h"
#include "Disk.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace s950;
using namespace s950::synth;

namespace
{
    FILE* out = nullptr;

    struct Lcg
    {
        std::uint32_t s;
        std::uint32_t next() { s = s * 1664525u + 1013904223u; return s >> 8; }
        int range (int lo, int hi) { return lo + static_cast<int> (next() % static_cast<std::uint32_t> (hi - lo + 1)); }
    };

    std::string hex64 (std::uint64_t v)
    {
        char b[32];
        std::snprintf (b, sizeof b, "%016llX", static_cast<unsigned long long> (v));
        return b;
    }

    std::string bits (double d)
    {
        std::uint64_t u;
        std::memcpy (&u, &d, 8);
        return hex64 (u);
    }

    struct Fnv
    {
        std::uint64_t h = 14695981039346656037ull;
        void byte (unsigned char b) { h ^= b; h *= 1099511628211ull; }
        void dbl (double d) { std::uint64_t u; std::memcpy (&u, &d, 8); for (int i = 0; i < 8; ++i) byte (static_cast<unsigned char> (u >> (8 * i))); }
        void word (short w) { byte (static_cast<unsigned char> (w & 0xFF)); byte (static_cast<unsigned char> ((w >> 8) & 0xFF)); }
    };

    void line (const std::string& section, const std::string& label, const std::string& payload)
    {
        std::fprintf (out, "%s|%s|%s\n", section.c_str(), label.c_str(), payload.c_str());
    }

    std::string wordsText (const std::vector<short>& w)
    {
        Fnv f;
        for (short v : w) f.word (v);
        std::string s = std::to_string (w.size()) + " " + hex64 (f.h);
        for (std::size_t i = 0; i < 4 && i < w.size(); ++i) s += " " + std::to_string (w[i]);
        return s;
    }

    std::string spectrumText (const Spectrum& sp)
    {
        Fnv f;
        for (int n = 0; n <= sp.harmonics(); ++n) { f.dbl (sp.cos[(std::size_t) n]); f.dbl (sp.sin[(std::size_t) n]); }
        return std::to_string (sp.harmonics()) + " " + hex64 (f.h);
    }

    std::string doublesText (const std::vector<double>& v)
    {
        Fnv f;
        for (double d : v) f.dbl (d);
        return std::to_string (v.size()) + " " + hex64 (f.h);
    }

    std::string imageText (const Disk& d)
    {
        Fnv f;
        for (unsigned char b : d.getImage()) f.byte (b);
        return std::to_string (d.getImage().size()) + " " + hex64 (f.h);
    }

    std::string shapeText (const Harmonic& h)
    {
        Fnv f;
        for (int n = 1; n <= 200; ++n) f.dbl (h (n));
        return hex64 (f.h) + " " + bits (h (1)) + " " + bits (h (7));
    }

    const Disk::Entry* programOf (const Disk& d)
    {
        const Disk::Entry* p = nullptr;
        for (const auto& e : d.getEntries()) if (e.type == 'P') p = &e;
        return p;
    }

    // ------------------------------------------------------------- Synth.h

    struct SweepAt
    {
        int kind; int h;
        Spectrum operator() (double t) const
        {
            switch (kind)
            {
                case 0:  return modulation::pulse (0.5 - 0.4 * t, h);
                case 1:  return modulation::fm (1, 6.0 * t, h);
                case 2:  return modulation::fm (7, 4.0 * t, h);
                case 3:  return modulation::fm2 (1, 4.0 * t, 3, 2.0 * t, h);
                case 4:  return modulation::ring (shapes::saw(), 24, 2 + 1 * t, h);
                case 5:  return modulation::bent (shapes::saw(), 24, 2.0 * t, h);
                case 6:  return modulation::phaseDistort (shapes::saw(), 16, 0.5 - 0.40 * t, h);
                case 7:  return noise::dusted (shapes::saw(), NoiseColour::pink, 1.2 * t, 404, h);
                default: return modulation::fm (2, 4.0 * t, h);
            }
        }
    };

    void synthChecks()
    {
        // NetRandom
        const int seeds[] = { 0, 1, -1, 2, 42, 101, 12345, -12345, 161803398, -161803398, 161803399,
                              2147483647, -2147483647, (-2147483647 - 1), 1000000007, 7919, 404 };
        for (int seed : seeds)
        {
            NetRandom r (seed);
            Fnv f;
            std::string first;
            for (int i = 0; i < 2000; ++i)
            {
                const double d = r.nextDouble();
                f.dbl (d);
                if (i < 3) first += " " + bits (d);
            }
            line ("rng", std::to_string (seed), hex64 (f.h) + first);
        }

        // netRound
        const double cases[] = { 0.0, -0.0, 0.5, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5, 0.49999999999999994,
                                 -0.49999999999999994, 2.5000000000000004, 1e300, -1e300, 4503599627370495.5,
                                 4503599627370496.5, 2047.5, -2048.5, 2046.5, 0.1, -0.9, 123456.49999 };
        int ci = 0;
        for (double c : cases) line ("netround", std::to_string (ci++), bits (netRound (c)));

        // drums::seed
        const char* names[] = { "", "a", "KICK 1", "SNARE 3", "HAT CLOSED", "RIDE BELL", "CLAVE", "ZZZZZZZZZZZZZZZZZZZZ", "\x7f\x01 x" };
        int ni = 0;
        for (const char* n : names) line ("seed", std::to_string (ni++), std::to_string (drums::seed (n)));

        // shapes
        line ("shape", "saw", shapeText (shapes::saw()));
        line ("shape", "square", shapeText (shapes::square()));
        line ("shape", "triangle", shapeText (shapes::triangle()));
        line ("shape", "sine", shapeText (shapes::sine()));
        line ("shape", "organ", shapeText (shapes::organ()));
        line ("shape", "hollow", shapeText (shapes::hollow()));
        line ("shape", "glass", shapeText (shapes::glass()));
        line ("shape", "buzz", shapeText (shapes::buzz()));
        for (int i = 0; i <= 10; ++i) line ("shape", "pulse" + std::to_string (i), shapeText (shapes::pulse (i / 10.0)));
        line ("shape", "mix", shapeText (shapes::mix (shapes::saw(), shapes::square(), 0.3)));
        line ("shape", "partials", shapeText (shapes::partials ({ 1.0, 0.5, 0.7, 0.25, 0.3, 0.2, 0.45 })));
        line ("shape", "lift", shapeText (shapes::lift (shapes::saw(), 0.55, { 3, 6 })));
        line ("shape", "plus", shapeText (shapes::plus (shapes::triangle(), shapes::organ(), 0.4)));
        line ("shape", "nest", shapeText (shapes::plus (shapes::mix (shapes::hollow(), shapes::glass(), 0.7),
                                                         shapes::lift (shapes::buzz(), -0.2, { 1, 2, 9 }), 1.3)));

        // spectra
        const int h = waveforms::highestHarmonic (20000, RootHz);
        for (int i = 0; i <= 8; ++i)
        {
            const double x = i / 8.0;
            line ("spec", "pulse" + std::to_string (i), spectrumText (modulation::pulse (0.5 - 0.45 * x, h)));
            line ("spec", "fm" + std::to_string (i), spectrumText (modulation::fm (1 + i % 3, 8.0 * x, h)));
            line ("spec", "fm2" + std::to_string (i), spectrumText (modulation::fm2 (1, 4.0 * x, 3, 2.0 * x, h)));
            line ("spec", "ring" + std::to_string (i), spectrumText (modulation::ring (shapes::saw(), 24, 2 + x, h)));
            line ("spec", "bent" + std::to_string (i), spectrumText (modulation::bent (shapes::saw(), 24, 2.5 * x, h)));
            line ("spec", "pd" + std::to_string (i), spectrumText (modulation::phaseDistort (shapes::sine(), 1, 0.5 - 0.44 * x - 0.1, h)));
            line ("spec", "blend" + std::to_string (i), spectrumText (Spectrum::blend (Spectrum::fromShape (shapes::saw(), h),
                                                                                         Spectrum::fromShape (shapes::sine(), 20 + i), x)));
            line ("spec", "limit" + std::to_string (i), spectrumText (Spectrum::fromShape (shapes::square(), h).limitedTo (i * 6)));
        }
        line ("spec", "analyse-big", spectrumText (modulation::fm (2, 3.0, 200)));
        for (int c = 0; c < 3; ++c)
            for (int seed : { 1, 101, 202, 303 })
            {
                const auto colour = static_cast<NoiseColour> (c);
                const std::string l = std::to_string (c) + "/" + std::to_string (seed);
                line ("noise", "spec" + l, spectrumText (noise::spectrum (colour, seed, h)));
                line ("noise", "dust" + l, spectrumText (noise::dusted (shapes::saw(), colour, 0.7, seed, h)));
                for (int points : { 2, 5, 24, 64 })
                    line ("noise", "wander" + l + "/" + std::to_string (points), doublesText (noise::wander (seed, points, colour, 1000 + points)));
            }

        // waveforms
        for (double rate : { 4000.0, 20000.0, 32000.0, 40000.0, 48000.0 })
            for (double hz : { 27.5, RootHz, 440.0, 1000.0, 9999.0, 30000.0 })
                line ("wave", "words " + bits (rate) + " " + bits (hz),
                      std::to_string (waveforms::wordsFor (8, rate, hz)) + " " + std::to_string (waveforms::wordsFor (96, rate, hz))
                      + " " + std::to_string (waveforms::highestHarmonic (rate, hz)));

        const double hz = RootHz;
        line ("wave", "SAW",      wordsText (waveforms::render (shapes::saw(), 40000, hz)));
        line ("wave", "SQUARE",   wordsText (waveforms::render (shapes::square(), 40000, hz)));
        line ("wave", "TRIANGLE", wordsText (waveforms::render (shapes::triangle(), 40000, hz)));
        line ("wave", "SINE",     wordsText (waveforms::render (shapes::sine(), 40000, hz)));
        line ("wave", "ORGAN",    wordsText (waveforms::render (shapes::organ(), 40000, hz)));
        line ("wave", "HOLLOW",   wordsText (waveforms::render (shapes::hollow(), 40000, hz)));
        line ("wave", "GLASS",    wordsText (waveforms::render (shapes::glass(), 40000, hz)));
        line ("wave", "BUZZ",     wordsText (waveforms::render (shapes::buzz(), 40000, hz)));
        line ("wave", "PULSE25",  wordsText (waveforms::render (shapes::pulse (0.25), 40000, hz)));
        line ("wave", "FIFTHS",   wordsText (waveforms::render (shapes::lift (shapes::saw(), 0.55, { 3, 6 }), 40000, hz)));
        line ("wave", "REED",     wordsText (waveforms::render (shapes::partials ({ 1.0, 0.5, 0.7, 0.25, 0.3, 0.2, 0.45 }), 40000, hz)));
        line ("wave", "SAW 32K 440", wordsText (waveforms::render (shapes::saw(), 32000, 440.0)));

        using waveforms::mirror;
        using waveforms::steps;
        line ("wave", "MORPH SS", wordsText (waveforms::render ({ Spectrum::fromShape (shapes::sine(), h), Spectrum::fromShape (shapes::saw(), h) }, 96, 20000, hz)));
        const int counts[] = { 5, 5, 5, 5, 4, 5, 5, 4, 4 };
        const int cyc[]    = { 96, 96, 96, 128, 96, 96, 96, 96, 128 };
        for (int k = 0; k < 9; ++k)
        {
            const SweepAt at { k, h };
            const auto table = mirror (steps (counts[k], at));
            line ("wave", "sweep" + std::to_string (k) + " " + std::to_string (table.size()), wordsText (waveforms::render (table, cyc[k], 20000, hz)));
            const auto two = steps (2, at);
            line ("wave", "two" + std::to_string (k) + " " + std::to_string (mirror (two).size()), wordsText (waveforms::render (mirror (two), 32, 20000, hz)));
        }
        line ("wave", "WHITE", wordsText (waveforms::render ({ noise::spectrum (NoiseColour::white, 101, h) }, 32, 20000, hz)));
        line ("wave", "PINK",  wordsText (waveforms::render ({ noise::spectrum (NoiseColour::pink,  202, h) }, 32, 20000, hz)));
        line ("wave", "BROWN", wordsText (waveforms::render ({ noise::spectrum (NoiseColour::brown, 303, h) }, 32, 20000, hz)));
        {
            Shake drift; drift.pitchDepth = 0.06; drift.colour = NoiseColour::brown; drift.points = 18; drift.seed = 11;
            line ("wave", "DRIFT", wordsText (waveforms::render ({ Spectrum::fromShape (shapes::saw(), h) }, 96, 20000, hz, &drift)));

            Shake grit; grit.amDepth = 0.45; grit.colour = NoiseColour::white; grit.points = 64; grit.seed = 22;
            line ("wave", "GRIT", wordsText (waveforms::render ({ Spectrum::fromShape (shapes::square(), h) }, 96, 20000, hz, &grit)));

            Shake unstable; unstable.pitchDepth = 0.12; unstable.amDepth = 0.35; unstable.colour = NoiseColour::pink; unstable.points = 40; unstable.seed = 33;
            line ("wave", "UNSTABLE", wordsText (waveforms::render (mirror (steps (4, SweepAt { 8, h })), 128, 20000, hz, &unstable)));

            Shake hard; hard.amDepth = 1.8; hard.pitchDepth = 0.3; hard.colour = NoiseColour::brown; hard.points = 3; hard.seed = 44;
            line ("wave", "HARD", wordsText (waveforms::render ({ Spectrum::fromShape (shapes::saw(), h) }, 64, 20000, hz, &hard)));
            Shake none;
            line ("wave", "NONE", wordsText (waveforms::render ({ Spectrum::fromShape (shapes::saw(), h) }, 8, 20000, hz, &none))
                                  + " " + (none.any() ? "1" : "0") + (hard.any() ? "1" : "0"));
        }
        for (int words : { 2, 7, 64, 513, 2000 })
            line ("wave", "HISS " + std::to_string (words), wordsText (waveforms::hiss (words, 12345 + words)));
        line ("wave", "QUANT", wordsText (waveforms::quantise ({ 0.0, 1.0, -1.0, 0.5, -0.5, 0.25 / 2047, 1e-300, -1e300 })));
        line ("wave", "QUANT0", wordsText (waveforms::quantise ({ 0.0, 0.0, -0.0 })));

        // drums
        for (const auto& d : drums::kit())
            line ("drum", d.name, std::to_string (d.key) + " " + std::to_string (d.rate) + " " + bits (d.seconds) + " "
                                + std::to_string (d.loudness) + " " + std::to_string (d.vel) + " " + wordsText (drums::render (d)));
    }

    // -------------------------------------------------------- SynthPatch.h

    std::string planText (const MixPlan& p)
    {
        std::string s = std::to_string (p.rate) + " " + std::to_string (p.words) + " " + std::to_string (p.rootCycles) + " o";
        for (int v : p.oscs) s += " " + std::to_string (v);
        s += " c";
        for (int v : p.cycles) s += " " + std::to_string (v);
        s += " t";
        for (int v : p.sweepTrips) s += " " + std::to_string (v);
        s += " e";
        for (double v : p.errorCents) s += " " + bits (v);
        return s;
    }

    void randomOsc (Lcg& t, OscSettings& o, int onPercent)
    {
        const bool on = t.range (0, 99) < onPercent;
        const int kind = t.range (1, 19);
        o.kind = on ? static_cast<OscKind> (kind) : OscKind::off;
        o.level = t.range (-5, 105);
        o.octave = t.range (-2, 2);
        o.fine = t.range (-60, 60);
        o.phase = t.range (0, 99);
        o.intensity = t.range (0, 99);
        if (t.range (0, 99) < 50) o.sweep = 0;
        else o.sweep = t.range (0, 99);
    }

    Recipe randomRecipe (Lcg& t)
    {
        static const char* names[] = { "SYNTH", "LEAD", "PAD 2", "BASS", "A", "LONGER NAME HERE", "lower", "X 9" };
        Recipe r;
        r.name = names[t.range (0, 7)];
        randomOsc (t, r.osc[0], 85);
        randomOsc (t, r.osc[1], 50);
        randomOsc (t, r.osc[2], 35);
        r.drumsOn = t.range (0, 1) != 0;
        for (auto& ds : r.drums)
        {
            ds.on = t.range (0, 3) != 0;
            ds.tune = t.range (-12, 12);
            ds.decay = t.range (0, 99);
            ds.tone = t.range (0, 99);
            ds.level = t.range (-50, 50);
        }
        r.filter = t.range (0, 99); r.keyTrack = t.range (0, 99); r.velFilter = t.range (0, 99);
        r.a = t.range (0, 99); r.d = t.range (0, 99); r.s = t.range (0, 99); r.r = t.range (0, 99);
        r.vcfA = t.range (0, 99); r.vcfD = t.range (0, 99); r.vcfS = t.range (0, 99); r.vcfR = t.range (0, 99);
        r.vcfAmount = t.range (-60, 60); r.velLoudness = t.range (0, 99);
        r.lfoRate = t.range (0, 99); r.lfoDepth = t.range (0, 99); r.lfoDelay = t.range (0, 99);
        return r;
    }

    void editKeygroups (Disk& d, int salt)
    {
        const auto* p = programOf (d);
        if (p == nullptr) return;
        const Disk::Entry prog = *p;
        const int n = static_cast<int> (d.keygroups (prog).size());
        for (int k = 0; k < n; ++k)
            for (int q = 0; q < static_cast<int> (KeygroupParam::Count); ++q)
            {
                const auto param = static_cast<KeygroupParam> (q);
                if (param == KeygroupParam::HighKey || param == KeygroupParam::LowKey) continue;
                d.setKeygroupParam (prog, k, param, ((k * 31 + q * 17 + salt) % 140) - 20);
            }
    }

    std::string renderText (const Recipe& r, WaveCache& cache, const Disk* previous, Disk* keep = nullptr)
    {
        Disk d;
        std::string error = "untouched";
        const bool ok = render (r, cache, previous, d, error);
        if (! ok) return "err " + error;
        std::string s = "ok " + error + " " + imageText (d) + " sep" + (hasSeparateOscillators (r, d) ? "1" : "0")
                      + " old" + (hasOldTuning (r, d) ? "1" : "0");
        if (keep != nullptr) *keep = d;
        return s;
    }

    void patchChecks()
    {
        for (int k = 0; k <= static_cast<int> (OscKind::count); ++k)
        {
            const auto l = oscKindLabels (static_cast<OscKind> (k));
            line ("kind", std::to_string (k), std::string (oscKindName (static_cast<OscKind> (k))) + "/" + l.intensity + "/" + l.sweep
                                            + "/" + (l.hasIntensity ? "1" : "0") + (l.hasSweep ? "1" : "0"));
        }
        for (int s = 0; s < static_cast<int> (DrumSlot::count); ++s)
            line ("slot", std::to_string (s), std::string (drumSlotName (static_cast<DrumSlot> (s))) + "/" + std::to_string (drumSlotNote (static_cast<DrumSlot> (s))));

        // single oscillator waves: every kind across a grid
        WaveCache cache;
        for (int k = 1; k < static_cast<int> (OscKind::count); ++k)
            for (int intensity : { 0, 37, 50, 99 })
                for (int sweep : { 0, 45, 99 })
                    for (int phase : { 0, 33, 99 })
                    {
                        OscSettings o;
                        o.kind = static_cast<OscKind> (k); o.intensity = intensity; o.sweep = sweep; o.phase = phase;
                        line ("osc", std::to_string (k) + "/" + std::to_string (intensity) + "/" + std::to_string (sweep) + "/" + std::to_string (phase),
                              wordsText (oscillatorWave (o, cache)));
                    }
        {
            Lcg t { 777 };
            for (int i = 0; i < 120; ++i)
            {
                OscSettings o;
                randomOsc (t, o, 100);
                line ("oscr", std::to_string (i), wordsText (oscillatorWave (o, cache)));
            }
            OscSettings off;
            line ("oscr", "off", wordsText (oscillatorWave (off, cache)));
            line ("oscr", "cache", std::to_string (cache.waves.size()));
        }

        // plans, for many recipes
        {
            Lcg t { 4242 };
            for (int i = 0; i < 1500; ++i)
            {
                const Recipe r = randomRecipe (t);
                line ("plan", std::to_string (i), planText (planMix (r)));
            }
            Recipe none;
            line ("plan", "none", planText (planMix (none)));
            for (int f = -60; f <= 60; f += 1)
            {
                Recipe r;
                r.osc[0].kind = OscKind::saw;
                r.osc[1].kind = OscKind::pulse; r.osc[1].fine = f; r.osc[1].sweep = (f + 60) % 100;
                r.osc[2].kind = OscKind::sine; r.osc[2].octave = (f + 60) % 5 - 2; r.osc[2].fine = -f / 2;
                line ("plan", "fine" + std::to_string (f), planText (planMix (r)));
            }
        }

        // mixes, small ones on their own
        {
            WaveCache mc;
            Lcg t { 99 };
            for (int i = 0; i < 40; ++i)
            {
                Recipe r;
                randomOsc (t, r.osc[0], 100);
                randomOsc (t, r.osc[1], 50);
                r.osc[0].fine = t.range (-1, 1) * 50;
                r.osc[1].fine = 0;
                MixPlan plan;
                const auto& w = mixedWave (r, mc, plan);
                line ("mix", std::to_string (i), planText (plan) + " " + wordsText (w));
            }
        }

        // presets, rendered and as text
        WaveCache rc;
        for (std::size_t i = 0; i < presets().size(); ++i)
        {
            const auto& p = presets()[i];
            line ("preset", std::to_string (i), std::string (p.name) + " " + toText (p.recipe));
            line ("preset-render", std::to_string (i), renderText (p.recipe, rc, nullptr));
            if (p.recipe.anyOscillator())
            {
                MixPlan plan;
                const auto& w = mixedWave (p.recipe, rc, plan);
                line ("preset-mix", std::to_string (i), planText (plan) + " " + wordsText (w));
            }
            line ("preset-text", std::to_string (i), toText (fromText (toText (p.recipe))));
        }

        // random recipes, rendered, and again over an edited disk
        {
            Lcg t { 2026 };
            for (int i = 0; i < 300; ++i)
            {
                Recipe r = randomRecipe (t);
                if (i % 9 == 0) { r.osc[0].kind = OscKind::off; r.osc[1].kind = OscKind::off; r.osc[2].kind = OscKind::off; }
                if (i % 23 == 0) for (auto& ds : r.drums) ds.on = false;
                line ("text", std::to_string (i), toText (r));
                line ("text-rt", std::to_string (i), toText (fromText (toText (r))));
                line ("anyosc", std::to_string (i), r.anyOscillator() ? "1" : "0");

                Disk first;
                line ("render", std::to_string (i), renderText (r, rc, nullptr, &first));

                if (i % 4 == 0 && ! first.getEntries().empty())
                {
                    editKeygroups (first, i);
                    line ("edited", std::to_string (i), imageText (first));

                    Recipe r2 = r;
                    r2.osc[0].level = t.range (0, 99);
                    r2.drums[0].decay = t.range (0, 99);
                    r2.drums[1].on = t.range (0, 1) != 0;
                    r2.drums[3].level = t.range (-50, 50);
                    r2.a = t.range (0, 99);
                    if (t.range (0, 3) == 0) r2.drumsOn = ! r2.drumsOn;
                    line ("again", std::to_string (i), renderText (r2, rc, &first));

                    Recipe r3 = r2;
                    r3.name = "OTHER";
                    line ("again-other", std::to_string (i), renderText (r3, rc, &first));
                }
            }
        }

        // a disk in the old layout: a keygroup per oscillator
        {
            Lcg t { 31337 };
            for (int i = 0; i < 24; ++i)
            {
                Recipe r = randomRecipe (t);
                r.osc[0].kind = static_cast<OscKind> (t.range (1, 19));
                r.osc[1].fine = t.range (-50, 50);
                r.osc[0].fine = t.range (-50, 50);

                Disk d = Disk::blank (r.name + " DISK");
                std::string error;
                std::vector<int> used;
                for (int o = 0; o < 3; ++o)
                {
                    if (r.osc[o].kind == OscKind::off) continue;
                    Disk::NewSample s;
                    s.name = "OSC" + std::to_string (o + 1);
                    s.words12 = oscillatorWave (r.osc[o], rc);
                    s.rate = 40000; s.rootNote = 60; s.loopMode = 'L';
                    const bool ok = d.addSample (s, error);
                    line ("old-add", std::to_string (i) + "/" + std::to_string (o), ok ? "ok" : "err " + error);
                    used.push_back (o);
                }
                if (t.range (0, 3) == 0)
                {
                    Disk::NewSample s;
                    s.name = "KICK 1";
                    s.words12 = std::vector<short> (300, 5);
                    s.rate = 20000; s.rootNote = 36; s.loopMode = 'O';
                    d.addSample (s, error);
                    used.push_back (9);
                }
                const bool okp = d.addProgram (r.name, static_cast<int> (used.size()), error);
                line ("old-prog", std::to_string (i), okp ? "ok" : "err " + error);
                const auto* pp = programOf (d);
                if (pp != nullptr)
                {
                    const Disk::Entry prog = *pp;
                    for (int k = 0; k < static_cast<int> (used.size()); ++k)
                    {
                        const int o = used[(std::size_t) k];
                        d.setZoneSample (prog, k, 0, o == 9 ? std::string ("KICK 1") : "OSC" + std::to_string (o + 1));
                        if (o == 9) continue;
                        const auto& os = r.osc[o];
                        const int cents = std::max (-50, std::min (50, os.fine));
                        const int fine256 = static_cast<int> (std::llround (std::abs (cents) * 2.56));
                        const int oldHigh = os.octave * 12 - (cents < 0 ? 1 : 0);
                        const int oldLow  = cents < 0 ? 256 - fine256 : fine256;
                        const int sixteenths = os.octave * 12 * 16 + static_cast<int> (std::lround (cents * 16.0 / 100.0));
                        const int newHigh = sixteenths >= 0 ? sixteenths / 256 : -((255 - sixteenths) / 256);
                        const int newLow  = sixteenths - newHigh * 256;
                        const int mode = t.range (0, 3);
                        if (mode == 0 || mode == 3) { d.setKeygroupParam (prog, k, KeygroupParam::Zone1Transpose, oldHigh); d.setKeygroupParam (prog, k, KeygroupParam::Zone1Fine, oldLow & 0xFF); }
                        else if (mode == 1) { d.setKeygroupParam (prog, k, KeygroupParam::Zone1Transpose, newHigh); d.setKeygroupParam (prog, k, KeygroupParam::Zone1Fine, newLow); }
                        else { d.setKeygroupParam (prog, k, KeygroupParam::Zone1Transpose, t.range (-30, 30)); d.setKeygroupParam (prog, k, KeygroupParam::Zone1Fine, t.range (0, 255)); }
                        d.setKeygroupParam (prog, k, KeygroupParam::VcaAttack, t.range (0, 99));
                        d.setKeygroupParam (prog, k, KeygroupParam::LfoRate, t.range (0, 99));
                        d.setKeygroupParam (prog, k, KeygroupParam::Zone1Filter, t.range (0, 99));
                    }
                }
                d.rebuildPointers();
                line ("old-disk", std::to_string (i), imageText (d) + " sep" + (hasSeparateOscillators (r, d) ? "1" : "0")
                                                    + " old" + (hasOldTuning (r, d) ? "1" : "0"));
                Recipe other = r; other.name = "NOPE";
                line ("old-other", std::to_string (i), std::string ("sep") + (hasSeparateOscillators (other, d) ? "1" : "0")
                                                     + " old" + (hasOldTuning (other, d) ? "1" : "0"));
                line ("old-render", std::to_string (i), renderText (r, rc, &d));
            }
        }

        // errors
        {
            Recipe r;
            r.osc[0].kind = OscKind::off;
            line ("error", "nothing", renderText (r, rc, nullptr));
            r.drumsOn = true;
            for (auto& ds : r.drums) ds.on = false;
            line ("error", "no drums", renderText (r, rc, nullptr));
            Recipe e;
            e.name = "";
            line ("error", "empty name", renderText (e, rc, nullptr));
            e.name = "   ";
            line ("error", "blank name", renderText (e, rc, nullptr));
            e.name = "lower case name";
            e.drumsOn = true;
            line ("error", "long name", renderText (e, rc, nullptr));
        }

        // text by hand
        const char* texts[] = {
            "", "name=FOO", "name=MY_PAD o0=5,99,0,0,0,40,70", "o1=3,1,2,3",
            "o0=99,1,2,3,4,5,6 o3=1,1,1,1,1,1,1 d9=1,1,1,1,1 d0=0,-3,50,60,-7",
            "voice=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16", "voice=1,2", "drums=1", "drums=x", "drums=-0",
            " name=A\tdrums=2\n o2=-4,a,3b,,7,8,9 ", "o0=1,2,3,4,5,6,7,", "o0=,1,2,3,4,5,6",
            "o0=99999999999,1,2,3,4,5,6", "o0=-99999999999,1,2,3,4,5,6", "noequals", "=5", "name=", "name==X",
            "o0==1,2,3,4,5,6,7", "d0=1,2,3,4,5 d0=0,0,0,0,0", "o0=+5,+1,-0,2,3,4,5", "oo=1,2,3,4,5,6,7",
            "o00=1,2,3,4,5,6,7", "d-=1,2,3,4,5", "o0=1,2,3,4,5,6,7,8,9", "o0=-1,1,1,1,1,1,1", "o2=19,1,1,1,1,1,1",
            "o2=20,1,1,1,1,1,1", "d8=7,1,1,1,1", "d9=1,1,1,1,1", "voice=,,,,,,,,,,,,,,,", "voice=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17",
            "name=a_b__c_ drums=0x10", "drums= 1", "o0=1, 2,3,4,5,6,7", "\x0b\x0cname=VT\r\n", "o0=2147483648,-2147483649,1,1,1,1,1",
            "o1=  ,1", "name=X name=Y", "drums=12abc", "o0=0x5,1e3,1.9,-1.9,--2,+-3,4"
        };
        int ti = 0;
        for (const char* s : texts) line ("fromtext", std::to_string (ti++), toText (fromText (s)));
    }
}

int main (int argc, char** argv)
{
    if (argc < 2) { std::fprintf (stderr, "usage: synth_cpp <out.txt>\n"); return 2; }
    out = std::fopen (argv[1], "wb");
    if (out == nullptr) { std::fprintf (stderr, "cannot write %s\n", argv[1]); return 1; }
    synthChecks();
    patchChecks();
    std::fclose (out);
    return 0;
}
