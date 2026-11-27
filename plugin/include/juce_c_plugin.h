/*
    juce_c_plugin.h - ABI between the PascalJUCE plug-in wrapper (C++/JUCE,
    builds the VST3 / AU / LV2 / Standalone binaries) and a plug-in library
    written in Pascal (or C).

    The library exports exactly one function:

        int32_t pascaljuce_plugin_entry(int32_t host_abi_version,
                                        jcp_plugin_factory* factory);

    The wrapper sets factory->struct_size (and zeroes the rest) before the
    call. The library fills the fields it knows that fit in struct_size and
    returns 0, or returns non-zero and (if it fits) sets error_message.

    The wrapper loads the library from the folder its own binary lives in
    (e.g. MySynth.vst3/Contents/x86_64-win/MySynth_pascal.dll), optionally
    after verifying a SHA-256 recorded at build time.

    Versioning
    ----------
    JCP_ABI_VERSION changes only for incompatible changes; both sides must
    agree on it. Compatible additions append fields to structs: every struct
    starts with struct_size, set by whoever allocates it; readers must not
    access fields beyond struct_size, and writers must not write beyond it.
    Function pointers that are NULL (or lie beyond struct_size) are absent.

    Layout: plain C structs, natural alignment, cdecl. Pascal: JucePlugin.pas
    ({$PACKRECORDS C} in FPC, {$ALIGN 8} {$MINENUMSIZE 4} in Delphi).

    Threads: `process` runs on the host's audio thread, and some hosts also
    call `reset` there (keep it real-time safe). `get_state` and `set_state`
    run on a non-real-time thread and never concurrently with `process` (the
    wrapper holds the processing lock; set_state of a large blob therefore
    stalls audio briefly). `get_parameter_text` and `get_tail_seconds` may run
    on any thread, concurrently with everything else. create, destroy,
    prepare and release run on a non-real-time thread. Custom-editor
    callbacks and jcp_editor_api run on the message thread only (see "Custom
    editors" below); set_meter may be called from any thread. Never let
    exceptions escape through this ABI.

    Security: treat everything that arrives through set_state (project files)
    and MIDI (devices, hosts) as untrusted input.
*/
#ifndef JUCE_C_PLUGIN_H
#define JUCE_C_PLUGIN_H

#include <stdint.h>

#if defined(_WIN32)
    #define JCP_CALL __cdecl
#else
    #define JCP_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define JCP_ABI_VERSION 2

typedef struct jcp_host jcp_host; /* opaque: one per plug-in instance */
typedef struct jcp_editor jcp_editor;     /* opaque: one per open editor (see Custom editors) */
typedef struct jcp_graphics jcp_graphics; /* opaque: a drawing context, valid only inside paint() */

/* Plug-in kinds; must match pascaljuce_add_plugin(... KIND ...). */
#define JCP_KIND_INSTRUMENT  0
#define JCP_KIND_EFFECT      1
#define JCP_KIND_MIDI_EFFECT 2

/* Parameter kinds */
#define JCP_PARAM_FLOAT  0  /* continuous min..max, optional step         */
#define JCP_PARAM_INT    1  /* integer min..max                           */
#define JCP_PARAM_BOOL   2  /* 0 / 1                                      */
#define JCP_PARAM_CHOICE 3  /* index into `choices` ("Sine|Saw|Square")   */

/* Parameter flags */
#define JCP_PARAM_FLAG_AUTOMATABLE 1

typedef struct jcp_parameter_info {
    int32_t struct_size;
    int32_t kind;          /* JCP_PARAM_*                                   */
    const char* id;        /* stable, unique, [A-Za-z0-9_.-]; saved by hosts */
    const char* name;      /* display name (UTF-8)                          */
    const char* label;     /* unit, e.g. "dB", "ms" (may be "")             */
    const char* choices;   /* JCP_PARAM_CHOICE only, '|' separated          */
    float min_value;
    float max_value;
    float default_value;
    float step;            /* 0 = continuous (float only)                   */
    int32_t flags;         /* JCP_PARAM_FLAG_*                              */
    int32_t version_hint;  /* >= 1: release in which the parameter appeared */
} jcp_parameter_info;

