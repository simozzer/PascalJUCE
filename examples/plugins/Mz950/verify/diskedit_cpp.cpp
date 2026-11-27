// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Disk editing and writing check, C++ side: the ORIGINAL Disk.cpp put through
// Plugin/Tests/DiskEditCheck.cpp's checks - every setting of every keygroup of every
// programme, at the bottom, the top, the middle, past both ends and one in - and through
// the writing half: a disk built from nothing, a high-density one, the failures and their
// messages, and a disk built to hold what the library disks lack (blank S900 filter
// envelopes, alternating and one-shot loops, two-zone keygroups). diskedit_pas.dpr does
// exactly the same; the two logs, and every image written, must be identical.
//
//     diskedit_cpp <log.txt> <imagedir> <tag> <image> [<image> ...]
//
// Images are written to <imagedir> as <what>_<tag>.img. (The Synth section of
// DiskEditCheck is the synthesiser's, not the disk's, and is not here.)

#include "Disk.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <set>
#include <string>
#include <vector>

using s950::Disk;
using s950::KeygroupParam;
using s950::KeygroupParamInfo;

namespace
{
    std::FILE* out = nullptr;
    int checks = 0, failures = 0, edits = 0;

    std::uint64_t fnv (const void* p, std::size_t n)
    {
        std::uint64_t h = 1469598103934665603ull;
        const unsigned char* b = static_cast<const unsigned char*> (p);
        for (std::size_t i = 0; i < n; ++i) { h ^= b[i]; h *= 1099511628211ull; }
        return h;
    }

    unsigned long long imageHash (const Disk& d)
    {
        return static_cast<unsigned long long> (fnv (d.getImage().data(), d.getImage().size()));
    }

    void fail (const std::string& where, const char* what, int got, int want)
    {
        ++failures;
        std::fprintf (out, "FAIL %s %s: got %d, want %d\n", where.c_str(), what, got, want);
        if (failures <= 40)
            std::printf ("  FAIL %s %s: got %d, want %d\n", where.c_str(), what, got, want);
    }

    bool save (const Disk& d, const std::string& path)
    {
        std::ofstream f (path, std::ios::binary);
        f.write (reinterpret_cast<const char*> (d.getImage().data()), static_cast<std::streamsize> (d.getImage().size()));
        return static_cast<bool> (f);
    }

    /// The same setting as the playing reader parses it.
    int parsed (const Disk::Keygroup& k, KeygroupParam p)
    {
        switch (p)
        {
            case KeygroupParam::HighKey:          return k.highKey;
            case KeygroupParam::LowKey:           return k.lowKey;
            case KeygroupParam::VelocitySwitch:   return k.velocitySwitch;
            case KeygroupParam::VcaAttack:        return k.vcaAttack;
            case KeygroupParam::VcaDecay:         return k.vcaDecay;
            case KeygroupParam::VcaSustain:       return k.vcaSustain;
            case KeygroupParam::VcaRelease:       return k.vcaRelease;
            case KeygroupParam::VelToFilter:      return k.velToFilter;
            case KeygroupParam::KeyToFilter:      return k.keyToFilter;
            case KeygroupParam::VelToAttack:      return k.velToAttack;
            case KeygroupParam::VelToRelease:     return k.velToRelease;
            case KeygroupParam::VelToLoudness:    return k.velToLoudness;
            case KeygroupParam::WarpVelocity:     return k.warpVelocity;
            case KeygroupParam::WarpDepth:        return k.warpDepth;
            case KeygroupParam::WarpTime:         return k.warpTime;
            case KeygroupParam::LfoDelay:         return k.lfoDelay;
            case KeygroupParam::LfoRate:          return k.lfoRate;
            case KeygroupParam::LfoDepth:         return k.lfoDepth;
            case KeygroupParam::LfoAftertouch:    return k.lfoAftertouchDepth;
            case KeygroupParam::LfoModwheel:      return k.lfoModwheelDepth;
            case KeygroupParam::OutputPort:       return k.outputPort;
            case KeygroupParam::VcfAmount:        return k.vcfAmount;
            case KeygroupParam::VcfAttack:        return k.vcfAttack;
            case KeygroupParam::VcfDecay:         return k.vcfDecay;
            case KeygroupParam::VcfSustain:       return k.vcfSustain;
            case KeygroupParam::VcfRelease:       return k.vcfRelease;
            case KeygroupParam::Zone1Fine:        return k.zone1.fine;
            case KeygroupParam::Zone1Transpose:   return k.zone1.transpose;
            case KeygroupParam::Zone1Filter:      return k.zone1.filter;
            case KeygroupParam::Zone1Loudness:    return k.zone1.loudness;
            case KeygroupParam::Zone2Fine:        return k.zone2.fine;
            case KeygroupParam::Zone2Transpose:   return k.zone2.transpose;
            case KeygroupParam::Zone2Filter:      return k.zone2.filter;
            case KeygroupParam::Zone2Loudness:    return k.zone2.loudness;
            case KeygroupParam::ConstantPitch:    return k.constantPitch() ? 1 : 0;
            case KeygroupParam::LfoDesync:        return k.lfoDesync() ? 1 : 0;
            case KeygroupParam::OneShot:          return k.oneShot() ? 1 : 0;
            case KeygroupParam::VelocityReleaseOn:return k.velocityReleaseOn() ? 1 : 0;
            default:                              return -9999;
        }
    }

