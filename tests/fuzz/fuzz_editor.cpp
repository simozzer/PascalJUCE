/*
    fuzz_editor - the custom-editor side of the wrapper under attack.

    Links the real wrapper (plugin/pascaljuce_plugin_processor.cpp) and loads
    the EditorProbe test library (tests/plugins/EditorProbe), a plug-in library
    written in C++ that calls the editor API with anything: NaN and huge
    coordinates, stale and forged handles, wrong threads, corrupt images,
    oversized menus, lying buffer sizes.

        fuzz_editor scenario                 scripted lifetime / security checks
        fuzz_editor fuzz [iterations] [seed] random host actions; the library makes
                                             random API calls in every callback

    Build with AddressSanitizer to turn memory errors into failures.
*/
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_events/juce_events.h>

#include "../plugins/EditorProbe/editor_probe.h"
#include "../test_foreground.h"

#include <cstdio>
#include <iterator>
#include <string>
#include <tuple>
#include <chrono>
#include <random>
#include <thread>

#if JUCE_WINDOWS
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <windows.h>
#else
    #include <dlfcn.h>
    #include <fcntl.h>
    #include <stdlib.h>
    #include <unistd.h>
#endif

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter();
int pascaljuce_live_editor_sessions();
int pascaljuce_test_opened_url_count();
std::string pascaljuce_test_opened_url(int index);
std::string pascaljuce_test_validated_url(const char* url);
std::string pascaljuce_test_launcher_input(const std::string& url);
bool pascaljuce_test_spawn_launcher(const std::string& program, const std::string& url);
bool pascaljuce_test_file_request(int* mode, std::string* title, std::string* patterns, std::string* initial);
bool pascaljuce_test_answer_file_request(const char* path);