typedef struct jcp_midi_event {
    const uint8_t* data;   /* one complete message; valid only during process() */
    int32_t size;
    int32_t sample_position;
} jcp_midi_event;

typedef struct jcp_transport {
    int32_t struct_size;
    int32_t has_info;      /* 0 = host gave no position; values are defaults */
    double  bpm;
    double  ppq_position;
    double  ppq_bar_start;
    int64_t time_in_samples;
    double  time_in_seconds;
    int32_t is_playing;
    int32_t is_recording;
    int32_t is_looping;
    int32_t time_sig_numerator;
    int32_t time_sig_denominator;
    int32_t reserved;
} jcp_transport;

typedef struct jcp_process_context {
    int32_t struct_size;
    int32_t num_samples;
    float* const* channels;            /* in-place: inputs arrive here, write outputs here      */
    const jcp_midi_event* midi_events; /* sorted by sample_position; stride = midi_event_size  */
    const float* parameters;           /* current values in plain units (index = order declared) */
    const jcp_transport* transport;
    int32_t num_channels;              /* max(inputs, outputs)                                  */
    int32_t num_input_channels;
    int32_t num_output_channels;
    int32_t num_midi_events;
    int32_t num_parameters;
    int32_t midi_event_size;           /* sizeof(jcp_midi_event) as compiled into the wrapper   */
    int32_t midi_events_dropped;       /* events beyond the wrapper's per-block limit           */
    int32_t is_non_realtime;           /* 1 while the host renders offline                      */
} jcp_process_context;

/* Services the wrapper offers to each instance. */
typedef struct jcp_host_api {
    int32_t struct_size;
    int32_t abi_version;
    /* process() only (ignored elsewhere): queue one complete MIDI message. */
    void   (JCP_CALL *add_midi_output)(jcp_host* host, const uint8_t* data, int32_t size, int32_t sample_position);
    /* Set a parameter in plain units and notify the host. Outside an explicit
       gesture this is wrapped in its own begin/end gesture. Not real-time safe. */
    void   (JCP_CALL *set_parameter)(jcp_host* host, int32_t index, float value);
    float  (JCP_CALL *get_parameter)(jcp_host* host, int32_t index);
    void   (JCP_CALL *set_latency_samples)(jcp_host* host, int32_t samples);
    /* Not real-time safe. */
    void   (JCP_CALL *log)(jcp_host* host, const char* message);
    double (JCP_CALL *get_sample_rate)(jcp_host* host);
    /* Bracket a user interaction (e.g. a knob drag) so hosts record one undo step. */
    void   (JCP_CALL *begin_parameter_gesture)(jcp_host* host, int32_t index);
    void   (JCP_CALL *end_parameter_gesture)(jcp_host* host, int32_t index);
    /* Future, optional services by name; NULL if unknown. */
    void*  (JCP_CALL *get_extension)(jcp_host* host, const char* id);
    /* --- added for custom editors (check struct_size) --- */
    /* Any thread, real-time safe (one atomic store): publish a value for the
       editor to show, e.g. an output peak from process(). index is
       0..JCP_MAX_METERS-1; non-finite values are stored as 0. */
    void   (JCP_CALL *set_meter)(jcp_host* host, int32_t index, float value);
    /* --- added for host programs (check struct_size) --- */
    /* Any thread but the audio thread (not from process()): the library's
       program list (get_program_count / get_program_name) or its current
       program changed. The wrapper tells the host from the message thread,
       coalesced, never from inside a library call. */
    void   (JCP_CALL *programs_changed)(jcp_host* host);
} jcp_host_api;

