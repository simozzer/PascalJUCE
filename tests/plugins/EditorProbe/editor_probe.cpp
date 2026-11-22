/*
    EditorProbe - a plug-in library written in C++ straight against
    juce_c_plugin.h, for testing the wrapper's custom-editor support.

    Unlike a Pascal library it can call every editor function with arguments
    no well-behaved library would pass (NaN, stale handles, other threads,
    corrupt images, lying sizes). Scripted checks run on request
    (editor_probe_state.action); in fuzz mode every callback makes
    calls_per_callback random calls. Driven by tests/fuzz/fuzz_editor.cpp.
*/
#include "editor_probe.h"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <random>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
    #define PROBE_EXPORT extern "C" __declspec(dllexport)
#else
    #define PROBE_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace
{
editor_probe_state S {};

void fail(const char* what)
{
    ++S.failures;
    std::snprintf(S.last_failure, sizeof(S.last_failure), "%s", what);
}

#define PROBE_CHECK(cond, what) do { if (! (cond)) fail(what); } while (0)

//==============================================================================
// Parameters
struct Param
{
    const char* id;
    const char* name;
    int32_t kind;
    const char* choices;
    float minValue, maxValue, defaultValue;
};

const Param params[] = {
    { "a", "Alpha", JCP_PARAM_FLOAT, "", 0.0f, 1.0f, 0.5f },
    { "b", "Beta", JCP_PARAM_CHOICE, "x|y|z", 0.0f, 2.0f, 0.0f },
    { "c", "Gamma", JCP_PARAM_BOOL, "", 0.0f, 1.0f, 0.0f },
};
constexpr int numParams = 3;

int32_t JCP_CALL getParameterCount() { return numParams; }

int32_t JCP_CALL getParameterInfo(int32_t index, jcp_parameter_info* info)
{
    if (index < 0 || index >= numParams || info == nullptr || info->struct_size < (int32_t) sizeof(jcp_parameter_info))
        return 1;
    const auto& p = params[index];
    info->kind = p.kind;
    info->id = p.id;
    info->name = p.name;
    info->label = "";
    info->choices = p.choices;
    info->min_value = p.minValue;
    info->max_value = p.maxValue;
    info->default_value = p.defaultValue;
    info->step = 0.0f;
    info->flags = JCP_PARAM_FLAG_AUTOMATABLE;
    info->version_hint = 1;
    return 0;
}

//==============================================================================
struct Instance
{
    const jcp_host_api* api = nullptr;
    jcp_host* host = nullptr;
};

struct ProbeEditor
{
    Instance* owner = nullptr;
    const jcp_editor_api* api = nullptr;
    jcp_editor* handle = nullptr;
    bool inCallback = false;
    bool destroyed = false;
    jcp_graphics* lastGraphics = nullptr;
    std::vector<int32_t> images;
};

// Destroyed editors are kept (marked) so a late callback is counted, not a crash.
std::vector<std::unique_ptr<ProbeEditor>> allEditors;
jcp_editor* lastHandle = nullptr;
const jcp_editor_api* lastApi = nullptr;
std::mt19937 rng;

struct CallbackScope
{
    explicit CallbackScope(ProbeEditor* e) : ed(e)
    {
        if (ed->inCallback)
            ++S.reentrant_callbacks;
        if (ed->destroyed)
            ++S.callback_after_destroy;
        wasInside = ed->inCallback;
        ed->inCallback = true;
    }
    ~CallbackScope() { ed->inCallback = wasInside; }
    ProbeEditor* ed;
    bool wasInside = false;
};

//==============================================================================
// Random arguments
float rf()
{
    switch (rng() % 14)
    {
        case 0: return 0.0f;
        case 1: return 1.0f;
        case 2: return -1.0f;
        case 3: return std::numeric_limits<float>::quiet_NaN();
        case 4: return std::numeric_limits<float>::infinity();
        case 5: return -std::numeric_limits<float>::infinity();
        case 6: return 1.0e30f;
        case 7: return -1.0e30f;
        case 8: return 1.0e-40f;
        case 9: return 65536.0f;
        case 10: return 0.5f;
        default: return std::uniform_real_distribution<float>(-200.0f, 900.0f)(rng);
    }
}

int32_t ri()
{
    switch (rng() % 9)
    {
        case 0: return 0;
        case 1: return -1;
        case 2: return std::numeric_limits<int32_t>::min();
        case 3: return std::numeric_limits<int32_t>::max();
        case 4: return 1;
        case 5: return (int32_t) (rng() % 8);
        case 6: return (int32_t) (rng() % 5000);
        default: return (int32_t) (rng() % 300);
    }
}

jcp_editor* re(ProbeEditor* e)
{
    switch (rng() % 24)
    {
        case 0: return nullptr;
        case 1: return reinterpret_cast<jcp_editor*>((uintptr_t) rng());
        case 2: return lastHandle;
        default: return e->handle;
    }
}

jcp_graphics* rg(ProbeEditor* e, jcp_graphics* current)
{
    switch (rng() % 24)
    {
        case 0: return nullptr;
        case 1: return reinterpret_cast<jcp_graphics*>((uintptr_t) rng());
        case 2: return e->lastGraphics;
        default: return current;
    }
}

const char* rs(std::string& storage)
{
    switch (rng() % 12)
    {
        case 0: return nullptr;
        case 1: storage = ""; break;
        case 2: storage = "Probe text"; break;
        case 3: storage = "\xC3\xA9t\xC3\xA9 \xE2\x82\xAC \xF0\x9F\x8E\xB9"; break; // valid UTF-8
        case 4: storage = "bad \xC3"; break;                                     // truncated
        case 5: storage = "surrogate \xED\xA0\x80"; break;
        case 6: storage = "overlong \xC0\xAF"; break;
        case 7: storage.assign(5000 + rng() % 100, 'x'); break;                    // longer than the limit
        case 8: storage = "a"; break;
        default:
        {
            storage.clear();
            const auto n = rng() % 64;
            for (unsigned i = 0; i < n; ++i)
                storage.push_back((char) (1 + rng() % 255));
            break;
        }
    }
    return storage.c_str();
}

uint32_t crc32(const uint8_t* p, size_t n)
{
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i)
    {
        c ^= p[i];
        for (int k = 0; k < 8; ++k)
            c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    }
    return c ^ 0xFFFFFFFFu;
}