    bool isVcfStage (KeygroupParam p)
    {
        return p == KeygroupParam::VcfAttack || p == KeygroupParam::VcfDecay
            || p == KeygroupParam::VcfSustain || p == KeygroupParam::VcfRelease;
    }

    /// One write of one value, checked every way there is - and logged, bytes and all.
    void tryValue (const Disk& original, int programIndex, int kg, KeygroupParam p, int value)
    {
        Disk d = original;                          // a fresh copy each time: nothing leaks
        const auto& program = d.getEntries()[static_cast<std::size_t> (programIndex)];
        const auto& info    = s950::keygroupParamInfo (p);

        std::string where = program.name + " kg" + std::to_string (kg) + " " + info.name
                          + " <- " + std::to_string (value);

        const bool blankBefore = isVcfStage (p) && d.vcfBlank (program, kg);
        ++edits;

        ++checks;
        if (! d.setKeygroupParam (program, kg, p, value))
        {
            std::fprintf (out, "e %d kg %d p %d v %d refused\n", programIndex, kg, static_cast<int> (p), value);
            fail (where, "write refused", 0, 1);
            return;
        }

        const int want = value < info.lo ? info.lo : (value > info.hi ? info.hi : value);

        ++checks;
        const int got = d.getKeygroupParam (program, kg, p);
        if (got != want) fail (where, "reads back", got, want);

        ++checks;
        int seen = -9999;
        const auto groups = d.keygroups (program);
        if (kg < static_cast<int> (groups.size()))
        {
            seen = parsed (groups[static_cast<std::size_t> (kg)], p);
            if (seen != want) fail (where, "the playing reader sees", seen, want);
        }

        // Which bytes were allowed to move.
        std::set<std::size_t> allowed;
        std::size_t at = 0;
        if (d.keygroupByteAt (program, kg, info.offset, at)) allowed.insert (at);

        if (blankBefore)
            for (int o = 34; o <= 37; ++o)
                if (d.keygroupByteAt (program, kg, o, at)) allowed.insert (at);

        const auto& before = original.getImage();
        const auto& after  = d.getImage();

        ++checks;
        if (before.size() != after.size())
        {
            fail (where, "image size changed", static_cast<int> (after.size()),
                  static_cast<int> (before.size()));
            return;
        }

        std::string moved;
        int strays = 0;
        const std::size_t chunk = 4096;
        for (std::size_t c = 0; c < before.size(); c += chunk)
        {
            const std::size_t len = std::min (chunk, before.size() - c);
            if (std::memcmp (before.data() + c, after.data() + c, len) == 0) continue;
            for (std::size_t i = c; i < c + len; ++i)
                if (before[i] != after[i])
                {
                    moved += " " + std::to_string (i);
                    if (allowed.count (i) == 0) ++strays;
                }
        }

        if (strays != 0) fail (where, "bytes changed outside the setting", strays, 0);

        std::fprintf (out, "e %d kg %d p %d v %d get %d seen %d blank %d rev %d moved%s\n", programIndex, kg,
                      static_cast<int> (p), value, got, seen, blankBefore ? 1 : 0, d.getRevision(), moved.c_str());
    }

    /// A value for the edited copy: distinct per keygroup and setting, always in range.
    int scrambled (const KeygroupParamInfo& info, int program, int kg, int p)
    {
        const int span = info.hi - info.lo + 1;
        return info.lo + (program * 31 + kg * 17 + p * 7 + 3) % span;
    }

