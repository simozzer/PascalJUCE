// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Audio equivalence harness, C++ side: renders scenarios.txt through the ORIGINAL engine,
// compiled straight from the VirtualS950 repository's Plugin/Source/S950 (see
// build_verify.cmd). The disks are read, and the synth disks made, by the original Disk and
// SynthPatch too, so the whole path from an image to the samples is the C++'s.
//
//     render_cpp <scenarios.txt> <disks dir> <outdir>

#define _CRT_SECURE_NO_WARNINGS

#include "Engine.h"
#include "Disk.h"
#include "SynthPatch.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

using namespace s950;

namespace
{

std::vector<std::string> words (const std::string& line)
{
    std::vector<std::string> w;
    std::istringstream in (line);
    std::string s;
    while (in >> s) w.push_back (s);
    return w;
}

// The rest of the line after the first word, for a recipe's text.
std::string restOf (const std::string& line)
{
    std::size_t i = 0;
    while (i < line.size() && line[i] <= ' ') ++i;
    while (i < line.size() && line[i] > ' ') ++i;
    while (i < line.size() && line[i] <= ' ') ++i;
    return line.substr (i);
}

int    toInt (const std::string& s)    { return std::atoi (s.c_str()); }
double toDouble (const std::string& s) { return std::strtod (s.c_str(), nullptr); }

std::atomic<float>* trimNamed (Engine& e, const std::string& n)
{
    auto& t = e.trims;
    if (n == "cutoff") return &t.cutoff;           if (n == "amount") return &t.amount;
    if (n == "vcaAttack") return &t.vcaAttack;     if (n == "vcaDecay") return &t.vcaDecay;
    if (n == "vcaSustain") return &t.vcaSustain;   if (n == "vcaRelease") return &t.vcaRelease;
    if (n == "vcfAttack") return &t.vcfAttack;     if (n == "vcfDecay") return &t.vcfDecay;
    if (n == "vcfSustain") return &t.vcfSustain;   if (n == "vcfRelease") return &t.vcfRelease;
    if (n == "lfoRate") return &t.lfoRate;         if (n == "lfoDepth") return &t.lfoDepth;
    if (n == "lfoDelay") return &t.lfoDelay;       if (n == "velToFilter") return &t.velToFilter;
    if (n == "velToLoudness") return &t.velToLoudness;
    if (n == "resonance") return &t.resonance;     if (n == "lfoShape") return &t.lfoShape;
    if (n == "lfoToFilter") return &t.lfoToFilter; if (n == "lfoSync") return &t.lfoSync;
    if (n == "lfoSyncDiv") return &t.lfoSyncDiv;
    if (n == "gain") return &e.gain;
    return nullptr;
}

struct Run
{
    std::string name;
    std::unique_ptr<Engine> engine;
    Disk disk;
    bool haveDisk = false;
    PatchPtr patch;
    const Disk::Entry* program = nullptr;
    int programIndex = -1;
    synth::WaveCache cache;
    std::vector<float> out;
    double bpm = 120.0, ppq = 0.0, qpb = 4.0;
    bool playing = false, transport = false;
    bool failed = false;
    int  xfade = -1;                // the crossfade command: -1 leaves the disk's byte 21 alone
};

// The patch to the engine, and taken by the audio side at once: a render of nothing takes
// the pending patch, and the retired one is collected straight after.
void send (Run& r)
{
    if (r.patch != nullptr && r.xfade >= 0)
        const_cast<Patch&> (*r.patch).positionalCrossfade = r.xfade != 0;
    if (! r.engine->trySetPatch (r.patch))
    {
        std::printf ("%s: trySetPatch refused\n", r.name.c_str());
        r.failed = true;
    }
    float none[1];
    r.engine->render (none, nullptr, 0);
    r.engine->collectRetiredPatch();
}

const Disk::Entry* nthProgram (const Disk& d, int n)
{
    int k = 0;
    for (const auto& e : d.getEntries())
        if (e.type == 'P' && k++ == n) return &e;
    return nullptr;
}

void selectProgram (Run& r, int n)
{
    r.program = nthProgram (r.disk, n);
    r.programIndex = n;
    if (r.program == nullptr) { std::printf ("%s: no programme %d\n", r.name.c_str(), n); r.failed = true; return; }
    r.patch = r.disk.buildPatch (*r.program, r.patch.get());
    send (r);
}

bool writeFloats (const std::string& path, const std::vector<float>& v)
{
    FILE* f = std::fopen (path.c_str(), "wb");
    if (f == nullptr) return false;
    if (! v.empty()) std::fwrite (v.data(), sizeof (float), v.size(), f);
    std::fclose (f);
    return true;
}

} // namespace

