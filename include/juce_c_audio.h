/*
    juce_c_audio - a plain C ABI over JUCE's audio/MIDI modules
    (juce_core, juce_events, juce_audio_basics, juce_audio_devices,
    juce_audio_formats).

    Conventions
    -----------
    * All functions and callbacks use the C calling convention (cdecl).
    * Strings are NUL-terminated UTF-8.
    * Functions returning text write into a caller-owned buffer:
          buffer       - destination (may be NULL to query the size)
          buffer_size  - in: capacity in bytes; out: bytes required,
                         including the terminating NUL.
      If the capacity is too small, JUCE_C_BUFFER_TOO_SMALL is returned and,
      when buffer != NULL and capacity > 0, a NUL-terminated prefix is written
      (cut at a UTF-8 character boundary). A size query (buffer == NULL) does
      not set the last error text.
    * Error reporting: every function that returns juce_c_result clears the
      calling thread's last-error text on success and sets it on failure
      (juce_c_get_last_error_message). Functions returning plain values
      (counts, rates, ...) return 0 / -1 / NULL-equivalents for invalid
      handles and do not touch the last-error text.
    * Structs that may grow carry a `struct_size` field: set it to
      sizeof(the struct) before passing the struct in.
    * Every handle created by *_create / *_open is freed by the matching
      *_destroy, which accepts NULL.
    * Threads:
        - juce_c_initialise() makes the calling thread JUCE's message thread.
          Device-manager functions that return juce_c_result must be called
          on that thread (else JUCE_C_INVALID_STATE).
        - Audio callbacks run on an audio thread, MIDI-input callbacks on a
          MIDI thread. They must be real-time safe and must not let language
          exceptions escape. Never destroy a handle from its own callback,
          and never block an audio callback waiting for the message thread
          (e.g. Delphi TThread.Synchronize): close/destroy/set_setup wait for
          the running callback to finish, so that deadlocks.
        - Every call that changes a device manager, its destroy, and its on_start,
          on_stop and change callbacks on the message thread mark it busy:
          changing or destroying a busy manager returns JUCE_C_INVALID_STATE
          from anywhere (including other managers' callbacks), and
          juce_c_dispatch_messages is refused while any of them runs.
        - on_start, on_stop and the change callback run on the message thread,
          nested inside initialise/close/set_setup/...: from inside them,
          destroy, close, restart, initialise, set_setup, set_current_device_type,
          add_virtual_device_type, set_change_callback, play_test_sound and
          set_midi_input_enabled on the same manager return JUCE_C_INVALID_STATE.
        - Audio-buffer, MIDI-buffer and audio-file functions may be used on
          any thread, but a given handle must not be used concurrently.
    * Device-manager getters that return plain values return their 0 / -1
      fallback when called on the wrong thread, because another thread may
      be changing what they would read:
        - getters of the open device (sample rate, buffer size, bit depth,
          latency, channels, is_device_open, CPU usage, xruns) work on the
          message thread and inside that same manager's own callbacks;
        - device-type and device counts, the default device index and
          is_midi_input_enabled work on the message thread only (JUCE
          changes those lists while the device keeps running).
    * Floating point: every entry point that does floating-point work or
      calls into JUCE or a driver masks FP exceptions for its duration and
      restores the caller's state, so hosts with unmasked FP exceptions
      (Delphi's default) are safe when calling in.
*/
#ifndef JUCE_C_AUDIO_H
#define JUCE_C_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
    #define JUCE_C_CALL __cdecl
    #if defined(JUCE_C_AUDIO_BUILD)
        #define JUCE_C_AUDIO_API __declspec(dllexport)
    #else
        #define JUCE_C_AUDIO_API __declspec(dllimport)
    #endif
#else
    #define JUCE_C_CALL
    #define JUCE_C_AUDIO_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define JUCE_C_AUDIO_ABI_VERSION 4

/* Result codes. A fixed-size integer, not an enum, so every language agrees
   on its size. */