// Recompute every PNG chunk CRC that lies inside the data, so a mutation gets
// past the wrapper's CRC check and reaches libpng itself.
void fixPngCrcs(std::vector<uint8_t>& d)
{
    size_t pos = 8;
    while (d.size() >= 12 && pos <= d.size() - 12)
    {
        const uint32_t len = ((uint32_t) d[pos] << 24) | ((uint32_t) d[pos + 1] << 16) | ((uint32_t) d[pos + 2] << 8) | d[pos + 3];
        if (len > d.size() - pos - 12)
            return;
        const uint32_t c = crc32(d.data() + pos + 4, (size_t) len + 4);
        uint8_t* out = d.data() + pos + 8 + len;
        out[0] = (uint8_t) (c >> 24); out[1] = (uint8_t) (c >> 16); out[2] = (uint8_t) (c >> 8); out[3] = (uint8_t) c;
        pos += 12 + (size_t) len;
    }
}

#ifdef PASCALJUCE_PRIVATE_TESTS
#include "../../private/probe_extra.inc"
#endif

std::vector<uint8_t> randomImage()
{
    std::vector<uint8_t> data;
    const auto pick = rng() % 6;
    if (pick <= 1 && S.png != nullptr)
        data.assign(S.png, S.png + S.png_size);
    else if (pick == 2 && S.jpeg != nullptr)
        data.assign(S.jpeg, S.jpeg + S.jpeg_size);
    else if (pick == 3)
    {
        data.resize(rng() % 256);
        for (auto& b : data)
            b = (uint8_t) rng();
        return data;
    }
    else if (S.png != nullptr)
        data.assign(S.png, S.png + S.png_size);
    // mutate
    const int rounds = (int) (rng() % 5);
    for (int r = 0; r < rounds && ! data.empty(); ++r)
    {
        switch (rng() % 5)
        {
            case 0: data[rng() % data.size()] ^= (uint8_t) (1u << (rng() % 8)); break;
            case 1: data.resize(rng() % data.size()); break;
            case 2: data[rng() % data.size()] = (uint8_t) rng(); break;
            case 3: if (data.size() > 24) { data[16] = (uint8_t) rng(); data[20] = (uint8_t) rng(); } break; // PNG dimensions
            case 4: data.insert(data.begin() + (long) (rng() % data.size()), (uint8_t) rng()); break;
        }
    }
    if (data.size() > 8 && data[0] == 0x89 && rng() % 2 == 0)
        fixPngCrcs(data);
    return data;
}

//==============================================================================
// One random API call. `g` is the graphics token if we are inside paint.
// URLs for open_url: a few good ones and many that must be refused.
const char* const goodUrls[] = { "https://github.com/simozzer/Mz101", "HTTPS://Example.COM:8443/a/b-c_d.e~f?q=1&r=%41#top" };
const char* const badUrls[] = {
    "", "http://example.com/", "file:///C:/Windows/System32/calc.exe", "file://server/share", "javascript:alert(1)",
    "mailto:a@example.com", "ftp://example.com/", " https://example.com/", "https://", "https:///path", "https://.com/",
    "https://example.com/a b", "https://example.com/\"&calc", "https://example.com/$(id)", "https://example.com/`id`",
    "https://example.com/a;b", "https://example.com/a|b", "https://example.com/'x'", "https://example.com/<x>",
    "https://example.com/(x)", "https://example.com/*", "https://example.com/!", "https://example.com/\\x",
    "https://example.com/{x}", "https://example.com/^", "https://exa_mple.com/", "https://user@example.com/",
    "https://user:pw@example.com/", "https://127.0.0.1/", "https://localhost/", "https://[::1]/", "https://10.0.0.1:8080/",
    "https://example.com:0/", "https://example.com:65536/", "https://example.com:/", "https://example.com:99999999/",
    "https://example.com:8a/", "https://-x.com/", "https://x-.com/", "https://example.123/", "https://example.com/%00",
    "https://example.com/%0A", "https://example.com/%7f", "https://example.com/%zz", "https://example.com/%4",
    "https://example.com/%", "https://example.com/\xC3\xA9", "https://exa%6Dple.com/", "https://example.com/\n",
    "https://example.com/\t", "https://example..com/", "https://example.com./", "https:\\\\example.com\\",
    "https://example.com/\x7F", "https://ex\xC3" "ample.com/",
};

const char* ru(std::string& storage)
{
    switch (rng() % 10)
    {
        case 0: return nullptr;
        case 1: return goodUrls[rng() % (sizeof(goodUrls) / sizeof(goodUrls[0]))];
        case 2: storage = "https://example.com/" + std::string(2100 + rng() % 50, 'a'); return storage.c_str(); // too long
        case 3: storage = "https://" + std::string(64, 'a') + ".com/"; return storage.c_str();               // label too long
        case 4:
        {
            storage = goodUrls[0];
            storage[rng() % storage.size()] = (char) (rng() % 256); // one byte changed: usually refused
            return storage.c_str();
        }
        default: return badUrls[rng() % (sizeof(badUrls) / sizeof(badUrls[0]))];
    }
}

// A look for set_look, mostly hostile.
const jcp_editor_look* rl(jcp_editor_look& look, std::string& font)
{
    if (rng() % 8 == 0)
        return nullptr;
    look = {};
    look.struct_size = rng() % 6 == 0 ? (int32_t) (rng() % sizeof(jcp_editor_look)) : (int32_t) sizeof(jcp_editor_look);
    look.tooltip_background = (uint32_t) rng();
    look.tooltip_text = (uint32_t) rng();
    look.tooltip_outline = rng() % 2 ? 0u : (uint32_t) rng();
    look.menu_background = (uint32_t) rng();
    look.menu_text = (uint32_t) rng();
    look.menu_highlight = (uint32_t) rng();
    look.menu_highlight_text = rng() % 2 ? 0u : (uint32_t) rng();
    look.menu_header_text = (uint32_t) rng();
    look.tooltip_font_height = rf();
    look.menu_font_height = rf();
    look.font_name = rs(font);
    return &look;
}