namespace
{
// Closes an editor the way JUCE's format wrappers do: tell the processor, then delete.
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

// An export of the probe library the wrapper loaded (nullptr if it is not loaded).
void* probeSymbol(const char* name)
{
#if JUCE_WINDOWS
    auto* module = GetModuleHandleW(L"EditorProbe_pascal.dll");
    return module != nullptr ? reinterpret_cast<void*>(GetProcAddress(module, name)) : nullptr;
#else
    // The wrapper loads it RTLD_LOCAL (on Linux through /proc/self/fd/N), so
    // its symbols are not global: ask for the already-loaded object by its
    // file, without loading it (glibc and dyld match on the file's identity).
    const auto file = juce::File::getSpecialLocation(juce::File::currentExecutableFile)
                          .getSiblingFile(PASCALJUCE_PLUGIN_LIBRARY);
    void* module = dlopen(file.getFullPathName().toRawUTF8(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (module == nullptr)
        return nullptr;
    void* symbol = dlsym(module, name);
    dlclose(module); // drops only the reference NOLOAD added
    return symbol;
#endif
}

editor_probe_state* probeState()
{
    auto fn = reinterpret_cast<editor_probe_state_fn>(probeSymbol("editor_probe_state_get"));
    return fn != nullptr ? fn() : nullptr;
}

editor_probe_poke_fn probePoke()
{
    return reinterpret_cast<editor_probe_poke_fn>(probeSymbol("editor_probe_poke_stale"));
}

juce::Image render(juce::Component& c)
{
    juce::Image image(juce::Image::ARGB, std::max(1, c.getWidth()), std::max(1, c.getHeight()), true,
                      juce::SoftwareImageType());
    juce::Graphics g(image);
    c.paintEntireComponent(g, true);
    return image;
}

juce::MouseEvent mouseEvent(juce::Component& c, juce::Point<float> pos, juce::ModifierKeys mods, int clicks = 1)
{
    const auto now = juce::Time::getCurrentTime();
    return juce::MouseEvent(juce::Desktop::getInstance().getMainMouseSource(), pos, mods,
                            juce::MouseInputSource::defaultPressure, 0.0f, 0.0f, 0.0f, 0.0f, &c, &c, now, pos, now,
                            clicks, false);
}

const auto leftButton = juce::ModifierKeys(juce::ModifierKeys::leftButtonModifier);

struct GestureCounter final : juce::AudioProcessorParameter::Listener
{
    void parameterValueChanged(int, float) override { ++changes; }
    void parameterGestureChanged(int, bool starting) override { ++(starting ? begins : ends); }
    std::atomic<int> begins { 0 }, ends { 0 }, changes { 0 };
};

// Closes (deletes) the editor when it is resized to a given width: a host
// reacting synchronously, from inside the library's own callback.
struct CloseOnWidth final : juce::ComponentListener
{
    CloseOnWidth(EditorPtr& e, int w) : editor(e), width(w)
    {
        editor->addComponentListener(this);
        watched = editor.get();
    }
    ~CloseOnWidth() override
    {
        if (editor != nullptr && editor.get() == watched)
            editor->removeComponentListener(this);
    }
    juce::Component* watched = nullptr;
    void componentMovedOrResized(juce::Component& c, bool, bool) override
    {
        if (c.getWidth() == width && editor != nullptr)
        {
            editor->removeComponentListener(this);
            editor.reset();
            ++closed;
        }
    }
    EditorPtr& editor;
    int width;
    int closed = 0;
};

struct Images
{
    Images()
    {
        juce::Image image(juce::Image::ARGB, 64, 48, true, juce::SoftwareImageType());
        {
            juce::Graphics g(image);
            g.setGradientFill(juce::ColourGradient(juce::Colours::red, 0, 0, juce::Colours::blue, 64, 48, false));
            g.fillAll();
        }
        juce::MemoryOutputStream p, j;
        juce::PNGImageFormat().writeImageToStream(image, p);
        juce::JPEGImageFormat().writeImageToStream(image, j);
        png = p.getMemoryBlock();
        jpeg = j.getMemoryBlock();
    }
    juce::MemoryBlock png, jpeg;
};

EditorPtr openEditor(juce::AudioProcessor& p)
{
    return EditorPtr(p.createEditorAndMakeActive());
}

void mouseDown(juce::Component& c, juce::Point<float> at = { 20.0f, 20.0f })
{
    c.mouseDown(mouseEvent(c, at, leftButton));
}

// Counts the host notifications that say the program changed.
struct ProgramListener final : juce::AudioProcessorListener
{
    void audioProcessorParameterChanged(juce::AudioProcessor*, int, float) override {}
    void audioProcessorChanged(juce::AudioProcessor*, const ChangeDetails& details) override
    {
        if (details.programChanged)
            ++changes;
    }
    int changes = 0;
};

void processBlock(juce::AudioProcessor& p)
{
    juce::AudioBuffer<float> buffer(2, 256);
    juce::MidiBuffer midi;
    buffer.clear();
    p.processBlock(buffer, midi);
}

//==============================================================================
int scenario(juce::AudioProcessor& p, editor_probe_state& s)
{
    auto& params = p.getParameters();
    check(params.size() == 3, "probe library loaded with 3 parameters");
    if (params.size() != 3)
        return 1;
    GestureCounter gestures;
    params[0]->addListener(&gestures);
    processBlock(p); // publishes meters

    std::printf("Generic editor fallback\n");
    s.refuse_editor = 1;
    {
        auto editor = openEditor(p);
        check(dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) != nullptr,
              "create_editor returning NULL gives the generic editor");
    }
    s.refuse_editor = 0;
    check(pascaljuce_live_editor_sessions() == 0, "no session left behind by a refused editor");

    std::printf("Custom editor\n");
    auto editor = openEditor(p);
    check(editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr,
          "custom editor created (" + juce::String(editor == nullptr ? "none" : typeid(*editor).name()) + ", "
              + juce::String(s.editors_created) + " made by the library)");
    if (editor == nullptr || dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) != nullptr)
        return 1;
    check(editor->getWidth() == 320 && editor->getHeight() == 120, "initial size from create_editor");
    auto image = render(*editor);
    check(s.paints == 1, "paint called once");
    check(image.getPixelAt(300, 100) == juce::Colour(0xFF203040u), "library's drawing reaches the image");
    check(image.getPixelAt(204, 12).getRed() > 100, "image created during create_editor is drawn");

    std::printf("Scripted checks inside callbacks\n");
    for (auto action : { PROBE_PARAMETERS, PROBE_IMAGES, PROBE_THREAD_CALLS, PROBE_STALE_GRAPHICS })
    {
        const int before = s.failures;
        s.action = action;
        mouseDown(*editor);
        check(s.action_done == action && s.failures == before,
              "probe action " + juce::String(action) + (s.failures != before ? ": " + juce::String(s.last_failure) : juce::String()));
    }
    render(*editor); // the editor still draws after all that

    std::printf("Popup menu\n");
    pascaljuceTestBringToFront(*editor);
    s.action = PROBE_SHOW_MENU;
    mouseDown(*editor);
    check(s.menu_first == 1 && s.menu_second == 0, "menu shown; a second one while it is open is refused");
    auto* modal = juce::ModalComponentManager::getInstance()->getModalComponent(0);
    check(modal != nullptr, "menu window is up");
    if (modal != nullptr)
    {
        modal->keyPressed(juce::KeyPress(juce::KeyPress::downKey));
        modal->keyPressed(juce::KeyPress(juce::KeyPress::returnKey));
    }
    pump(200);
    check(s.popup_results == 1 && s.last_popup_menu == 7 && s.last_popup_item == 11,
          "choice delivered: menu " + juce::String(s.last_popup_menu) + ", item " + juce::String(s.last_popup_item));

    std::printf("Popup answer after the window closed\n");
    s.action = PROBE_SHOW_MENU;
    mouseDown(*editor);
    check(s.menu_first == 1, "menu shown again (the first one answered)");
    const int destroyedBefore = s.editors_destroyed;
    editor.reset();
    pump(200);
    juce::PopupMenu::dismissAllActiveMenus();
    pump(200);
    check(s.editors_destroyed == destroyedBefore + 1, "library editor destroyed with the window");
    check(s.popup_results == 1, "the late menu answer is dropped");
    check(probePoke() != nullptr && probePoke()() == 0, "calls with the closed editor's handle are refused");

    std::printf("Gesture left open by the library\n");
    editor = openEditor(p);
    s.action = PROBE_OPEN_GESTURE;
    mouseDown(*editor);
    pump(100);
    check(gestures.begins == 1 && gestures.ends == 0, "gesture begun on the host");
    check(std::abs(params[0]->getValue() - 0.9f) < 1.0e-4f, "value set from the editor reached the parameter");
    editor.reset();
    pump(100);
    check(gestures.begins == 1 && gestures.ends == 1, "closing the editor ends its open gesture");
    s.gesture_in_destroy = 1;
    editor = openEditor(p);
    editor.reset();
    pump(100);
    s.gesture_in_destroy = 0;
    check(gestures.begins == gestures.ends, "a gesture begun inside destroy() never stays open on the host");

    std::printf("Host closes the window inside a library callback\n");
    editor = openEditor(p);
    {
        CloseOnWidth closer(editor, 777);
        s.close_width = 777;
        s.action = PROBE_RESIZE_TO_CLOSE;
        const int destroyed = s.editors_destroyed;
        const int failed = s.failures;
        auto* raw = editor.get();
        mouseDown(*raw);
        check(closer.closed == 1 && editor == nullptr, "window closed by the host during the callback");
        check(s.failures == failed, juce::String("library saw a consistent editor: ") + (s.failures != failed ? juce::String(s.last_failure) : juce::String("ok")));
        check(s.editors_destroyed == destroyed + 1, "library editor destroyed once the callback returned");
        check(s.destroyed_inside_callback == 0, "never destroyed while its callback ran");
        s.close_width = 0;
    }
    pump(50);

    std::printf("Host closes the window while a scaled resize is applied\n");
    editor = openEditor(p);
    {
        CloseOnWidth closer(editor, 778);
        s.close_width = 778;
        s.action = PROBE_SCALE_TO_CLOSE;
        const int destroyed = s.editors_destroyed;
        const int failed = s.failures;
        mouseDown(*editor);
        check(closer.closed == 1 && editor == nullptr, "window closed by the host inside set_design_size's resize");
        check(s.failures == failed, juce::String("library saw a consistent editor: ")
                                        + (s.failures != failed ? juce::String(s.last_failure) : juce::String("ok")));
        check(s.editors_destroyed == destroyed + 1 && s.destroyed_inside_callback == 0,
              "destroyed once the callback returned, and the resize stopped touching the window");
        s.close_width = 0;
    }
    pump(50);

    std::printf("Host automation reaches the editor\n");
    editor = openEditor(p);
    const int changesBefore = s.parameter_changes;
    std::thread automation([&params]
    {
        for (int i = 0; i < 50; ++i)
        {
            params[0]->setValue((float) i / 50.0f); // as VST3 hosts deliver automation
            params[0]->sendValueChangedMessageToListeners((float) i / 50.0f);
        }
    });
    automation.join();
    pump(100);
    check(s.parameter_changes > changesBefore, "parameter_changed delivered on the message thread ("
                                                   + juce::String(s.parameter_changes - changesBefore) + ", coalesced)");
    editor.reset();

    std::printf("open_url: the validator\n");
    {
        const std::pair<const char*, const char*> cases[] = {
            { "https://github.com/simozzer/Mz101", "https://github.com/simozzer/Mz101" },
            { "HTTPS://Example.COM:8443/a?b=1&c=%41#x", "https://Example.COM:8443/a?b=1&c=%41#x" },
            { "https://a.b.example.org", "https://a.b.example.org" },
            { "https://xn--bcher-kva.example/", "https://xn--bcher-kva.example/" },
            { "https://example.com/@user/x:y", "https://example.com/@user/x:y" },
            { "http://example.com/", "" }, { "file:///etc/passwd", "" }, { "https://example.com/a\"b", "" },
            { "https://example.com/$HOME", "" }, { "https://example.com/a&b;c", "" }, { "https://u@example.com/", "" },
            { "https://192.168.0.1/", "" }, { "https://localhost:8080/", "" }, { "https://example.com:70000/", "" },
            { "https://example.com/%0d%0a", "" }, { "https://exa mple.com/", "" }, { "https://example.com/\xC3\xA9", "" },
            { "https://example.c0m/", "" }, { "https://example.xn--p1ai/", "https://example.xn--p1ai/" }, { "https://example.com:443:1/", "" }, { "", "" }, { nullptr, "" },
        };
        int wrong = 0;
        for (const auto& [in, out] : cases)
            if (pascaljuce_test_validated_url(in) != out)
            {
                ++wrong;
                std::printf("    %s -> '%s'\n", in == nullptr ? "(null)" : in, pascaljuce_test_validated_url(in).c_str());
            }
        check(wrong == 0, "https only, DNS hosts, a fixed character set (" + juce::String((int) std::size(cases)) + " cases)");
        const std::string longest = "https://example.com/" + std::string(JCP_MAX_URL - 20, 'a');
        check(pascaljuce_test_validated_url(longest.c_str()) == longest, "JCP_MAX_URL bytes accepted");
        check(pascaljuce_test_validated_url((longest + "a").c_str()).empty(), "one more refused");
    }

    std::printf("open_url: the platform launcher\n");
    {
        // What the launcher is handed must be exactly the validated URL, as one value.
        int wrong = 0;
        const std::string longest = "https://example.com/" + std::string(JCP_MAX_URL - 20, 'a');
        for (const std::string& url : { std::string("https://github.com/simozzer/Mz101"),
                                       std::string("https://Example.COM:8443/a/b-c_d.e~f?q=1&r=%41#top"),
                                       std::string("https://example.com/@user/x:y+z,w=v"), longest })
        {
            const auto validated = pascaljuce_test_validated_url(url.c_str());
            const auto input = pascaljuce_test_launcher_input(validated);
           #if JUCE_WINDOWS || JUCE_MAC
            const auto expected = validated;
           #else
            const auto expected = "xdg-open\n" + validated + "\n";
           #endif
            if (validated != url || input != expected)
            {
                ++wrong;
                std::printf("    %s -> '%s'\n", url.c_str(), input.c_str());
            }
        }
        check(wrong == 0, "the launcher gets the URL unchanged, as a single argument");

       #if ! JUCE_WINDOWS && ! JUCE_MAC
        // The real fork/exec path, with a stand-in for xdg-open that records its
        // arguments and what it inherited: an open descriptor of ours (it must not
        // see it), LD_LIBRARY_PATH (removed) and stdin (/dev/null).
        std::string dirTemplate = juce::File::getSpecialLocation(juce::File::tempDirectory)
                                      .getChildFile("pascaljuce_launcher_XXXXXX").getFullPathName().toStdString();
        const bool madeDir = mkdtemp(dirTemplate.data()) != nullptr; // private (0700), unpredictable name
        check(madeDir, "launcher test directory created");
        const juce::File dir(dirTemplate);
        const auto script = dir.getChildFile("fake-xdg-open");
        const auto record = dir.getChildFile("args.txt");
        const int leakFd = 57;
        const int opened = open("/dev/null", O_RDONLY); // no O_CLOEXEC: inheritable
        const bool haveLeakFd = opened >= 0 && dup2(opened, leakFd) == leakFd;
        if (opened >= 0 && opened != leakFd)
            close(opened);
        const char* oldLibPath = std::getenv("LD_LIBRARY_PATH");
        const std::string savedLibPath = oldLibPath != nullptr ? oldLibPath : "";
        setenv("LD_LIBRARY_PATH", "/nonexistent/pascaljuce", 1);
        const auto r = record.getFullPathName();
        script.replaceWithText("#!/bin/sh\n{ echo \"$#\"; for a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
                               "  if [ -e /proc/self/fd/" + juce::String(leakFd) + " ]; then echo fd=open; else echo fd=closed; fi\n"
                               "  echo \"libpath=${LD_LIBRARY_PATH-unset}\"\n"
                               "  echo \"stdin=$(readlink /proc/self/fd/0)\"; } > \"" + r + ".tmp\"\n"
                               "mv \"" + r + ".tmp\" \"" + r + "\"\n",
                               false, false, "\n"); // Unix line ends (the default is CR LF)
        script.setExecutePermission(true);
        const std::string url = "https://Example.COM:8443/a/b-c_d.e~f?q=1&r=%41#top";
        check(madeDir && pascaljuce_test_spawn_launcher(script.getFullPathName().toStdString(), url),
              "launcher process started");
        if (oldLibPath != nullptr)
            setenv("LD_LIBRARY_PATH", savedLibPath.c_str(), 1);
        else
            unsetenv("LD_LIBRARY_PATH");
        if (haveLeakFd)
            close(leakFd);
        for (int i = 0; i < 100 && ! record.existsAsFile(); ++i)
            juce::Thread::sleep(50);
        const auto lines = juce::StringArray::fromLines(record.loadFileAsString().trimEnd());
        check(lines.size() == 5 && lines[0] == "1" && lines[1] == juce::String(url),
              "the detached launcher ran with exactly one argument, the URL: '" + record.loadFileAsString() + "'");
        check(haveLeakFd && lines[2] == "fd=closed", "the launcher inherits none of the host's descriptors");
        check(lines[3] == "libpath=unset", "the launcher's environment has no LD_LIBRARY_PATH");
        check(lines[4] == "stdin=/dev/null", "the launcher's stdin is /dev/null");
        if (madeDir)
            dir.deleteRecursively();
       #endif
    }

    std::printf("open_url: only as the answer to a click\n");
    {
        editor = openEditor(p);
        const int opened = pascaljuce_test_opened_url_count();
        s.url_everywhere = 1;
        render(*editor);
        editor->mouseMove(mouseEvent(*editor, { 30, 30 }, juce::ModifierKeys()));
        editor->mouseEnter(mouseEvent(*editor, { 30, 30 }, juce::ModifierKeys()));
        editor->mouseWheelMove(mouseEvent(*editor, { 30, 30 }, juce::ModifierKeys()), juce::MouseWheelDetails {});
        editor->mouseDrag(mouseEvent(*editor, { 31, 30 }, leftButton));
        params[0]->setValueNotifyingHost(0.25f);
        pump(100);
        const int failed = s.failures;
        s.action = PROBE_OPEN_URL;
        mouseDown(*editor);
        check(s.action_done == PROBE_OPEN_URL && s.failures == failed,
              "hostile URLs refused, one accepted, a second in the same click refused"
                  + (s.failures != failed ? ": " + juce::String(s.last_failure) : juce::String()));
        check(pascaljuce_test_opened_url_count() == opened, "the page is not opened inside the library's callback");
        pump(50);
        check(pascaljuce_test_opened_url_count() == opened + 1
                  && pascaljuce_test_opened_url(opened) == "https://github.com/simozzer/Mz101",
              "but just after it, from the message loop");
        s.action = PROBE_OPEN_URL_AGAIN;
        mouseDown(*editor);
        check(s.url_result == 0, "another page within a second refused");
        juce::Thread::sleep(1100);
        s.action = PROBE_OPEN_URL_AGAIN;
        mouseDown(*editor);
        pump(50);
        check(s.url_result == 1 && pascaljuce_test_opened_url_count() == opened + 2
                  && pascaljuce_test_opened_url(opened + 1) == "https://Example.COM:8443/a/b-c_d.e~f?q=1&r=%41#top",
              "a second later it is accepted (the scheme normalised, the rest as given): "
                  + juce::String(pascaljuce_test_opened_url(opened + 1)));
        juce::Thread::sleep(1100);
        s.url_in_menu = 1;
        s.url_result = -1;
        s.action = PROBE_SHOW_MENU;
        mouseDown(*editor);
        if (auto* modal = juce::ModalComponentManager::getInstance()->getModalComponent(0))
        {
            modal->keyPressed(juce::KeyPress(juce::KeyPress::downKey));
            modal->keyPressed(juce::KeyPress(juce::KeyPress::returnKey));
        }
        pump(200);
        check(s.url_result == 1, "a menu choice is a click too");
        s.action = PROBE_SHOW_MENU;
        mouseDown(*editor);
        juce::PopupMenu::dismissAllActiveMenus();
        pump(200);
        s.url_in_menu = 0;
        editor->setSize(330, 130);
        pump(100);
        render(*editor);
        s.url_everywhere = 0;
        check(s.urls_accepted_outside == 0 && s.url_attempts_outside >= 8,
              "refused in create_editor, paint, timer, parameter, resize, move / drag / wheel and a dismissed menu ("
                  + juce::String(s.url_attempts_outside) + " tries)");
        editor.reset();
        pump(100);
        check(pascaljuce_test_opened_url_count() == opened + 3, "three pages opened in all");
    }

    std::printf("choose_file: only as the answer to a click\n");
    {
        editor = openEditor(p);
        s.url_everywhere = 1;
        render(*editor);
        editor->mouseMove(mouseEvent(*editor, { 30, 30 }, juce::ModifierKeys()));
        editor->mouseDrag(mouseEvent(*editor, { 31, 30 }, leftButton));
        params[0]->setValueNotifyingHost(0.3f);
        pump(100);
        check(! pascaljuce_test_file_request(nullptr, nullptr, nullptr, nullptr), "no dialog yet");
        const int failed = s.failures;
        s.action = PROBE_CHOOSE_FILE;
        mouseDown(*editor);
        check(s.action_done == PROBE_CHOOSE_FILE && s.failures == failed,
              "hostile modes, titles, patterns and paths refused, one dialog shown, a second refused"
                  + (s.failures != failed ? ": " + juce::String(s.last_failure) : juce::String()));
        int mode = -1;
        std::string title, patterns, initial;
        const bool requested = pascaljuce_test_file_request(&mode, &title, &patterns, &initial);
        check(requested && mode == JCP_FILE_OPEN && title == "Open a probe file" && patterns == "*.txt;*.probe"
                  && initial.empty(),
              "the dialog: open, its title and patterns; a relative initial path ignored ("
                  + juce::String(title) + ", " + juce::String(patterns) + ", '" + juce::String(initial) + "')");
        const int chosen = s.files_chosen;
        const auto path = juce::File::getSpecialLocation(juce::File::tempDirectory).getChildFile("caf\xc3\xa9 probe.txt");
        check(pascaljuce_test_answer_file_request(path.getFullPathName().toRawUTF8()), "answered");
        pump(50);
        check(s.files_chosen == chosen + 1 && s.last_file_request == 41 && s.last_file_cancelled == 0
                  && juce::String::fromUTF8(s.last_file_path) == path.getFullPathName(),
              "file_chosen(41, the path in UTF-8): " + juce::String::fromUTF8(s.last_file_path));
        s.action = PROBE_CHOOSE_FILE_AGAIN;
        mouseDown(*editor);
        check(s.file_request_result == 1 && pascaljuce_test_file_request(&mode, &title, &patterns, nullptr)
                  && mode == JCP_FILE_SAVE && title == "Save as" && patterns == "*",
              "once answered another may open: save, a default title, any file");
        pascaljuce_test_answer_file_request(nullptr);
        pump(50);
        check(s.files_chosen == chosen + 2 && s.last_file_request == 43 && s.last_file_cancelled == 1,
              "Cancel: file_chosen(43, NULL)");
        // a menu choice is a click too
        s.file_in_menu = 1;
        s.file_request_result = -1;
        s.action = PROBE_SHOW_MENU;
        mouseDown(*editor);
        if (auto* modal = juce::ModalComponentManager::getInstance()->getModalComponent(0))
        {
            modal->keyPressed(juce::KeyPress(juce::KeyPress::downKey));
            modal->keyPressed(juce::KeyPress(juce::KeyPress::returnKey));
        }
        pump(200);
        check(s.file_request_result == 1, "a menu choice may open a dialog");
        s.file_in_menu = 0;
        // the window closes while the dialog is up: the answer goes nowhere
        const int before = s.files_chosen;
        editor.reset();
        pump(100);
        check(pascaljuce_test_answer_file_request(path.getFullPathName().toRawUTF8()), "answered after the window closed");
        pump(100);
        check(s.files_chosen == before && s.callback_after_destroy == 0, "and the answer is dropped");
        s.url_everywhere = 0;
        check(s.files_accepted_outside == 0, "refused in create_editor, paint, timer, parameter, resize, move, drag and a dismissed menu");
    }

    std::printf("Programs\n");
    {
        ProgramListener listener;
        p.addListener(&listener);
        s.program_count = 0;
        check(p.getNumPrograms() == 1 && p.getProgramName(0) == "Default" && p.getCurrentProgram() == 0,
              "a library with no programs: one, \"Default\"");
        s.program_count = 3;
        check(p.getNumPrograms() == 3 && p.getProgramName(2) == juce::String::fromUTF8("Program 2 \xc3\xa9")
                  && p.getProgramName(3).isEmpty() && p.getProgramName(-1).isEmpty(),
              "three programs, named by the library; out of range: no name");
        p.setCurrentProgram(1);
        check(p.getCurrentProgram() == 1 && s.program_selections == 1, "setCurrentProgram reaches the library");
        p.setCurrentProgram(3);
        p.setCurrentProgram(-1);
        check(s.program_selections == 1 && s.failures == 0, "out-of-range programs never reach it");
        pump(100);
        check(listener.changes >= 1, "programs_changed tells the host (" + juce::String(listener.changes) + ")");
        s.current_program = 77;
        check(p.getCurrentProgram() == 0, "a current program out of range reads as 0");
        s.current_program = 1;
        s.program_count = 100000;
        check(p.getNumPrograms() == JCP_MAX_PROGRAMS, "at most JCP_MAX_PROGRAMS offered");
        s.program_count = -5;
        check(p.getNumPrograms() == 1, "a negative count is none");
        s.program_count = 3;
        s.bad_program_names = 1;
        check(p.getProgramName(0).isEmpty(), "a name that is not UTF-8 (nor ends) is not used");
        s.bad_program_names = 0;
        s.program_count = 0;
        p.removeListener(&listener);
    }

    std::printf("Scaled editor\n");
    {
        editor = openEditor(p);
        s.action = PROBE_SCALE;
        mouseDown(*editor);
        pump(50);
        check(editor->getWidth() == 320 && editor->getHeight() == 120, "set_design_size: scale 1 to start with ("
                  + juce::String(editor->getWidth()) + " x " + juce::String(editor->getHeight()) + ")");
        auto* constrainer = editor->getConstrainer();
        check(editor->isResizable() && constrainer != nullptr && constrainer->getMinimumWidth() == 160
                  && constrainer->getMaximumWidth() == 640 && constrainer->getMinimumHeight() == 60
                  && constrainer->getMaximumHeight() == 240
                  && std::abs(constrainer->getFixedAspectRatio() - 320.0 / 120.0) < 1.0e-9,
              "resizable from 0.5x to 2x, the aspect ratio kept");
        bool corner = false;
        for (auto* child : editor->getChildren())
            corner = corner || dynamic_cast<juce::ResizableCornerComponent*>(child) != nullptr;
        check(corner, "with a resize corner (JCP_SCALE_CORNER_RESIZER)");
        const int resizes = s.resizes;
        editor->setSize(640, 240);
        pump(50);
        check(s.resizes == resizes, "the host resizing it does not resize the library's layout");
        const auto image = render(*editor);
        check(image.getPixelAt(100, 50) == juce::Colour(0xFFE0C040u) && image.getPixelAt(130, 70) == juce::Colour(0xFFE0C040u)
                  && image.getPixelAt(630, 230) == juce::Colour(0xFF203040u) && image.getPixelAt(150, 90) == juce::Colour(0xFF203040u),
              "the drawing is scaled 2x (the 60 x 30 box at 10, 10 now covers 20..140 x 20..80)");
        editor->mouseDown(mouseEvent(*editor, { 200.0f, 100.0f }, leftButton));
        check(std::abs(s.last_mouse_x - 100.0f) < 1.0e-4f && std::abs(s.last_mouse_y - 50.0f) < 1.0e-4f,
              "mouse events in design units (" + juce::String(s.last_mouse_x) + ", " + juce::String(s.last_mouse_y) + ")");
        check(std::abs(s.last_scale - 2.0f) < 1.0e-6f, "get_scale: 2");
        editor.reset();
        s.scale_in_create = 1;
        editor = openEditor(p);
        check(editor->getWidth() == 640 && editor->getHeight() == 240, "reopened at the scale it had");
        juce::MemoryBlock state;
        p.getStateInformation(state);
        const auto withScale = [&state](const char* number)
        {
            const auto* d = static_cast<const char*>(state.getData());
            std::string text(d + 8, state.getSize() - 9);
            const std::string key = "id=\"pascaljuce.editor.scale\" value=\"";
            auto at = text.find(key);
            juce::MemoryBlock out;
            if (at == std::string::npos)
                return out;
            at += key.size();
            text.replace(at, text.find('"', at) - at, number);
            const uint32_t length = (uint32_t) text.size() + 1;
            out.append(d, 4);
            out.append(&length, 4);
            out.append(text.data(), text.size() + 1);
            return out;
        };
        check(withScale("2").getSize() > 0, "the scale is saved with the state");
        editor.reset();
        for (const auto& [number, w, h] : { std::tuple<const char*, int, int> { "1.5", 480, 180 }, { "1e30", 640, 240 },
                                            { "0.0001", 160, 60 }, { "-3", 160, 60 } })
        {
            const auto hostile = withScale(number);
            p.setStateInformation(hostile.getData(), (int) hostile.getSize());
            editor = openEditor(p);
            check(editor->getWidth() == w && editor->getHeight() == h,
                  juce::String("a saved scale of ") + number + " opens at " + juce::String(editor->getWidth()) + " x "
                      + juce::String(editor->getHeight()));
            editor.reset();
        }
        editor = openEditor(p);
        editor->setSize(640, 100); // a host ignoring the aspect ratio
        const auto boxed = render(*editor);
        check(boxed.getPixelAt(600, 50) == juce::Colours::black && boxed.getPixelAt(30, 20) == juce::Colour(0xFFE0C040u),
              "a window of the wrong shape: drawn at the smaller scale, the rest black");
        editor->mouseMove(mouseEvent(*editor, { 600.0f, 90.0f }, juce::ModifierKeys()));
        render(*editor);
        s.action = PROBE_UNSCALE;
        const int resizesBefore = s.resizes;
        mouseDown(*editor);
        pump(50);
        check(editor->getWidth() == 320 && editor->getHeight() == 120 && ! editor->isResizable()
                  && (s.resizes == resizesBefore || (s.last_resize_w == 320 && s.last_resize_h == 120)),
              "set_resize_limits ends scaling: back to the design size, unscaled (" + juce::String(editor->getWidth())
                  + " x " + juce::String(editor->getHeight()) + (editor->isResizable() ? ", resizable" : "") + ")");
        editor->mouseDown(mouseEvent(*editor, { 200.0f, 100.0f }, leftButton));
        check(std::abs(s.last_mouse_x - 200.0f) < 1.0e-4f && std::abs(s.last_scale - 1.0f) < 1.0e-6f,
              "mouse events unscaled again, get_scale 1");
        editor.reset();
        s.scale_in_create = 0;
        p.setStateInformation(withScale("1").getData(), (int) withScale("1").getSize());
    }

    std::printf("Tooltip and menu look\n");
    {
        editor = openEditor(p);
        const int failed = s.failures;
        s.action = PROBE_LOOK;
        mouseDown(*editor);
        auto& look = editor->getLookAndFeel();
        check(s.failures == failed && look.findColour(juce::PopupMenu::backgroundColourId) == juce::Colour(s.look_colour)
                  && look.findColour(juce::TooltipWindow::outlineColourId) == juce::Colour(0xFFD2382Fu)
                  && look.findColour(juce::PopupMenu::highlightedBackgroundColourId) == juce::Colour(0xFFD2382Fu),
              "set_look reaches the editor's LookAndFeel; hostile looks after it change nothing");
        check(std::abs(look.getPopupMenuFont().getHeight() - 15.0f) < 0.01f
                  && look.getPopupMenuFont().getTypefaceName() == "Lucida Console",
              "the menu font: " + look.getPopupMenuFont().getTypefaceName() + " " + juce::String(look.getPopupMenuFont().getHeight()));
        const auto tip = look.getTooltipBounds("Probe tooltip", { 10, 10 }, { 0, 0, 1000, 1000 });
        check(tip.getHeight() >= 70, "the tooltip font (clamped to 72): " + juce::String(tip.getHeight()) + " pixels high");
        juce::Image tipImage(juce::Image::ARGB, tip.getWidth(), tip.getHeight(), true, juce::SoftwareImageType());
        {
            juce::Graphics g(tipImage);
            look.drawTooltip(g, "Probe tooltip", tip.getWidth(), tip.getHeight());
        }
        check(tipImage.getPixelAt(tip.getWidth() / 2, 2) == juce::Colour(0xFF111214u), "drawn in its colours");
        s.action = PROBE_SHOW_MENU;
        mouseDown(*editor);
        const int destroyed = s.editors_destroyed;
        editor.reset(); // the menu is still up: it keeps the look alive
        pump(100);
        juce::PopupMenu::dismissAllActiveMenus();
        pump(200);
        check(s.editors_destroyed == destroyed + 1 && pascaljuce_live_editor_sessions() == 0,
              "a menu outliving its editor keeps its look, and its answer is dropped");
    }

    std::printf("1000 editors\n");
    for (int i = 0; i < 1000; ++i)
    {
        editor = openEditor(p);
        if (i % 50 == 0)
            render(*editor);
        editor.reset();
    }
    pump(50);
    check(s.live_editors == 0 && pascaljuce_live_editor_sessions() == 0, "every editor and session freed");

    std::printf("Processor destroyed while its editor is still open (a host bug)\n");
    {
        std::unique_ptr<juce::AudioProcessor> second(createPluginFilter());
        std::unique_ptr<juce::AudioProcessorEditor> orphan(second->createEditorAndMakeActive());
        render(*orphan);
        const int destroyed = s.editors_destroyed;
        second.reset();
        check(s.editors_destroyed == destroyed + 1, "the library editor goes before its instance");
        render(*orphan);                 // nothing left to call: draws nothing, no crash
        mouseDown(*orphan);
        orphan->setSize(200, 100);
        pump(50);
        orphan.reset();                  // (the processor is gone: no editorBeingDeleted)
        check(pascaljuce_live_editor_sessions() == 0 && s.live_editors == 0, "nothing left behind");
    }

    check(s.reentrant_callbacks == 0, "no re-entrant editor callback");
    check(s.callback_after_destroy == 0, "no callback after destroy");
    check(s.destroyed_inside_callback == 0, "no destroy inside a callback");
    params[0]->removeListener(&gestures);
    return 0;
}

//==============================================================================
bool verbose = false;

int fuzz(juce::AudioProcessor& p, editor_probe_state& s, long iterations, unsigned seed)
{
    std::mt19937 rng(seed);
    s.fuzz = 1;
    s.seed = seed;
    s.calls_per_callback = 12;
    s.close_width = 555;
    EditorPtr editor;
    std::unique_ptr<CloseOnWidth> closer;
    auto& params = p.getParameters();
    const auto modsFor = [&rng]
    {
        int m = 0;
        if (rng() % 2) m |= juce::ModifierKeys::leftButtonModifier;
        if (rng() % 8 == 0) m |= juce::ModifierKeys::rightButtonModifier;
        if (rng() % 6 == 0) m |= juce::ModifierKeys::shiftModifier;
        if (rng() % 9 == 0) m |= juce::ModifierKeys::ctrlModifier;
        return juce::ModifierKeys(m);
    };
    const auto point = [&rng]
    {
        const float values[] = { -1.0e9f, -5.0f, 0.0f, 10.0f, 100.0f, 319.0f, 1.0e9f,
                                 std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity() };
        if (rng() % 4 == 0)
            return juce::Point<float>(values[rng() % 9], values[rng() % 9]);
        return juce::Point<float>((float) (rng() % 400), (float) (rng() % 200));
    };

    // A hang is a failure too: report the API call that never returned.
    std::atomic<long> progress { 0 };
    std::atomic<bool> finished { false };
    std::thread watchdog([&]
    {
        long last = -1;
        auto since = std::chrono::steady_clock::now();
        while (! finished.load())
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            const long now = progress.load();
            if (now != last)
            {
                last = now;
                since = std::chrono::steady_clock::now();
            }
            else if (std::chrono::steady_clock::now() - since > std::chrono::seconds(60))
            {
                std::printf("HANG: iteration %ld has not finished after 60 s; library API call in progress: %d (image byte 0: %d)\n",
                            now, (int) s.current_call, (int) s.current_detail);
                std::fflush(stdout);
                std::_Exit(3);
            }
        }
    });
    s.current_call = -1;