typedef int32_t juce_c_result;
#define JUCE_C_OK                0
#define JUCE_C_INVALID_ARGUMENT  1
#define JUCE_C_OUT_OF_MEMORY     2
#define JUCE_C_JUCE_ERROR        3
#define JUCE_C_OUT_OF_RANGE      4
#define JUCE_C_BUFFER_TOO_SMALL  5
#define JUCE_C_NOT_INITIALISED   6
#define JUCE_C_INVALID_STATE     7

typedef struct juce_c_audio_buffer juce_c_audio_buffer;
typedef struct juce_c_midi_buffer juce_c_midi_buffer;
typedef struct juce_c_audio_device_manager juce_c_audio_device_manager;
typedef struct juce_c_midi_device_list juce_c_midi_device_list;
typedef struct juce_c_midi_input juce_c_midi_input;
typedef struct juce_c_midi_output juce_c_midi_output;
typedef struct juce_c_audio_file_reader juce_c_audio_file_reader;
typedef struct juce_c_audio_file_writer juce_c_audio_file_writer;

/* ------------------------------------------------------------------------
   Library
   ------------------------------------------------------------------------ */

/* JUCE_C_AUDIO_ABI_VERSION of the compiled library. */
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_get_abi_version(void);

/* Last error text for the calling thread (see "Error reporting"). */
JUCE_C_AUDIO_API const char* JUCE_C_CALL juce_c_get_last_error_message(void);

/* JUCE version string, e.g. "JUCE v8.0.6". */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_get_juce_version(
    char* buffer, size_t* buffer_size);

/* Initialises JUCE and makes the calling thread the message thread.
   Reference counted: balance every successful call with juce_c_shutdown(),
   from the same thread. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_initialise(void);

/* Decrements the reference count; the last call shuts JUCE down.
   Fails with JUCE_C_INVALID_STATE if called from another thread, or if
   device managers or MIDI inputs/outputs are still alive at the last call
   (destroy them first) or other threads are still inside library calls (while
   such a refused shutdown runs, those threads may briefly see
   JUCE_C_NOT_INITIALISED), or if the last call is made from code running inside
   juce_c_dispatch_messages (a timer or event handler it pumped): that would
   delete the message loop under itself. Calling it when not initialised is a
   no-op (OK). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_shutdown(void);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_is_initialised(void);

/* Runs JUCE's message loop for about `milliseconds` ms (0 = handle at most
   one pending message). Needed in console programs and on Linux, where the
   host's event loop is not JUCE's; Windows/macOS GUI apps (VCL/LCL/Cocoa)
   need not call it. Must be called on the message thread. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_dispatch_messages(int32_t milliseconds);

/* High-resolution monotonic time in milliseconds. MIDI input timestamps are
   this value / 1000. */
JUCE_C_AUDIO_API double JUCE_C_CALL juce_c_get_millisecond_counter_hires(void);

/* ------------------------------------------------------------------------
   Audio buffers (juce::AudioBuffer<float>)
   Pointers returned by get_read/write_pointer stay valid until the buffer
   is resized or destroyed. At most 1024 channels, 2^29 - 1 samples per channel and 2^30 samples
   (channels x length) per buffer.
   ------------------------------------------------------------------------ */

JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_create(
    int32_t channel_count, int32_t sample_count, juce_c_audio_buffer** result);
JUCE_C_AUDIO_API void JUCE_C_CALL juce_c_audio_buffer_destroy(juce_c_audio_buffer* buffer);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_buffer_get_channel_count(const juce_c_audio_buffer* buffer);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_buffer_get_sample_count(const juce_c_audio_buffer* buffer);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_set_size(
    juce_c_audio_buffer* buffer, int32_t channel_count, int32_t sample_count, int32_t keep_existing_content);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_get_read_pointer(
    const juce_c_audio_buffer* buffer, int32_t channel, const float** result);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_get_write_pointer(
    juce_c_audio_buffer* buffer, int32_t channel, float** result);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_clear(juce_c_audio_buffer* buffer);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_clear_region(
    juce_c_audio_buffer* buffer, int32_t start_sample, int32_t sample_count);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_apply_gain(juce_c_audio_buffer* buffer, float gain);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_apply_gain_ramp(
    juce_c_audio_buffer* buffer, int32_t start_sample, int32_t sample_count, float start_gain, float end_gain);