void fuzzCall(ProbeEditor* e, jcp_graphics* g)
{
    const jcp_editor_api* a = e->api;
    std::string s1, s2;
    ++S.api_calls;
    const int32_t which = (int32_t) (rng() % 52);
    S.current_call = which;
    struct Done { ~Done() { S.current_call = -1; } } done;
    switch (which)
    {
        case 0: a->repaint(re(e), rf(), rf(), rf(), rf()); break;
        case 1:
        {
            int32_t w = ri(), h = ri();
            if (rng() % 10 == 0 && S.close_width > 0)
                w = S.close_width; // makes the driver close the window inside this callback
            a->set_size(re(e), w, h);
            break;
        }
        case 2: a->set_resize_limits(re(e), ri(), ri(), ri(), ri()); break;
        case 3: a->start_timer(re(e), ri()); break;
        case 4: a->stop_timer(re(e)); break;
        case 5: a->set_tooltip(re(e), rs(s1)); break;
        case 6:
        {
            const int32_t count = (int32_t) (rng() % 8 == 0 ? rng() % 600 : rng() % 6);
            const int32_t stride = (int32_t) sizeof(jcp_menu_item) + (rng() % 4 == 0 ? 8 : 0);
            std::vector<uint8_t> memory((size_t) std::max(1, count) * (size_t) stride);
            std::vector<std::string> texts((size_t) std::max(1, count));
            for (int32_t i = 0; i < count; ++i)
            {
                auto* item = reinterpret_cast<jcp_menu_item*>(memory.data() + (size_t) i * (size_t) stride);
                item->id = rng() % 5 == 0 ? ri() : 1 + (int32_t) (rng() % 20);
                item->flags = (int32_t) (rng() % 16);
                item->text = rs(texts[(size_t) i]);
            }
            int32_t declared = count;
            int32_t declaredStride = stride;
            if (rng() % 6 == 0) declared = ri() % (count + 1); // never more than we have
            if (rng() % 6 == 0) declaredStride = (int32_t) (rng() % sizeof(jcp_menu_item)); // smaller than an item: refused
            a->show_popup_menu(re(e), rng() % 10 == 0 ? nullptr : reinterpret_cast<const jcp_menu_item*>(memory.data()),
                               declared, declaredStride, ri(), rf(), rf());
            break;
        }
        case 7: a->get_parameter_count(re(e)); break;
        case 8: a->find_parameter(re(e), rs(s1)); break;
        case 9: a->get_parameter_normalised(re(e), ri()); break;
        case 10: a->get_parameter_default(re(e), ri()); break;
        case 11: a->normalised_to_plain(re(e), ri() % 5, rf()); break;
        case 12: a->plain_to_normalised(re(e), ri() % 5, rf()); break;
        case 13:
        {
            const size_t n = rng() % 40;
            std::vector<char> buffer(n + 1, 'Z');
            const int32_t declared = rng() % 8 == 0 ? ri() % (int32_t) (n + 1) : (int32_t) n;
            a->get_parameter_text(re(e), ri() % 5, rf(), rng() % 10 == 0 ? nullptr : buffer.data(), declared);
            break;
        }
        case 14: a->begin_gesture(re(e), ri() % 5); break;
        case 15: a->set_parameter_normalised(re(e), ri() % 5, rf()); break;
        case 16: a->end_gesture(re(e), ri() % 5); break;
        case 17: a->get_meter(re(e), ri()); break;
        case 18:
        {
            auto data = randomImage();
            S.current_detail = data.empty() ? -1 : data[0];
            if (const char* dump = std::getenv("EDITOR_PROBE_DUMP")) // keep the input a hang leaves behind
                if (FILE* f = std::fopen(dump, "wb"))
                {
                    if (! data.empty())
                        std::fwrite(data.data(), 1, data.size(), f);
                    std::fclose(f);
                }
            int32_t size = (int32_t) data.size();
            if (rng() % 8 == 0) size = -size;
            if (rng() % 8 == 0 && size > 0) size = (int32_t) (rng() % (uint32_t) size);
            const auto h = a->create_image(re(e), data.empty() ? nullptr : data.data(), size);
            if (h > 0)
                e->images.push_back(h);
            break;
        }
        case 19:
        {
            int32_t img = ri();
            if (! e->images.empty() && rng() % 2 == 0)
            {
                const auto i = rng() % e->images.size();
                img = e->images[i];
                e->images.erase(e->images.begin() + (long) i);
            }
            a->destroy_image(re(e), img);
            break;
        }
        case 20:
        {
            int32_t w = 0, h = 0;
            const int32_t img = ! e->images.empty() && rng() % 2 == 0 ? e->images[rng() % e->images.size()] : ri();
            a->get_image_size(re(e), img, rng() % 5 == 0 ? nullptr : &w, rng() % 5 == 0 ? nullptr : &h);
            break;
        }
        case 21: a->get_text_width(re(e), rs(s1), rs(s2), rf(), ri()); break;
        case 22: a->set_colour(rg(e, g), (uint32_t) rng()); break;
        case 23: a->set_gradient(rg(e, g), (uint32_t) rng(), rf(), rf(), (uint32_t) rng(), rf(), rf(), ri()); break;
        case 24: a->fill_all(rg(e, g)); break;
        case 25: a->fill_rect(rg(e, g), rf(), rf(), rf(), rf()); break;
        case 26: a->draw_rect(rg(e, g), rf(), rf(), rf(), rf(), rf()); break;
        case 27: a->fill_rounded_rect(rg(e, g), rf(), rf(), rf(), rf(), rf()); break;
        case 28: a->draw_rounded_rect(rg(e, g), rf(), rf(), rf(), rf(), rf(), rf()); break;
        case 29: a->fill_ellipse(rg(e, g), rf(), rf(), rf(), rf()); break;
        case 30: a->draw_ellipse(rg(e, g), rf(), rf(), rf(), rf(), rf()); break;
        case 31: a->draw_line(rg(e, g), rf(), rf(), rf(), rf(), rf()); break;
        case 32: a->path_begin(rg(e, g)); break;
        case 33: a->path_move_to(rg(e, g), rf(), rf()); break;
        case 34:
        {
            const int n = rng() % 20 == 0 ? 70000 : 1; // past the element limit now and then
            auto* gg = rg(e, g);
            for (int i = 0; i < n; ++i)
                a->path_line_to(gg, rf(), rf());
            break;
        }
        case 35: a->path_quad_to(rg(e, g), rf(), rf(), rf(), rf()); break;
        case 36: a->path_cubic_to(rg(e, g), rf(), rf(), rf(), rf(), rf(), rf()); break;
        case 37: a->path_arc(rg(e, g), rf(), rf(), rf(), rf(), rf() * 100.0f, rf() * 1000.0f, ri()); break;
        case 38: a->path_close(rg(e, g)); break;
        case 39: a->fill_path(rg(e, g)); break;
        case 40: a->stroke_path(rg(e, g), rf(), ri(), ri()); break;
        case 41: a->set_font(rg(e, g), rs(s1), rf(), ri()); break;
        case 42: a->draw_text(rg(e, g), rs(s1), rf(), rf(), rf(), rf(), ri(), ri()); break;
        case 43:
        {
            const int32_t img = ! e->images.empty() && rng() % 3 != 0 ? e->images[rng() % e->images.size()] : ri();
            a->draw_image(rg(e, g), img, rf(), rf(), rf(), rf(), rf(), rf(), rf(), rf(), rf());
            break;
        }
        case 44:
        {
            const int n = rng() % 10 == 0 ? 100 : 1; // past the nesting limit now and then
            auto* gg = rg(e, g);
            for (int i = 0; i < n; ++i)
                a->save_state(gg);
            break;
        }
        case 45: a->restore_state(rg(e, g)); break;
        case 46: a->clip_rect(rg(e, g), rf(), rf(), rf(), rf()); break;
        case 47: a->translate(rg(e, g), rf(), rf()); break;
        case 48:
        {
            int32_t w = ri(), h = ri();
            if (rng() % 3 == 0) { w = 16 + (int32_t) (rng() % 400); h = 16 + (int32_t) (rng() % 300); }
            a->set_design_size(re(e), w, h, rng() % 3 == 0 ? rf() : 0.5f, rng() % 3 == 0 ? rf() : 2.0f, ri());
            break;
        }
        case 49:
        {
            const float scale = a->get_scale(re(e));
            if (! std::isfinite(scale) || scale < 0.0f || scale > 1000.0f)
                fail("get_scale returned a bad value");
            break;
        }
        case 50: a->open_url(re(e), ru(s1)); break;
        default:
        {
            jcp_editor_look look;
            a->set_look(re(e), rl(look, s1));
            break;
        }
    }
}