int main (int argc, char** argv)
{
    if (argc < 4) { std::printf ("render_cpp <scenarios.txt> <disks dir> <outdir>\n"); return 2; }

    std::ifstream in (argv[1]);
    if (! in) { std::printf ("cannot read %s\n", argv[1]); return 2; }
    const std::string disks = argv[2], outdir = argv[3];

    std::unique_ptr<Run> r;
    std::string line;
    int scenarios = 0, failures = 0;

    while (std::getline (in, line))
    {
        if (! line.empty() && line.back() == '\r') line.pop_back();
        const auto w = words (line);
        if (w.empty() || w[0][0] == '#') continue;
        const std::string& c = w[0];
        auto arg = [&] (std::size_t i) -> std::string { return i < w.size() ? w[i] : std::string(); };
        auto at  = [&] (std::size_t i) -> int { return i < w.size() ? toInt (w[i]) : 0; };

        if (c == "scenario")
        {
            r = std::make_unique<Run>();
            r->name = arg (1);
            r->engine = std::make_unique<Engine> (toDouble (arg (2)));
            continue;
        }
        if (r == nullptr) continue;

        if (c == "disk")
        {
            std::string error;
            if (! r->disk.loadFile (arg (1).find (':') != std::string::npos ? arg (1) : disks + "\\" + arg (1), error))
            { std::printf ("%s: %s\n", r->name.c_str(), error.c_str()); r->failed = true; }
            r->haveDisk = true;
        }
        else if (c == "synth" || c == "synthtext")
        {
            synth::Recipe recipe = c == "synth" ? synth::presets()[static_cast<std::size_t> (toInt (arg (1)))].recipe
                                                : synth::fromText (restOf (line));
            Disk out;
            std::string error;
            if (! synth::render (recipe, r->cache, r->haveDisk ? &r->disk : nullptr, out, error))
            { std::printf ("%s: %s\n", r->name.c_str(), error.c_str()); r->failed = true; }
            r->disk = out;
            r->haveDisk = true;
            if (r->programIndex >= 0) selectProgram (*r, r->programIndex);
        }
        else if (c == "program") selectProgram (*r, toInt (arg (1)));
        else if (c == "edit")
        {
            if (r->program == nullptr) { r->failed = true; continue; }
            r->disk.setKeygroupParam (*r->program, toInt (arg (1)), static_cast<KeygroupParam> (toInt (arg (2))), toInt (arg (3)));
            r->patch = r->disk.buildPatch (*r->program, r->patch.get());
            send (*r);
        }
        else if (c == "crossfade") { r->xfade = toInt (arg (1)); if (r->patch != nullptr) send (*r); }
        else if (c == "nopatch") { r->patch = nullptr; send (*r); }
        else if (c == "trim")
        {
            auto* t = trimNamed (*r->engine, arg (1));
            if (t == nullptr) { std::printf ("unknown trim %s\n", arg (1).c_str()); r->failed = true; continue; }
            t->store (static_cast<float> (toDouble (arg (2))));
        }
        else if (c == "bendrange")    r->engine->bendRange.store (toDouble (arg (1)));
        else if (c == "glidetime")    r->engine->glideSeconds.store (toDouble (arg (1)));
        else if (c == "widecents")    r->engine->wideCents.store (toDouble (arg (1)));
        else if (c == "widespread")   r->engine->wideSpread.store (toDouble (arg (1)));
        else if (c == "wideoffset")   r->engine->wideOffset.store (toInt (arg (1)) != 0);
        else if (c == "on")           r->engine->noteOn (toInt (arg (1)), toInt (arg (2)), at (3));
        else if (c == "off")          r->engine->noteOff (toInt (arg (1)), at (2));
        else if (c == "wheel")        r->engine->modwheel (toInt (arg (1)), at (2));
        else if (c == "pressure")     r->engine->aftertouch (toInt (arg (1)), at (2));
        else if (c == "bend")         r->engine->pitchBend (toInt (arg (1)), at (2));
        else if (c == "glide")        r->engine->glide (toInt (arg (1)) != 0, at (2));
        else if (c == "voices")       r->engine->setVoiceLimit (toInt (arg (1)), at (2));
        else if (c == "wide")         r->engine->wide (toInt (arg (1)) != 0, at (2));
        else if (c == "alloff")       r->engine->allNotesOff (at (1));
        else if (c == "transport")
        {
            r->transport = true;
            r->bpm = toDouble (arg (1)); r->ppq = toDouble (arg (2));
            r->playing = toInt (arg (3)) != 0; r->qpb = toDouble (arg (4));
        }
        else if (c == "render")
        {
            const int total = toInt (arg (1));
            const int block = w.size() > 2 ? toInt (arg (2)) : total;
            const bool mono = arg (3) == "mono";
            std::vector<float> left (static_cast<std::size_t> (block > 0 ? block : 1)), right (left.size());

            for (int done = 0; done < total; done += block)
            {
                const int n = std::min (block, total - done);
                if (r->transport)
                {
                    r->engine->setTransport (r->bpm, r->ppq, r->playing, r->qpb);
                    if (r->playing) r->ppq += n / r->engine->getSampleRate() * r->bpm / 60.0;
                }
                r->engine->render (left.data(), mono ? nullptr : right.data(), n);
                for (int i = 0; i < n; ++i)
                {
                    r->out.push_back (left[static_cast<std::size_t> (i)]);
                    if (! mono) r->out.push_back (right[static_cast<std::size_t> (i)]);
                }
                r->engine->collectRetiredPatch();
            }
        }
        else if (c == "end")
        {
            ++scenarios;
            if (! writeFloats (outdir + "\\" + r->name + ".f32", r->out)) r->failed = true;
            std::printf ("%-28s %9zu floats  active %d%s\n", r->name.c_str(), r->out.size(),
                         r->engine->getActiveVoices(), r->failed ? "  FAILED" : "");
            if (r->failed) ++failures;
            r.reset();
        }
        else { std::printf ("unknown command: %s\n", c.c_str()); return 2; }
    }

    std::printf ("render_cpp: %d scenarios, %d failed\n", scenarios, failures);
    return failures == 0 ? 0 : 1;
}
