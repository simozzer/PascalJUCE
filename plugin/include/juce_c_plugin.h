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
    prepare and release run on a non-real-time thread. Never let exceptions
    escape through this ABI.

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
} jcp_host_api;

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