/* dest[dest_channel][dest_start..] += source[source_channel][source_start..] * gain */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_add_from(
    juce_c_audio_buffer* dest, int32_t dest_channel, int32_t dest_start_sample,
    const juce_c_audio_buffer* source, int32_t source_channel, int32_t source_start_sample,
    int32_t sample_count, float gain);
/* dest[dest_channel][dest_start..] = source[source_channel][source_start..] */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_copy_from(
    juce_c_audio_buffer* dest, int32_t dest_channel, int32_t dest_start_sample,
    const juce_c_audio_buffer* source, int32_t source_channel, int32_t source_start_sample,
    int32_t sample_count);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_get_magnitude(
    const juce_c_audio_buffer* buffer, int32_t channel, int32_t start_sample, int32_t sample_count, float* result);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_buffer_get_rms_level(
    const juce_c_audio_buffer* buffer, int32_t channel, int32_t start_sample, int32_t sample_count, float* result);

/* ------------------------------------------------------------------------
   MIDI buffers (juce::MidiBuffer) and messages

   A "MIDI message" is one complete message: a status byte followed by
   exactly the data bytes that status requires (e.g. 3 for note on), or a
   SysEx F0 ... F7, at most 65529 bytes. Running status and concatenated
   messages are rejected with JUCE_C_INVALID_ARGUMENT.
   ------------------------------------------------------------------------ */

JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_buffer_create(juce_c_midi_buffer** result);
/* Called from inside that buffer's own for_each visitor it does nothing (the
   buffer leaks rather than being freed under the running iteration). */
JUCE_C_AUDIO_API void JUCE_C_CALL juce_c_midi_buffer_destroy(juce_c_midi_buffer* buffer);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_buffer_clear(juce_c_midi_buffer* buffer);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_midi_buffer_get_event_count(const juce_c_midi_buffer* buffer);
/* OUT_OF_RANGE once the buffer would hold more than 256 MB of events. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_buffer_add_event(
    juce_c_midi_buffer* buffer, const uint8_t* message, size_t message_size, int32_t sample_position);
/* Random access by index; O(n). Prefer juce_c_midi_buffer_for_each. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_buffer_get_event(
    const juce_c_midi_buffer* buffer, int32_t event_index,
    uint8_t* message, size_t* message_size, int32_t* sample_position);

/* Return non-zero from the visitor to stop iterating. */
typedef int32_t (JUCE_C_CALL *juce_c_midi_event_visitor)(
    void* user_data, const uint8_t* message, int32_t message_size, int32_t sample_position);

/* Visits events in time order. `message` is only valid during the call. The
   visitor must not change this buffer (add_event / clear return
   JUCE_C_INVALID_STATE while it runs). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_buffer_for_each(
    const juce_c_midi_buffer* buffer, juce_c_midi_event_visitor visitor, void* user_data);

/* Human-readable description, e.g. "Note on C3 Velocity 100 Channel 1". */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_message_get_description(
    const uint8_t* message, size_t message_size, char* buffer, size_t* buffer_size);

/* Note name, e.g. 60 -> "C3" (middle_c_octave = 3). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_get_note_name(
    int32_t note_number, int32_t use_sharps, int32_t include_octave, int32_t middle_c_octave,
    char* buffer, size_t* buffer_size);

/* Frequency in Hz of a MIDI note (A4 = note 69 = frequency_of_a). */
JUCE_C_AUDIO_API double JUCE_C_CALL juce_c_midi_get_note_frequency(int32_t note_number, double frequency_of_a);

/* ------------------------------------------------------------------------
   Audio device manager (juce::AudioDeviceManager)
   ------------------------------------------------------------------------ */

/* Audio thread, every block. Output channels are zero-filled before the
   call. sample_count can vary between blocks and is not guaranteed to stay
   within the block size reported at start - always honour it. `midi` holds
   this block's MIDI from enabled inputs and injected messages (never NULL;
   it grows on the audio thread only if more than 16 KB arrives in a block). */
