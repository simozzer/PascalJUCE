/*
    test_foreground.h - puts a test's editor in a focused window of a
    foreground process.

    On Linux and macOS, JUCE dismisses a popup menu at once while no window of
    the process has the keyboard focus (on Linux: no JUCE window was focused;
    on macOS: the application is not active). Offscreen test editors have no
    window at all, so the menu checks show the editor on the desktop first.
    Windows needs nothing (and the tests there stay offscreen).
*/
#pragma once

#include <juce_gui_basics/juce_gui_basics.h>

#if JUCE_MAC
    #include <objc/message.h>
    #include <objc/runtime.h>
#endif

inline void pascaljuceTestBringToFront(juce::Component& c)
{
#if ! JUCE_WINDOWS
   #if JUCE_MAC
    // A command-line program is not an application macOS will activate unless it says so.
    using SendPolicy = void (*)(id, SEL, long);
    using SendActivate = void (*)(id, SEL, signed char);
    using SendShared = id (*)(id, SEL);
    id app = reinterpret_cast<SendShared>(objc_msgSend)((id) objc_getClass("NSApplication"),
                                                        sel_registerName("sharedApplication"));
    reinterpret_cast<SendPolicy>(objc_msgSend)(app, sel_registerName("setActivationPolicy:"), 0); // regular
    reinterpret_cast<SendActivate>(objc_msgSend)(app, sel_registerName("activateIgnoringOtherApps:"), 1);
   #endif
    if (! c.isOnDesktop())
        c.addToDesktop(juce::ComponentPeer::windowHasTitleBar);
    c.setVisible(true);
    c.setWantsKeyboardFocus(true);
    juce::Process::makeForegroundProcess();
    c.toFront(true);
    c.grabKeyboardFocus();
    for (int i = 0; i < 20 && ! (juce::Process::isForegroundProcess() && c.hasKeyboardFocus(true)); ++i)
        juce::MessageManager::getInstance()->runDispatchLoopUntil(50);
    std::printf("  note  editor window: %s, %s\n", juce::Process::isForegroundProcess() ? "foreground" : "not foreground",
                c.hasKeyboardFocus(true) ? "focused" : "not focused");
#else
    juce::ignoreUnused(c);
#endif
}