void fuzzCalls(ProbeEditor* e, jcp_graphics* g)
{
    if (! S.fuzz)
        return;
    for (int i = 0; i < S.calls_per_callback; ++i)
        fuzzCall(e, g);
}

//==============================================================================
// Scripted checks
void checkThreadCalls(ProbeEditor* e)
{
    const auto* a = e->api;
    auto* h = e->handle;
    int notRefused = 0;
    std::thread other([&]
    {
        notRefused += a->get_parameter_count(h) != 0;
        notRefused += a->find_parameter(h, "a") != -1;
        notRefused += a->get_parameter_default(h, 0) != 0.0f;
        notRefused += a->get_meter(h, 0) != 0.0f;
        notRefused += S.png != nullptr && a->create_image(h, S.png, S.png_size) != 0;
        jcp_menu_item item { 1, 0, "x" };
        notRefused += a->show_popup_menu(h, &item, 1, (int32_t) sizeof(item), 1, 0, 0) != 0;
        char buffer[16] = "unchanged";
        notRefused += a->get_parameter_text(h, 0, 0.5f, buffer, sizeof(buffer)) != 0;
        a->set_size(h, 999, 999);
        a->begin_gesture(h, 0);
        a->set_parameter_normalised(h, 0, 0.123f);
        a->end_gesture(h, 0);
        a->start_timer(h, 60);
        a->repaint(h, 0, 0, 10, 10);
        a->fill_all(e->lastGraphics);
        notRefused += a->open_url(h, goodUrls[0]) != 0;
        notRefused += a->get_scale(h) != 0.0f;
        a->set_design_size(h, 999, 999, 1.0f, 2.0f, 0);
        jcp_editor_look look {};
        look.struct_size = (int32_t) sizeof(look);
        look.menu_background = 0xFFFF00FFu;
        a->set_look(h, &look);
    });
    other.join();
    PROBE_CHECK(notRefused == 0, "editor API calls from another thread must be refused");
}

void checkStaleGraphics(ProbeEditor* e)
{
    const auto* a = e->api;
    auto* g = e->lastGraphics;
    PROBE_CHECK(g != nullptr, "a paint happened before the stale-graphics check");
    a->set_colour(g, 0xFFFF0000u);
    a->fill_all(g);
    a->fill_rect(g, 0, 0, 100, 100);
    a->path_begin(g);
    a->path_line_to(g, 10, 10);
    a->stroke_path(g, 2, 0, 0);
    a->draw_text(g, "stale", 0, 0, 50, 20, 36, 1);
    a->save_state(g);
    a->restore_state(g);
    PROBE_CHECK(a->clip_rect(g, 0, 0, 10, 10) == 0, "clip_rect with a stale graphics token returns 0");
}