    /// DiskEditCheck's checks, on one disk.
    void editDisk (const Disk& original, const std::string& label, const std::string& dir, const std::string& tag)
    {
        std::fprintf (out, "disk %s image %016llX\n", label.c_str(), imageHash (original));

        const auto& entries = original.getEntries();
        int programs = 0, keygroups = 0;

        for (int e = 0; e < static_cast<int> (entries.size()); ++e)
        {
            if (entries[static_cast<std::size_t> (e)].type != 'P') continue;

            ++programs;
            const int n = Disk::keygroupCount (entries[static_cast<std::size_t> (e)]);

            for (int kg = 0; kg < n; ++kg)
            {
                ++keygroups;

                for (int p = 0; p < static_cast<int> (KeygroupParam::Count); ++p)
                {
                    const auto  param = static_cast<KeygroupParam> (p);
                    const auto& info  = s950::keygroupParamInfo (param);

                    for (int v : { info.lo, info.hi, (info.lo + info.hi) / 2,
                                   info.lo - 5, info.hi + 5, info.lo + 1, -100000, 100000 })
                        tryValue (original, e, kg, param, v);
                }
            }

            // Past the last keygroup nothing may be written, and nothing may move.
            for (int kg : { n, -1, n + 7 })
            {
                Disk d = original;
                ++checks;
                if (d.setKeygroupParam (d.getEntries()[static_cast<std::size_t> (e)], kg,
                                        KeygroupParam::VcaDecay, 50))
                    fail (entries[static_cast<std::size_t> (e)].name, "wrote past the last keygroup", 1, 0);
                ++checks;
                if (d.getImage() != original.getImage())
                    fail (entries[static_cast<std::size_t> (e)].name, "a refused write moved bytes", 1, 0);
            }
        }

        std::fprintf (out, "  %d programmes, %d keygroups, %d settings each\n",
                      programs, keygroups, static_cast<int> (KeygroupParam::Count));

        /*
         * A rebuild after an edit hears the edit, and keeps the samples it had.
         */
        for (const auto& e : entries)
        {
            if (e.type != 'P' || Disk::keygroupCount (e) == 0) continue;

            Disk d = original;
            const auto& program = d.getEntries()[static_cast<std::size_t> (&e - entries.data())];

            auto before = d.buildPatch (program);
            if (before == nullptr || before->keygroups.empty()) continue;

            const int kg   = before->keygroups.front().keygroupIndex;
            const int want = before->keygroups.front().vcaSustain == 40 ? 41 : 40;
            d.setKeygroupParam (program, kg, KeygroupParam::VcaSustain, want);

            auto after = d.buildPatch (program, before.get());

            ++checks;
            if (after == nullptr || after->keygroups.size() != before->keygroups.size())
            {
                fail (e.name, "rebuild changed the keygroups", 0, 1);
                continue;
            }

            ++checks;
            if (after->keygroups.front().vcaSustain != want)
                fail (e.name, "the rebuild hears the edit", after->keygroups.front().vcaSustain, want);

            for (std::size_t i = 0; i < after->keygroups.size(); ++i)
            {
                ++checks;
                if (after->keygroups[i].sound != before->keygroups[i].sound)
                    fail (e.name, "a rebuild decoded a sample afresh", 0, 1);
            }
            std::fprintf (out, "  rebuilt %s %d\n", e.name.c_str(), static_cast<int> (after->keygroups.size()));
        }

        /*
         * A note starts at the sample's start marker (header 0x20), measured on the machine.
         */
        {
            int marked = 0, cut = 0;
            std::set<std::string> seen;
            for (const auto& p : entries)
            {
                if (p.type != 'P') continue;
                const auto patch = original.buildPatch (p);
                if (patch == nullptr) continue;

                for (const auto& k : patch->keygroups)
                {
                    if (k.sound == nullptr || ! seen.insert (k.sound->name).second) continue;
                    const Disk::Entry* s = original.find (k.sound->name, 'S');
                    if (s == nullptr) continue;

                    const auto words = original.sampleWords12 (*s);
                    const long long size  = static_cast<long long> (words.size());
                    const long long end   = std::min<long long> (s->loopEnd, size);
                    const long long stop  = k.sound->loops ? size : (s->loopEnd > 0 && s->loopEnd < size ? s->loopEnd : size);
                    const long long plays = k.sound->loops ? end : stop;
                    const long long first = s->loopStart > 0 && s->loopStart < plays ? s->loopStart : 0;
                    if (first > 0) ++marked;
                    if (stop < size) ++cut;

                    const std::string where = "sample " + s->name;
                    ++checks;
                    if (static_cast<long long> (k.sound->audio.size()) != stop - first)
                    {
                        fail (where, "plays from the start marker to the end marker (length)",
                              static_cast<int> (k.sound->audio.size()), static_cast<int> (stop - first));
                        continue;
                    }
                    ++checks;
                    if (! k.sound->audio.empty() && k.sound->audio.front() != words[static_cast<std::size_t> (first)] / 2048.0f)
                        fail (where, "plays from the start marker (first word)", 0, 1);

                    if (k.sound->loops)
                    {
                        ++checks;
                        if (k.sound->loopTo != static_cast<int> (end - first))
                            fail (where, "the loop end moves with the start", k.sound->loopTo, static_cast<int> (end - first));
                    }
                }
            }
            std::fprintf (out, "  %d sounds played, %d of them from a start marker past word 0, %d one-shots cut at an end marker\n",
                          static_cast<int> (seen.size()), marked, cut);
        }

        // ------------------------------------------------------------- the edited copy
        {
            Disk d = original;

            int pi = 0;
            for (const auto& e : d.getEntries())
            {
                if (e.type != 'P') continue;

                const int n = Disk::keygroupCount (e);
                for (int kg = 0; kg < n; ++kg)
                    for (int p = 0; p < static_cast<int> (KeygroupParam::Count); ++p)
                    {
                        const auto param = static_cast<KeygroupParam> (p);
                        d.setKeygroupParam (e, kg, param,
                                            scrambled (s950::keygroupParamInfo (param), pi, kg, p));
                    }
                ++pi;
            }

            const std::string path = dir + "\\edited_" + label + "_" + tag + ".img";
            ++checks;
            if (! save (d, path)) fail (path, "could not write", 0, 1);

            // And read back from the file, not from memory: what was saved is what counts.
            Disk reread;
            std::string error;
            ++checks;
            if (! reread.loadFile (path, error))
                fail (path, "the edited copy will not open", 0, 1);
            else
            {
                pi = 0;
                for (const auto& e : reread.getEntries())
                {
                    if (e.type != 'P') continue;

                    const int n = Disk::keygroupCount (e);
                    for (int kg = 0; kg < n; ++kg)
                        for (int p = 0; p < static_cast<int> (KeygroupParam::Count); ++p)
                        {
                            const auto  param = static_cast<KeygroupParam> (p);
                            const int   want  = scrambled (s950::keygroupParamInfo (param), pi, kg, p);
                            ++checks;
                            const int   got   = reread.getKeygroupParam (e, kg, param);
                            if (got != want)
                                fail (e.name + " kg" + std::to_string (kg) + " (saved)",
                                      s950::keygroupParamInfo (param).name, got, want);
                        }
                    ++pi;
                }
            }

            std::fprintf (out, "  edited image %016llX rev %d\n", imageHash (d), d.getRevision());
        }
    }

