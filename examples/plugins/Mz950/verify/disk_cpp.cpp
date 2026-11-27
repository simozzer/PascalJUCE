// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Disk reading check, C++ side: dumps everything the ORIGINAL Disk.cpp / Hfe.cpp read out
// of each image, as text, for disk_pas.dpr to dump the same way and compare.
//
//     disk_cpp <out.txt> <image> [<image> ...]
//
// Every directory entry and field, every keygroup and zone, every getKeygroupParam,
// vcfBlank and keygroupByteAt, sampleWords12 and readFile (as hashes), buildPatch to the
// last field and the bits of every double, which entries share a sound object, a rebuild
// with `reuse`, and - on a copy - rebuildPointers and a sample and programme added. The
// same dump serves the fuzz cases, so its loops are capped where a hostile directory could
// make them enormous.

#include "Disk.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

using s950::Disk;
using s950::KeygroupParam;

namespace
{
    std::FILE* out = nullptr;

    std::uint64_t fnv (const void* p, std::size_t n, std::uint64_t h = 1469598103934665603ull)
    {
        const unsigned char* b = static_cast<const unsigned char*> (p);
        for (std::size_t i = 0; i < n; ++i) { h ^= b[i]; h *= 1099511628211ull; }
        return h;
    }

    unsigned long long bits (double d)
    {
        unsigned long long u;
        std::memcpy (&u, &d, sizeof u);
        return u;
    }

    std::string base (const std::string& p)
    {
        const auto at = p.find_last_of ("\\/");
        return at == std::string::npos ? p : p.substr (at + 1);
    }

    const int Params = static_cast<int> (KeygroupParam::Count);

    void dumpZone (const char* label, const Disk::Zone& z)
    {
        std::fprintf (out, "    %s '%s' ptr %d fine %d trans %d filt %d loud %d pitch %016llX use %d\n",
                      label, z.name.c_str(), z.pointer, z.fine, z.transpose, z.filter, z.loudness,
                      bits (z.pitchOffset()), z.inUse() ? 1 : 0);
    }

    void dumpPatch (const Disk& d, const Disk::Entry& e)
    {
        auto patch = d.buildPatch (e);
        if (patch == nullptr) { std::fprintf (out, "  patch nil\n"); return; }

        std::fprintf (out, "  patch '%s' xfade %d entries %d\n", patch->name.c_str(),
                      patch->positionalCrossfade ? 1 : 0, static_cast<int> (patch->keygroups.size()));

        std::map<const s950::Sound*, int> ids;
        int shown = 0;
        for (const auto& k : patch->keygroups)
        {
            int id = -1;
            if (k.sound != nullptr)
            {
                auto it = ids.find (k.sound.get());
                if (it == ids.end())
                {
                    id = static_cast<int> (ids.size());
                    ids[k.sound.get()] = id;
                    const auto& s = *k.sound;
                    std::fprintf (out, "   sound %d '%s' fp %016llX rate %d root %016llX loop %d-%d loops %d alt %d smooth %d len %d hash %016llX\n",
                                  id, s.name.c_str(), s.fingerprint, s.sourceRate, bits (s.rootPitch),
                                  s.loopFrom, s.loopTo, s.loops ? 1 : 0, s.alternates ? 1 : 0, s.loopSmoothed,
                                  static_cast<int> (s.audio.size()),
                                  static_cast<unsigned long long> (fnv (s.audio.data(), s.audio.size() * sizeof (float))));
                }
                else
                    id = it->second;
            }

            if (++shown > 2000) continue;
            std::fprintf (out, "   pk keys %d-%d kg %d vel %d-%d sound %d vca %d,%d,%d,%d vcf %d,%d,%d,%d w %d amt %d"
                               " vtf %d ktf %d vtl %d vta %d vtr %d vro %d warp %d,%d,%d port %d lfo %d,%d,%d,%d,%d ds %d"
                               " zf %d zl %d zt %016llX cp %d os %d\n",
                          k.lowKey, k.highKey, k.keygroupIndex, k.velocityFrom, k.velocityTo, id,
                          k.vcaAttack, k.vcaDecay, k.vcaSustain, k.vcaRelease,
                          k.vcfAttack, k.vcfDecay, k.vcfSustain, k.vcfRelease, k.vcfWritten ? 1 : 0, k.vcfAmount,
                          k.velToFilter, k.keyToFilter, k.velToLoudness, k.velToAttack, k.velToRelease,
                          k.velocityReleaseOn ? 1 : 0, k.warpVelocity, k.warpDepth, k.warpTime, k.outputPort,
                          k.lfoDelay, k.lfoRate, k.lfoDepth, k.lfoModwheelDepth, k.lfoAftertouchDepth,
                          k.lfoDesync ? 1 : 0, k.zoneFilter, k.zoneLoudness, bits (k.zoneTranspose),
                          k.constantPitch ? 1 : 0, k.oneShot ? 1 : 0);
        }

        // Rebuilt with the first as `reuse`: every sound must be the very same object.
        auto again = d.buildPatch (e, patch.get());
        std::string same;
        for (std::size_t i = 0; i < again->keygroups.size(); ++i)
            same += (i < patch->keygroups.size() && again->keygroups[i].sound == patch->keygroups[i].sound) ? 's' : 'd';
        std::fprintf (out, "  reuse %d hash %016llX\n", static_cast<int> (again->keygroups.size()),
                      static_cast<unsigned long long> (fnv (same.data(), same.size())));
    }