void checkImages(ProbeEditor* e)
{
    const auto* a = e->api;
    auto* h = e->handle;
    PROBE_CHECK(S.png != nullptr && S.jpeg != nullptr, "driver supplied test images");
    if (S.png == nullptr || S.jpeg == nullptr)
        return;
    const int32_t png = a->create_image(h, S.png, S.png_size);
    const int32_t jpg = a->create_image(h, S.jpeg, S.jpeg_size);
    PROBE_CHECK(png > 0, "valid PNG accepted");
    PROBE_CHECK(jpg > 0, "valid JPEG accepted");
    int32_t w = 0, ht = 0;
    PROBE_CHECK(a->get_image_size(h, png, &w, &ht) == 1 && w == 64 && ht == 48, "PNG size 64 x 48");
    PROBE_CHECK(a->get_image_size(h, jpg, &w, &ht) == 1 && w == 64 && ht == 48, "JPEG size 64 x 48");
    PROBE_CHECK(a->create_image(h, nullptr, 100) == 0, "NULL data refused");
    PROBE_CHECK(a->create_image(h, S.png, 0) == 0, "size 0 refused");
    PROBE_CHECK(a->create_image(h, S.png, -5) == 0, "negative size refused");
    PROBE_CHECK(a->create_image(h, S.png, JCP_MAX_IMAGE_BYTES + 1) == 0, "oversized buffer refused before reading");
    PROBE_CHECK(a->create_image(h, S.png, 20) == 0, "truncated PNG refused");

    std::vector<uint8_t> big(S.png, S.png + S.png_size);
    big[16] = 0; big[17] = 0; big[18] = 0x23; big[19] = 0x28; // width 9000
    PROBE_CHECK(a->create_image(h, big.data(), (int32_t) big.size()) == 0, "PNG wider than 8192 refused by its header");
    big[18] = 0x20; big[19] = 0x00;                            // width 8192
    big[20] = 0; big[21] = 0; big[22] = 0x08; big[23] = 0x01;  // height 2049: > 16 M pixels
    PROBE_CHECK(a->create_image(h, big.data(), (int32_t) big.size()) == 0, "PNG over 16 M pixels refused by its header");
    big.assign(S.png, S.png + S.png_size);
    big[20] = 0; big[21] = 0; big[22] = 0; big[23] = 0;        // height 0
    PROBE_CHECK(a->create_image(h, big.data(), (int32_t) big.size()) == 0, "PNG of height 0 refused");
    big.assign(S.png, S.png + S.png_size);
    big[30] ^= 0xFF;                                           // IHDR CRC damaged
    PROBE_CHECK(a->create_image(h, big.data(), (int32_t) big.size()) == 0, "PNG with a bad header CRC refused");
    const char gif[] = "GIF89a\x40\x00\x30\x00\x80\x00\x00";
    PROBE_CHECK(a->create_image(h, gif, (int32_t) sizeof(gif)) == 0, "GIF refused (PNG and JPEG only)");
    std::vector<uint8_t> jpegHuge(S.jpeg, S.jpeg + S.jpeg_size);
    for (size_t i = 2; i + 9 < jpegHuge.size(); ++i)
        if (jpegHuge[i] == 0xFF && (jpegHuge[i + 1] == 0xC0 || jpegHuge[i + 1] == 0xC2))
        {
            jpegHuge[i + 5] = 0xFF; jpegHuge[i + 6] = 0xFF; // height 65535
            break;
        }
    PROBE_CHECK(a->create_image(h, jpegHuge.data(), (int32_t) jpegHuge.size()) == 0, "JPEG taller than 8192 refused");
#ifdef PASCALJUCE_PRIVATE_TESTS
    PASCALJUCE_PRIVATE_PNG_CHECKS(a, h);

#endif

    // JPEG headers the wrapper's structure check must refuse.
    const auto findSof = [](std::vector<uint8_t>& j) -> size_t
    {
        for (size_t i = 2; i + 12 < j.size(); ++i)
            if (j[i] == 0xFF && j[i + 1] == 0xC0)
                return i;
        return 0;
    };
    std::vector<uint8_t> jpeg(S.jpeg, S.jpeg + S.jpeg_size);
    const size_t sof = findSof(jpeg);
    PROBE_CHECK(sof != 0, "test JPEG has a baseline frame header");
    if (sof != 0)
    {
        auto bad = jpeg;
#ifdef PASCALJUCE_PRIVATE_TESTS
        PASCALJUCE_PRIVATE_JPEG_CHECKS(a, h, jpeg, sof);
#endif
        bad[sof + 1] = 0xC2; // progressive
        PROBE_CHECK(a->create_image(h, bad.data(), (int32_t) bad.size()) == 0, "progressive JPEG refused (not checked deeply enough)");
        bad = jpeg;
        bad.resize(bad.size() - 2); // no EOI
        PROBE_CHECK(a->create_image(h, bad.data(), (int32_t) bad.size()) == 0, "JPEG without EOI refused");
        bad = jpeg;
        for (size_t i = bad.size() - 40; i < bad.size() - 30; ++i)
            if (bad[i] != 0xFF && bad[i] != 0x00 && (bad[i] ^ 0x5A) != 0xFF && (bad[i] ^ 0x5A) != 0x00)
                bad[i] ^= 0x5A; // corrupt entropy-coded data, structure intact
        const int32_t corrupt = a->create_image(h, bad.data(), (int32_t) bad.size());
        PROBE_CHECK(corrupt > 0, "JPEG with corrupt scan data still decodes");
        a->destroy_image(h, corrupt);
    }

    a->destroy_image(h, png);
    PROBE_CHECK(a->get_image_size(h, png, &w, &ht) == 0 && w == 0 && ht == 0, "destroyed image is gone");
    a->destroy_image(h, png); // twice: ignored
    a->destroy_image(h, 0);
    a->destroy_image(h, -7);

    std::vector<int32_t> made;
    for (int i = 0; i < JCP_MAX_EDITOR_IMAGES + 20; ++i)
    {
        const auto img = a->create_image(h, S.png, S.png_size);
        if (img > 0)
            made.push_back(img);
    }
    PROBE_CHECK((int) made.size() == JCP_MAX_EDITOR_IMAGES - 2, "at most JCP_MAX_EDITOR_IMAGES live images"); // 2 already live
    for (auto img : made)
        a->destroy_image(h, img);
    PROBE_CHECK(a->create_image(h, S.png, S.png_size) > 0, "images can be created again after destroying");
}