    std::vector<short> sawWords (int n)
    {
        std::vector<short> w (static_cast<std::size_t> (n));
        for (int i = 0; i < n; ++i)
            w[static_cast<std::size_t> (i)] = static_cast<short> (-2048 + (4095 * (i % 153)) / 152);
        return w;
    }

    void logEntries (const Disk& d, const char* what)
    {
        std::fprintf (out, "%s entries %d image %016llX rev %d\n", what, static_cast<int> (d.getEntries().size()),
                      imageHash (d), d.getRevision());
        for (const auto& e : d.getEntries())
            std::fprintf (out, "  %d %c '%s' len %d start %d blocks %d ok %d\n", e.slot, e.type, e.name.c_str(),
                          e.length, e.startBlock, e.chainBlocks, e.chainOk ? 1 : 0);
    }

    // The Pascal port's `out Error` is cleared on entry, where the C++ leaves `error` as it was
    // on success: cleared after each report here, so both logs show each call's own message.
    void result (const char* what, bool ok, std::string& why)
    {
        std::fprintf (out, "%s %d '%s'\n", what, ok ? 1 : 0, why.c_str());
        why.clear();
    }

    /// DiskEditCheck's "making a disk from nothing", to the letter.
    void builtDisk (const std::string& dir, const std::string& tag)
    {
        Disk d = Disk::blank ("BUILT");
        std::string why;
        // (Every message below is printed only by result, which clears it.)

        Disk::NewSample saw;  saw.name  = "saw";  saw.words12  = sawWords (1223);  saw.rate  = 40000;   // odd: last word dropped
        Disk::NewSample kick; kick.name = "kick"; kick.words12 = sawWords (6000);  kick.rate = 20000; kick.loopMode = 'O'; kick.rootNote = 36;
        Disk::NewSample big;  big.name  = "long"; big.words12  = sawWords (140000); big.rate = 20000;  // over a 128K page

        ++checks; if (! d.addSample (saw,  why)) fail ("built", why.c_str(), 0, 1);
        ++checks; if (! d.addSample (kick, why)) fail ("built", why.c_str(), 0, 1);
        ++checks; if (! d.addSample (big,  why)) fail ("built", why.c_str(), 0, 1);

        ++checks; if (! d.addProgram ("lead", 2, why)) fail ("built", why.c_str(), 0, 1);
        ++checks; if (! d.addProgram ("kit",  1, why)) fail ("built", why.c_str(), 0, 1);

        // a duplicate name within a type is refused, and the disk is untouched by it
        ++checks;
        const auto hashBefore = imageHash (d);
        if (d.addSample (saw, why)) fail ("built", "a second SAW was allowed", 1, 0);
        result ("duplicate", false, why);
        ++checks; if (imageHash (d) != hashBefore) fail ("built", "a refused sample moved bytes", 1, 0);

        const auto& es = d.getEntries();
        ++checks;
        if (es.size() != 5) { fail ("built", "five entries", static_cast<int> (es.size()), 5); return; }

        const char order[] = { 'P', 'P', 'S', 'S', 'S' };
        for (int i = 0; i < 5; ++i)
        {
            ++checks;
            if (es[static_cast<std::size_t> (i)].slot != i || es[static_cast<std::size_t> (i)].type != order[i])
                fail ("built", "directory order and contiguity", es[static_cast<std::size_t> (i)].slot, i);
        }

        const Disk::Entry* lead = d.find ("LEAD", 'P');
        const Disk::Entry* kit  = d.find ("KIT",  'P');
        const Disk::Entry* sawE = d.find ("SAW",  'S');
        const Disk::Entry* kkE  = d.find ("KICK", 'S');
        const Disk::Entry* bigE = d.find ("LONG", 'S');

        ++checks;
        if (! lead || ! kit || ! sawE || ! kkE || ! bigE) { fail ("built", "every file found by name", 0, 1); return; }

        ++checks; if (sawE->sampleCount != 1222)   fail ("built", "SAW words (odd one dropped)", static_cast<int> (sawE->sampleCount), 1222);
        ++checks; if (sawE->sampleRate  != 40000)  fail ("built", "SAW rate", sawE->sampleRate, 40000);
        ++checks; if (sawE->loopMode    != 'L')    fail ("built", "SAW looped", sawE->loopMode, 'L');
        ++checks; if (kkE->loopMode     != 'O')    fail ("built", "KICK one-shot", kkE->loopMode, 'O');
        ++checks; if (sawE->loopLength  != 1222)   fail ("built", "SAW loop is the whole sample", static_cast<int> (sawE->loopLength), 1222);

        auto same = [&] (const Disk::Entry& e, const std::vector<short>& want, const char* what)
        {
            const auto got = d.sampleWords12 (e);
            const std::size_t n = want.size() & ~static_cast<std::size_t> (1);
            ++checks;
            if (got.size() != n) { fail ("built", what, static_cast<int> (got.size()), static_cast<int> (n)); return; }
            for (std::size_t i = 0; i < n; ++i)
                if (got[i] != want[i]) { fail ("built", what, got[i], want[i]); return; }
        };
        same (*sawE, saw.words12,  "SAW audio round-trips");
        same (*kkE,  kick.words12, "KICK audio round-trips");
        same (*bigE, big.words12,  "LONG audio round-trips");

        auto header = [&] (const Disk::Entry& e, int at) { return static_cast<int> (d.getImage()[static_cast<std::size_t> (e.startBlock * Disk::BlockSize + at)]); };
        auto mem = [&] (const Disk::Entry& e) { return header (e, 0x36) | (header (e, 0x37) << 8) | (header (e, 0x38) << 16); };
        auto lp  = [&] (const Disk::Entry& e) { return header (e, 0x28) | (header (e, 0x29) << 8); };

        ++checks; if (mem (*sawE) != 0x18000)          fail ("built", "first sample at the RAM base", mem (*sawE), 0x18000);
        ++checks; if (mem (*kkE)  != 0x18000 + 2448)   fail ("built", "second follows: 1222 words in sixteens", mem (*kkE), 0x18000 + 2448);
        ++checks; if (mem (*bigE) != 0x18000 + 2448 + 12000) fail ("built", "third follows", mem (*bigE), 0x18000 + 2448 + 12000);
        ++checks; if (lp (*sawE)  != 0xB6F4)           fail ("built", "first loop descriptor", lp (*sawE), 0xB6F4);
        ++checks; if (lp (*kkE)   != 0xB6F4 + 30)      fail ("built", "a looped sample takes three", lp (*kkE), 0xB6F4 + 30);
        ++checks; if (lp (*bigE)  != 0xB6F4 + 30 + 20) fail ("built", "a one-shot takes two", lp (*bigE), 0xB6F4 + 50);

        ++checks; if (! d.setZoneSample (*lead, 0, 0, "SAW"))  fail ("built", "zone SAW", 0, 1);
        ++checks; if (! d.setZoneSample (*lead, 1, 0, "LONG")) fail ("built", "zone LONG", 0, 1);
        ++checks; if (! d.setZoneSample (*kit,  0, 0, "KICK")) fail ("built", "zone KICK", 0, 1);
        ++checks; if (d.setZoneSample (*kit, 1, 0, "KICK"))    fail ("built", "no third keygroup to name", 1, 0);

        d.setKeygroupParam (*kit, 0, KeygroupParam::ConstantPitch, 1);
        d.setKeygroupParam (*kit, 0, KeygroupParam::OneShot, 1);
        d.setKeygroupParam (*kit, 0, KeygroupParam::LowKey, 36);
        d.setKeygroupParam (*kit, 0, KeygroupParam::HighKey, 36);

        const int firstRebuild = d.rebuildPointers();
        ++checks;
        const int secondRebuild = d.rebuildPointers();
        if (secondRebuild != 0) fail ("built", "a second rebuild changes nothing", 1, 0);
        std::fprintf (out, "built rebuild %d %d\n", firstRebuild, secondRebuild);

        const int arena = 0xC5F6, table = arena + 70 * 4;
        const auto leadRaw = d.readFile (*lead);
        const auto kitRaw  = d.readFile (*kit);
        auto u16 = [] (const std::vector<unsigned char>& b, int at) { return static_cast<int> (b[static_cast<std::size_t> (at)]) | (static_cast<int> (b[static_cast<std::size_t> (at) + 1]) << 8); };

        ++checks; if (u16 (leadRaw, 18) != arena)          fail ("built", "LEAD loads at the arena", u16 (leadRaw, 18), arena);
        ++checks; if (leadRaw[23] != 2)                    fail ("built", "LEAD header counts two", leadRaw[23], 2);
        ++checks; if (u16 (kitRaw, 18) != arena + 70 * 3)  fail ("built", "KIT loads after the empty record", u16 (kitRaw, 18), arena + 210);
        ++checks; if (kitRaw[23] != 1)                     fail ("built", "KIT header counts one", kitRaw[23], 1);

        ++checks; if (u16 (leadRaw, 38 + 68) != arena + 70)      fail ("built", "LEAD kg0 chains to kg1", u16 (leadRaw, 38 + 68), arena + 70);
        ++checks; if (u16 (leadRaw, 38 + 70 + 68) != 0)          fail ("built", "LEAD kg1 ends the chain", u16 (leadRaw, 38 + 70 + 68), 0);
        ++checks; if (u16 (kitRaw, 38 + 68) != 0)                fail ("built", "KIT kg0 ends the chain", u16 (kitRaw, 38 + 68), 0);

        ++checks; if (u16 (leadRaw, 38 + 40) != table)           fail ("built", "SAW is sample 0", u16 (leadRaw, 38 + 40), table);
        ++checks; if (u16 (leadRaw, 38 + 70 + 40) != table + 140) fail ("built", "LONG is sample 2", u16 (leadRaw, 38 + 70 + 40), table + 140);
        ++checks; if (u16 (kitRaw, 38 + 40) != table + 70)       fail ("built", "KICK is sample 1", u16 (kitRaw, 38 + 40), table + 70);
        ++checks; if (u16 (leadRaw, 38 + 62) != 0)               fail ("built", "an empty zone points nowhere", u16 (leadRaw, 38 + 62), 0);

        auto patch = d.buildPatch (*lead);
        ++checks;
        if (patch == nullptr || patch->keygroups.size() != 2 || patch->keygroups[0].sound == nullptr
            || patch->keygroups[1].sound == nullptr)
            fail ("built", "LEAD plays two keygroups with sounds", 0, 2);

        auto kitPatch = d.buildPatch (*kit);
        ++checks;
        if (kitPatch == nullptr || kitPatch->keygroups.size() != 1 || ! kitPatch->keygroups[0].constantPitch
            || ! kitPatch->keygroups[0].oneShot || kitPatch->keygroups[0].lowKey != 36)
            fail ("built", "KIT is a one-shot drum on 36", 0, 1);

        logEntries (d, "built");
        ++checks; if (! save (d, dir + "\\built_" + tag + ".img")) fail ("built", "could not write", 0, 1);
    }