/* ===========================================================================
   Custom editors
   ===========================================================================
   A library that fills jcp_plugin_vtable.create_editor draws its own editor
   through the wrapper: JUCE owns the window (every host and OS), the library
   paints with the jcp_graphics functions below and reacts to mouse, timer and
   parameter callbacks. Libraries without create_editor (or returning NULL)
   get JUCE's generic editor, as before.

   Threads: every editor callback and every jcp_editor_api function runs on
   the message thread only; calls from any other thread are ignored (getters
   return 0). The editor never touches DSP state: it reads parameters through
   the API and meters published with jcp_host_api.set_meter.

   Handles: jcp_editor and jcp_graphics values are validated tokens, never
   dereferenced. A stale handle (closed editor, finished paint) is ignored.
   A jcp_graphics is valid only during the paint() call that received it.
   Images are positive integers owned by one editor and freed with it.

   Values: coordinates must be finite and are clamped to +-JCP_EDITOR_MAX_COORD
   (sizes to 0..2*JCP_EDITOR_MAX_COORD, line thickness to 0..1000); a call with
   a non-finite argument does nothing. Text is NUL-terminated UTF-8 of at most
   JCP_EDITOR_MAX_TEXT bytes; invalid text is not used. Parameter changes from
   the editor reach the host after the callback that made them has returned
   (never re-entering the library); gestures are balanced by the wrapper, also
   when the editor closes mid-gesture.

   Lifetime: the wrapper calls the editor vtable's destroy() exactly once,
   when the window closes (deferred to the end of the callback if the host
   closes it during one). A popup-menu result arriving after the editor closed
   is dropped. After destroy() no other editor callback is made.
*/
#define JCP_EDITOR_MIN_SIZE   16
#define JCP_EDITOR_MAX_SIZE   4096
#define JCP_EDITOR_MAX_COORD  100000.0f
#define JCP_EDITOR_MAX_TEXT   4096
#define JCP_MAX_METERS        64
#define JCP_MAX_IMAGE_BYTES   (32 * 1024 * 1024) /* encoded PNG / JPEG          */
#define JCP_MAX_IMAGE_SIDE    8192               /* pixels, width and height    */
#define JCP_MAX_IMAGE_PIXELS  (16 * 1024 * 1024) /* per image                   */
#define JCP_MAX_EDITOR_IMAGES 256                /* live images per editor      */
#define JCP_MAX_MENU_ITEMS    512

/* Mouse event types */
#define JCP_MOUSE_MOVE         0
#define JCP_MOUSE_DOWN         1
#define JCP_MOUSE_DRAG         2
#define JCP_MOUSE_UP           3
#define JCP_MOUSE_ENTER        4
#define JCP_MOUSE_EXIT         5
#define JCP_MOUSE_DOUBLE_CLICK 6
#define JCP_MOUSE_WHEEL        7

/* Modifier flags (jcp_mouse_event.modifiers) */
#define JCP_MOD_SHIFT  1
#define JCP_MOD_CTRL   2
#define JCP_MOD_ALT    4
#define JCP_MOD_CMD    8    /* Cmd on macOS, Ctrl elsewhere                   */
#define JCP_MOD_LEFT   16   /* buttons held                                   */
#define JCP_MOD_RIGHT  32
#define JCP_MOD_MIDDLE 64
#define JCP_MOD_POPUP  128  /* this click should open a context menu          */

typedef struct jcp_mouse_event {
    int32_t struct_size;
    int32_t type;          /* JCP_MOUSE_*                                      */
    float x, y;            /* editor coordinates (finite)                       */
    int32_t modifiers;     /* JCP_MOD_*                                         */
    int32_t click_count;   /* 1, 2 (double click), ...                          */
    float wheel_dx;        /* JCP_MOUSE_WHEEL: about +-1 per notch, finite and  */
    float wheel_dy;        /*   clamped to +-64; positive = up / right          */
} jcp_mouse_event;