    for (long it = 0; it < iterations; ++it)
    {
        progress.store(it);
        if (editor == nullptr)
            closer.reset();
        s.refuse_editor = rng() % 25 == 0 ? 1 : 0;
        const auto action = rng() % 14;
        if (verbose)
            std::printf("    %ld: action %u (editor %s)\n", it, (unsigned) action, editor != nullptr ? "open" : "closed");
        switch (action)
        {
            case 0:
                if (editor == nullptr)
                {
                    editor = openEditor(p);
                    if (editor != nullptr && dynamic_cast<juce::GenericAudioProcessorEditor*>(editor.get()) == nullptr)
                        closer = std::make_unique<CloseOnWidth>(editor, s.close_width);
                }
                break;
            case 1:
                closer.reset();
                editor.reset();
                break;
            case 2: case 3:
                if (editor != nullptr)
                    render(*editor);
                break;
            case 4: case 5: case 6:
                if (editor != nullptr)
                {
                    auto* c = editor.get();
                    const auto e = mouseEvent(*c, point(), modsFor(), 1 + (int) (rng() % 2));
                    switch (rng() % 7)
                    {
                        case 0: c->mouseDown(e); break;
                        case 1: c->mouseDrag(e); break;
                        case 2: c->mouseUp(e); break;
                        case 3: c->mouseMove(e); break;
                        case 4: c->mouseEnter(e); break;
                        case 5: c->mouseExit(e); break;
                        default: c->mouseDoubleClick(e); break;
                    }
                }
                break;
            case 7:
                if (editor != nullptr)
                {
                    juce::MouseWheelDetails wheel {};
                    wheel.deltaX = (float) ((int) (rng() % 200) - 100) / 50.0f;
                    wheel.deltaY = rng() % 10 == 0 ? std::numeric_limits<float>::quiet_NaN() : (float) ((int) (rng() % 200) - 100) / 50.0f;
                    wheel.isReversed = rng() % 2 == 0;
                    editor->mouseWheelMove(mouseEvent(*editor, point(), modsFor()), wheel);
                }
                break;
            case 8:
            {
                auto* param = params[(int) (rng() % (unsigned) params.size())];
                const float v = rng() % 10 == 0 ? std::numeric_limits<float>::quiet_NaN() : (float) (rng() % 1001) / 1000.0f;
                if (rng() % 2)
                    param->setValueNotifyingHost(v);
                else
                {
                    std::thread t([param, v] { param->setValue(v); param->sendValueChangedMessageToListeners(v); });
                    t.join();
                }
                break;
            }
            case 9:
                pump(1 + (int) (rng() % 8));
                break;
            case 10:
                juce::PopupMenu::dismissAllActiveMenus();
                break;
            case 11:
                processBlock(p);
                break;
            case 12:
                if (editor != nullptr)
                    editor->setSize(16 + (int) (rng() % 600), 16 + (int) (rng() % 400));
                break;
            default:
                if (probePoke() != nullptr)
                    probePoke()();
                break;
        }
        if (it % 1000 == 0)
            std::printf("  %ld / %ld, %lld API calls\n", it, iterations, (long long) s.api_calls);
    }
    finished.store(true);
    watchdog.join();
    closer.reset();
    editor.reset();
    juce::PopupMenu::dismissAllActiveMenus();
    pump(50);
    s.refuse_editor = 0;
    check(s.live_editors == 0 && pascaljuce_live_editor_sessions() == 0, "every editor freed");
    check(s.reentrant_callbacks == 0, "no re-entrant editor callback");
    check(s.callback_after_destroy == 0, "no callback after destroy");
    check(s.destroyed_inside_callback == 0, "no destroy inside a callback");
    check(s.failures == 0, juce::String("library-side checks: ") + (s.failures != 0 ? juce::String(s.last_failure) : juce::String("ok")));
    int badOpened = 0;
    for (int i = 0; i < pascaljuce_test_opened_url_count(); ++i)
    {
        const auto url = pascaljuce_test_opened_url(i);
        if (url.rfind("https://", 0) != 0 || pascaljuce_test_validated_url(url.c_str()) != url)
            ++badOpened;
    }
    check(badOpened == 0, "every page the fuzzed library got opened is a valid https URL ("
                              + juce::String(pascaljuce_test_opened_url_count()) + " opened)");
    std::printf("  %lld random API calls, %d editors, %d paints, %d mouse events, %d timer ticks\n",
                (long long) s.api_calls, s.editors_created, s.paints, s.mouse_events, s.timer_ticks);
    return 0;
}
} // namespace