void checkParameters(ProbeEditor* e)
{
    const auto* a = e->api;
    auto* h = e->handle;
    PROBE_CHECK(a->get_parameter_count(h) == 3, "parameter count");
    PROBE_CHECK(a->find_parameter(h, "b") == 1, "find_parameter by id");
    PROBE_CHECK(a->find_parameter(h, "zz") == -1, "unknown id -> -1");
    PROBE_CHECK(a->find_parameter(h, nullptr) == -1, "NULL id -> -1");
    PROBE_CHECK(a->find_parameter(h, "b\xC3") == -1, "invalid UTF-8 id -> -1");
    std::string longId(300, 'b');
    PROBE_CHECK(a->find_parameter(h, longId.c_str()) == -1, "overlong id -> -1");
    PROBE_CHECK(a->get_parameter_normalised(h, -1) == 0.0f && a->get_parameter_normalised(h, 3) == 0.0f, "bad index -> 0");
    PROBE_CHECK(std::abs(a->get_parameter_default(h, 0) - 0.5f) < 1e-6f, "default (normalised)");
    PROBE_CHECK(std::abs(a->normalised_to_plain(h, 1, 1.0f) - 2.0f) < 1e-6f, "choice: normalised 1 -> index 2");
    PROBE_CHECK(std::abs(a->plain_to_normalised(h, 1, 1.0f) - 0.5f) < 1e-6f, "choice: index 1 -> 0.5");
    const float n = a->normalised_to_plain(h, 0, std::numeric_limits<float>::quiet_NaN());
    PROBE_CHECK(std::isfinite(n), "NaN in -> finite out");
    PROBE_CHECK(std::isfinite(a->plain_to_normalised(h, 0, std::numeric_limits<float>::infinity())), "Inf in -> finite out");

    char buffer[32];
    std::memset(buffer, 'Z', sizeof(buffer));
    PROBE_CHECK(a->get_parameter_text(h, 0, 0.5f, buffer, 0) == 0 && buffer[0] == 'Z', "size 0: nothing written");
    PROBE_CHECK(a->get_parameter_text(h, 0, 0.5f, buffer, 1) == 0 && buffer[0] == '\0', "size 1: empty string");
    // The library's text is "a=0.50 é€…": cut it at every size and check no character is split.
    for (int size = 2; size < 24; ++size)
    {
        std::memset(buffer, 'Z', sizeof(buffer));
        const int len = a->get_parameter_text(h, 0, 0.5f, buffer, size);
        bool ok = len >= 0 && len < size && buffer[len] == '\0' && buffer[size] == 'Z';
        // the last byte must not start or continue an incomplete sequence
        int i = 0;
        while (ok && i < len)
        {
            const auto c = (unsigned char) buffer[i];
            const int need = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
            ok = need > 0 && i + need <= len;
            i += need;
        }
        PROBE_CHECK(ok, "parameter text is cut at a character boundary");
    }
    PROBE_CHECK(a->get_parameter_text(h, 7, 0.5f, buffer, sizeof(buffer)) == 0, "text for a bad index -> 0");
    a->get_parameter_text(h, 0, std::numeric_limits<float>::quiet_NaN(), buffer, sizeof(buffer));
    a->begin_gesture(h, 99);
    a->end_gesture(h, 99);
    a->end_gesture(h, 1); // never begun
    a->set_parameter_normalised(h, 0, std::numeric_limits<float>::quiet_NaN());
    PROBE_CHECK(a->get_meter(h, -1) == 0.0f && a->get_meter(h, JCP_MAX_METERS) == 0.0f, "bad meter index -> 0");
    PROBE_CHECK(std::abs(a->get_meter(h, 0) - 0.25f) < 1e-6f, "meter published by process()");
    PROBE_CHECK(a->get_meter(h, 1) == 0.0f, "NaN meter value stored as 0");
}

void runAction(ProbeEditor* e)
{
    const auto* a = e->api;
    S.action_done = S.action;
    switch (S.action)
    {
        case PROBE_RESIZE_TO_CLOSE:
        {
            a->set_size(e->handle, S.close_width, 200);
            // The host closed the window in reaction; destroy must wait for us.
            PROBE_CHECK(! e->destroyed, "destroy deferred until the callback returns");
            a->repaint(e->handle, 0, 0, 0, 0);
            a->start_timer(e->handle, 30);
            a->set_tooltip(e->handle, "late");
            jcp_menu_item item { 1, 0, "late" };
            PROBE_CHECK(a->show_popup_menu(e->handle, &item, 1, (int32_t) sizeof(item), 3, 0, 0) == 0,
                        "no popup menu for a closed window");
            break;
        }
        case PROBE_SHOW_MENU:
        {
            const jcp_menu_item items[] = {
                { 0, JCP_MENU_HEADER, "Probe" },
                { 11, 0, "First" },
                { 0, JCP_MENU_SEPARATOR, nullptr },
                { 12, JCP_MENU_TICKED, "Second \xC3\xA9" },
                { 13, JCP_MENU_DISABLED, "Disabled" },
            };
            S.menu_first = a->show_popup_menu(e->handle, items, 5, (int32_t) sizeof(jcp_menu_item), 7, 10, 10);
            S.menu_second = a->show_popup_menu(e->handle, items, 5, (int32_t) sizeof(jcp_menu_item), 8, 10, 10);
            const jcp_menu_item bad[] = { { 1, 0, "bad \xC3" } };
            PROBE_CHECK(a->show_popup_menu(e->handle, bad, 1, (int32_t) sizeof(jcp_menu_item), 9, 0, 0) == 0,
                        "menu with invalid UTF-8 refused");
            break;
        }
        case PROBE_THREAD_CALLS: checkThreadCalls(e); break;
        case PROBE_STALE_GRAPHICS: checkStaleGraphics(e); break;
        case PROBE_IMAGES: checkImages(e); break;
        case PROBE_PARAMETERS: checkParameters(e); break;
        case PROBE_OPEN_GESTURE:
            a->begin_gesture(e->handle, 0);
            a->set_parameter_normalised(e->handle, 0, 0.9f);
            break;
        case PROBE_OPEN_URL:
        {
            PROBE_CHECK(a->open_url(e->handle, nullptr) == 0, "open_url(NULL) refused");
            for (const char* url : badUrls)
                if (a->open_url(e->handle, url) != 0)
                {
                    static char what[200];
                    std::snprintf(what, sizeof(what), "hostile URL refused: %.120s", url);
                    fail(what);
                }
            const std::string tooLong = "https://example.com/" + std::string(2100, 'a');
            PROBE_CHECK(a->open_url(e->handle, tooLong.c_str()) == 0, "a URL over JCP_MAX_URL refused");
            PROBE_CHECK(a->open_url(e->handle, goodUrls[0]) == 1, "a good https URL accepted during a click");
            PROBE_CHECK(a->open_url(e->handle, goodUrls[0]) == 0, "a second URL in the same click refused");
            break;
        }
        case PROBE_OPEN_URL_AGAIN:
            S.url_result = a->open_url(e->handle, goodUrls[1]);
            break;
        case PROBE_SCALE:
            a->set_design_size(e->handle, 320, 120, 0.5f, 2.0f, JCP_SCALE_CORNER_RESIZER);
            break;
        case PROBE_UNSCALE:
            a->set_resize_limits(e->handle, 0, 0, 0, 0);
            break;
        case PROBE_SCALE_TO_CLOSE:
            a->set_design_size(e->handle, S.close_width, 100, 1.0f, 1.0f, JCP_SCALE_CORNER_RESIZER);
            PROBE_CHECK(! e->destroyed, "destroy deferred until the callback returns (scaling)");
            a->set_size(e->handle, 300, 100);   // the window is gone: nothing to resize
            a->set_resize_limits(e->handle, 0, 0, 0, 0);
            break;
        case PROBE_LOOK:
        {
            jcp_editor_look look {};
            look.struct_size = (int32_t) sizeof(look);
            look.tooltip_background = 0xFF111214u;
            look.tooltip_text = 0xFFE9E9E6u;
            look.tooltip_outline = 0xFFD2382Fu;
            look.menu_background = 0xFF112233u;
            look.menu_text = 0xFFE9E9E6u;
            look.menu_highlight = 0xFFD2382Fu;
            look.menu_font_height = 15.0f;
            look.tooltip_font_height = 500.0f; // clamped to 72
            look.font_name = "Lucida Console";
            a->set_look(e->handle, &look);
            S.look_colour = look.menu_background;
            // none of these may replace it
            auto bad = look;
            bad.menu_background = 0xFFFF0000u;
            bad.struct_size = (int32_t) sizeof(look) - 8;
            a->set_look(e->handle, &bad);
            bad.struct_size = (int32_t) sizeof(look);
            bad.menu_font_height = std::numeric_limits<float>::quiet_NaN();
            a->set_look(e->handle, &bad);
            bad.menu_font_height = 15.0f;
            bad.tooltip_font_height = std::numeric_limits<float>::infinity();
            a->set_look(e->handle, &bad);
            bad.tooltip_font_height = 13.0f;
            bad.font_name = "bad \xC3";
            a->set_look(e->handle, &bad);
            const std::string longName(300, 'f');
            bad.font_name = longName.c_str();
            a->set_look(e->handle, &bad);
            break;
        }
        default: break;
    }
    S.action = PROBE_NOTHING;
}