/* Library callbacks for one editor. All optional except destroy. */
typedef struct jcp_editor_vtable {
    int32_t struct_size;
    int32_t reserved;
    void (JCP_CALL *destroy)(void* editor);
    /* Draw everything (the wrapper does not clear the background). */
    void (JCP_CALL *paint)(void* editor, jcp_graphics* g);
    void (JCP_CALL *mouse)(void* editor, const jcp_mouse_event* event);
    /* After start_timer, at about the requested rate. */
    void (JCP_CALL *timer)(void* editor);
    /* A parameter changed (host automation, a preset, this editor): coalesced,
       on the message thread. */
    void (JCP_CALL *parameter_changed)(void* editor, int32_t index, float normalised);
    /* The host resized a resizable editor (see set_resize_limits). */
    void (JCP_CALL *resized)(void* editor, int32_t width, int32_t height);
    /* Answer to show_popup_menu: the chosen item id, or 0 if dismissed. */
    void (JCP_CALL *popup_result)(void* editor, int32_t menu_id, int32_t item_id);
    /* --- added later (the wrapper checks struct_size) --- */
    /* Answer to choose_file: the full path chosen (UTF-8), or NULL if the
       user cancelled. The library opens or writes the file itself. */
    void (JCP_CALL *file_chosen)(void* editor, int32_t request_id, const char* path);
} jcp_editor_vtable;

/* Popup-menu item flags */
#define JCP_MENU_DISABLED  1
#define JCP_MENU_TICKED    2
#define JCP_MENU_SEPARATOR 4  /* id and text ignored                          */
#define JCP_MENU_HEADER    8  /* a section title; id ignored                   */

typedef struct jcp_menu_item {
    int32_t id;            /* > 0, handed back by popup_result                  */
    int32_t flags;         /* JCP_MENU_*                                        */
    const char* text;      /* UTF-8; copied before show_popup_menu returns      */
} jcp_menu_item;

/* Font styles (bit flags) */
#define JCP_FONT_BOLD      1
#define JCP_FONT_ITALIC    2
#define JCP_FONT_UNDERLINE 4

/* Text justification: one horizontal and one vertical flag (JUCE's values) */
#define JCP_JUSTIFY_LEFT     1
#define JCP_JUSTIFY_RIGHT    2
#define JCP_JUSTIFY_HCENTRE  4
#define JCP_JUSTIFY_TOP      8
#define JCP_JUSTIFY_BOTTOM   16
#define JCP_JUSTIFY_VCENTRE  32

/* draw_text's last argument: what happens to text wider than its rectangle */
#define JCP_TEXT_CLIP      0  /* drawn as it is (clipped)                                */
#define JCP_TEXT_ELLIPSIS  1  /* shortened with an ellipsis                             */
#define JCP_TEXT_FIT       2  /* squeezed sideways to as little as 70%, then shortened  */
                              /* (JUCE drawFittedText, one line; older wrappers: ellipsis) */

/* Stroke styles */
#define JCP_JOIN_MITER 0
#define JCP_JOIN_ROUND 1
#define JCP_JOIN_BEVEL 2
#define JCP_CAP_BUTT   0
#define JCP_CAP_SQUARE 1
#define JCP_CAP_ROUND  2

/* set_design_size flags */
#define JCP_SCALE_CORNER_RESIZER 1  /* also show JUCE's resize handle in the bottom right corner */

/* Scale limits for set_design_size (also bounded by JCP_EDITOR_MIN/MAX_SIZE). */
#define JCP_EDITOR_MIN_SCALE 0.25f
#define JCP_EDITOR_MAX_SCALE 4.0f

/* open_url: at most this many bytes (without the NUL). */
#define JCP_MAX_URL 2048

/* choose_file */
#define JCP_FILE_OPEN 0   /* pick an existing file                                  */
#define JCP_FILE_SAVE 1   /* name a file to write (the user is asked before replacing) */
#define JCP_MAX_FILE_PATTERNS 256  /* bytes of the pattern list                     */
#define JCP_MAX_PATH          4096 /* bytes of a path, either way                   */

/* Host programs */
#define JCP_MAX_PROGRAMS      1024
#define JCP_MAX_PROGRAM_NAME  256  /* bytes, without the NUL                         */