typedef void (JUCE_C_CALL *juce_c_audio_callback)(
    void* user_data,
    const float* const* input_channels, int32_t input_channel_count,
    float* const* output_channels, int32_t output_channel_count,
    int32_t sample_count, const juce_c_midi_buffer* midi);

/* Before the first block after a device (re)starts. Runs on the thread that
   opens/restarts the device - usually the message thread, not the audio
   thread. expected_block_size is the device's nominal block size. */
typedef void (JUCE_C_CALL *juce_c_audio_start_callback)(
    void* user_data, double sample_rate, int32_t expected_block_size);

/* After the device stops calling the audio callback (thread as above). */
typedef void (JUCE_C_CALL *juce_c_audio_stop_callback)(void* user_data);

/* Message thread, when the device or its setup changes. */
typedef void (JUCE_C_CALL *juce_c_change_callback)(void* user_data);

typedef struct juce_c_audio_callbacks {
    int32_t struct_size;              /* sizeof(juce_c_audio_callbacks) */
    int32_t reserved;
    void* user_data;
    juce_c_audio_callback on_audio;   /* may be NULL (silence)           */
    juce_c_audio_start_callback on_start;
    juce_c_audio_stop_callback on_stop;
} juce_c_audio_callbacks;

/* Device configuration (fixed 600-byte layout, no padding). Channel masks
   cover channels 0..255: bit n of input_channels[n / 64] = channel n. */
typedef struct juce_c_audio_device_setup {
    int32_t  struct_size;                 /* sizeof(juce_c_audio_device_setup) */
    int32_t  buffer_size;                 /* samples, 0 = device default        */
    double   sample_rate;                 /* 0 = device default                 */
    uint64_t input_channels[4];
    uint64_t output_channels[4];
    int32_t  use_default_input_channels;  /* non-zero = ignore the mask         */
    int32_t  use_default_output_channels;
    char     output_device_name[256];     /* UTF-8; "" = no device (see below)  */
    char     input_device_name[256];
} juce_c_audio_device_setup;

/* sizeof(juce_c_audio_device_setup) as compiled into the library. */
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_setup_size(void);

/* Creates a manager (no device open yet). `callbacks` is copied; NULL means
   no callbacks. Requires juce_c_initialise(). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_create(
    const juce_c_audio_callbacks* callbacks, juce_c_audio_device_manager** result);
/* Closes the device; no callbacks run after it returns. Must be called on the
   message thread (else JUCE_C_INVALID_STATE and the handle stays valid). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_destroy(juce_c_audio_device_manager* manager);

/* Receives device-change notifications on the message thread (NULL = off). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_set_change_callback(
    juce_c_audio_device_manager* manager, juce_c_change_callback callback, void* user_data);

/* Registers the "Virtual" device type: a software device (8 in / 8 out)
   for tests, CI and headless use. realtime = 0 runs the callback as fast as
   possible (offline rendering). input_signal: 0 = silence, 1 = 440 Hz sine
   at 0.25 on every input, 2 = loopback (each input carries the matching
   output of the previous block - handy for testing effects). Call once, before opening a "Virtual" device. */
typedef struct juce_c_virtual_device_options {
    int32_t struct_size;   /* sizeof(juce_c_virtual_device_options) */
    int32_t realtime;
    int32_t input_signal;
    int32_t reserved;
} juce_c_virtual_device_options;

JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_add_virtual_device_type(
    juce_c_audio_device_manager* manager, const juce_c_virtual_device_options* options);