// open_url outside a click: always refused.
void tryUrlOutside(ProbeEditor* e)
{
    if (! S.url_everywhere || S.fuzz)
        return;
    ++S.url_attempts_outside;
    if (e->api->open_url(e->handle, goodUrls[0]) != 0)
        ++S.urls_accepted_outside;
}

//==============================================================================
// Editor callbacks
void JCP_CALL edDestroy(void* p)
{
    auto* e = static_cast<ProbeEditor*>(p);
    if (e->inCallback)
        ++S.destroyed_inside_callback;
    if (e->destroyed)
        ++S.callback_after_destroy;
    e->destroyed = true;
    ++S.editors_destroyed;
    --S.live_editors;
    // API calls from destroy are allowed (e.g. freeing images).
    for (auto img : e->images)
        e->api->destroy_image(e->handle, img);
    e->images.clear();
    e->api->stop_timer(e->handle);
    if (S.gesture_in_destroy)
        e->api->begin_gesture(e->handle, 0); // the wrapper must still end it for the host
}

void JCP_CALL edPaint(void* p, jcp_graphics* g)
{
    auto* e = static_cast<ProbeEditor*>(p);
    CallbackScope scope(e);
    ++S.paints;
    const auto* a = e->api;
    a->set_colour(g, 0xFF203040u);
    a->fill_all(g);
    a->set_colour(g, 0xFFE0C040u);
    a->fill_rounded_rect(g, 10, 10, 60, 30, 5);
    a->set_font(g, nullptr, 14, JCP_FONT_BOLD);
    a->draw_text(g, "Probe \xC3\xA9", 10, 50, 100, 20, JCP_JUSTIFY_LEFT | JCP_JUSTIFY_VCENTRE, 1);
    a->path_begin(g);
    a->path_arc(g, 150, 60, 30, 30, -2.0f, 2.0f, 1);
    a->stroke_path(g, 3, JCP_JOIN_ROUND, JCP_CAP_ROUND);
    if (! e->images.empty())
        a->draw_image(g, e->images.front(), 200, 10, 64, 48, 0, 0, 64, 48, 1.0f);
    fuzzCalls(e, g);
    tryUrlOutside(e);
    e->lastGraphics = g;
}

void JCP_CALL edMouse(void* p, const jcp_mouse_event* event)
{
    auto* e = static_cast<ProbeEditor*>(p);
    CallbackScope scope(e);
    ++S.mouse_events;
    if (event == nullptr || event->struct_size < (int32_t) sizeof(jcp_mouse_event) || ! std::isfinite(event->x)
        || ! std::isfinite(event->y) || ! std::isfinite(event->wheel_dx) || ! std::isfinite(event->wheel_dy))
        fail("mouse event malformed");
    if (event != nullptr && ! S.fuzz)
    {
        S.last_mouse_x = event->x;
        S.last_mouse_y = event->y;
        S.last_scale = e->api->get_scale(e->handle);
        if (event->type != JCP_MOUSE_DOWN && event->type != JCP_MOUSE_UP && event->type != JCP_MOUSE_DOUBLE_CLICK)
            tryUrlOutside(e);
    }
    if (! S.fuzz && event != nullptr && event->type == JCP_MOUSE_DOWN && S.action != PROBE_NOTHING)
        runAction(e);
    fuzzCalls(e, nullptr);
}

void JCP_CALL edTimer(void* p)
{
    auto* e = static_cast<ProbeEditor*>(p);
    CallbackScope scope(e);
    ++S.timer_ticks;
    tryUrlOutside(e);
    fuzzCalls(e, nullptr);
}

void JCP_CALL edParameterChanged(void* p, int32_t index, float normalised)
{
    auto* e = static_cast<ProbeEditor*>(p);
    CallbackScope scope(e);
    ++S.parameter_changes;
    tryUrlOutside(e);
    if (index < 0 || index >= numParams || ! std::isfinite(normalised) || normalised < 0.0f || normalised > 1.0f)
        fail("parameter_changed with a bad index or value");
    fuzzCalls(e, nullptr);
}

void JCP_CALL edResized(void* p, int32_t w, int32_t h)
{
    auto* e = static_cast<ProbeEditor*>(p);
    CallbackScope scope(e);
    ++S.resizes;
    S.last_resize_w = w;
    S.last_resize_h = h;
    tryUrlOutside(e);
    if (w < JCP_EDITOR_MIN_SIZE || h < JCP_EDITOR_MIN_SIZE || w > JCP_EDITOR_MAX_SIZE || h > JCP_EDITOR_MAX_SIZE)
        fail("resized outside the size limits");
    fuzzCalls(e, nullptr);
}