    /// DiskEditCheck's high-density disk.
    void hdDisk (const std::string& dir, const std::string& tag)
    {
        std::unique_ptr<Disk> hold (new Disk (Disk::blank ("HD", true)));
        Disk& d = *hold;
        std::string why;

        ++checks; if (d.getImage().size() != 1638400) fail ("hd", "1600K", static_cast<int> (d.getImage().size() / 1024), 1600);
        ++checks; if (! d.isHighDensity() || d.headerBlocks() != 5) fail ("hd", "a five-block header", d.headerBlocks(), 5);

        std::vector<std::vector<short>> waves;
        for (int k = 0; k < 6; ++k)
        {
            std::vector<short> w (140000);
            for (int i = 0; i < 140000; ++i)
                w[static_cast<std::size_t> (i)] = static_cast<short> (((i * (k + 3)) % 4096) - 2048);
            waves.push_back (w);

            Disk::NewSample s; s.name = "HD" + std::to_string (k); s.words12 = w; s.rate = 48000;
            ++checks; if (! d.addSample (s, why)) fail ("hd", ("sample " + std::to_string (k) + ": " + why).c_str(), 0, 1);
        }
        ++checks; if (! d.addProgram ("HD PROG", 1, why)) fail ("hd", why.c_str(), 0, 1);

        int lowest = 1 << 30, highest = 0;
        for (const auto& e : d.getEntries())
        {
            lowest = std::min (lowest, e.startBlock);
            highest = std::max (highest, e.startBlock + e.chainBlocks - 1);
        }
        ++checks; if (lowest != 5) fail ("hd", "file data starts at block 5", lowest, 5);
        ++checks; if (highest <= 800) fail ("hd", "the files reach past block 800", highest, 801);

        Disk back;
        ++checks;
        if (! back.loadBytes ("HD", d.getImage(), why)) fail ("hd", ("reload: " + why).c_str(), 0, 1);
        else
        {
            ++checks; if (back.getEntries().size() != 7) fail ("hd", "seven files come back", static_cast<int> (back.getEntries().size()), 7);
            for (int k = 0; k < 6; ++k)
            {
                const Disk::Entry* e = back.find ("HD" + std::to_string (k), 'S');
                ++checks;
                if (e == nullptr) { fail ("hd", "a sample comes back by name", 0, 1); continue; }
                ++checks; if (e->sampleRate != 48000) fail ("hd", "48 kHz survives", e->sampleRate, 48000);
                const auto got = back.sampleWords12 (*e);
                ++checks;
                if (got != waves[static_cast<std::size_t> (k)]) fail ("hd", ("sample " + std::to_string (k) + " audio round-trips").c_str(), static_cast<int> (got.size()), 140000);
            }
        }

        // And filled to the last block: the message a full HD disk gives.
        int added = 0;
        for (int k = 6; k < 40; ++k)
        {
            Disk::NewSample s; s.name = "FILL" + std::to_string (k); s.words12 = waves[static_cast<std::size_t> (k % 6)]; s.loopMode = 'A';
            const bool ok = d.addSample (s, why);
            if (! ok) { result ("hd full", ok, why); break; }
            ++added;
        }
        std::fprintf (out, "hd filled with %d more\n", added);
        logEntries (d, "hd");
        ++checks; if (! save (d, dir + "\\hd_" + tag + ".img")) fail ("hd", "could not write", 0, 1);
    }