/* The look of the wrapper's own windows: tooltips and popup menus (set_look).
   Colours are 0xAARRGGBB; 0 keeps JUCE's default for that colour. Font
   heights 0 keep JUCE's default, others are clamped to 6..72. font_name NULL
   or "" is the default sans-serif (at most 256 bytes of UTF-8). Everything is
   copied before set_look returns. */
typedef struct jcp_editor_look {
    int32_t struct_size;          /* sizeof(jcp_editor_look)                    */
    int32_t reserved;
    uint32_t tooltip_background;
    uint32_t tooltip_text;
    uint32_t tooltip_outline;
    uint32_t menu_background;
    uint32_t menu_text;
    uint32_t menu_highlight;      /* the item under the mouse                    */
    uint32_t menu_highlight_text;
    uint32_t menu_header_text;    /* section headers                            */
    float tooltip_font_height;    /* JUCE: 13                                   */
    float menu_font_height;       /* JUCE: 17                                   */
    const char* font_name;
} jcp_editor_look;

/* Services for one editor (message thread only). Colours are 0xAARRGGBB.
   Angles are radians, clockwise from 12 o'clock. */
typedef struct jcp_editor_api {
    int32_t struct_size;
    int32_t reserved;

    /* --- window --- */
    /* Ask for a redraw of a rectangle (w or h <= 0: the whole editor). */
    void    (JCP_CALL *repaint)(jcp_editor* e, float x, float y, float w, float h);
    /* Asked for during paint(), this and set_resize_limits take effect after it. */
    void    (JCP_CALL *set_size)(jcp_editor* e, int32_t width, int32_t height);
    /* Let the host resize the editor within these limits (max_w or max_h 0: not resizable). */
    void    (JCP_CALL *set_resize_limits)(jcp_editor* e, int32_t min_w, int32_t min_h, int32_t max_w, int32_t max_h);
    void    (JCP_CALL *start_timer)(jcp_editor* e, int32_t hz);   /* clamped to 1..120 */
    void    (JCP_CALL *stop_timer)(jcp_editor* e);
    /* Tooltip for the editor area under the mouse (NULL or "" hides it). */
    void    (JCP_CALL *set_tooltip)(jcp_editor* e, const char* text);
    /* Shows a menu at (x, y) and returns at once (1 = shown). The choice
       arrives later through popup_result(menu_id, item id or 0). item_size =
       sizeof(jcp_menu_item); at most JCP_MAX_MENU_ITEMS items. One menu per
       editor at a time: while one is open this returns 0. */
    int32_t (JCP_CALL *show_popup_menu)(jcp_editor* e, const jcp_menu_item* items, int32_t count, int32_t item_size,
                                        int32_t menu_id, float x, float y);

    /* --- parameters (index = declaration order) --- */
    int32_t (JCP_CALL *get_parameter_count)(jcp_editor* e);
    int32_t (JCP_CALL *find_parameter)(jcp_editor* e, const char* id);          /* index or -1 */
    float   (JCP_CALL *get_parameter_normalised)(jcp_editor* e, int32_t index);  /* 0..1 */
    float   (JCP_CALL *get_parameter_default)(jcp_editor* e, int32_t index);     /* normalised */
    float   (JCP_CALL *normalised_to_plain)(jcp_editor* e, int32_t index, float normalised);
    float   (JCP_CALL *plain_to_normalised)(jcp_editor* e, int32_t index, float plain);
    /* Display text for a normalised value (the library's own text if it gives
       one). Writes NUL-terminated UTF-8, never split inside a character, and
       returns its length in bytes (0 if none). */
    int32_t (JCP_CALL *get_parameter_text)(jcp_editor* e, int32_t index, float normalised, char* buffer, int32_t size);
    /* Bracket a drag with begin/end; set_parameter outside a gesture gets its own. */
    void    (JCP_CALL *begin_gesture)(jcp_editor* e, int32_t index);
    void    (JCP_CALL *set_parameter_normalised)(jcp_editor* e, int32_t index, float normalised);
    void    (JCP_CALL *end_gesture)(jcp_editor* e, int32_t index);
    /* Latest value published with jcp_host_api.set_meter (0 if none). */
    float   (JCP_CALL *get_meter)(jcp_editor* e, int32_t index);

    /* --- images: PNG, or sequential (baseline) JPEG with 3 components and one
       scan; the whole file structure is checked before decoding, and the
       JCP_MAX_IMAGE_* limits apply --- */
    int32_t (JCP_CALL *create_image)(jcp_editor* e, const void* data, int32_t size); /* handle > 0, or 0 */
    void    (JCP_CALL *destroy_image)(jcp_editor* e, int32_t image);
    int32_t (JCP_CALL *get_image_size)(jcp_editor* e, int32_t image, int32_t* width, int32_t* height); /* 1 = ok */
    /* Width of one line of text (font name NULL or "": the default sans-serif). */
    float   (JCP_CALL *get_text_width)(jcp_editor* e, const char* text, const char* font_name, float height, int32_t style);

    /* --- drawing: only with the jcp_graphics passed to paint(), during that call --- */
    void    (JCP_CALL *set_colour)(jcp_graphics* g, uint32_t argb);
    void    (JCP_CALL *set_gradient)(jcp_graphics* g, uint32_t argb1, float x1, float y1,
                                     uint32_t argb2, float x2, float y2, int32_t radial);
    void    (JCP_CALL *fill_all)(jcp_graphics* g);
    void    (JCP_CALL *fill_rect)(jcp_graphics* g, float x, float y, float w, float h);
    void    (JCP_CALL *draw_rect)(jcp_graphics* g, float x, float y, float w, float h, float thickness);
    void    (JCP_CALL *fill_rounded_rect)(jcp_graphics* g, float x, float y, float w, float h, float radius);
    void    (JCP_CALL *draw_rounded_rect)(jcp_graphics* g, float x, float y, float w, float h, float radius, float thickness);
    void    (JCP_CALL *fill_ellipse)(jcp_graphics* g, float x, float y, float w, float h);
    void    (JCP_CALL *draw_ellipse)(jcp_graphics* g, float x, float y, float w, float h, float thickness);
    void    (JCP_CALL *draw_line)(jcp_graphics* g, float x1, float y1, float x2, float y2, float thickness);
    /* One current path per paint, at most 65536 elements. */
    void    (JCP_CALL *path_begin)(jcp_graphics* g);
    void    (JCP_CALL *path_move_to)(jcp_graphics* g, float x, float y);
    void    (JCP_CALL *path_line_to)(jcp_graphics* g, float x, float y);
    void    (JCP_CALL *path_quad_to)(jcp_graphics* g, float cx, float cy, float x, float y);
    void    (JCP_CALL *path_cubic_to)(jcp_graphics* g, float c1x, float c1y, float c2x, float c2y, float x, float y);
    void    (JCP_CALL *path_arc)(jcp_graphics* g, float cx, float cy, float rx, float ry,
                                 float from_radians, float to_radians, int32_t start_new_subpath);
    void    (JCP_CALL *path_close)(jcp_graphics* g);
    void    (JCP_CALL *fill_path)(jcp_graphics* g);
    void    (JCP_CALL *stroke_path)(jcp_graphics* g, float thickness, int32_t join, int32_t cap);
    void    (JCP_CALL *set_font)(jcp_graphics* g, const char* name, float height, int32_t style); /* height 1..1000 */
    void    (JCP_CALL *draw_text)(jcp_graphics* g, const char* text, float x, float y, float w, float h,
                                  int32_t justification, int32_t ellipsis); /* JCP_TEXT_* */
    /* Draws a source rectangle of one of this editor's images into a destination rectangle. */
    void    (JCP_CALL *draw_image)(jcp_graphics* g, int32_t image, float dx, float dy, float dw, float dh,
                                   float sx, float sy, float sw, float sh, float opacity);
    void    (JCP_CALL *save_state)(jcp_graphics* g);      /* nesting up to 64; unbalanced saves are undone */
    void    (JCP_CALL *restore_state)(jcp_graphics* g);
    int32_t (JCP_CALL *clip_rect)(jcp_graphics* g, float x, float y, float w, float h); /* 1 = something visible */
    void    (JCP_CALL *translate)(jcp_graphics* g, float dx, float dy);

    /* --- added later (check struct_size before use) --- */

    /* A scaled editor: the library lays out and draws at a fixed design size
       (width x height, 16..4096), and the wrapper scales the whole drawing to
       the window (the graphics context is scaled, so text, paths and images
       stay sharp). The host and the user may resize the window, keeping the
       aspect ratio, from min_scale to max_scale times the design size (both
       clamped to JCP_EDITOR_MIN_SCALE..JCP_EDITOR_MAX_SCALE and to the window
       limits; non-finite: the call does nothing). Every coordinate the
       library sees or passes stays in design units: paint, mouse events,
       repaint, show_popup_menu; resized() reports the design size. The scale
       is remembered per plug-in instance (and saved with its state), and an
       editor opened again starts at it. set_size changes the design size;
       set_resize_limits ends scaling. flags: JCP_SCALE_*. */
    void    (JCP_CALL *set_design_size)(jcp_editor* e, int32_t width, int32_t height,
                                        float min_scale, float max_scale, int32_t flags);
    /* Window pixels per design unit (1 for an editor that is not scaled). */
    float   (JCP_CALL *get_scale)(jcp_editor* e);
    /* Asks the host OS to open a web page in the default browser. Only
       inside the library's mouse callback for a button press, release or
       double click, or its popup_result for a chosen item - i.e. as the
       answer to a user's click - once per click, and at most once a second;
       never from paint, timers, parameter changes or create_editor. The URL
       must be https://host[:port][/path][?query][#fragment] with a DNS host
       name (letters, digits, '-', at least one '.', no user name, no IP
       address), printable ASCII from a fixed set (no spaces, quotes,
       backslashes, '<', '>', '`', '$', ';', '|', '(', ')', '*', '!', '\''),
       '%' only before two hex digits (not a control character), at most
       JCP_MAX_URL bytes. Returns 1 if the URL was accepted (it is opened from
       the message loop, after the callback), 0 if refused. */
    int32_t (JCP_CALL *open_url)(jcp_editor* e, const char* url);
    /* Colours and fonts of this editor's tooltips and popup menus (look NULL:
       JUCE's defaults again). struct_size must be at least
       sizeof(jcp_editor_look). */
    void    (JCP_CALL *set_look)(jcp_editor* e, const jcp_editor_look* look);
    /* The OS's file dialog, to open a file (JCP_FILE_OPEN) or name one to
       write (JCP_FILE_SAVE). Returns at once (1 = shown); the answer comes
       later through file_chosen(request_id, path or NULL), and is dropped if
       the editor has closed by then. Like open_url, only as the answer to a
       user's click (inside the library's mouse press, release or double
       click callback, or its popup_result for a chosen item), and one dialog
       per editor at a time. title: UTF-8, at most 256 bytes (NULL or "":
       a default). patterns: e.g. "*.hfe;*.img" - only letters, digits and
       * ? . ; _ - characters, at most JCP_MAX_FILE_PATTERNS bytes (NULL or
       "": any file). initial: a folder, or a file to start at (UTF-8, at
       most JCP_MAX_PATH bytes; NULL or "": the OS's choice). The library
       needs the editor vtable's file_chosen; without it this returns 0. */
    int32_t (JCP_CALL *choose_file)(jcp_editor* e, int32_t request_id, int32_t mode, const char* title,
                                    const char* patterns, const char* initial);
} jcp_editor_api;