void JCP_CALL edPopupResult(void* p, int32_t menu, int32_t item)
{
    auto* e = static_cast<ProbeEditor*>(p);
    CallbackScope scope(e);
    ++S.popup_results;
    S.last_popup_menu = menu;
    S.last_popup_item = item;
    if (item > 0 && S.url_in_menu && ! S.fuzz)
        S.url_result = e->api->open_url(e->handle, goodUrls[0]); // a chosen item is a click
    else if (item == 0)
        tryUrlOutside(e);
    fuzzCalls(e, nullptr);
}

//==============================================================================
// Plug-in callbacks
void JCP_CALL destroyInstance(void* self) { delete static_cast<Instance*>(self); }
void JCP_CALL prepare(void*, double, int32_t) {}

void JCP_CALL process(void* self, const jcp_process_context* ctx)
{
    auto* inst = static_cast<Instance*>(self);
    if (ctx == nullptr || inst->api == nullptr || inst->api->struct_size < (int32_t) (offsetof(jcp_host_api, set_meter) + sizeof(void*)))
        return;
    inst->api->set_meter(inst->host, 0, 0.25f);
    inst->api->set_meter(inst->host, 1, std::numeric_limits<float>::quiet_NaN());
    inst->api->set_meter(inst->host, JCP_MAX_METERS, 1.0f);
    inst->api->set_meter(inst->host, -1, 1.0f);
}

int32_t JCP_CALL parameterText(void*, int32_t index, float value, char* buffer, int32_t size)
{
    if (index != 0 || buffer == nullptr || size < 1)
        return 0;
    char text[64];
    std::snprintf(text, sizeof(text), "a=%.2f \xC3\xA9\xE2\x82\xAC\xE2\x80\xA6", (double) value);
    std::snprintf(buffer, (size_t) size, "%s", text);
    // keep the result valid UTF-8 even when cut
    size_t n = std::strlen(buffer);
    while (n > 0 && ((unsigned char) buffer[n - 1] & 0x80) != 0)
    {
        // drop an incomplete trailing sequence
        size_t start = n - 1;
        while (start > 0 && ((unsigned char) buffer[start] & 0xC0) == 0x80)
            --start;
        const auto c = (unsigned char) buffer[start];
        const size_t need = (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
        if (start + need <= n)
            break;
        n = start;
        buffer[n] = '\0';
    }
    return 1;
}

void* JCP_CALL createEditor(void* self, const jcp_editor_api* api, jcp_editor* editor, jcp_editor_vtable* vt,
                            int32_t* width, int32_t* height)
{
    if (S.refuse_editor || api == nullptr || api->struct_size < (int32_t) sizeof(jcp_editor_api) || vt == nullptr
        || vt->struct_size < (int32_t) sizeof(jcp_editor_vtable))
        return nullptr;
    auto e = std::make_unique<ProbeEditor>();
    e->owner = static_cast<Instance*>(self);
    e->api = api;
    e->handle = editor;
    lastHandle = editor;
    lastApi = api;
    vt->destroy = &edDestroy;
    vt->paint = &edPaint;
    vt->mouse = &edMouse;
    vt->timer = &edTimer;
    vt->parameter_changed = &edParameterChanged;
    vt->resized = &edResized;
    vt->popup_result = &edPopupResult;
    *width = 320;
    *height = 120;
    if (S.png != nullptr)
    {
        const auto img = api->create_image(editor, S.png, S.png_size); // allowed during creation
        if (img > 0)
            e->images.push_back(img);
    }
    ++S.editors_created;
    ++S.live_editors;
    auto* raw = e.get();
    allEditors.push_back(std::move(e));
    rng.seed(S.seed + (uint32_t) S.editors_created);
    if (S.scale_in_create)
        api->set_design_size(editor, 320, 120, 0.5f, 2.0f, JCP_SCALE_CORNER_RESIZER);
    tryUrlOutside(raw);
    return raw;
}

void* JCP_CALL createInstance(const jcp_host_api* api, jcp_host* host, jcp_plugin_vtable* vt)
{
    if (api == nullptr || vt == nullptr || vt->struct_size < (int32_t) sizeof(jcp_plugin_vtable))
        return nullptr;
    auto* inst = new Instance();
    inst->api = api;
    inst->host = host;
    vt->destroy = &destroyInstance;
    vt->prepare = &prepare;
    vt->process = &process;
    vt->get_parameter_text = &parameterText;
    vt->create_editor = &createEditor;
    return inst;
}
} // namespace

PROBE_EXPORT int32_t JCP_CALL pascaljuce_plugin_entry(int32_t hostAbi, jcp_plugin_factory* factory)
{
    if (factory == nullptr || factory->struct_size < (int32_t) sizeof(jcp_plugin_factory) || hostAbi != JCP_ABI_VERSION)
        return 1;
    factory->abi_version = JCP_ABI_VERSION;
    factory->kind = JCP_KIND_INSTRUMENT;
    factory->get_parameter_count = &getParameterCount;
    factory->get_parameter_info = &getParameterInfo;
    factory->create = &createInstance;
    return 0;
}

PROBE_EXPORT editor_probe_state* JCP_CALL editor_probe_state_get()
{
    return &S;
}

PROBE_EXPORT int32_t JCP_CALL editor_probe_poke_stale()
{
    if (lastApi == nullptr || lastHandle == nullptr)
        return -1;
    const auto* a = lastApi;
    int notRefused = 0;
    notRefused += a->get_parameter_count(lastHandle) != 0;
    notRefused += a->find_parameter(lastHandle, "a") != -1;
    notRefused += S.png != nullptr && a->create_image(lastHandle, S.png, S.png_size) != 0;
    jcp_menu_item item { 1, 0, "stale" };
    notRefused += a->show_popup_menu(lastHandle, &item, 1, (int32_t) sizeof(item), 1, 0, 0) != 0;
    int32_t w = 0, h = 0;
    notRefused += a->get_image_size(lastHandle, 1, &w, &h) != 0;
    a->set_size(lastHandle, 100, 100);
    a->begin_gesture(lastHandle, 0);
    a->set_parameter_normalised(lastHandle, 0, 0.7f);
    a->repaint(lastHandle, 0, 0, 0, 0);
    a->start_timer(lastHandle, 10);
    notRefused += a->open_url(lastHandle, goodUrls[0]) != 0;
    notRefused += a->get_scale(lastHandle) != 0.0f;
    a->set_design_size(lastHandle, 100, 100, 1.0f, 2.0f, 0);
    a->set_look(lastHandle, nullptr);
    return notRefused;
}