int main(int argc, char* argv[])
{
    const juce::String mode = argc > 1 ? argv[1] : "scenario";
    const long iterations = argc > 2 ? std::strtol(argv[2], nullptr, 10) : 3000;
    const unsigned seed = argc > 3 ? (unsigned) std::strtoul(argv[3], nullptr, 10) : 7u;
    verbose = argc > 4 && juce::String(argv[4]) == "verbose";

    std::setvbuf(stdout, nullptr, _IONBF, 0); // keep output up to a crash
    juce::ScopedJuceInitialiser_GUI juceInit;
    int result = 1;
    {
        std::unique_ptr<juce::AudioProcessor> plugin(createPluginFilter());
        plugin->setPlayConfigDetails(0, 2, 48000.0, 256);
        plugin->prepareToPlay(48000.0, 256);
        auto* s = probeState();
        check(s != nullptr, "EditorProbe library loaded next to the executable");
        if (s != nullptr)
        {
            static Images images;
            s->png = static_cast<const uint8_t*>(images.png.getData());
            s->png_size = (int32_t) images.png.getSize();
            s->jpeg = static_cast<const uint8_t*>(images.jpeg.getData());
            s->jpeg_size = (int32_t) images.jpeg.getSize();
            std::printf("%s\n", mode.toRawUTF8());
            result = mode == "fuzz" ? fuzz(*plugin, *s, iterations, seed) : scenario(*plugin, *s);
        }
        plugin->releaseResources();
    }
    juce::PopupMenu::dismissAllActiveMenus();
    std::printf(failures == 0 && result == 0 ? "All checks passed\n" : "%d check(s) FAILED\n", failures);
    return failures == 0 && result == 0 ? 0 : 1;
}
