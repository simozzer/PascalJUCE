/*
    editor_probe.h - shared between the EditorProbe test library (a plug-in
    library written in C++ against juce_c_plugin.h, so it can call the editor
    API with arguments no Pascal code would produce) and its driver,
    tests/fuzz/fuzz_editor.cpp, which links the real wrapper.

    The driver finds the library's state with GetProcAddress /
    dlsym("editor_probe_state") and steers it through the fields below.
*/
#ifndef EDITOR_PROBE_H
#define EDITOR_PROBE_H

#include "juce_c_plugin.h"

#include <stdint.h>

/* What the library does in its next mouse-down callback (scripted mode). */
enum
{
    PROBE_NOTHING = 0,
    PROBE_RESIZE_TO_CLOSE,   /* set_size(close_width, ...) - the driver closes the window in reaction */
    PROBE_SHOW_MENU,         /* show_popup_menu, twice: the second must be refused */
    PROBE_THREAD_CALLS,      /* every API function from another thread: all refused */
    PROBE_STALE_GRAPHICS,    /* drawing with the token of a finished paint: ignored */
    PROBE_IMAGES,            /* image creation limits */
    PROBE_PARAMETERS,        /* parameter functions, bad indices, text buffers */
    PROBE_OPEN_GESTURE,      /* begin a gesture and leave it open */
    PROBE_OPEN_URL,          /* open_url: hostile URLs refused, one good one accepted, a second refused */
    PROBE_OPEN_URL_AGAIN,    /* open_url(good) once: the result goes to url_result */
    PROBE_SCALE,             /* set_design_size(320, 120, 0.5, 2, corner) */
    PROBE_LOOK,              /* set_look: hostile looks refused, then a valid one */
    PROBE_UNSCALE,           /* set_resize_limits(0, ...): scaling ends */
    PROBE_SCALE_TO_CLOSE     /* set_design_size(close_width, 100, 1, 1, corner): the driver closes the window in reaction */
};

typedef struct editor_probe_state
{
    /* --- set by the driver --- */
    int32_t fuzz;                 /* 1: random API calls in every callback      */
    uint32_t seed;
    int32_t calls_per_callback;
    int32_t close_width;          /* set_size to this width makes the driver close the editor */
    int32_t refuse_editor;        /* create_editor returns NULL (generic editor) */
    int32_t action;               /* PROBE_* for the next mouse down             */
    int32_t gesture_in_destroy;   /* destroy() begins a gesture on parameter 0   */
    int32_t scale_in_create;      /* create_editor calls set_design_size(320, 120, 0.5, 2, corner) */
    int32_t url_everywhere;       /* try open_url in every callback that is not a click (all must fail) */
    int32_t url_in_menu;          /* popup_result tries open_url (allowed for a chosen item) */
    const uint8_t* png;           /* a valid PNG and JPEG for image tests        */
    int32_t png_size;
    const uint8_t* jpeg;
    int32_t jpeg_size;

    /* --- reported by the library --- */
    int32_t editors_created;
    int32_t editors_destroyed;
    int32_t live_editors;
    int32_t destroyed_inside_callback;  /* must stay 0 */
    int32_t callback_after_destroy;     /* must stay 0 */
    int32_t reentrant_callbacks;        /* must stay 0 */
    int32_t paints, mouse_events, timer_ticks, parameter_changes, resizes;
    int32_t popup_results, last_popup_menu, last_popup_item;
    int32_t menu_first, menu_second;
    int32_t failures;                   /* scripted checks that failed */
    char last_failure[256];
    int64_t api_calls;
    int32_t action_done;                /* the PROBE_* that last ran */
    volatile int32_t current_call;      /* fuzz: API call in progress (watchdog), -1 = none */
    volatile int32_t current_detail;    /* fuzz: first byte of the image being created */
    int32_t url_result;                 /* the last scripted open_url call (PROBE_OPEN_URL_AGAIN, menus) */
    int32_t urls_accepted_outside;      /* open_url accepted outside a click (must stay 0) */
    int32_t url_attempts_outside;
    float last_mouse_x, last_mouse_y;   /* where the last mouse event arrived */
    float last_scale;                   /* get_scale in the last mouse callback */
    int32_t last_resize_w, last_resize_h;
    uint32_t look_colour;               /* menu_background PROBE_LOOK set */
} editor_probe_state;

/* Exported by the library. */
typedef editor_probe_state* (JCP_CALL *editor_probe_state_fn)(void);
/* Calls a few API functions with the handle of the last (maybe closed)
   editor, from the caller's thread, outside any callback. Returns how many
   were not refused (0 expected for a closed editor). */
typedef int32_t (JCP_CALL *editor_probe_poke_fn)(void);

#endif