/* Virtual device only: count a simulated dropout (reported by get_xrun_count). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_simulate_xrun(
    juce_c_audio_device_manager* manager);

/* Opens default devices for the given channel counts (may be called again,
   e.g. after close). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_initialize(
    juce_c_audio_device_manager* manager, int32_t input_channel_count, int32_t output_channel_count);

/* Like initialize, with a device type and/or preferred setup (either may be
   NULL). With a type, devices of exactly that type are opened (empty names in
   `preferred` select the type's defaults) or an error is returned - there is
   no silent fallback to another type. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_initialize_with_setup(
    juce_c_audio_device_manager* manager, int32_t input_channel_count, int32_t output_channel_count,
    const char* device_type, const juce_c_audio_device_setup* preferred);

JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_close(juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_restart(juce_c_audio_device_manager* manager);

/* Device types ("Windows Audio", "ASIO", "CoreAudio", "ALSA", "Virtual"...). */
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_device_type_count(
    juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_get_device_type_name(
    juce_c_audio_device_manager* manager, int32_t type_index, char* buffer, size_t* buffer_size);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_get_current_device_type(
    const juce_c_audio_device_manager* manager, char* buffer, size_t* buffer_size);
/* Switches type and opens its default devices. Fails if the type is unknown
   or no device of that type could be opened. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_set_current_device_type(
    juce_c_audio_device_manager* manager, const char* type_name, int32_t treat_as_chosen_device);

/* Device names of a type. is_input: 0 = outputs, 1 = inputs. */
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_device_count(
    juce_c_audio_device_manager* manager, int32_t type_index, int32_t is_input);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_get_device_name(
    juce_c_audio_device_manager* manager, int32_t type_index, int32_t is_input, int32_t device_index,
    char* buffer, size_t* buffer_size);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_default_device_index(
    juce_c_audio_device_manager* manager, int32_t type_index, int32_t is_input);

/* get_setup: set setup->struct_size first. set_setup: empty input and
   output names close the device; an empty name on one side means "no
   device" for that direction. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_get_setup(
    const juce_c_audio_device_manager* manager, juce_c_audio_device_setup* setup);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_set_setup(
    juce_c_audio_device_manager* manager, const juce_c_audio_device_setup* setup, int32_t treat_as_chosen_device);

/* The open device. */
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_is_device_open(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_get_device_name_current(
    const juce_c_audio_device_manager* manager, char* buffer, size_t* buffer_size);
JUCE_C_AUDIO_API double JUCE_C_CALL juce_c_audio_device_manager_get_sample_rate(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_block_size(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_bit_depth(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_input_latency(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_output_latency(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_active_input_channel_count(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_active_output_channel_count(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_channel_name_count(
    const juce_c_audio_device_manager* manager, int32_t is_input);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_get_channel_name(
    const juce_c_audio_device_manager* manager, int32_t is_input, int32_t channel_index,
    char* buffer, size_t* buffer_size);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_available_sample_rate_count(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API double JUCE_C_CALL juce_c_audio_device_manager_get_available_sample_rate(
    const juce_c_audio_device_manager* manager, int32_t index);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_available_buffer_size_count(const juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_available_buffer_size(
    const juce_c_audio_device_manager* manager, int32_t index);
/* Fraction (0..1+) of the block time spent in the audio callback. */
JUCE_C_AUDIO_API double JUCE_C_CALL juce_c_audio_device_manager_get_cpu_usage(const juce_c_audio_device_manager* manager);
/* Dropouts: device-reported xruns plus callbacks that overran their block
   time (0 when nothing is open). */
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_get_xrun_count(const juce_c_audio_device_manager* manager);

JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_play_test_sound(juce_c_audio_device_manager* manager);

/* MIDI routed into the audio callback's `midi` buffer. Identifiers come from
   juce_c_midi_device_list_get_identifier. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_set_midi_input_enabled(
    juce_c_audio_device_manager* manager, const char* device_identifier, int32_t enabled);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_device_manager_is_midi_input_enabled(
    const juce_c_audio_device_manager* manager, const char* device_identifier);
/* Queues a message for the next audio block. Any thread. Takes a short lock
   shared with the audio thread (do not call it from the audio callback).
   Messages (and enabled MIDI-input traffic) are dropped while no audio device
   is running: nothing would take them from the queue. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_device_manager_add_midi_message(
    juce_c_audio_device_manager* manager, const uint8_t* message, size_t message_size);

/* For bindings: count an error caught inside a callback (any thread,
   real-time safe), and read-and-reset the count. */
JUCE_C_AUDIO_API void JUCE_C_CALL juce_c_audio_device_manager_report_callback_error(juce_c_audio_device_manager* manager);
JUCE_C_AUDIO_API uint32_t JUCE_C_CALL juce_c_audio_device_manager_consume_callback_error_count(
    juce_c_audio_device_manager* manager);

/* ------------------------------------------------------------------------
   MIDI devices (juce::MidiInput / juce::MidiOutput). Require
   juce_c_initialise().
   ------------------------------------------------------------------------ */

/* Snapshot of the available devices. is_input: 0 = outputs, 1 = inputs. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_device_list_create(
    int32_t is_input, juce_c_midi_device_list** result);
JUCE_C_AUDIO_API void JUCE_C_CALL juce_c_midi_device_list_destroy(juce_c_midi_device_list* list);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_midi_device_list_get_count(const juce_c_midi_device_list* list);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_device_list_get_name(
    const juce_c_midi_device_list* list, int32_t index, char* buffer, size_t* buffer_size);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_device_list_get_identifier(
    const juce_c_midi_device_list* list, int32_t index, char* buffer, size_t* buffer_size);
/* Identifier of the system default device ("" if none). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_get_default_device_identifier(
    int32_t is_input, char* buffer, size_t* buffer_size);

/* MIDI thread, each incoming message. timestamp_seconds is
   juce_c_get_millisecond_counter_hires() / 1000 at arrival. */
typedef void (JUCE_C_CALL *juce_c_midi_input_callback)(
    void* user_data, const uint8_t* message, int32_t message_size, double timestamp_seconds);

/* Fails with JUCE_C_JUCE_ERROR if no device has this identifier. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_input_open(
    const char* device_identifier, juce_c_midi_input_callback callback, void* user_data,
    juce_c_midi_input** result);
/* Stops (if needed) and closes the device. No callbacks after return.
   From inside any MIDI-input callback, open, start, stop and destroy of any
   input return JUCE_C_INVALID_STATE (and destroy leaves the input alive): they
   would change or free what JUCE is delivering from. NULL returns OK. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_input_destroy(juce_c_midi_input* input);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_input_start(juce_c_midi_input* input);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_input_stop(juce_c_midi_input* input);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_input_get_name(
    const juce_c_midi_input* input, char* buffer, size_t* buffer_size);

/* Fails with JUCE_C_JUCE_ERROR if no device has this identifier. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_output_open(
    const char* device_identifier, juce_c_midi_output** result);
JUCE_C_AUDIO_API void JUCE_C_CALL juce_c_midi_output_destroy(juce_c_midi_output* output);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_output_get_name(
    const juce_c_midi_output* output, char* buffer, size_t* buffer_size);
/* Sends one complete message (see "MIDI message") immediately. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_output_send(
    juce_c_midi_output* output, const uint8_t* message, size_t message_size);
/* Schedules a buffer on a background thread. Event sample positions are
   converted to time using `sample_rate`, starting at `start_time_ms` on the
   juce_c_get_millisecond_counter_hires() clock (<= 0 means now, at most a
   day ahead, for the last event too); sample_rate 1 Hz .. 10 MHz; at most 8192 events per call
   (JUCE inserts each into a sorted queue: large blocks cost quadratic time).
   Events more than 200 ms late when their turn comes are dropped. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_output_send_block(
    juce_c_midi_output* output, const juce_c_midi_buffer* buffer, double start_time_ms, double sample_rate);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_midi_output_clear_pending(juce_c_midi_output* output);

/* ------------------------------------------------------------------------
   Audio files (juce_audio_formats). No juce_c_initialise() needed.
   Readable and writable: WAV, AIFF, FLAC, Ogg Vorbis, on every platform.
   MP3/WMA (Windows Media) and Core Audio formats are deliberately not
   offered: their readers were not part of this library's review. Up to 256
   channels for reading, 255 for writing.
   Paths are UTF-8; relative paths resolve against the current directory.
   ------------------------------------------------------------------------ */

/* Wildcard of all readable extensions, e.g. "*.wav;*.aiff;*.flac;..." */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_get_wildcard(char* buffer, size_t* buffer_size);

/* Rejects files whose header describes an impossible format (0 or > 256
   channels, > 64-bit samples, non-standard WAV/AIFF sample widths, ...).
   WAV and AIFF files are re-framed before JUCE parses them: only the
   format and audio chunks are used, metadata chunks are never parsed, and a
   chunk that runs past the end of the file is rejected (a truncated audio
   chunk is clamped instead, so cut-short recordings still open). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_reader_open(
    const char* path, juce_c_audio_file_reader** result);
JUCE_C_AUDIO_API void JUCE_C_CALL juce_c_audio_file_reader_destroy(juce_c_audio_file_reader* reader);
JUCE_C_AUDIO_API double JUCE_C_CALL juce_c_audio_file_reader_get_sample_rate(const juce_c_audio_file_reader* reader);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_file_reader_get_channel_count(const juce_c_audio_file_reader* reader);
/* For compressed formats (FLAC, Ogg) the length a header claims is capped at
   1024 samples per byte of file (in total over all channels, at least 2^20):
   a tiny file cannot claim billions of frames. Reads beyond it return 0s. */
JUCE_C_AUDIO_API int64_t JUCE_C_CALL juce_c_audio_file_reader_get_length(const juce_c_audio_file_reader* reader);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_file_reader_get_bits_per_sample(const juce_c_audio_file_reader* reader);
JUCE_C_AUDIO_API int32_t JUCE_C_CALL juce_c_audio_file_reader_is_floating_point(const juce_c_audio_file_reader* reader);
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_reader_get_format_name(
    const juce_c_audio_file_reader* reader, char* buffer, size_t* buffer_size);
/* Reads `sample_count` frames from `reader_start_sample` into
   dest[*][dest_start_sample..]. A mono file is copied to every channel of
   dest; extra file channels are ignored; frames past the end read as 0. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_reader_read(
    juce_c_audio_file_reader* reader, juce_c_audio_buffer* dest, int32_t dest_start_sample,
    int32_t sample_count, int64_t reader_start_sample);

/* Loads a whole file into a new buffer (caller destroys it). Fails above
   2^29 - 1 frames or 2^30 samples (channels x frames); for WAV/AIFF the length is also capped
   at what the file's size can hold, and compressed formats (FLAC, Ogg) fail with OUT_OF_RANGE if the header claims more than 1024
   samples per byte of file.
   sample_rate may be NULL. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_load(
    const char* path, juce_c_audio_buffer** result, double* sample_rate);

/* Creates (or replaces) a file. format_name: "wav", "aiff", "flac", "ogg",
   or NULL/"" for "from the extension". bits_per_sample: WAV 8/16/24/32
   (32 = float), AIFF 8/16/24/32, FLAC 16/24; Ogg has a single depth and
   ignores this value. quality_index: Ogg 0..10 (higher = better), else 0.
   sample_rate: 1 Hz to 10 MHz; channel_count: 1 to 255.
   An existing file is only replaced once the settings are known to work.
   The file is complete when the writer is destroyed. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_writer_create(
    const char* path, const char* format_name, double sample_rate, int32_t channel_count,
    int32_t bits_per_sample, int32_t quality_index, juce_c_audio_file_writer** result);
JUCE_C_AUDIO_API void JUCE_C_CALL juce_c_audio_file_writer_destroy(juce_c_audio_file_writer* writer);
/* Writes the file's channel count from `source` (which must have at least
   that many channels). */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_writer_write_buffer(
    juce_c_audio_file_writer* writer, const juce_c_audio_buffer* source, int32_t start_sample, int32_t sample_count);
/* Non-interleaved data; channels[0..file channels-1] must be non-NULL;
   extra channels are ignored. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_writer_write_channels(
    juce_c_audio_file_writer* writer, const float* const* channels, int32_t channel_count, int32_t sample_count);
/* Updates the file on disk where the format supports it (WAV); a no-op
   returning OK for other formats, which are finalised on destroy. */
JUCE_C_AUDIO_API juce_c_result JUCE_C_CALL juce_c_audio_file_writer_flush(juce_c_audio_file_writer* writer);

#ifdef __cplusplus
}
#endif

#endif