    void dumpDisk (const std::string& path)
    {
        Disk d;
        std::string error;
        std::fprintf (out, "file %s\n", base (path).c_str());

        if (! d.loadFile (path, error))
        {
            std::fprintf (out, "load fail '%s' badcrc %d missing %d hfe %d\n", error.c_str(),
                          d.getBadCrcSectors(), d.getMissingSectors(), d.wasHfe() ? 1 : 0);
            return;
        }

        const auto& img = d.getImage();
        const auto& entries = d.getEntries();
        std::fprintf (out, "load ok hfe %d size %d badcrc %d missing %d rev %d hd %d header %d image %016llX entries %d\n",
                      d.wasHfe() ? 1 : 0, static_cast<int> (img.size()), d.getBadCrcSectors(), d.getMissingSectors(),
                      d.getRevision(), d.isHighDensity() ? 1 : 0, d.headerBlocks(),
                      static_cast<unsigned long long> (fnv (img.data(), img.size())), static_cast<int> (entries.size()));

        for (const auto& e : entries)
        {
            std::fprintf (out, "entry %d type %d '%s' len %d start %d blocks %d ok %d count %lld rate %d tuning %d"
                               " mode %d dir %d loop %lld/%lld/%lld loud %d pitch %d/%d secs %016llX\n",
                          e.slot, static_cast<int> (static_cast<unsigned char> (e.type)), e.name.c_str(), e.length,
                          e.startBlock, e.chainBlocks, e.chainOk ? 1 : 0, e.sampleCount, e.sampleRate, e.tuning,
                          static_cast<int> (static_cast<unsigned char> (e.loopMode)),
                          static_cast<int> (static_cast<unsigned char> (e.loopDirection)),
                          e.loopStart, e.loopEnd, e.loopLength, e.loudness, e.nominalPitch(), e.finePitch(),
                          bits (e.seconds()));

            const auto raw = d.readFile (e);
            const auto words = d.sampleWords12 (e);
            const Disk::Entry* f = d.find (e.name, e.type);
            std::fprintf (out, "  file %d %016llX words %d %016llX kgcount %d find %d index %d norm '%s'\n",
                          static_cast<int> (raw.size()), static_cast<unsigned long long> (fnv (raw.data(), raw.size())),
                          static_cast<int> (words.size()),
                          static_cast<unsigned long long> (fnv (words.data(), words.size() * sizeof (short))),
                          Disk::keygroupCount (e), f ? f->slot : -1, d.sampleIndex (e.name),
                          Disk::normaliseNameFor (e.name + " x").c_str());

            const auto groups = d.keygroups (e);
            std::fprintf (out, "  keygroups %d\n", static_cast<int> (groups.size()));

            int shown = 0;
            for (const auto& k : groups)
            {
                if (++shown > 2000) break;
                std::fprintf (out, "   kg %d keys %d-%d vsw %d vca %d,%d,%d,%d vcf %d,%d,%d,%d amt %d vtf %d ktf %d vtl %d"
                                   " vta %d vtr %d warp %d,%d,%d port %d lfo %d,%d,%d,%d,%d flags %d bits %d%d%d%d second %d\n",
                              k.index, k.lowKey, k.highKey, k.velocitySwitch,
                              k.vcaAttack, k.vcaDecay, k.vcaSustain, k.vcaRelease,
                              k.vcfAttack, k.vcfDecay, k.vcfSustain, k.vcfRelease, k.vcfAmount,
                              k.velToFilter, k.keyToFilter, k.velToLoudness, k.velToAttack, k.velToRelease,
                              k.warpVelocity, k.warpDepth, k.warpTime, k.outputPort,
                              k.lfoDelay, k.lfoRate, k.lfoDepth, k.lfoAftertouchDepth, k.lfoModwheelDepth,
                              k.flags, k.constantPitch() ? 1 : 0, k.lfoDesync() ? 1 : 0, k.oneShot() ? 1 : 0,
                              k.velocityReleaseOn() ? 1 : 0, k.hasSecondZone() ? 1 : 0);
                dumpZone ("z1", k.zone1);
                dumpZone ("z2", k.zone2);
            }

            // Every setting, through the reader the editor uses, and where each byte lives -
            // one keygroup before the first and one past the last included.
            const int n = Disk::keygroupCount (e);
            std::vector<int> which;
            for (int kg = -1; kg <= n && kg <= 70; ++kg) which.push_back (kg);
            if (n > 70) { which.push_back (n - 1); which.push_back (n); }

            for (int kg : which)
            {
                std::string line = "  get " + std::to_string (kg) + ":";
                for (int p = 0; p < Params; ++p)
                    line += " " + std::to_string (d.getKeygroupParam (e, kg, static_cast<KeygroupParam> (p)));
                line += " blank " + std::to_string (d.vcfBlank (e, kg) ? 1 : 0);

                std::vector<long long> at;
                for (int o = -1; o <= 70; ++o)
                {
                    std::size_t a = 0;
                    at.push_back (d.keygroupByteAt (e, kg, o, a) ? static_cast<long long> (a) : -1);
                }
                char buf[40];
                std::snprintf (buf, sizeof buf, " at %016llX", static_cast<unsigned long long> (fnv (at.data(), at.size() * sizeof (long long))));
                std::fprintf (out, "%s%s\n", line.c_str(), buf);
            }

            dumpPatch (d, e);
        }

        {
            std::string slots;
            for (int s = -1; s <= 64; ++s)
            {
                const Disk::Entry* e = d.entryInSlot (s);
                slots += " " + std::to_string (e ? e->slot : -1);
            }
            std::fprintf (out, "slots%s\n", slots.c_str());
        }

        // The writing half on whatever this disk holds: rebuild, then add a sample and a
        // programme and point a zone at it.
        {
            Disk w = d;
            const int first = w.rebuildPointers();
            const int second = w.rebuildPointers();
            std::fprintf (out, "rebuild %d %d image %016llX rev %d\n", first, second,
                          static_cast<unsigned long long> (fnv (w.getImage().data(), w.getImage().size())), w.getRevision());

            Disk::NewSample s;
            s.name = "zz test";
            for (int i = 0; i < 3001; ++i) s.words12.push_back (static_cast<short> ((i * 37) % 4096 - 2048));
            std::string why;
            const bool a = w.addSample (s, why);
            std::fprintf (out, "addsample %d '%s'\n", a ? 1 : 0, why.c_str());
            why.clear();
            const bool b = w.addProgram ("zz prog", 3, why);
            std::fprintf (out, "addprogram %d '%s'\n", b ? 1 : 0, why.c_str());
            const Disk::Entry* p = w.find ("ZZ PROG", 'P');
            int z = -1;
            if (p != nullptr)
            {
                z = (w.setZoneSample (*p, 1, 0, "zz test") ? 1 : 0) + 2 * (w.setZoneSample (*p, 2, 1, "nothing") ? 1 : 0);
                w.setKeygroupParam (*p, 1, KeygroupParam::VcfDecay, 12);
            }
            const int third = w.rebuildPointers();
            std::fprintf (out, "written zone %d rebuild %d entries %d image %016llX rev %d\n", z, third,
                          static_cast<int> (w.getEntries().size()),
                          static_cast<unsigned long long> (fnv (w.getImage().data(), w.getImage().size())), w.getRevision());
        }

        // The same image again, from its bytes: a plain image, read the same.
        {
            Disk again;
            std::string why;
            const bool ok = again.loadBytes ("again", d.getImage(), why);
            std::fprintf (out, "reload %d hfe %d entries %d image %016llX\n", ok ? 1 : 0, again.wasHfe() ? 1 : 0,
                          static_cast<int> (again.getEntries().size()),
                          static_cast<unsigned long long> (fnv (again.getImage().data(), again.getImage().size())));
        }
    }
}

int main (int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf (stderr, "usage: disk_cpp <out.txt> <image> [<image> ...]\n");
        return 2;
    }

    out = std::fopen (argv[1], "wb");
    if (out == nullptr) { std::fprintf (stderr, "cannot write %s\n", argv[1]); return 2; }

    // An argument @file names a file listing images, one to a line.
    int images = 0;
    for (int i = 2; i < argc; ++i)
    {
        if (argv[i][0] != '@') { dumpDisk (argv[i]); ++images; continue; }
        std::ifstream list (argv[i] + 1);
        std::string path;
        while (std::getline (list, path))
        {
            while (! path.empty() && (path.back() == '\r' || path.back() == ' ')) path.pop_back();
            if (path.empty()) continue;
            dumpDisk (path);
            ++images;
        }
    }

    std::fclose (out);
    std::printf ("disk_cpp: %d images dumped\n", images);
    return 0;
}