    /// The failures, and the names, and their messages.
    void failures_ (const std::string& dir, const std::string& tag)
    {
        std::string why;
        {
            Disk d = Disk::blank();
            Disk::NewSample s; s.name = "one"; s.words12 = { 5 };
            result ("one word", d.addSample (s, why), why);
            s.words12.clear();
            result ("no words", d.addSample (s, why), why);
            result ("programme 0", d.addProgram ("p", 0, why), why);
            result ("programme 65", d.addProgram ("p", 65, why), why);
            result ("programme 64", d.addProgram ("p64", 64, why), why);
            result ("programme 64 again", d.addProgram ("P64 ", 64, why), why);
            result ("programme 1", d.addProgram ("p1", 1, why), why);

            Disk::NewSample huge; huge.name = "huge"; huge.words12 = sawWords (600000);
            result ("huge", d.addSample (huge, why), why);
            logEntries (d, "programmes");
        }

        // a directory filled to its 64 slots
        {
            Disk d = Disk::blank ("FULL");
            int added = 0;
            for (int i = 0; i < 70; ++i)
            {
                Disk::NewSample s; s.name = "s" + std::to_string (i); s.words12 = sawWords (2 + i);
                if (! d.addSample (s, why)) { result ("directory", false, why); break; }
                ++added;
            }
            std::fprintf (out, "directory took %d\n", added);
            result ("programme into a full directory", d.addProgram ("late", 1, why), why);
            logEntries (d, "full");
        }

        // 63 samples, then a programme: the slot opened in front of them
        {
            Disk d = Disk::blank ("OPEN");
            for (int i = 0; i < 63; ++i)
            {
                Disk::NewSample s; s.name = "t" + std::to_string (i); s.words12 = sawWords (40 + i); s.loopMode = (i % 3 == 0 ? 'O' : (i % 3 == 1 ? 'L' : 'A'));
                d.addSample (s, why);
            }
            result ("programme in front", d.addProgram ("front", 2, why), why);
            const Disk::Entry* p = d.find ("FRONT", 'P');
            if (p != nullptr) { d.setZoneSample (*p, 0, 0, "t5"); d.setZoneSample (*p, 1, 1, "T62"); }
            std::fprintf (out, "open rebuild %d\n", d.rebuildPointers());
            logEntries (d, "open");
            ++checks; if (! save (d, dir + "\\open_" + tag + ".img")) fail ("open", "could not write", 0, 1);
        }

        // a disk filled by blocks
        {
            Disk d = Disk::blank ("BLOCKS");
            int added = 0;
            for (int i = 0; i < 40; ++i)
            {
                Disk::NewSample s; s.name = "big" + std::to_string (i); s.words12 = sawWords (100000);
                if (! d.addSample (s, why)) { result ("blocks", false, why); break; }
                ++added;
            }
            std::fprintf (out, "blocks took %d\n", added);
            result ("programme onto a full disk", d.addProgram ("late", 1, why), why);
            logEntries (d, "blocks");
        }

        // names
        for (const char* n : { "", "   ", "abcdefghijklmnop", "a\tb", " lead ", "Mixed Case", "x\x7f" "y", "2 sample" })
            std::fprintf (out, "normalise '%s'\n", Disk::normaliseNameFor (n).c_str());
    }

