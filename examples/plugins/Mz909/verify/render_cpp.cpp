// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Equivalence harness, C++ side: renders scenarios.txt through the ORIGINAL engine,
// compiled straight from the Mz909 repository's Source/TR909 (see build_verify.cmd).
// Factory presets are read from that repository's Source/Presets.cpp, so the Pascal
// preset table is checked against the real one, not a copy.
//
//     render_cpp <scenarios.txt> <Presets.cpp> <outdir>

#define _CRT_SECURE_NO_WARNINGS

#include "Engine.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using namespace tr909;

namespace
{

// Parameter ID -> Settings member, as Params.cpp's table.
const std::map<std::string, float Settings::*>& fields()
{
    using S = Settings;
    static const std::map<std::string, float Settings::*> m = {
        { "accent", &S::accent },
        { "bdLevel", &S::bdLevel }, { "bdTune", &S::bdTune }, { "bdAttack", &S::bdAttack }, { "bdDecay", &S::bdDecay },
        { "sdLevel", &S::sdLevel }, { "sdTune", &S::sdTune }, { "sdTone", &S::sdTone }, { "sdSnappy", &S::sdSnappy },
        { "ltLevel", &S::ltLevel }, { "ltTune", &S::ltTune }, { "ltDecay", &S::ltDecay },
        { "mtLevel", &S::mtLevel }, { "mtTune", &S::mtTune }, { "mtDecay", &S::mtDecay },
        { "htLevel", &S::htLevel }, { "htTune", &S::htTune }, { "htDecay", &S::htDecay },
        { "rsLevel", &S::rsLevel }, { "cpLevel", &S::cpLevel },
        { "hhLevel", &S::hhLevel }, { "chDecay", &S::chDecay }, { "ohDecay", &S::ohDecay },
        { "crLevel", &S::crLevel }, { "crTune", &S::crTune }, { "rdLevel", &S::rdLevel }, { "rdTune", &S::rdTune },
        { "volume", &S::volume },
    };
    return m;
}

bool setField(Settings& s, const std::string& id, double v)
{
    const auto it = fields().find(id);
    if (it == fields().end()) return false;
    s.*(it->second) = (float) v;
    return true;
}

// The factory presets, parsed out of Presets.cpp: { "Name", { { "id", value }, ... } }
std::map<std::string, std::vector<std::pair<std::string, double>>> readPresets(const std::string& path)
{
    std::ifstream in(path);
    std::stringstream ss;
    ss << in.rdbuf();
    const std::string text = ss.str();

    std::map<std::string, std::vector<std::pair<std::string, double>>> out;
    const std::regex head(R"re(\{\s*"([^"]+)"\s*,\s*\{)re");
    const std::regex pair(R"re(\{\s*"(\w+)"\s*,\s*(-?[0-9.]+)f?\s*\})re");

    for (auto it = std::sregex_iterator(text.begin(), text.end(), head); it != std::sregex_iterator(); ++it)
    {
        // the value list runs from its opening brace to the matching close
        size_t p = (size_t) (it->position(0) + it->length(0));
        int depth = 1;
        const size_t start = p;
        while (p < text.size() && depth > 0)
        {
            if (text[p] == '{') ++depth;
            else if (text[p] == '}') --depth;
            ++p;
        }
        const std::string body = text.substr(start, p - start);
        auto& list = out[(*it)[1].str()];
        for (auto v = std::sregex_iterator(body.begin(), body.end(), pair); v != std::sregex_iterator(); ++v)
            list.push_back({ (*v)[1].str(), std::stod((*v)[2].str()) });
    }
    return out;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: render_cpp <scenarios.txt> <Presets.cpp> <outdir>\n");
        return 2;
    }

    const auto presets = readPresets(argv[2]);
    std::printf("presets parsed from Presets.cpp: %d\n", (int) presets.size());

    std::ifstream script(argv[1]);
    const std::string outDir = argv[3];
    std::string line;

    // The ROMs are built by the first Engine; time it.
    {
        const auto t0 = std::chrono::steady_clock::now();
        Engine first;
        std::printf("C++ ROMs built in %.3f s\n",
                    std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
    }

    Engine* e = nullptr;
    Settings pending;
    std::string name;
    double rate = 48000;
    std::vector<float> out, block;
    double totalRendered = 0, totalSeconds = 0;
    int lineNo = 0, scenarios = 0;

    auto render = [&] (int samples, int blockSize)
    {
        if (blockSize <= 0) blockSize = samples;
        const auto t0 = std::chrono::steady_clock::now();
        for (int done = 0; done < samples; )
        {
            const int n = std::min(blockSize, samples - done);
            block.resize((size_t) n);
            e->render(block.data(), n);
            out.insert(out.end(), block.begin(), block.end());
            done += n;
        }
        totalSeconds += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        totalRendered += samples / rate;
    };

    while (std::getline(script, line))
    {
        ++lineNo;
        std::istringstream ls(line);
        std::string cmd;
        if (! (ls >> cmd) || cmd[0] == '#') continue;

        if (cmd == "scenario")
        {
            ls >> name >> rate;
            delete e;
            e = new Engine();
            e->prepare(rate);
            pending = Settings();
            out.clear();
        }
        else if (cmd == "set")
        {
            std::string id; double v;
            ls >> id >> v;
            if (! setField(pending, id, v)) { std::fprintf(stderr, "line %d: unknown id %s\n", lineNo, id.c_str()); return 1; }
        }
        else if (cmd == "patch")
        {
            std::string pname;
            std::getline(ls >> std::ws, pname);
            const auto it = presets.find(pname);
            if (it == presets.end()) { std::fprintf(stderr, "line %d: no preset %s\n", lineNo, pname.c_str()); return 1; }
            pending = Settings();
            for (const auto& [id, v] : it->second)
                if (! setField(pending, id, v)) { std::fprintf(stderr, "preset id %s?\n", id.c_str()); return 1; }
        }
        else if (cmd == "apply") e->setSettings(pending);
        else if (cmd == "on")  { int n, vel = 100; ls >> n; ls >> vel; e->noteOn(n, vel); }
        else if (cmd == "hit") { int v, acc = 0; ls >> v; ls >> acc; e->trigger(v, acc != 0); }
        else if (cmd == "allsoundoff") e->allSoundOff();
        else if (cmd == "prepare") { ls >> rate; e->prepare(rate); }
        else if (cmd == "render")
        {
            int samples, blockSize = 0;
            ls >> samples;
            ls >> blockSize;
            render(samples, blockSize);
        }
        else if (cmd == "roms")
        {
            // the four ROMs' bytes, as floats, and each one's clock: compared like audio
            for (const Rom* r : { &closedHatRom(), &openHatRom(), &crashRom(), &rideRom() })
            {
                out.push_back(r->clock);
                out.push_back((float) r->data.size());
                for (const auto v : r->data) out.push_back((float) v);
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
                scenarios, totalRendered, totalSeconds, totalRendered / totalSeconds);
    return 0;
}