typedef void (JCP_CALL *jcp_state_writer)(void* writer, const void* data, int32_t size);

/* Per-instance callbacks, filled in by create(). All optional except
   `destroy` and `process`. */
typedef struct jcp_plugin_vtable {
    int32_t struct_size;
    int32_t reserved;
    void   (JCP_CALL *destroy)(void* self);
    void   (JCP_CALL *prepare)(void* self, double sample_rate, int32_t max_block_size);
    void   (JCP_CALL *release)(void* self);
    void   (JCP_CALL *reset)(void* self);
    void   (JCP_CALL *process)(void* self, const jcp_process_context* context);
    /* Extra state beyond parameter values (which the wrapper saves itself). */
    void   (JCP_CALL *get_state)(void* self, jcp_state_writer write, void* writer);
    /* `data` is untrusted (it comes from a project file); size may be 0. */
    void   (JCP_CALL *set_state)(void* self, const void* data, int32_t size);
    double (JCP_CALL *get_tail_seconds)(void* self);
    /* Optional value-to-text: write NUL-terminated UTF-8 into buffer and
       return 1, or return 0 for the default text. */
    int32_t (JCP_CALL *get_parameter_text)(void* self, int32_t index, float value, char* buffer, int32_t buffer_size);
    void*  (JCP_CALL *get_extension)(void* self, const char* id);
    /* --- added for custom editors (check struct_size) --- */
    /* Optional. Message thread. Create the library's editor object for this
       instance, fill `vtable` (the wrapper sets its struct_size and zeroes the
       rest) and set *width / *height (preset to 400 x 300, clamped to
       JCP_EDITOR_MIN_SIZE..JCP_EDITOR_MAX_SIZE). Return NULL for JUCE's
       generic editor. `editor` names this editor in jcp_editor_api calls;
       `api` stays valid while the library is loaded. */
    void*  (JCP_CALL *create_editor)(void* self, const jcp_editor_api* api, jcp_editor* editor,
                                     jcp_editor_vtable* vtable, int32_t* width, int32_t* height);
    /* --- added for host programs (check struct_size) --- */
    /* Optional, all four or none. The library's own programs (presets, or
       e.g. the programmes of a loaded sound bank), offered to the host as the
       plug-in's programs. A count of 0 (or these absent) gives the host one
       program, "Default", as before; the wrapper offers at most
       JCP_MAX_PROGRAMS. Call jcp_host_api.programs_changed when the list or
       the current program changes.
       get_program_count, get_current_program, get_program_name: any thread,
       possibly concurrently with process (keep them quick and lock-free).
       get_program_name writes NUL-terminated UTF-8 (at most
       JCP_MAX_PROGRAM_NAME bytes are used) and returns 1, or 0 for none.
       set_current_program: a non-real-time thread, with index in range;
       never concurrently with process (the wrapper holds the processing
       lock, as for set_state). */
    int32_t (JCP_CALL *get_program_count)(void* self);
    int32_t (JCP_CALL *get_current_program)(void* self);
    void    (JCP_CALL *set_current_program)(void* self, int32_t index);
    int32_t (JCP_CALL *get_program_name)(void* self, int32_t index, char* buffer, int32_t buffer_size);
} jcp_plugin_vtable;

typedef struct jcp_plugin_factory {
    int32_t struct_size;
    int32_t abi_version;
    int32_t kind;          /* JCP_KIND_*: must match the wrapper's KIND */
    int32_t reserved;
    int32_t (JCP_CALL *get_parameter_count)(void);
    /* The wrapper sets info->struct_size. Strings must stay valid until the
       library is unloaded. Returns 0 on success. */
    int32_t (JCP_CALL *get_parameter_info)(int32_t index, jcp_parameter_info* info);
    /* Returns the instance (`self`) or NULL. The wrapper sets
       vtable->struct_size and zeroes the rest first. */
    void*   (JCP_CALL *create)(const jcp_host_api* api, jcp_host* host, jcp_plugin_vtable* vtable);
    /* Set when the entry point fails: why (UTF-8), or NULL. */
    const char* error_message;
} jcp_plugin_factory;

typedef int32_t (JCP_CALL *jcp_plugin_entry_fn)(int32_t host_abi_version, jcp_plugin_factory* factory);

#define JCP_ENTRY_NAME "pascaljuce_plugin_entry"

#ifdef __cplusplus
}
#endif

#endif