    /// A disk holding what the library disks lack: blank S900 filter envelopes (every
    /// fresh keygroup has them), alternating, one-shot and short loops, a rate the engine
    /// falls back from, fine tuning, two-zone keygroups at every kind of switch.
    Disk richDisk()
    {
        Disk d = Disk::blank ("RICH");
        std::string why;

        struct { const char* name; int n; int rate; int root; int fine; char mode; int loop; } samples[] =
        {
            { "alt", 5000, 30000, 48, 5, 'A', 1200 }, { "shot", 3001, 44100, 60, 15, 'O', -1 },
            { "short", 900, 500, 72, 0, 'L', 7 },     { "zero", 2000, 40000, 59, 8, 'L', 0 },
            { "over", 1500, 20000, 61, 3, 'A', 99999 }, { "plain", 4000, 32000, 36, 0, 'L', -1 },
        };
        for (const auto& s : samples)
        {
            Disk::NewSample ns; ns.name = s.name; ns.words12 = sawWords (s.n); ns.rate = s.rate; ns.rootNote = s.root;
            ns.fine = s.fine; ns.loopMode = s.mode; ns.loopLength = s.loop;
            for (std::size_t i = 0; i < ns.words12.size(); i += 7) ns.words12[i] = static_cast<short> (i % 5000 - 2500);  // and clipped
            result ("rich sample", d.addSample (ns, why), why);
        }

        result ("rich prog A", d.addProgram ("prog a", 4, why), why);
        result ("rich prog B", d.addProgram ("prog b", 3, why), why);

        const Disk::Entry* a = d.find ("PROG A", 'P');
        const Disk::Entry* b = d.find ("PROG B", 'P');
        if (a == nullptr || b == nullptr) { fail ("rich", "programmes", 0, 1); return d; }

        const char* names[] = { "alt", "shot", "short", "zero", "over", "plain" };
        const int switches[] = { 1, 64, 127, 128 };
        for (int k = 0; k < 4; ++k)
        {
            d.setZoneSample (*a, k, 0, names[k]);
            d.setZoneSample (*a, k, 1, names[(k + 2) % 6]);
            d.setKeygroupParam (*a, k, KeygroupParam::VelocitySwitch, switches[k]);
            d.setKeygroupParam (*a, k, KeygroupParam::LowKey, 20 * k);
            d.setKeygroupParam (*a, k, KeygroupParam::HighKey, 20 * k + 30);
            d.setKeygroupParam (*a, k, KeygroupParam::Zone2Transpose, k - 2);
            d.setKeygroupParam (*a, k, KeygroupParam::Zone1Fine, 40 * k);
        }
        for (int k = 0; k < 3; ++k)
            d.setZoneSample (*b, k, 0, names[3 + k]);
        d.setZoneSample (*b, 2, 1, "plain");          // a second zone at the default switch
        d.setKeygroupParam (*b, 0, KeygroupParam::VcfSustain, 50);   // one blank envelope written

        std::fprintf (out, "rich rebuild %d\n", d.rebuildPointers());
        logEntries (d, "rich");
        return d;
    }
}

int main (int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf (stderr, "usage: diskedit_cpp <log.txt> <imagedir> <tag> [<image> ...]\n");
        return 2;
    }

    out = std::fopen (argv[1], "wb");
    if (out == nullptr) { std::fprintf (stderr, "cannot write %s\n", argv[1]); return 2; }
    const std::string dir = argv[2], tag = argv[3];

    /*
     * A zone's pitch: transpose and fine as one signed 16-bit count of sixteenths of a
     * semitone.
     */
    {
        struct { int fine, transpose; double semitones; } cases[] =
        {
            { 192, 0, 12 }, { 80, 0, 5 }, { 0, 0, 0 }, { 144, -1, -7 }, { 64, -1, -12 },
            { 128, 1, 24 }, { 255, -1, -1.0 / 16 }
        };
        for (const auto& c : cases)
        {
            Disk::Zone z;
            z.fine = c.fine; z.transpose = c.transpose;
            ++checks;
            if (z.pitchOffset() != c.semitones)
                fail ("zone pitch", ("fine " + std::to_string (c.fine) + " transpose " + std::to_string (c.transpose)).c_str(),
                      static_cast<int> (z.pitchOffset() * 16), static_cast<int> (c.semitones * 16));
        }
    }

    std::fprintf (out, "making a disk from nothing\n");
    builtDisk (dir, tag);
    std::fprintf (out, "a high-density disk\n");
    hdDisk (dir, tag);
    std::fprintf (out, "failures\n");
    failures_ (dir, tag);

    int disks = 0;
    {
        Disk rich = richDisk();
        ++checks; if (! save (rich, dir + "\\rich_" + tag + ".img")) fail ("rich", "could not write", 0, 1);
        editDisk (rich, "RICH", dir, tag);
        ++disks;
    }

    // An argument @file names a file listing images, one to a line.
    std::vector<std::string> paths;
    for (int i = 4; i < argc; ++i)
    {
        if (argv[i][0] != '@') { paths.push_back (argv[i]); continue; }
        std::ifstream list (argv[i] + 1);
        std::string path;
        while (std::getline (list, path))
        {
            while (! path.empty() && (path.back() == '\r' || path.back() == ' ')) path.pop_back();
            if (! path.empty()) paths.push_back (path);
        }
    }

    for (const auto& path : paths)
    {
        Disk original;
        std::string error;
        if (! original.loadFile (path, error))
        {
            fail (path, "could not read", 0, 1);
            continue;
        }
        std::string label = path;
        const auto at = label.find_last_of ("\\/");
        if (at != std::string::npos) label = label.substr (at + 1);
        const auto dot = label.rfind ('.');
        if (dot != std::string::npos) label = label.substr (0, dot);
        editDisk (original, label, dir, tag);
        ++disks;
    }

    std::fprintf (out, "%d disks, %d edits, %d checks, %d failed\n", disks, edits, checks, failures);
    std::fclose (out);
    std::printf ("diskedit_cpp: %d disks, %d edits, %d checks, %d failed\n", disks, edits, checks, failures);
    return failures == 0 ? 0 : 1;
}
