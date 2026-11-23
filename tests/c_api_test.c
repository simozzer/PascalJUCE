/*
    c_api_test - exhaustive tests of the juce_c_audio C API, written in C so
    they see exactly what any binding sees.

    Hardware-dependent sections detect availability and skip:
      - audio device tests need an openable default output device
      - MIDI loopback tests need the Windows MIDI Services loopback ports
    Set JUCE_C_TEST_NO_AUDIO=1 to skip opening audio devices.
*/
#include "juce_c_audio.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#if defined(_WIN32)
    #include <direct.h>
    #include <process.h>
    #include <windows.h>
    #define chdir _chdir
    #define getcwd _getcwd
#else
    #include <pthread.h>
    #include <unistd.h>
#endif

/* Run fn(arg) on a new thread and wait for it. */
typedef void (*thread_fn)(void*);
typedef struct thread_call { thread_fn fn; void* arg; } thread_call;

#if defined(_WIN32)
static unsigned __stdcall thread_entry(void* p)
{
    thread_call* call = (thread_call*) p;
    call->fn(call->arg);
    return 0;
}
static void run_on_other_thread(thread_fn fn, void* arg)
{
    thread_call call = { fn, arg };
    HANDLE h = (HANDLE) _beginthreadex(NULL, 0, thread_entry, &call, 0, NULL);
    WaitForSingleObject(h, INFINITE);
    CloseHandle(h);
}
#else
static void* thread_entry(void* p)
{
    thread_call* call = (thread_call*) p;
    call->fn(call->arg);
    return NULL;
}
static void run_on_other_thread(thread_fn fn, void* arg)
{
    thread_call call = { fn, arg };
    pthread_t t;
    pthread_create(&t, NULL, thread_entry, &call);
    pthread_join(t, NULL);
}
#endif

/* ------------------------------------------------------------------------ */
static int passed, failed, skipped;
static const char* suite_name = "";

static void suite(const char* name)
{
    suite_name = name;
    printf("%s\n", name);
}

static void check_impl(int ok, const char* what, const char* file, int line)
{
    if (ok)
    {
        ++passed;
        printf("  ok    %s\n", what);
    }
    else
    {
        ++failed;
        printf("  FAIL  %s   [%s, %s:%d] last error: \"%s\"\n", what, suite_name, file, line,
               juce_c_get_last_error_message());
    }
}

#define CHECK(cond, what) check_impl((cond) ? 1 : 0, what, __FILE__, __LINE__)
#define CHECK_RESULT(expr, expected, what) CHECK((expr) == (expected), what)

static void skip(const char* what, const char* why)
{
    ++skipped;
    printf("  skip  %s (%s)\n", what, why);
}

static int approx(double a, double b, double tolerance)
{
    return fabs(a - b) <= tolerance;
}

static void sleep_dispatch(int ms)
{
    double end = juce_c_get_millisecond_counter_hires() + ms;
    while (juce_c_get_millisecond_counter_hires() < end)
        juce_c_dispatch_messages(5);
}

/* ------------------------------------------------------------------------ */
static void test_library_before_init(void)
{
    suite("Library (before initialise)");
    CHECK(juce_c_get_abi_version() == JUCE_C_AUDIO_ABI_VERSION, "ABI version matches header");
    CHECK(!juce_c_is_initialised(), "not initialised at start");
    CHECK_RESULT(juce_c_dispatch_messages(0), JUCE_C_NOT_INITIALISED, "dispatch before initialise -> NOT_INITIALISED");

    juce_c_audio_device_manager* manager = (juce_c_audio_device_manager*) 1;
    CHECK_RESULT(juce_c_audio_device_manager_create(NULL, &manager), JUCE_C_NOT_INITIALISED,
                 "device manager before initialise -> NOT_INITIALISED");
    CHECK(manager == NULL, "out-handle cleared on failure");
    CHECK(strlen(juce_c_get_last_error_message()) > 0, "failure sets last error text");
    juce_c_midi_device_list* list = (juce_c_midi_device_list*) 1;
    CHECK_RESULT(juce_c_midi_device_list_create(1, &list), JUCE_C_NOT_INITIALISED, "MIDI list before initialise -> NOT_INITIALISED");
    CHECK_RESULT(juce_c_shutdown(), JUCE_C_OK, "shutdown when not initialised is a no-op");
    CHECK(sizeof(juce_c_result) == 4, "juce_c_result is 32-bit");

    double t1 = juce_c_get_millisecond_counter_hires();
    double t2 = juce_c_get_millisecond_counter_hires();
    CHECK(t1 > 0 && t2 >= t1, "hi-res millisecond counter is monotonic");
}

static void test_strings(void)
{
    suite("String output protocol");
    size_t size = 0;
    CHECK_RESULT(juce_c_get_juce_version(NULL, &size), JUCE_C_BUFFER_TOO_SMALL, "NULL buffer -> BUFFER_TOO_SMALL");
    CHECK(size > 5, "required size reported (includes NUL)");

    CHECK(juce_c_get_last_error_message()[0] == '\0', "a size query does not set the error text");

    char* text = (char*) malloc(size);
    size_t exact = size;
    CHECK_RESULT(juce_c_get_juce_version(text, &exact), JUCE_C_OK, "exact-size buffer -> OK");
    CHECK(exact == size && strlen(text) + 1 == size && strncmp(text, "JUCE v", 6) == 0, "text and size agree");
    CHECK(juce_c_get_last_error_message()[0] == '\0', "success clears last error");

    char tiny[4] = { 'x', 'x', 'x', 'x' };
    size_t small_size = sizeof(tiny);
    CHECK_RESULT(juce_c_get_juce_version(tiny, &small_size), JUCE_C_BUFFER_TOO_SMALL, "short buffer -> BUFFER_TOO_SMALL");
    CHECK(tiny[3] == '\0' && strncmp(tiny, "JUC", 3) == 0, "short buffer gets truncated NUL-terminated prefix");
    CHECK(small_size == size, "short buffer reports required size");

    char zero[1] = { 'x' };
    size_t zero_size = 0;
    CHECK_RESULT(juce_c_get_juce_version(zero, &zero_size), JUCE_C_BUFFER_TOO_SMALL, "zero capacity -> BUFFER_TOO_SMALL");
    CHECK(zero[0] == 'x', "zero capacity: buffer untouched");

    CHECK_RESULT(juce_c_get_juce_version(text, NULL), JUCE_C_INVALID_ARGUMENT, "NULL size pointer -> INVALID_ARGUMENT");
    free(text);

    /* Regression: malformed UTF-8 must be rejected before it reaches JUCE
       (JUCE's UTF-8 decoder reads past a truncated sequence). */
    const char truncated[] = { 'a', (char) 0xF0, 0 };       /* 4-byte lead, nothing after */
    const char overlong[] = { (char) 0xC0, (char) 0xAF, 0 }; /* overlong '/' */
    const char surrogate[] = { (char) 0xED, (char) 0xA0, (char) 0x80, 0 };
    juce_c_audio_file_reader* r = NULL;
    CHECK_RESULT(juce_c_audio_file_reader_open(truncated, &r), JUCE_C_INVALID_ARGUMENT, "truncated UTF-8 path rejected");
    CHECK(strstr(juce_c_get_last_error_message(), "UTF-8") != NULL, "error names UTF-8");
    CHECK_RESULT(juce_c_audio_file_reader_open(overlong, &r), JUCE_C_INVALID_ARGUMENT, "overlong UTF-8 path rejected");
    CHECK_RESULT(juce_c_audio_file_reader_open(surrogate, &r), JUCE_C_INVALID_ARGUMENT, "UTF-16 surrogate in UTF-8 rejected");
    juce_c_audio_file_writer* w = NULL;
    CHECK_RESULT(juce_c_audio_file_writer_create("x.wav", truncated, 48000, 1, 16, 0, &w), JUCE_C_INVALID_ARGUMENT,
                 "truncated UTF-8 format name rejected");
}

typedef struct other_thread_results
{
    juce_c_result dispatch, create, shutdown, initialise;
    juce_c_audio_device_manager* manager;
    juce_c_result close, list;
} other_thread_results;

static void call_from_other_thread(void* p)
{
    other_thread_results* r = (other_thread_results*) p;
    juce_c_audio_device_manager* created = NULL;
    juce_c_midi_device_list* list = NULL;
    r->dispatch = juce_c_dispatch_messages(0);
    r->create = juce_c_audio_device_manager_create(NULL, &created);
    r->close = juce_c_audio_device_manager_close(r->manager);
    r->shutdown = juce_c_shutdown();
    r->initialise = juce_c_initialise();
    r->list = juce_c_midi_device_list_create(0, &list);
    juce_c_midi_device_list_destroy(list);
}

static void test_init_refcount(void)
{
    suite("Initialise / shutdown / threads");
    CHECK_RESULT(juce_c_initialise(), JUCE_C_OK, "first initialise");
    CHECK_RESULT(juce_c_initialise(), JUCE_C_OK, "second initialise (ref counted)");
    CHECK(juce_c_is_initialised(), "initialised");
    CHECK_RESULT(juce_c_shutdown(), JUCE_C_OK, "first shutdown");
    CHECK(juce_c_is_initialised(), "still initialised after one shutdown");
    CHECK_RESULT(juce_c_dispatch_messages(0), JUCE_C_OK, "dispatch on the message thread");
    CHECK_RESULT(juce_c_dispatch_messages(-5), JUCE_C_OK, "negative dispatch time treated as 0");

    other_thread_results r = { 0 };
    juce_c_audio_device_manager_create(NULL, &r.manager);
    run_on_other_thread(call_from_other_thread, &r);
    CHECK(r.dispatch == JUCE_C_INVALID_STATE, "dispatch from another thread -> INVALID_STATE");
    CHECK(r.create == JUCE_C_INVALID_STATE, "create manager from another thread -> INVALID_STATE");
    CHECK(r.close == JUCE_C_INVALID_STATE, "close from another thread -> INVALID_STATE");
    CHECK(r.shutdown == JUCE_C_INVALID_STATE, "shutdown from another thread -> INVALID_STATE");
    CHECK(r.initialise == JUCE_C_INVALID_STATE, "initialise from another thread while initialised -> INVALID_STATE");
    CHECK(r.list == JUCE_C_OK, "MIDI device list works from any thread");
    CHECK(juce_c_is_initialised(), "still initialised after rejected calls");

    /* The last shutdown refuses while device handles are alive (they would dangle). */
    CHECK_RESULT(juce_c_shutdown(), JUCE_C_INVALID_STATE, "last shutdown with a live manager -> INVALID_STATE");
    CHECK(strstr(juce_c_get_last_error_message(), "still open") != NULL, "error explains why");
    CHECK(juce_c_is_initialised(), "still initialised after refused shutdown");
    juce_c_audio_device_manager_destroy(r.manager);
    CHECK_RESULT(juce_c_initialise(), JUCE_C_OK, "initialise again for the rest of the tests");
}

/* ------------------------------------------------------------------------ */
static void test_audio_buffers(void)
{
    suite("Audio buffers");
    juce_c_audio_buffer* a = (juce_c_audio_buffer*) 1;
    CHECK_RESULT(juce_c_audio_buffer_create(0, 8, &a), JUCE_C_INVALID_ARGUMENT, "zero channels rejected");
    CHECK(a == NULL, "out-handle cleared");
    CHECK_RESULT(juce_c_audio_buffer_create(2, -1, &a), JUCE_C_INVALID_ARGUMENT, "negative samples rejected");
    CHECK_RESULT(juce_c_audio_buffer_create(2, 8, NULL), JUCE_C_INVALID_ARGUMENT, "NULL result rejected");
    CHECK_RESULT(juce_c_audio_buffer_create(2, 16, &a), JUCE_C_OK, "create 2x16");
    CHECK(juce_c_audio_buffer_get_channel_count(a) == 2 && juce_c_audio_buffer_get_sample_count(a) == 16, "dimensions");
    CHECK(juce_c_audio_buffer_get_channel_count(NULL) == 0 && juce_c_audio_buffer_get_sample_count(NULL) == 0,
          "NULL handle -> 0 counts");

    float* w = NULL;
    const float* r = NULL;
    CHECK_RESULT(juce_c_audio_buffer_get_write_pointer(a, 2, &w), JUCE_C_OUT_OF_RANGE, "write pointer channel 2 out of range");
    CHECK_RESULT(juce_c_audio_buffer_get_write_pointer(a, -1, &w), JUCE_C_OUT_OF_RANGE, "write pointer channel -1 out of range");
    CHECK_RESULT(juce_c_audio_buffer_get_read_pointer(a, 0, NULL), JUCE_C_INVALID_ARGUMENT, "read pointer NULL result");
    CHECK_RESULT(juce_c_audio_buffer_get_write_pointer(a, 0, &w), JUCE_C_OK, "write pointer");
    CHECK_RESULT(juce_c_audio_buffer_get_read_pointer(a, 0, &r), JUCE_C_OK, "read pointer");
    CHECK(r == w, "read and write pointers alias the same data");

    int zero = 1;
    for (int i = 0; i < 16; ++i)
        zero = zero && w[i] == 0.0f;
    CHECK(zero, "new buffer is cleared");

    for (int i = 0; i < 16; ++i)
        w[i] = 1.0f;
    CHECK_RESULT(juce_c_audio_buffer_apply_gain(a, 0.5f), JUCE_C_OK, "apply gain");
    CHECK(w[15] == 0.5f, "gain applied");

    CHECK_RESULT(juce_c_audio_buffer_apply_gain_ramp(a, 0, 16, 0.0f, 2.0f), JUCE_C_OK, "gain ramp");
    CHECK(w[0] == 0.0f && w[15] > 0.8f, "ramp starts at 0 and rises");
    CHECK_RESULT(juce_c_audio_buffer_apply_gain_ramp(a, 10, 7, 1, 1), JUCE_C_OUT_OF_RANGE, "ramp past end rejected");

    CHECK_RESULT(juce_c_audio_buffer_clear_region(a, 0, 17), JUCE_C_OUT_OF_RANGE, "clear region too long");
    CHECK_RESULT(juce_c_audio_buffer_clear_region(a, 17, 0), JUCE_C_OUT_OF_RANGE, "clear region start past end");
    CHECK_RESULT(juce_c_audio_buffer_clear_region(a, -1, 1), JUCE_C_INVALID_ARGUMENT, "clear region negative start");
    CHECK_RESULT(juce_c_audio_buffer_clear_region(a, 16, 0), JUCE_C_OK, "empty region at end is valid");
    CHECK_RESULT(juce_c_audio_buffer_clear_region(a, 0, 8), JUCE_C_OK, "clear first half");
    CHECK(w[7] == 0.0f && w[8] != 0.0f, "only the region was cleared");

    /* Regression: JUCE's internal "is clear" flag must not hide writes made
       through a cached pointer after clear(). */
    CHECK_RESULT(juce_c_audio_buffer_clear(a), JUCE_C_OK, "clear whole buffer");
    w[3] = 1.0f;
    float peak = 0;
    juce_c_audio_buffer_get_magnitude(a, 0, 0, 16, &peak);
    CHECK(peak == 1.0f, "write through cached pointer after clear() is seen by magnitude");
    juce_c_audio_buffer_apply_gain(a, 0.5f);
    CHECK(w[3] == 0.5f, "...and by apply_gain");

    /* copy / add / measure */
    juce_c_audio_buffer* b = NULL;
    juce_c_audio_buffer_create(1, 16, &b);
    float* bw = NULL;
    juce_c_audio_buffer_get_write_pointer(b, 0, &bw);
    for (int i = 0; i < 16; ++i)
        bw[i] = (i % 2) ? -0.25f : 0.25f;

    CHECK_RESULT(juce_c_audio_buffer_copy_from(a, 1, 0, b, 0, 0, 16), JUCE_C_OK, "copy_from");
    float* a1 = NULL;
    juce_c_audio_buffer_get_write_pointer(a, 1, &a1);
    CHECK(a1[0] == 0.25f && a1[1] == -0.25f, "copied data");
    CHECK_RESULT(juce_c_audio_buffer_add_from(a, 1, 0, b, 0, 0, 16, 2.0f), JUCE_C_OK, "add_from with gain");
    CHECK(approx(a1[0], 0.75, 1e-6), "added data");
    CHECK_RESULT(juce_c_audio_buffer_add_from(a, 1, 8, b, 0, 0, 9, 1.0f), JUCE_C_OUT_OF_RANGE, "add_from dest range past end");
    CHECK_RESULT(juce_c_audio_buffer_copy_from(a, 0, 0, b, 1, 0, 1), JUCE_C_OUT_OF_RANGE, "copy_from bad source channel");
    CHECK_RESULT(juce_c_audio_buffer_copy_from(a, 0, 0, NULL, 0, 0, 1), JUCE_C_INVALID_ARGUMENT, "copy_from NULL source");

    float level = -1;
    CHECK_RESULT(juce_c_audio_buffer_get_magnitude(b, 0, 0, 16, &level), JUCE_C_OK, "magnitude");
    CHECK(approx(level, 0.25, 1e-6), "magnitude value");
    CHECK_RESULT(juce_c_audio_buffer_get_rms_level(b, 0, 0, 16, &level), JUCE_C_OK, "rms");
    CHECK(approx(level, 0.25, 1e-6), "rms value");
    CHECK_RESULT(juce_c_audio_buffer_get_rms_level(b, 1, 0, 16, &level), JUCE_C_OUT_OF_RANGE, "rms bad channel");
    CHECK_RESULT(juce_c_audio_buffer_get_magnitude(b, 0, 4, 13, &level), JUCE_C_OUT_OF_RANGE, "magnitude bad range");

    /* resize */
    CHECK_RESULT(juce_c_audio_buffer_set_size(b, 2, 32, 1), JUCE_C_OK, "set_size keeping content");
    juce_c_audio_buffer_get_write_pointer(b, 0, &bw);
    CHECK(juce_c_audio_buffer_get_channel_count(b) == 2 && juce_c_audio_buffer_get_sample_count(b) == 32
          && bw[0] == 0.25f, "resized with content kept");
    CHECK_RESULT(juce_c_audio_buffer_set_size(b, 0, 32, 0), JUCE_C_INVALID_ARGUMENT, "set_size zero channels rejected");

    /* The API caps buffer sizes. */
    CHECK_RESULT(juce_c_audio_buffer_set_size(b, 1025, 1, 0), JUCE_C_INVALID_ARGUMENT, "set_size above 1024 channels rejected");
    CHECK_RESULT(juce_c_audio_buffer_set_size(b, 2, 600000000, 0), JUCE_C_INVALID_ARGUMENT, "set_size above 2^30 samples rejected");
    juce_c_audio_buffer* huge = NULL;
    CHECK_RESULT(juce_c_audio_buffer_create(4096, 16, &huge), JUCE_C_INVALID_ARGUMENT, "create above 1024 channels rejected");
    CHECK_RESULT(juce_c_audio_buffer_create(1024, 16, &huge), JUCE_C_OK, "create with 1024 channels allowed");
    juce_c_audio_buffer_destroy(huge);
    CHECK(juce_c_audio_buffer_get_channel_count(b) == 2, "rejected set_size left the buffer unchanged");

    CHECK_RESULT(juce_c_audio_buffer_clear(NULL), JUCE_C_INVALID_ARGUMENT, "clear NULL");
    CHECK_RESULT(juce_c_audio_buffer_apply_gain(NULL, 1), JUCE_C_INVALID_ARGUMENT, "gain NULL");
    juce_c_audio_buffer_destroy(NULL);
    CHECK(1, "destroy(NULL) is a no-op");
    juce_c_audio_buffer_destroy(a);
    juce_c_audio_buffer_destroy(b);
}

/* ------------------------------------------------------------------------ */
typedef struct visit_log
{
    int count;
    int positions[8];
    int stop_after;
} visit_log;

static int JUCE_C_CALL visit(void* user, const uint8_t* message, int size, int position)
{
    visit_log* log = (visit_log*) user;
    (void) message;
    (void) size;
    if (log->count < 8)
        log->positions[log->count] = position;
    ++log->count;
    return log->stop_after > 0 && log->count >= log->stop_after;
}

static int JUCE_C_CALL mutating_visitor(void* user, const uint8_t* message, int32_t size, int32_t position)
{
    juce_c_midi_buffer* self = (juce_c_midi_buffer*) user;
    const uint8_t on[] = { 0x90, 1, 1 };
    (void) message;
    (void) size;
    (void) position;
    /* Both must be refused: they would reallocate under the live iterator. */
    if (juce_c_midi_buffer_add_event(self, on, 3, 0) != JUCE_C_INVALID_STATE)
        return 2;
    if (juce_c_midi_buffer_clear(self) != JUCE_C_INVALID_STATE)
        return 3;
    return 1; /* stop */
}

static void test_midi_buffers(void)
{
    suite("MIDI buffers and helpers");
    juce_c_midi_buffer* m = NULL;
    CHECK_RESULT(juce_c_midi_buffer_create(NULL), JUCE_C_INVALID_ARGUMENT, "create NULL result");
    CHECK_RESULT(juce_c_midi_buffer_create(&m), JUCE_C_OK, "create");
    CHECK(juce_c_midi_buffer_get_event_count(m) == 0 && juce_c_midi_buffer_get_event_count(NULL) == 0, "empty");

    const uint8_t on[] = { 0x90, 60, 100 };
    const uint8_t off[] = { 0x80, 60, 0 };
    const uint8_t sysex[] = { 0xF0, 0x7D, 0x01, 0x02, 0x03, 0xF7 };
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, on, 0, 0), JUCE_C_INVALID_ARGUMENT, "zero-size event rejected");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, NULL, 3, 0), JUCE_C_INVALID_ARGUMENT, "NULL event rejected");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, off, 3, 30), JUCE_C_OK, "add note off @30");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, on, 3, 10), JUCE_C_OK, "add note on @10 (out of order)");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, sysex, sizeof(sysex), 20), JUCE_C_OK, "add sysex @20");
    CHECK(juce_c_midi_buffer_get_event_count(m) == 3, "three events");

    uint8_t data[8];
    size_t size = sizeof(data);
    int pos = -1;
    CHECK_RESULT(juce_c_midi_buffer_get_event(m, 0, data, &size, &pos), JUCE_C_OK, "get event 0");
    CHECK(pos == 10 && size == 3 && data[0] == 0x90, "events are sorted by time");
    size = sizeof(data);
    CHECK_RESULT(juce_c_midi_buffer_get_event(m, 1, data, &size, &pos), JUCE_C_OK, "get event 1 (sysex)");
    CHECK(size == sizeof(sysex) && memcmp(data, sysex, sizeof(sysex)) == 0, "sysex round-trips");
    size = 2;
    CHECK_RESULT(juce_c_midi_buffer_get_event(m, 2, data, &size, &pos), JUCE_C_BUFFER_TOO_SMALL, "tiny destination");
    CHECK(size == 3 && pos == 30, "required size and position reported");
    CHECK_RESULT(juce_c_midi_buffer_get_event(m, 3, data, &size, &pos), JUCE_C_OUT_OF_RANGE, "index past end");
    CHECK_RESULT(juce_c_midi_buffer_get_event(m, -1, data, &size, &pos), JUCE_C_OUT_OF_RANGE, "negative index");

    visit_log log = { 0 };
    CHECK_RESULT(juce_c_midi_buffer_for_each(m, visit, &log), JUCE_C_OK, "for_each");
    CHECK(log.count == 3 && log.positions[0] == 10 && log.positions[1] == 20 && log.positions[2] == 30,
          "for_each visits in time order");
    visit_log early = { 0 };
    early.stop_after = 1;
    juce_c_midi_buffer_for_each(m, visit, &early);
    CHECK(early.count == 1, "non-zero visitor return stops iteration");
    CHECK_RESULT(juce_c_midi_buffer_for_each(m, NULL, NULL), JUCE_C_INVALID_ARGUMENT, "NULL visitor rejected");

    /* Regression: only exactly-one-complete-message is accepted. */
    const uint8_t short_note[] = { 0x90, 60 };
    const uint8_t two_notes[] = { 0x90, 60, 100, 0x90, 62, 100 };
    const uint8_t bad_data[] = { 0x90, 0xC0, 100 };
    const uint8_t open_sysex[] = { 0xF0, 0x7D, 0x01 };
    const uint8_t program[] = { 0xC0, 5 };
    const uint8_t clock[] = { 0xF8 };
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, short_note, 2, 0), JUCE_C_INVALID_ARGUMENT, "truncated note-on rejected");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, two_notes, 6, 0), JUCE_C_INVALID_ARGUMENT, "two concatenated messages rejected");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, bad_data, 3, 0), JUCE_C_INVALID_ARGUMENT, "data byte >= 0x80 rejected");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, open_sysex, 3, 0), JUCE_C_INVALID_ARGUMENT, "SysEx without F7 rejected");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, on + 1, 2, 0), JUCE_C_INVALID_ARGUMENT, "running status rejected");
    CHECK(juce_c_midi_buffer_get_event_count(m) == 3, "rejected events were not added");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, program, 2, 40), JUCE_C_OK, "2-byte program change accepted");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, clock, 1, 41), JUCE_C_OK, "1-byte realtime message accepted");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, on, 3, -5), JUCE_C_OK, "negative position accepted");
    size = sizeof(data);
    juce_c_midi_buffer_get_event(m, 0, data, &size, &pos);
    CHECK(pos == 0, "negative position clamped to 0");

    /* Regression: mutating a buffer from inside its own for_each is refused. */
    const int before_visit = juce_c_midi_buffer_get_event_count(m);
    juce_c_midi_buffer_for_each(m, mutating_visitor, m);
    CHECK(juce_c_midi_buffer_get_event_count(m) == before_visit, "for_each visitor cannot add or clear (use-after-free guard)");
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, on, 3, 1), JUCE_C_OK, "mutation allowed again after for_each");

    /* Regression: SysEx above the 65529-byte limit is rejected, not silently dropped. */
    uint8_t* big = (uint8_t*) calloc(70000, 1);
    big[0] = 0xF0;
    big[69999] = 0xF7;
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, big, 70000, 0), JUCE_C_INVALID_ARGUMENT, "70000-byte SysEx rejected");
    big[65528] = 0xF7;
    CHECK_RESULT(juce_c_midi_buffer_add_event(m, big, 65529, 0), JUCE_C_OK, "65529-byte SysEx accepted");
    free(big);

    CHECK_RESULT(juce_c_midi_buffer_clear(m), JUCE_C_OK, "clear");
    CHECK(juce_c_midi_buffer_get_event_count(m) == 0, "cleared");
    juce_c_midi_buffer_destroy(m);
    juce_c_midi_buffer_destroy(NULL);

    char text[128];
    size_t text_size = sizeof(text);
    CHECK_RESULT(juce_c_midi_message_get_description(on, 3, text, &text_size), JUCE_C_OK, "describe note on");
    CHECK(strncmp(text, "Note on C3", 10) == 0, text);
    const uint8_t running_status[] = { 60, 100 };
    text_size = sizeof(text);
    CHECK_RESULT(juce_c_midi_message_get_description(running_status, 2, text, &text_size), JUCE_C_INVALID_ARGUMENT,
                 "message without status byte rejected");
    text_size = sizeof(text);
    CHECK_RESULT(juce_c_midi_message_get_description(sysex, sizeof(sysex), text, &text_size), JUCE_C_OK, "describe SysEx");
    text_size = sizeof(text);
    CHECK_RESULT(juce_c_midi_message_get_description(short_note, 2, text, &text_size), JUCE_C_INVALID_ARGUMENT,
                 "describe truncated message rejected");
    CHECK_RESULT(juce_c_midi_message_get_description(NULL, 3, text, &text_size), JUCE_C_INVALID_ARGUMENT, "NULL message rejected");

    text_size = sizeof(text);
    juce_c_midi_get_note_name(61, 1, 1, 3, text, &text_size);
    CHECK(strcmp(text, "C#3") == 0, "note name 61 sharps = C#3");
    text_size = sizeof(text);
    juce_c_midi_get_note_name(61, 0, 0, 3, text, &text_size);
    CHECK(strcmp(text, "Db") == 0, "note name 61 flats, no octave = Db");
    text_size = sizeof(text);
    juce_c_midi_get_note_name(60, 1, 1, 4, text, &text_size);
    CHECK(strcmp(text, "C4") == 0, "middle C octave 4 = C4");
    CHECK_RESULT(juce_c_midi_get_note_name(128, 1, 1, 3, text, &text_size), JUCE_C_OUT_OF_RANGE, "note 128 rejected");
    CHECK_RESULT(juce_c_midi_get_note_name(-1, 1, 1, 3, text, &text_size), JUCE_C_OUT_OF_RANGE, "note -1 rejected");
    CHECK(approx(juce_c_midi_get_note_frequency(69, 440), 440, 1e-9), "A4 = 440 Hz");
    CHECK(approx(juce_c_midi_get_note_frequency(57, 440), 220, 1e-9), "A3 = 220 Hz");
    CHECK(approx(juce_c_midi_get_note_frequency(69, 432), 432, 1e-9), "custom reference pitch");
}

/* ------------------------------------------------------------------------ */
typedef struct audio_probe
{
    volatile int blocks;
    volatile int midi_events;
    volatile int last_note;
    volatile int started;
    volatile int stopped;
    volatile double start_rate;
    volatile int start_block;
    volatile int changes;
    volatile int nonzero_outputs;
    volatile float input_peak;
    volatile int last_samples;
    volatile int input_channels;
    juce_c_audio_device_manager* volatile manager; /* set to read getters from inside the callback */
    juce_c_audio_device_manager* volatile other; /* another manager: must not be readable */
    volatile double cb_rate;
    volatile int cb_type_count;
    volatile double cb_other_rate;
} audio_probe;

static int JUCE_C_CALL probe_visit(void* user, const uint8_t* message, int32_t size, int32_t position)
{
    audio_probe* probe = (audio_probe*) user;
    (void) position;
    probe->midi_events++;
    if (size >= 2)
        probe->last_note = message[1];
    return 0;
}

static void JUCE_C_CALL probe_audio(void* user, const float* const* in, int32_t num_in, float* const* out,
                                    int32_t num_out, int32_t samples, const juce_c_midi_buffer* midi)
{
    audio_probe* probe = (audio_probe*) user;
    probe->blocks++;
    probe->last_samples = samples;
    probe->input_channels = num_in;
    juce_c_midi_buffer_for_each(midi, probe_visit, probe);
    for (int ch = 0; ch < num_out; ++ch)
        for (int i = 0; i < samples; ++i)
            if (out[ch] != NULL && out[ch][i] != 0.0f)
                probe->nonzero_outputs++;
    float peak = 0;
    for (int ch = 0; ch < num_in; ++ch)
        for (int i = 0; i < samples; ++i)
            if (in[ch] != NULL && fabsf(in[ch][i]) > peak)
                peak = fabsf(in[ch][i]);
    probe->input_peak = peak;
    juce_c_audio_device_manager* const self = probe->manager;
    juce_c_audio_device_manager* const other = probe->other;
    if (self != NULL && other != NULL)
    {
        probe->cb_rate = juce_c_audio_device_manager_get_sample_rate(self);
        probe->cb_type_count = juce_c_audio_device_manager_get_device_type_count(self);
        probe->cb_other_rate = juce_c_audio_device_manager_get_sample_rate(other);
    }
}

static void JUCE_C_CALL probe_start(void* user, double rate, int32_t block)
{
    audio_probe* probe = (audio_probe*) user;
    probe->started++;
    probe->start_rate = rate;
    probe->start_block = block;
}

static void JUCE_C_CALL probe_stop(void* user)
{
    ((audio_probe*) user)->stopped++;
}

static void JUCE_C_CALL probe_change(void* user)
{
    ((audio_probe*) user)->changes++;
}

static juce_c_audio_callbacks probe_callbacks(audio_probe* probe)
{
    juce_c_audio_callbacks cb;
    memset(&cb, 0, sizeof(cb));
    cb.struct_size = sizeof(cb);
    cb.user_data = probe;
    cb.on_audio = probe_audio;
    cb.on_start = probe_start;
    cb.on_stop = probe_stop;
    return cb;
}

static void new_setup(juce_c_audio_device_setup* setup)
{
    memset(setup, 0, sizeof(*setup));
    setup->struct_size = sizeof(*setup);
}

static void test_device_manager_closed(void)
{
    suite("Device manager (no device open)");
    audio_probe probe = { 0 };
    juce_c_audio_callbacks cb = probe_callbacks(&probe);
    juce_c_audio_device_manager* dm = NULL;
    CHECK_RESULT(juce_c_audio_device_manager_create(&cb, NULL), JUCE_C_INVALID_ARGUMENT, "NULL result");
    juce_c_audio_callbacks tiny = cb;
    tiny.struct_size = 8;
    CHECK_RESULT(juce_c_audio_device_manager_create(&tiny, &dm), JUCE_C_INVALID_ARGUMENT, "callbacks struct_size too tiny");
    CHECK_RESULT(juce_c_audio_device_manager_create(&cb, &dm), JUCE_C_OK, "create");
    CHECK(juce_c_audio_device_setup_size() == (int) sizeof(juce_c_audio_device_setup)
          && sizeof(juce_c_audio_device_setup) == 600, "setup struct is 600 bytes");
    CHECK(offsetof(juce_c_audio_device_setup, sample_rate) == 8 && offsetof(juce_c_audio_device_setup, input_channels) == 16
          && offsetof(juce_c_audio_device_setup, output_device_name) == 88, "setup field offsets");

    int types = juce_c_audio_device_manager_get_device_type_count(dm);
    CHECK(types > 0, "at least one device type");
    char text[512];
    size_t size = sizeof(text);
    CHECK_RESULT(juce_c_audio_device_manager_get_device_type_name(dm, 0, text, &size), JUCE_C_OK, "type name 0");
    size = sizeof(text);
    CHECK_RESULT(juce_c_audio_device_manager_get_device_type_name(dm, types, text, &size), JUCE_C_OUT_OF_RANGE, "type index past end");
    CHECK(juce_c_audio_device_manager_get_device_count(dm, types, 0) == 0, "device count for bad type = 0");
    CHECK(juce_c_audio_device_manager_get_default_device_index(dm, types, 0) == -1, "default index for bad type = -1");
    size = sizeof(text);
    CHECK_RESULT(juce_c_audio_device_manager_get_device_name(dm, 0, 0, 100000, text, &size), JUCE_C_OUT_OF_RANGE,
                 "device index past end");
    CHECK_RESULT(juce_c_audio_device_manager_set_current_device_type(dm, "No Such Type", 0), JUCE_C_INVALID_ARGUMENT,
                 "unknown device type rejected");
    CHECK_RESULT(juce_c_audio_device_manager_set_current_device_type(dm, NULL, 0), JUCE_C_INVALID_ARGUMENT, "NULL type rejected");

    CHECK(!juce_c_audio_device_manager_is_device_open(dm), "no device open");
    CHECK(juce_c_audio_device_manager_get_sample_rate(dm) == 0.0 && juce_c_audio_device_manager_get_block_size(dm) == 0,
          "no rate / block size without device");
    CHECK(juce_c_audio_device_manager_get_available_sample_rate_count(dm) == 0, "no sample rates without device");
    CHECK(juce_c_audio_device_manager_get_channel_name_count(dm, 0) == 0, "no channel names without device");
    size = sizeof(text);
    CHECK_RESULT(juce_c_audio_device_manager_get_channel_name(dm, 0, 0, text, &size), JUCE_C_INVALID_STATE,
                 "channel name without device -> INVALID_STATE");
    CHECK_RESULT(juce_c_audio_device_manager_play_test_sound(dm), JUCE_C_INVALID_STATE, "test sound without device");
    CHECK_RESULT(juce_c_audio_device_manager_simulate_xrun(dm), JUCE_C_INVALID_STATE, "simulate_xrun without a virtual device");
    size = sizeof(text);
    CHECK_RESULT(juce_c_audio_device_manager_get_device_name_current(dm, text, &size), JUCE_C_OK, "current name without device");
    CHECK(text[0] == '\0', "current name is empty");

    juce_c_audio_device_setup setup;
    new_setup(&setup);
    CHECK_RESULT(juce_c_audio_device_manager_get_setup(dm, &setup), JUCE_C_OK, "get_setup without device");
    CHECK(setup.struct_size == (int32_t) sizeof(setup), "get_setup preserves struct_size");
    CHECK_RESULT(juce_c_audio_device_manager_get_setup(dm, NULL), JUCE_C_INVALID_ARGUMENT, "get_setup NULL");
    setup.struct_size = 100;
    CHECK_RESULT(juce_c_audio_device_manager_get_setup(dm, &setup), JUCE_C_INVALID_ARGUMENT, "get_setup struct_size too tiny");
    CHECK_RESULT(juce_c_audio_device_manager_set_setup(dm, &setup, 0), JUCE_C_INVALID_ARGUMENT, "set_setup struct_size too tiny");

    CHECK_RESULT(juce_c_audio_device_manager_initialize(dm, 0, 0), JUCE_C_INVALID_ARGUMENT, "0 in / 0 out rejected");
    CHECK_RESULT(juce_c_audio_device_manager_initialize(dm, -1, 2), JUCE_C_INVALID_ARGUMENT, "negative channels rejected");
    CHECK_RESULT(juce_c_audio_device_manager_initialize(dm, 0, 300), JUCE_C_INVALID_ARGUMENT, "more than 256 channels rejected");
    CHECK_RESULT(juce_c_audio_device_manager_initialize_with_setup(dm, 0, 2, "No Such Type", NULL),
                 JUCE_C_INVALID_ARGUMENT, "initialise with unknown type rejected");

    CHECK_RESULT(juce_c_audio_device_manager_set_midi_input_enabled(dm, "", 1), JUCE_C_INVALID_ARGUMENT, "empty MIDI id");
    CHECK_RESULT(juce_c_audio_device_manager_set_midi_input_enabled(dm, NULL, 1), JUCE_C_INVALID_ARGUMENT, "NULL MIDI id");
    CHECK_RESULT(juce_c_audio_device_manager_set_midi_input_enabled(dm, "no-such-input", 1), JUCE_C_JUCE_ERROR,
                 "enabling an unknown MIDI input fails");
    const char bad_utf8[] = { 'x', (char) 0xE2, (char) 0x82, 0 }; /* truncated 3-byte sequence */
    CHECK_RESULT(juce_c_audio_device_manager_set_midi_input_enabled(dm, bad_utf8, 1), JUCE_C_INVALID_ARGUMENT,
                 "malformed UTF-8 MIDI identifier rejected");
    CHECK_RESULT(juce_c_audio_device_manager_set_current_device_type(dm, bad_utf8, 0), JUCE_C_INVALID_ARGUMENT,
                 "malformed UTF-8 device type rejected");
    juce_c_audio_device_setup bad_setup;
    new_setup(&bad_setup);
    memset(bad_setup.output_device_name, 'A', sizeof(bad_setup.output_device_name)); /* no NUL at all */
    bad_setup.output_device_name[255] = (char) 0xF0;                                 /* and a dangling lead byte */
    CHECK_RESULT(juce_c_audio_device_manager_set_setup(dm, &bad_setup, 0), JUCE_C_INVALID_ARGUMENT,
                 "unterminated name ending in a dangling UTF-8 lead byte rejected (no overread)");
    CHECK(!juce_c_audio_device_manager_is_midi_input_enabled(dm, "nope"), "unknown MIDI input not enabled");
    const uint8_t on[] = { 0x90, 64, 1 };
    const uint8_t bad[] = { 64, 1 };
    const uint8_t short_note[] = { 0x90, 64 };
    CHECK_RESULT(juce_c_audio_device_manager_add_midi_message(dm, on, 3), JUCE_C_OK, "inject MIDI");
    CHECK_RESULT(juce_c_audio_device_manager_add_midi_message(dm, bad, 2), JUCE_C_INVALID_ARGUMENT, "inject running status rejected");
    CHECK_RESULT(juce_c_audio_device_manager_add_midi_message(dm, short_note, 2), JUCE_C_INVALID_ARGUMENT, "inject truncated note rejected");

    CHECK(juce_c_audio_device_manager_consume_callback_error_count(dm) == 0, "no callback errors");
    juce_c_audio_device_manager_report_callback_error(dm);
    juce_c_audio_device_manager_report_callback_error(dm);
    CHECK(juce_c_audio_device_manager_consume_callback_error_count(dm) == 2, "reported errors counted");
    CHECK(juce_c_audio_device_manager_consume_callback_error_count(dm) == 0, "count resets on read");

    CHECK_RESULT(juce_c_audio_device_manager_set_change_callback(dm, probe_change, &probe), JUCE_C_OK, "set change callback");
    CHECK_RESULT(juce_c_audio_device_manager_set_change_callback(dm, NULL, NULL), JUCE_C_OK, "clear change callback");
    CHECK_RESULT(juce_c_audio_device_manager_close(dm), JUCE_C_OK, "close without device is harmless");

    /* NULL-handle guards */
    CHECK(juce_c_audio_device_manager_get_device_type_count(NULL) == 0, "NULL manager: type count 0");
    CHECK(juce_c_audio_device_manager_get_xrun_count(NULL) == 0, "NULL manager: xruns 0");
    CHECK(juce_c_audio_device_manager_get_cpu_usage(NULL) == 0.0, "NULL manager: cpu 0");
    CHECK_RESULT(juce_c_audio_device_manager_initialize(NULL, 0, 2), JUCE_C_INVALID_ARGUMENT, "NULL manager: initialise");
    juce_c_audio_device_manager_destroy(NULL);
    juce_c_audio_device_manager_destroy(dm);
    CHECK(probe.blocks == 0 && probe.started == 0, "no callbacks without a device");

    /* A manager with no callbacks at all is valid. */
    CHECK_RESULT(juce_c_audio_device_manager_create(NULL, &dm), JUCE_C_OK, "create with NULL callbacks");
    juce_c_audio_device_manager_destroy(dm);
}

static int count_virtual_types(juce_c_audio_device_manager* dm, int* platform_types)
{
    int found = 0;
    *platform_types = 0;
    for (int i = 0; i < juce_c_audio_device_manager_get_device_type_count(dm); ++i)
    {
        char name[256];
        size_t size = sizeof(name);
        juce_c_audio_device_manager_get_device_type_name(dm, i, name, &size);
        if (strcmp(name, "Virtual") == 0)
            ++found;
        else
            ++*platform_types;
    }
    return found;
}

typedef struct off_thread_probe
{
    juce_c_audio_device_manager* dm;
    double rate;
    int block, open, xruns;
    juce_c_result xrun_result, destroy_result;
} off_thread_probe;

static void read_device_from_other_thread(void* p)
{
    off_thread_probe* op = (off_thread_probe*) p;
    op->rate = juce_c_audio_device_manager_get_sample_rate(op->dm);
    op->block = juce_c_audio_device_manager_get_block_size(op->dm);
    op->open = juce_c_audio_device_manager_is_device_open(op->dm);
    op->xruns = juce_c_audio_device_manager_get_xrun_count(op->dm);
    op->xrun_result = juce_c_audio_device_manager_simulate_xrun(op->dm);
    op->destroy_result = juce_c_audio_device_manager_destroy(op->dm);
}

/* Review round 3: closing or destroying a manager from inside its own
   on_start / on_stop / change callback freed the device the outer call was
   still using. Those calls must now be refused. */
typedef struct
{
    juce_c_audio_device_manager* volatile manager;
    juce_c_result close_in_start, destroy_in_start, restart_in_stop, close_in_change;
    int starts, stops, changes;
} reenter_probe;

static void JUCE_C_CALL reenter_start(void* user, double rate, int32_t block)
{
    reenter_probe* p = (reenter_probe*) user;
    (void) rate;
    (void) block;
    if (p->manager != NULL && p->starts++ == 0)
    {
        p->close_in_start = juce_c_audio_device_manager_close(p->manager);
        p->destroy_in_start = juce_c_audio_device_manager_destroy(p->manager);
    }
}

static void JUCE_C_CALL reenter_stop(void* user)
{
    reenter_probe* p = (reenter_probe*) user;
    if (p->manager != NULL && p->stops++ == 0)
        p->restart_in_stop = juce_c_audio_device_manager_restart(p->manager);
}

static void JUCE_C_CALL reenter_change(void* user)
{
    reenter_probe* p = (reenter_probe*) user;
    if (p->manager != NULL && p->changes++ == 0)
        p->close_in_change = juce_c_audio_device_manager_close(p->manager);
}

static void test_reentrancy(void)
{
    suite("Re-entrant calls from device callbacks");
    reenter_probe p;
    memset(&p, 0, sizeof(p));
    p.close_in_start = p.destroy_in_start = p.restart_in_stop = p.close_in_change = -100;
    juce_c_audio_callbacks cb;
    memset(&cb, 0, sizeof(cb));
    cb.struct_size = sizeof(cb);
    cb.user_data = &p;
    cb.on_start = reenter_start;
    cb.on_stop = reenter_stop;
    juce_c_audio_device_manager* dm = NULL;
    CHECK_RESULT(juce_c_audio_device_manager_create(&cb, &dm), JUCE_C_OK, "create");
    juce_c_audio_device_manager_set_change_callback(dm, reenter_change, &p);
    juce_c_virtual_device_options options = { sizeof(juce_c_virtual_device_options), 1, 0, 0 };
    juce_c_audio_device_manager_add_virtual_device_type(dm, &options);
    p.manager = dm;
    CHECK_RESULT(juce_c_audio_device_manager_initialize_with_setup(dm, 0, 2, "Virtual", NULL), JUCE_C_OK,
                 "initialise survives callbacks that try to close/destroy");
    sleep_dispatch(100);
    CHECK(p.close_in_start == JUCE_C_INVALID_STATE, "close from on_start refused");
    CHECK(p.destroy_in_start == JUCE_C_INVALID_STATE, "destroy from on_start refused");
    CHECK(p.close_in_change == JUCE_C_INVALID_STATE || p.changes == 0, "close from the change callback refused");
    CHECK(juce_c_audio_device_manager_is_device_open(dm) == 1, "device still open afterwards");
    CHECK_RESULT(juce_c_audio_device_manager_close(dm), JUCE_C_OK, "close from outside works");
    CHECK(p.restart_in_stop == JUCE_C_INVALID_STATE, "restart from on_stop refused");
    p.manager = NULL;
    CHECK_RESULT(juce_c_audio_device_manager_destroy(dm), JUCE_C_OK, "destroy from outside works");
}

/* Review round 4: calls nest across managers. B's on_start closes A (allowed),
   A's on_stop then destroys B while B's initialise is still running: refused. */
typedef struct
{
    juce_c_audio_device_manager* volatile self;
    juce_c_audio_device_manager* volatile other;
    juce_c_result close_other, destroy_other, dispatch;
    int armed;
} nest_probe;

static void JUCE_C_CALL nest_b_start(void* user, double rate, int32_t block)
{
    nest_probe* p = (nest_probe*) user;
    (void) rate;
    (void) block;
    if (p->armed && p->other != NULL)
    {
        p->armed = 0;
        p->dispatch = juce_c_dispatch_messages(0);
        p->close_other = juce_c_audio_device_manager_close(p->other); /* closes A */
    }
}

static void JUCE_C_CALL nest_a_stop(void* user)
{
    nest_probe* p = (nest_probe*) user;
    if (p->armed && p->other != NULL)
    {
        p->armed = 0;
        p->destroy_other = juce_c_audio_device_manager_destroy(p->other); /* destroys B */
    }
}

static void test_nested_managers(void)
{
    suite("Calls nested across device managers");
    nest_probe pa, pb;
    memset(&pa, 0, sizeof(pa));
    memset(&pb, 0, sizeof(pb));
    pa.close_other = pa.destroy_other = pb.close_other = pb.destroy_other = pb.dispatch = -100;
    juce_c_audio_callbacks ca, cbb;
    memset(&ca, 0, sizeof(ca));
    memset(&cbb, 0, sizeof(cbb));
    ca.struct_size = cbb.struct_size = sizeof(ca);
    ca.user_data = &pa;
    ca.on_stop = nest_a_stop;
    cbb.user_data = &pb;
    cbb.on_start = nest_b_start;
    juce_c_audio_device_manager *a = NULL, *b = NULL;
    juce_c_virtual_device_options options = { sizeof(juce_c_virtual_device_options), 1, 0, 0 };
    CHECK(juce_c_audio_device_manager_create(&ca, &a) == JUCE_C_OK && juce_c_audio_device_manager_create(&cbb, &b) == JUCE_C_OK,
          "two managers");
    juce_c_audio_device_manager_add_virtual_device_type(a, &options);
    juce_c_audio_device_manager_add_virtual_device_type(b, &options);
    CHECK_RESULT(juce_c_audio_device_manager_initialize_with_setup(a, 0, 2, "Virtual", NULL), JUCE_C_OK, "A open");

    pa.other = b;
    pb.other = a;
    pa.armed = pb.armed = 1;
    CHECK_RESULT(juce_c_audio_device_manager_initialize_with_setup(b, 0, 2, "Virtual", NULL), JUCE_C_OK,
                 "B's initialise survives a nested attempt to destroy B");
    CHECK(pb.close_other == JUCE_C_OK, "B's on_start may close A (A is not mid-call)");
    CHECK(pa.destroy_other == JUCE_C_INVALID_STATE, "A's on_stop may not destroy B while B's initialise runs (was a use-after-free)");
    CHECK(pb.dispatch == JUCE_C_INVALID_STATE, "dispatch_messages refused inside a manager call");
    CHECK(juce_c_audio_device_manager_is_device_open(b) == 1, "B open");
    pa.other = pb.other = NULL;
    CHECK_RESULT(juce_c_audio_device_manager_destroy(b), JUCE_C_OK, "destroy B afterwards");
    CHECK_RESULT(juce_c_audio_device_manager_destroy(a), JUCE_C_OK, "destroy A afterwards");
}

/* Review round 5: destroy(A) runs A's on_stop; that opened B, whose on_start
   destroyed A again from inside A's destructor (double delete). */
typedef struct
{
    juce_c_audio_device_manager* volatile a;
    juce_c_audio_device_manager* volatile b;
    juce_c_result init_b, destroy_a_again, dispatch_in_stop, buffer_destroy_dummy;
    int armed_a, armed_b;
} dtor_probe;

static dtor_probe g_dtor;

static void JUCE_C_CALL dtor_a_stop(void* user)
{
    (void) user;
    if (g_dtor.armed_a && g_dtor.b != NULL)
    {
        g_dtor.armed_a = 0;
        g_dtor.dispatch_in_stop = juce_c_dispatch_messages(0);
        g_dtor.init_b = juce_c_audio_device_manager_initialize_with_setup(g_dtor.b, 0, 2, "Virtual", NULL);
    }
}

static void JUCE_C_CALL dtor_b_start(void* user, double rate, int32_t block)
{
    (void) user;
    (void) rate;
    (void) block;
    if (g_dtor.armed_b && g_dtor.a != NULL)
    {
        g_dtor.armed_b = 0;
        g_dtor.destroy_a_again = juce_c_audio_device_manager_destroy(g_dtor.a);
    }
}

static int JUCE_C_CALL destroy_self_visitor(void* user, const uint8_t* message, int32_t size, int32_t position)
{
    (void) message;
    (void) size;
    (void) position;
    juce_c_midi_buffer_destroy((juce_c_midi_buffer*) user); /* must be ignored */
    return 0;
}

static void test_destroy_reentry(void)
{
    suite("Re-entry during destroy");
    memset(&g_dtor, 0, sizeof(g_dtor));
    g_dtor.init_b = g_dtor.destroy_a_again = g_dtor.dispatch_in_stop = -100;
    juce_c_audio_callbacks ca, cbb;
    memset(&ca, 0, sizeof(ca));
    memset(&cbb, 0, sizeof(cbb));
    ca.struct_size = cbb.struct_size = sizeof(ca);
    ca.on_stop = dtor_a_stop;
    cbb.on_start = dtor_b_start;
    juce_c_audio_device_manager *a = NULL, *b = NULL;
    juce_c_virtual_device_options options = { sizeof(juce_c_virtual_device_options), 1, 0, 0 };
    juce_c_audio_device_manager_create(&ca, &a);
    juce_c_audio_device_manager_create(&cbb, &b);
    juce_c_audio_device_manager_add_virtual_device_type(a, &options);
    juce_c_audio_device_manager_add_virtual_device_type(b, &options);
    CHECK_RESULT(juce_c_audio_device_manager_initialize_with_setup(a, 0, 2, "Virtual", NULL), JUCE_C_OK, "A open");
    g_dtor.a = a;
    g_dtor.b = b;
    g_dtor.armed_a = g_dtor.armed_b = 1;
    CHECK_RESULT(juce_c_audio_device_manager_destroy(a), JUCE_C_OK, "destroy A (its on_stop opens B)");
    CHECK(g_dtor.init_b == JUCE_C_OK, "A's on_stop may open B");
    CHECK(g_dtor.destroy_a_again == JUCE_C_INVALID_STATE, "B's on_start may not destroy A while A is being destroyed (was a double delete)");
    CHECK(g_dtor.dispatch_in_stop == JUCE_C_INVALID_STATE, "dispatch_messages refused inside on_stop");
    g_dtor.a = g_dtor.b = NULL;
    CHECK_RESULT(juce_c_audio_device_manager_destroy(b), JUCE_C_OK, "destroy B");

    /* A MIDI buffer destroyed from its own visitor is left alone (no use-after-free). */
    juce_c_midi_buffer* mb = NULL;
    juce_c_midi_buffer_create(&mb);
    const uint8_t note[] = { 0x90, 60, 100 };
    juce_c_midi_buffer_add_event(mb, note, 3, 0);
    juce_c_midi_buffer_for_each(mb, destroy_self_visitor, mb);
    CHECK(juce_c_midi_buffer_get_event_count(mb) == 1, "buffer survives destroy from its own visitor");
    juce_c_midi_buffer_destroy(mb);
}

static void test_virtual_device(void)
{
    suite("Virtual audio device");
    audio_probe probe = { 0 };
    juce_c_audio_callbacks cb = probe_callbacks(&probe);
    juce_c_audio_device_manager* dm = NULL;
    juce_c_audio_device_manager_create(&cb, &dm);
    juce_c_audio_device_manager_set_change_callback(dm, probe_change, &probe);

    juce_c_virtual_device_options options = { sizeof(juce_c_virtual_device_options), 1, 1, 0 };
    juce_c_virtual_device_options tiny = options;
    tiny.struct_size = 4;
    CHECK_RESULT(juce_c_audio_device_manager_add_virtual_device_type(dm, &tiny), JUCE_C_INVALID_ARGUMENT,
                 "options struct_size too tiny");
    CHECK_RESULT(juce_c_audio_device_manager_add_virtual_device_type(dm, &options), JUCE_C_OK, "register Virtual type");
    CHECK_RESULT(juce_c_audio_device_manager_add_virtual_device_type(dm, &options), JUCE_C_INVALID_STATE, "registering twice rejected");
    int platform = 0;
    CHECK(count_virtual_types(dm, &platform) == 1, "Virtual listed once");
    CHECK(platform > 0, "platform device types still created (regression)");

    /* Opens once, on exactly the requested type. */
    CHECK_RESULT(juce_c_audio_device_manager_initialize_with_setup(dm, 2, 2, "Virtual", NULL), JUCE_C_OK,
                 "initialise with type Virtual");
    char text[256];
    size_t size = sizeof(text);
    juce_c_audio_device_manager_get_current_device_type(dm, text, &size);
    CHECK(strcmp(text, "Virtual") == 0, "current type is Virtual");
    size = sizeof(text);
    juce_c_audio_device_manager_get_device_name_current(dm, text, &size);
    CHECK(strcmp(text, "Virtual Device") == 0, "device name");
    CHECK(probe.started == 1, "device started exactly once (no double open)");
    CHECK(juce_c_audio_device_manager_get_active_input_channel_count(dm) == 2
          && juce_c_audio_device_manager_get_active_output_channel_count(dm) == 2, "2 in / 2 out active");
    CHECK(juce_c_audio_device_manager_get_channel_name_count(dm, 1) == 8, "8 input channel names");
    size = sizeof(text);
    juce_c_audio_device_manager_get_channel_name(dm, 0, 1, text, &size);
    CHECK(strcmp(text, "Virtual Out 2") == 0, "output channel name");
    CHECK(juce_c_audio_device_manager_get_available_buffer_size_count(dm) == 10, "buffer size list");

    double rate = juce_c_audio_device_manager_get_sample_rate(dm);
    int block = juce_c_audio_device_manager_get_block_size(dm);
    CHECK(rate > 0 && block > 0 && probe.start_rate == rate && probe.start_block == block, "start callback rate/block");

    /* Real-time pacing: ~0.5 s of blocks. */
    int blocks0 = probe.blocks;
    sleep_dispatch(500);
    double expected = 0.5 * rate / block;
    int got = probe.blocks - blocks0;
    char label[160];
    snprintf(label, sizeof(label), "real-time pacing (%d blocks in 0.5 s, expected ~%.0f)", got, expected);
    CHECK(got > expected * 0.6 && got < expected * 1.4, label);
    CHECK(probe.nonzero_outputs == 0, "outputs arrive zero-filled");
    CHECK(probe.input_channels == 2 && fabs(probe.input_peak - 0.25) < 0.01, "test tone on the inputs");

    /* Getter rules inside a callback: own device yes; lists and other managers no. */
    {
        juce_c_audio_device_manager* other = NULL;
        juce_c_audio_callbacks none;
        memset(&none, 0, sizeof(none));
        none.struct_size = sizeof(none);
        juce_c_virtual_device_options offline = { sizeof(juce_c_virtual_device_options), 1, 0, 0 };
        if (juce_c_audio_device_manager_create(&none, &other) == JUCE_C_OK
            && juce_c_audio_device_manager_add_virtual_device_type(other, &offline) == JUCE_C_OK
            && juce_c_audio_device_manager_initialize_with_setup(other, 0, 2, "Virtual", NULL) == JUCE_C_OK)
        {
            CHECK(juce_c_audio_device_manager_get_sample_rate(other) > 0, "second manager open");
            probe.cb_rate = -1;
            probe.cb_type_count = -1;
            probe.cb_other_rate = -1;
            probe.other = other;
            probe.manager = dm;
            sleep_dispatch(100);
            probe.manager = NULL;
            sleep_dispatch(50);
            probe.other = NULL;
            sleep_dispatch(50);
            CHECK(probe.cb_rate == rate, "own device rate readable inside its callback");
            CHECK(probe.cb_type_count == 0, "device-type count is message-thread only (fallback in callback)");
            CHECK(probe.cb_other_rate == 0.0, "another manager is not readable from this callback");
            juce_c_audio_device_manager_destroy(other);
        }
        else
        {
            CHECK(0, "second virtual manager opened");
            juce_c_audio_device_manager_destroy(other);
        }
    }

    /* MIDI injection reaches the block. */
    const uint8_t on[] = { 0x90, 72, 100 };
    juce_c_audio_device_manager_add_midi_message(dm, on, 3);
    sleep_dispatch(150);
    CHECK(probe.midi_events == 1 && probe.last_note == 72, "injected MIDI reaches the audio callback once");

    /* xruns */
    int xruns = juce_c_audio_device_manager_get_xrun_count(dm);
    CHECK_RESULT(juce_c_audio_device_manager_simulate_xrun(dm), JUCE_C_OK, "simulate xrun");
    CHECK(juce_c_audio_device_manager_get_xrun_count(dm) == xruns + 1, "xrun counted");

    /* Setup round-trip and a sample-rate change restart the device. */
    juce_c_audio_device_setup setup;
    new_setup(&setup);
    juce_c_audio_device_manager_get_setup(dm, &setup);
    CHECK(strcmp(setup.output_device_name, "Virtual Device") == 0 && setup.output_channels[0] == 3, "setup reflects device");
    setup.sample_rate = 96000;
    setup.buffer_size = 256;
    int started = probe.started;
    CHECK_RESULT(juce_c_audio_device_manager_set_setup(dm, &setup, 1), JUCE_C_OK, "set_setup 96 kHz / 256");
    CHECK(juce_c_audio_device_manager_get_sample_rate(dm) == 96000 && juce_c_audio_device_manager_get_block_size(dm) == 256,
          "new rate and block size");
    CHECK(probe.started == started + 1 && probe.start_rate == 96000 && probe.stopped >= 1, "stop + start around the change");
    sleep_dispatch(100);
    CHECK(probe.last_samples == 256, "callback receives the new block size");
    CHECK(probe.changes > 0, "change callback fired on the message thread");

    /* Channel masks above 64 are representable (mask word 1). */
    setup.output_channels[0] = 0;
    setup.output_channels[1] = 0;
    setup.output_channels[0] = 1u << 7; /* channel 7 */
    setup.use_default_output_channels = 0;
    CHECK_RESULT(juce_c_audio_device_manager_set_setup(dm, &setup, 1), JUCE_C_OK, "select output channel 7 only");
    CHECK(juce_c_audio_device_manager_get_active_output_channel_count(dm) == 1, "one active output");

    /* close / re-initialise / restart (regression: initialise was one-shot) */
    CHECK_RESULT(juce_c_audio_device_manager_close(dm), JUCE_C_OK, "close");
    int after_close = probe.blocks;
    sleep_dispatch(100);
    CHECK(probe.blocks == after_close, "no callbacks after close");
    CHECK_RESULT(juce_c_audio_device_manager_restart(dm), JUCE_C_OK, "restart reopens");
    sleep_dispatch(100);
    CHECK(probe.blocks > after_close, "callbacks resume after restart");
    CHECK_RESULT(juce_c_audio_device_manager_close(dm), JUCE_C_OK, "close again");
    CHECK_RESULT(juce_c_audio_device_manager_initialize_with_setup(dm, 0, 2, "Virtual", NULL), JUCE_C_OK,
                 "initialise again after close");
    CHECK(juce_c_audio_device_manager_is_device_open(dm), "open again");

    /* Regression: device state may only be read on the message thread or in
       a callback; other threads get the documented fallback values, and
       destroy is refused there (it would race JUCE's message delivery). */
    {
        off_thread_probe op = { 0 };
        op.dm = dm;
        run_on_other_thread(read_device_from_other_thread, &op);
        CHECK(op.rate == 0.0 && op.block == 0 && op.open == 0 && op.xruns == 0,
              "device getters from another thread return fallbacks");
        CHECK(op.xrun_result == JUCE_C_INVALID_STATE, "simulate_xrun from another thread -> INVALID_STATE");
        CHECK(op.destroy_result == JUCE_C_INVALID_STATE, "destroy from another thread -> INVALID_STATE (handle kept)");
        CHECK(juce_c_audio_device_manager_is_device_open(dm), "device still open after the refused destroy");
    }

    /* A device opened by set_setup alone still drives the callback (regression). */
    juce_c_audio_device_manager_close(dm);
    new_setup(&setup);
    strcpy(setup.output_device_name, "Virtual Device");
    setup.use_default_output_channels = 1;
    setup.use_default_input_channels = 1;
    int before = probe.blocks;
    CHECK_RESULT(juce_c_audio_device_manager_set_setup(dm, &setup, 0), JUCE_C_OK, "open via set_setup only");
    sleep_dispatch(100);
    CHECK(probe.blocks > before, "callback attached without initialise");

    juce_c_audio_device_manager_destroy(dm);
    int after_destroy = probe.blocks;
    sleep_dispatch(50);
    CHECK(probe.blocks == after_destroy, "no callbacks after destroy");

    /* Non-real-time mode renders as fast as possible. */
    audio_probe fast = { 0 };
    juce_c_audio_callbacks fcb = probe_callbacks(&fast);
    juce_c_virtual_device_options offline = { sizeof(juce_c_virtual_device_options), 0, 0, 0 };
    juce_c_audio_device_manager_create(&fcb, &dm);
    juce_c_audio_device_manager_add_virtual_device_type(dm, &offline);
    CHECK_RESULT(juce_c_audio_device_manager_set_current_device_type(dm, "Virtual", 0), JUCE_C_OK,
                 "set_current_device_type opens the Virtual device");
    sleep_dispatch(200);
    snprintf(label, sizeof(label), "offline mode runs faster than real time (%d blocks in 0.2 s)", fast.blocks);
    CHECK(fast.blocks > 200, label);
    CHECK(fast.input_peak == 0.0f, "silent inputs when input_signal = 0");
    juce_c_audio_device_manager_destroy(dm);
}

static void test_device_manager_hardware(void)
{
    suite("Device manager (default hardware output, optional)");
    if (getenv("JUCE_C_TEST_NO_AUDIO") != NULL)
    {
        skip("hardware audio tests", "JUCE_C_TEST_NO_AUDIO set");
        return;
    }

    audio_probe probe = { 0 };
    juce_c_audio_callbacks cb = probe_callbacks(&probe);
    juce_c_audio_device_manager* dm = NULL;
    juce_c_audio_device_manager_create(&cb, &dm);
    if (juce_c_audio_device_manager_initialize(dm, 0, 2) != JUCE_C_OK)
    {
        skip("hardware audio tests", juce_c_get_last_error_message());
        juce_c_audio_device_manager_destroy(dm);
        return;
    }

    CHECK(juce_c_audio_device_manager_is_device_open(dm), "device open");
    CHECK(juce_c_audio_device_manager_get_sample_rate(dm) > 0, "rate reported");
    CHECK(juce_c_audio_device_manager_get_available_sample_rate(dm, 9999) == 0.0, "sample rate index past end -> 0");
    sleep_dispatch(300);
    CHECK(probe.blocks > 5 && probe.nonzero_outputs == 0, "callback runs with zeroed outputs");
    CHECK_RESULT(juce_c_audio_device_manager_initialize(dm, 0, 2), JUCE_C_OK, "initialise is re-callable");
    juce_c_audio_device_manager_destroy(dm);
    int after = probe.blocks;
    sleep_dispatch(100);
    CHECK(probe.blocks == after, "no callbacks after destroy");
}

/* ------------------------------------------------------------------------ */
typedef struct midi_probe
{
    volatile int received;
    volatile int last_note;
    volatile double last_time;
    volatile int reentry; /* result of an open attempted inside the callback */
} midi_probe;

static void JUCE_C_CALL on_midi(void* user, const uint8_t* message, int size, double timestamp)
{
    midi_probe* probe = (midi_probe*) user;
    if (size == 3 && (message[0] & 0xF0) == 0x90)
    {
        probe->last_note = message[1];
        probe->last_time = timestamp;
        probe->received++;
        if (probe->received == 1)
        {
            juce_c_midi_input* nested = NULL;
            probe->reentry = juce_c_midi_input_open("no-such-device", on_midi, probe, &nested);
        }
    }
}

static int find_device(int is_input, const char* wanted, char* id, size_t id_capacity)
{
    juce_c_midi_device_list* list = NULL;
    int found = 0;
    if (juce_c_midi_device_list_create(is_input, &list) != JUCE_C_OK)
        return 0;
    for (int i = 0; i < juce_c_midi_device_list_get_count(list) && !found; ++i)
    {
        char name[256];
        size_t size = sizeof(name);
        juce_c_midi_device_list_get_name(list, i, name, &size);
        if (strcmp(name, wanted) == 0)
        {
            size = id_capacity;
            found = juce_c_midi_device_list_get_identifier(list, i, id, &size) == JUCE_C_OK;
        }
    }
    juce_c_midi_device_list_destroy(list);
    return found;
}

static void test_midi_devices(void)
{
    suite("MIDI devices");
    juce_c_midi_device_list* list = NULL;
    CHECK_RESULT(juce_c_midi_device_list_create(1, NULL), JUCE_C_INVALID_ARGUMENT, "list NULL result");
    CHECK_RESULT(juce_c_midi_device_list_create(1, &list), JUCE_C_OK, "input list");
    int count = juce_c_midi_device_list_get_count(list);
    CHECK(count >= 0 && juce_c_midi_device_list_get_count(NULL) == 0, "count");
    char text[512];
    size_t size = sizeof(text);
    CHECK_RESULT(juce_c_midi_device_list_get_name(list, count, text, &size), JUCE_C_OUT_OF_RANGE, "name index past end");
    size = sizeof(text);
    CHECK_RESULT(juce_c_midi_device_list_get_identifier(list, -1, text, &size), JUCE_C_OUT_OF_RANGE, "id index -1");
    juce_c_midi_device_list_destroy(list);
    juce_c_midi_device_list_destroy(NULL);

    size = sizeof(text);
    CHECK_RESULT(juce_c_midi_get_default_device_identifier(0, text, &size), JUCE_C_OK, "default output id query");

    midi_probe probe = { 0 };
    juce_c_midi_input* in = NULL;
    juce_c_midi_output* out = NULL;
    CHECK_RESULT(juce_c_midi_input_open("", on_midi, &probe, &in), JUCE_C_INVALID_ARGUMENT, "input empty id");
    CHECK_RESULT(juce_c_midi_input_open("x", NULL, &probe, &in), JUCE_C_INVALID_ARGUMENT, "input NULL callback");
    CHECK_RESULT(juce_c_midi_input_open("no-such-device", on_midi, &probe, &in), JUCE_C_JUCE_ERROR, "input bogus id");
    CHECK(in == NULL, "input handle cleared on failure");
    CHECK_RESULT(juce_c_midi_output_open("no-such-device", &out), JUCE_C_JUCE_ERROR, "output bogus id");
    CHECK_RESULT(juce_c_midi_output_send(NULL, (const uint8_t*) "\x90\x40\x40", 3), JUCE_C_INVALID_ARGUMENT, "send on NULL");
    CHECK_RESULT(juce_c_midi_input_start(NULL), JUCE_C_INVALID_ARGUMENT, "start NULL");
    juce_c_midi_input_destroy(NULL);
    juce_c_midi_output_destroy(NULL);

    char out_id[512], in_id[512];
    if (!find_device(0, "Default App Loopback (A)", out_id, sizeof(out_id))
        || !find_device(1, "Default App Loopback (B)", in_id, sizeof(in_id)))
    {
        skip("MIDI loopback tests", "Windows MIDI Services loopback ports not present");
        return;
    }

    CHECK_RESULT(juce_c_midi_input_open(in_id, on_midi, &probe, &in), JUCE_C_OK, "open loopback input");
    CHECK_RESULT(juce_c_midi_output_open(out_id, &out), JUCE_C_OK, "open loopback output");
    size = sizeof(text);
    juce_c_midi_output_get_name(out, text, &size);
    CHECK(strcmp(text, "Default App Loopback (A)") == 0, "output name");
    CHECK_RESULT(juce_c_midi_input_start(in), JUCE_C_OK, "start input");

    const uint8_t on[] = { 0x90, 64, 90 };
    double sent_at = juce_c_get_millisecond_counter_hires();
    CHECK_RESULT(juce_c_midi_output_send(out, on, 3), JUCE_C_OK, "send note");
    const uint8_t bad[] = { 64, 90 };
    CHECK_RESULT(juce_c_midi_output_send(out, bad, 2), JUCE_C_INVALID_ARGUMENT, "send without status byte rejected");
    sleep_dispatch(300);
    CHECK(probe.received == 1 && probe.last_note == 64, "note received through loopback");
    CHECK(probe.reentry == JUCE_C_INVALID_STATE, "opening a MIDI input inside a MIDI callback is refused (round 4)");
    CHECK(fabs(probe.last_time * 1000.0 - sent_at) < 1000.0, "timestamp on the hi-res clock (seconds)");

    juce_c_midi_buffer* block = NULL;
    juce_c_midi_buffer_create(&block);
    const uint8_t n1[] = { 0x90, 65, 90 }, n2[] = { 0x90, 66, 90 };
    juce_c_midi_buffer_add_event(block, n1, 3, 0);
    juce_c_midi_buffer_add_event(block, n2, 3, 4800);   /* 100 ms later at 48 kHz */
    CHECK_RESULT(juce_c_midi_output_send_block(out, block, juce_c_get_millisecond_counter_hires() + 50, 48000), JUCE_C_OK,
                 "send_block");
    CHECK_RESULT(juce_c_midi_output_send_block(out, block, 0, 0), JUCE_C_INVALID_ARGUMENT, "send_block rate 0 rejected");
    CHECK_RESULT(juce_c_midi_output_send_block(out, block, 0, 1e-300), JUCE_C_INVALID_ARGUMENT, "send_block rate 1e-300 rejected");
    CHECK_RESULT(juce_c_midi_output_send_block(out, block, juce_c_get_millisecond_counter_hires() + 1e12, 48000),
                 JUCE_C_INVALID_ARGUMENT, "send_block far-future start rejected");
    sleep_dispatch(400);
    CHECK(probe.received == 3 && probe.last_note == 66, "scheduled block delivered in order");

    juce_c_midi_output_send_block(out, block, juce_c_get_millisecond_counter_hires() + 300, 48000);
    CHECK_RESULT(juce_c_midi_output_clear_pending(out), JUCE_C_OK, "clear pending");
    sleep_dispatch(500);
    CHECK(probe.received == 3, "cleared messages are not sent");

    CHECK_RESULT(juce_c_midi_input_stop(in), JUCE_C_OK, "stop input");
    juce_c_midi_output_send(out, on, 3);
    sleep_dispatch(200);
    CHECK(probe.received == 3, "no callbacks after stop");

    juce_c_midi_buffer_destroy(block);
    juce_c_midi_output_destroy(out);
    juce_c_midi_input_destroy(in);
}

/* ------------------------------------------------------------------------ */
static void temp_path(char* out, size_t capacity, const char* name)
{
    const char* dir = getenv("TEMP");
    if (dir == NULL)
        dir = getenv("TMPDIR");
    if (dir == NULL)
        dir = "/tmp";
    snprintf(out, capacity, "%s/juce_c_test_%s", dir, name);
}

static juce_c_audio_buffer* make_sine(int channels, int samples)
{
    juce_c_audio_buffer* b = NULL;
    juce_c_audio_buffer_create(channels, samples, &b);
    for (int ch = 0; ch < channels; ++ch)
    {
        float* w = NULL;
        juce_c_audio_buffer_get_write_pointer(b, ch, &w);
        for (int i = 0; i < samples; ++i)
            w[i] = (float) (0.5 * sin(2 * 3.14159265358979 * 440.0 * i / 48000.0)) * (ch == 0 ? 1.0f : -1.0f);
    }
    return b;
}

static double max_error(juce_c_audio_buffer* a, juce_c_audio_buffer* b, int channel, int samples)
{
    const float *ra = NULL, *rb = NULL;
    juce_c_audio_buffer_get_read_pointer(a, channel, &ra);
    juce_c_audio_buffer_get_read_pointer(b, channel, &rb);
    double worst = 0;
    for (int i = 0; i < samples; ++i)
        if (fabs(ra[i] - rb[i]) > worst)
            worst = fabs(ra[i] - rb[i]);
    return worst;
}

static void roundtrip(const char* file, const char* format, int bits, double tolerance, int lossy)
{
    char path[1024], label[256];
    temp_path(path, sizeof(path), file);
    const int n = 4800;
    juce_c_audio_buffer* src = make_sine(2, n);
    juce_c_audio_file_writer* writer = NULL;

    snprintf(label, sizeof(label), "%s %d-bit: create writer", file, bits);
    CHECK_RESULT(juce_c_audio_file_writer_create(path, format, 48000, 2, bits, 5, &writer), JUCE_C_OK, label);
    if (writer == NULL)
    {
        juce_c_audio_buffer_destroy(src);
        return;
    }
    juce_c_audio_file_writer_write_buffer(writer, src, 0, n);
    juce_c_audio_file_writer_destroy(writer);

    juce_c_audio_buffer* loaded = NULL;
    double rate = 0;
    snprintf(label, sizeof(label), "%s: load", file);
    CHECK_RESULT(juce_c_audio_file_load(path, &loaded, &rate), JUCE_C_OK, label);
    if (loaded != NULL)
    {
        int frames = juce_c_audio_buffer_get_sample_count(loaded);
        snprintf(label, sizeof(label), "%s: rate, channels, length (%d)", file, frames);
        CHECK(rate == 48000 && juce_c_audio_buffer_get_channel_count(loaded) == 2
              && (lossy ? abs(frames - n) < 2048 : frames == n), label);
        if (!lossy)
        {
            double err = max_error(src, loaded, 1, n);
            snprintf(label, sizeof(label), "%s: samples within %.1g (max err %.2g)", file, tolerance, err);
            CHECK(err <= tolerance, label);
        }
        else
        {
            float rms = 0;
            juce_c_audio_buffer_get_rms_level(loaded, 0, 0, n < frames ? n : frames, &rms);
            snprintf(label, sizeof(label), "%s: lossy signal level preserved (rms %.3f)", file, rms);
            CHECK(fabs(rms - 0.3536) < 0.05, label);
        }
        juce_c_audio_buffer_destroy(loaded);
    }
    remove(path);
    juce_c_audio_buffer_destroy(src);
}

static void buffer_set_sample(juce_c_audio_buffer* b, int channel, int index, float value)
{
    float* p = NULL;
    if (juce_c_audio_buffer_get_write_pointer(b, channel, &p) == JUCE_C_OK && p != NULL)
        p[index] = value;
}

static float buffer_get_sample(juce_c_audio_buffer* b, int channel, int index)
{
    float* p = NULL;
    return juce_c_audio_buffer_get_write_pointer(b, channel, &p) == JUCE_C_OK && p != NULL ? p[index] : -99.0f;
}

/* Appends a RIFF chunk (little-endian length, padded to even). */
static size_t put_chunk(unsigned char* out, size_t at, const char* id, unsigned int declared, const void* body,
                        size_t body_size)
{
    memcpy(out + at, id, 4);
    memcpy(out + at + 4, &declared, 4);
    if (body_size > 0)
        memcpy(out + at + 8, body, body_size);
    at += 8 + body_size;
    if (body_size & 1)
        out[at++] = 0;
    return at;
}

static size_t put_fmt16(unsigned char* out, size_t at)
{
    unsigned char fmt[16];
    const unsigned short tag = 1, ch = 1, align = 2, bits = 16;
    const unsigned int rate = 48000, bps = 96000;
    memcpy(fmt, &tag, 2); memcpy(fmt + 2, &ch, 2); memcpy(fmt + 4, &rate, 4);
    memcpy(fmt + 8, &bps, 4); memcpy(fmt + 12, &align, 2); memcpy(fmt + 14, &bits, 2);
    return put_chunk(out, at, "fmt ", 16, fmt, 16);
}

static int write_file(const char* path, const unsigned char* data, size_t size)
{
    FILE* f = fopen(path, "wb");
    if (f == NULL)
        return 0;
    const size_t written = fwrite(data, 1, size, f);
    fclose(f);
    return written == size;
}

/* Round-2 review findings: reads past the end, writer limits, metadata chunks,
   lying length headers. */
static void test_audio_file_round2(void)
{
    char path[1024];
    temp_path(path, sizeof(path), "r2.wav");

    /* writer limits */
    juce_c_audio_file_writer* writer = NULL;
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 48000, 256, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "256-channel writer refused");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 1.0e-300, 1, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "sub-1 Hz writer rate refused");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 3.0e9, 1, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "writer rate above 10 MHz refused");
    juce_c_audio_buffer* wide = NULL;
    juce_c_audio_buffer_create(255, 4, &wide);
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 48000, 255, 16, 0, &writer), JUCE_C_OK,
                 "255-channel writer allowed");
    CHECK_RESULT(juce_c_audio_file_writer_write_buffer(writer, wide, 0, 4), JUCE_C_OK, "255-channel write");
    juce_c_audio_file_writer_destroy(writer);
    writer = NULL;
    juce_c_audio_buffer_destroy(wide);

    /* reads past the end return zeros */
    juce_c_audio_buffer* ten = NULL;
    juce_c_audio_buffer_create(1, 10, &ten);
    for (int i = 0; i < 10; ++i)
        buffer_set_sample(ten, 0, i, 0.5f);
    juce_c_audio_file_writer_create(path, "wav", 48000, 1, 16, 0, &writer);
    juce_c_audio_file_writer_write_buffer(writer, ten, 0, 10);
    juce_c_audio_file_writer_destroy(writer);
    juce_c_audio_buffer_destroy(ten);

    juce_c_audio_file_reader* reader = NULL;
    CHECK_RESULT(juce_c_audio_file_reader_open(path, &reader), JUCE_C_OK, "open 10-frame file");
    const int64_t length = juce_c_audio_file_reader_get_length(reader);
    CHECK(length == 10, "length 10");
    juce_c_audio_buffer* dest = NULL;
    juce_c_audio_buffer_create(1, 16, &dest);
    for (int i = 0; i < 16; ++i)
        buffer_set_sample(dest, 0, i, 9.0f);
    CHECK_RESULT(juce_c_audio_file_reader_read(reader, dest, 0, 16, length + 1000), JUCE_C_OK,
                 "read far past the end returns zeros");
    int zeros = 1;
    for (int i = 0; i < 16; ++i)
        zeros = zeros && buffer_get_sample(dest, 0, i) == 0.0f;
    CHECK(zeros, "frames past the end read as 0");
    CHECK_RESULT(juce_c_audio_file_reader_read(reader, dest, 0, 16, 6), JUCE_C_OK, "read straddling the end");
    CHECK(approx(buffer_get_sample(dest, 0, 3), 0.5, 1.0e-3) && buffer_get_sample(dest, 0, 4) == 0.0f
              && buffer_get_sample(dest, 0, 15) == 0.0f,
          "4 real frames, then zeros");
    CHECK_RESULT(juce_c_audio_file_reader_read(reader, dest, 0, 16, INT64_MAX), JUCE_C_OK, "read at INT64_MAX");
    juce_c_audio_file_reader_destroy(reader);
    reader = NULL;

    /* re-framing: metadata never reaches JUCE, audio still does */
    {
        unsigned char wav[512];
        const short samples[4] = { 16384, -16384, 8192, 0 };
        const char ixml[] = "<a b=\"x\xF4"; /* truncated UTF-8: JUCE's XmlDocument over-reads */
        size_t n = 12;
        n = put_chunk(wav, n, "iXML", (unsigned int) strlen(ixml), ixml, strlen(ixml));
        n = put_chunk(wav, n, "data", sizeof(samples), samples, sizeof(samples)); /* data before fmt */
        n = put_fmt16(wav, n);
        n = put_chunk(wav, n, "LIST", 0xFFFFFFF0u, "adtl", 4); /* runs past EOF, after everything needed */
        const unsigned int riff = (unsigned int) n - 8;
        memcpy(wav, "RIFF", 4); memcpy(wav + 4, &riff, 4); memcpy(wav + 8, "WAVE", 4);
        CHECK(write_file(path, wav, n), "write metadata WAV");
        CHECK_RESULT(juce_c_audio_file_reader_open(path, &reader), JUCE_C_OK, "WAV with iXML, late fmt and a bad trailing LIST opens");
        CHECK(juce_c_audio_file_reader_get_length(reader) == 4 && juce_c_audio_file_reader_get_channel_count(reader) == 1,
              "length and channels from the real chunks");
        CHECK_RESULT(juce_c_audio_file_reader_read(reader, dest, 0, 4, 0), JUCE_C_OK, "read re-framed audio");
        CHECK(approx(buffer_get_sample(dest, 0, 0), 0.5, 1.0e-3)
                  && approx(buffer_get_sample(dest, 0, 1), -0.5, 1.0e-3)
                  && approx(buffer_get_sample(dest, 0, 2), 0.25, 1.0e-3),
              "samples come from the data chunk");
        juce_c_audio_file_reader_destroy(reader);
        reader = NULL;

        /* a chunk before fmt/data that claims more than the file holds */
        n = 12;
        n = put_chunk(wav, n, "smpl", 0xFFFFFFFFu, "abcd", 4);
        n = put_fmt16(wav, n);
        n = put_chunk(wav, n, "data", sizeof(samples), samples, sizeof(samples));
        CHECK(write_file(path, wav, n), "write smpl WAV");
        CHECK_RESULT(juce_c_audio_file_reader_open(path, &reader), JUCE_C_JUCE_ERROR,
                     "chunk running past the end of the file rejected (was a 4 GB calloc)");
        CHECK(strstr(juce_c_get_last_error_message(), "past the end") != NULL, "error explains why");

        /* a cut-short recording: data length clamped to the file */
        n = 12;
        n = put_fmt16(wav, n);
        n = put_chunk(wav, n, "data", 0x7FFFFFF0u, samples, sizeof(samples));
        CHECK(write_file(path, wav, n), "write truncated WAV");
        CHECK_RESULT(juce_c_audio_file_reader_open(path, &reader), JUCE_C_OK, "truncated recording opens");
        CHECK(juce_c_audio_file_reader_get_length(reader) == 4, "length clamped to the bytes present");
        juce_c_audio_file_reader_destroy(reader);
        reader = NULL;

        /* no fmt at all */
        n = 12;
        n = put_chunk(wav, n, "data", sizeof(samples), samples, sizeof(samples));
        CHECK(write_file(path, wav, n), "write fmt-less WAV");
        CHECK_RESULT(juce_c_audio_file_reader_open(path, &reader), JUCE_C_JUCE_ERROR, "WAV without fmt rejected");
    }

#ifdef PASCALJUCE_TEST_DATA
    {
        const char* corpus[] = { "meta_adtl_hang", "meta_ixml_2", "meta_ixml_14", "meta_axml_2",
                                 "meta_smpl_4g", "meta_aiff_mark", "meta_two_fmt" };
        for (size_t i = 0; i < sizeof(corpus) / sizeof(corpus[0]); ++i)
        {
            /* Corpus files are fuzz inputs: byte 0 picks the extension, the rest is the file. */
            char file[1024], label[256], copy[1024];
            static const char* const exts[] = { "r2.wav", "r2.aiff", "r2.flac", "r2.ogg" };
            snprintf(file, sizeof(file), "%s/fuzz_file/%s.bin", PASCALJUCE_TEST_DATA, corpus[i]);
            unsigned char bytes[4096];
            size_t got = 0;
            FILE* in = fopen(file, "rb");
            if (in != NULL)
            {
                got = fread(bytes, 1, sizeof(bytes), in);
                fclose(in);
            }
            CHECK(got > 1, corpus[i]);
            if (got <= 1)
                continue;
            temp_path(copy, sizeof(copy), exts[bytes[0] % 4]);
            write_file(copy, bytes + 1, got - 1);
            juce_c_audio_buffer* loaded = NULL;
            const juce_c_result r = juce_c_audio_file_load(copy, &loaded, NULL);
            if (r != JUCE_C_OK)
                printf("      %s: %s\n", corpus[i], juce_c_get_last_error_message());
            remove(copy);
            snprintf(label, sizeof(label), "%s: load returns (result %d) without hanging or overflowing", corpus[i], (int) r);
            CHECK(r == JUCE_C_OK || r == JUCE_C_JUCE_ERROR, label);
            juce_c_audio_buffer_destroy(loaded);
        }

        juce_c_audio_buffer* huge = NULL;
        CHECK_RESULT(juce_c_audio_file_load(PASCALJUCE_TEST_DATA "/hostile_huge_header.flac", &huge, NULL),
                     JUCE_C_OUT_OF_RANGE, "42-byte FLAC claiming 2^30 frames is not loaded (was 4 GB)");
        CHECK(huge == NULL, "no buffer for the lying FLAC");
    }
#endif

    juce_c_audio_buffer_destroy(dest);
    remove(path);
}

#ifdef _WIN32
/* Review round 3: the file was checked through one handle, then reopened by path
   for JUCE; a file rewritten in between reached JUCE's unprotected WAV chunk
   parsers. A writer thread flips the file between "not audio" and a hostile
   WAV (iXML with truncated UTF-8 = heap over-read under ASan) while we open it. */
static unsigned char race_a[128], race_b[128];
static size_t race_size;
static char race_path[1024];
static volatile LONG race_stop;

static DWORD WINAPI race_writer(void* arg)
{
    (void) arg;
    HANDLE h = CreateFileA(race_path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return 1;
    for (unsigned i = 0; ! race_stop; ++i)
    {
        DWORD written;
        SetFilePointer(h, 0, NULL, FILE_BEGIN);
        WriteFile(h, (i & 1) ? race_b : race_a, (DWORD) race_size, &written, NULL);
    }
    CloseHandle(h);
    return 0;
}

static void test_audio_file_reopen_race(void)
{
    const unsigned char fmt[16] = { 1, 0, 1, 0, 0x44, 0xAC, 0, 0, 0x88, 0x58, 1, 0, 2, 0, 16, 0 };
    const char ixml[] = "<a b=\"x\xF4";
    size_t n = 12;
    n = put_chunk(race_b, n, "iXML", (unsigned int) strlen(ixml), ixml, strlen(ixml));
    n = put_chunk(race_b, n, "fmt ", 16, fmt, 16);
    n = put_chunk(race_b, n, "JUNK", 0x7FFFFFF0u, "abcd", 4);
    const unsigned int riff = (unsigned int) n - 8;
    memcpy(race_b, "RIFF", 4); memcpy(race_b + 4, &riff, 4); memcpy(race_b + 8, "WAVE", 4);
    race_size = n;
    memset(race_a, 'X', sizeof(race_a));
    temp_path(race_path, sizeof(race_path), "race.wav");
    write_file(race_path, race_b, race_size);

    race_stop = 0;
    HANDLE thread = CreateThread(NULL, 0, race_writer, NULL, 0, NULL);
    int opened = 0;
    for (int i = 0; i < 3000; ++i)
    {
        juce_c_audio_file_reader* reader = NULL;
        if (juce_c_audio_file_reader_open(race_path, &reader) == JUCE_C_OK)
        {
            ++opened;
            juce_c_audio_file_reader_destroy(reader);
        }
    }
    race_stop = 1;
    if (thread != NULL)
    {
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
    }
    char label[160];
    snprintf(label, sizeof(label), "file rewritten while opening never reaches JUCE's WAV parser (%d bogus opens)", opened);
    CHECK(thread != NULL && opened == 0, label);
    remove(race_path);
}
#endif

#ifdef PASCALJUCE_PRIVATE_TESTS
#include "private/c_api.inc"
#endif

/* MIDI and WAV format limits. */
static void test_format_limits(void)
{
    suite("MIDI and WAV format limits");

    /* SysEx size limit: 65529 bytes. */
    {
        const size_t sizes[] = { 65529, 70000 };
        for (size_t k = 0; k < 2; ++k)
        {
            uint8_t* sysex = (uint8_t*) malloc(sizes[k]);
            memset(sysex, 0x11, sizes[k]);
            sysex[0] = 0xF0;
            sysex[sizes[k] - 1] = 0xF7;
            juce_c_midi_buffer* mb = NULL;
            juce_c_midi_buffer_create(&mb);
            const juce_c_result r = juce_c_midi_buffer_add_event(mb, sysex, sizes[k], 0);
            CHECK(sizes[k] == 65529 ? r == JUCE_C_OK : r == JUCE_C_INVALID_ARGUMENT,
                  sizes[k] == 65529 ? "65529-byte SysEx accepted" : "70000-byte SysEx refused");
            juce_c_midi_buffer_destroy(mb);
            free(sysex);
        }
    }

    char path[1024];
    juce_c_audio_file_reader* reader = NULL;
    juce_c_audio_buffer* dest = NULL;
    juce_c_audio_buffer_create(8, 4096, &dest);

    /* WAV fmt with bits > 64, rate -1 and bytes/sec INT_MIN. */
    {
        unsigned char wav[128];
        unsigned char fmt[16] = { 1, 0, 1, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x80, 2, 0, 65, 0 };
        const short samples[4] = { 1, 2, 3, 4 };
        size_t n = 12;
        n = put_chunk(wav, n, "fmt ", 16, fmt, 16);
        n = put_chunk(wav, n, "data", sizeof(samples), samples, sizeof(samples));
        const unsigned int riff = (unsigned int) n - 8;
        memcpy(wav, "RIFF", 4); memcpy(wav + 4, &riff, 4); memcpy(wav + 8, "WAVE", 4);
        temp_path(path, sizeof(path), "fable_div.wav");
        write_file(path, wav, n);
        CHECK_RESULT(juce_c_audio_file_reader_open(path, &reader), JUCE_C_JUCE_ERROR,
                     "impossible WAV fmt (bits > 64, rate -1) is rejected");
        remove(path);
    }

    juce_c_audio_buffer_destroy(dest);
}

static void test_audio_files(void)
{
    suite("Audio files");
    char text[1024];
    size_t size = sizeof(text);
    CHECK_RESULT(juce_c_audio_file_get_wildcard(text, &size), JUCE_C_OK, "wildcard");
    CHECK(strstr(text, "*.wav") && strstr(text, "*.flac") && strstr(text, "*.ogg") && strstr(text, "*.aiff"),
          "wildcard lists wav, aiff, flac, ogg");

    roundtrip("pcm16.wav", "wav", 16, 1.0 / 16000, 0);
    roundtrip("pcm24.wav", "", 24, 1.0e-6, 0);
    roundtrip("float32.wav", "wav", 32, 0, 0);
    roundtrip("pcm24.aif", "", 24, 1.0e-6, 0);          /* .aif -> AIFF from extension */
    roundtrip("pcm16.aiff", "aiff", 16, 1.0 / 16000, 0);
    roundtrip("pcm24.flac", "flac", 24, 1.0e-6, 0);
    roundtrip("vorbis.ogg", "ogg", 16, 0, 1);

    char path[1024];
    juce_c_audio_file_writer* writer = NULL;
    temp_path(path, sizeof(path), "x.wav");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "mp3", 48000, 2, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "unwritable format rejected");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 48000, 2, 12, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "unsupported bit depth rejected");
    CHECK(strstr(juce_c_get_last_error_message(), "12-bit") != NULL, "error names the bit depth");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 0, 2, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT, "rate 0 rejected");
    CHECK_RESULT(juce_c_audio_file_writer_create(NULL, "wav", 48000, 2, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT, "NULL path rejected");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 48000, 0, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT, "0 channels rejected");
    CHECK(writer == NULL, "writer handle cleared on failure");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", 48000, 257, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "more than 256 channels rejected");
    CHECK_RESULT(juce_c_audio_file_writer_create(path, "wav", NAN, 2, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT, "NaN rate rejected");

    /* Regression: a rejected configuration must not destroy an existing file. */
    char keep[1024];
    temp_path(keep, sizeof(keep), "keep.flac");
    FILE* kf = fopen(keep, "wb");
    if (kf != NULL)
    {
        fputs("precious", kf);
        fclose(kf);
    }
    CHECK_RESULT(juce_c_audio_file_writer_create(keep, "", 1234567, 2, 16, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "writer rejects an unsupported sample rate");
    kf = fopen(keep, "rb");
    char kept[16] = { 0 };
    if (kf != NULL)
    {
        fread(kept, 1, sizeof(kept) - 1, kf);
        fclose(kf);
    }
    CHECK(strcmp(kept, "precious") == 0, "existing file untouched after rejected settings");
    remove(keep);

    /* Regression: wide sources and NULL channel pointers must not overrun anything. */
    juce_c_audio_buffer* wide = NULL;
    juce_c_audio_buffer_create(300, 64, &wide);
    juce_c_audio_file_writer_create(path, "wav", 48000, 2, 24, 0, &writer);
    CHECK_RESULT(juce_c_audio_file_writer_write_buffer(writer, wide, 5, 50), JUCE_C_OK,
                 "300-channel source at an offset writes the file's 2 channels");
    const float* wide_ptrs[300];
    for (int ch = 0; ch < 300; ++ch)
        juce_c_audio_buffer_get_read_pointer(wide, ch, &wide_ptrs[ch]);
    CHECK_RESULT(juce_c_audio_file_writer_write_channels(writer, wide_ptrs, 300, 10), JUCE_C_OK, "extra channel pointers ignored");
    const float* holes[2] = { wide_ptrs[0], NULL };
    CHECK_RESULT(juce_c_audio_file_writer_write_channels(writer, holes, 2, 10), JUCE_C_INVALID_ARGUMENT, "NULL channel pointer rejected");
    CHECK_RESULT(juce_c_audio_file_writer_write_channels(writer, wide_ptrs, 2, -1), JUCE_C_INVALID_ARGUMENT, "negative count rejected");
    juce_c_audio_file_writer_destroy(writer);
    juce_c_audio_buffer_destroy(wide);

    char flac[1024];
    temp_path(flac, sizeof(flac), "flush.flac");
    juce_c_audio_file_writer_create(flac, NULL, 48000, 1, 16, 0, &writer);
    CHECK_RESULT(juce_c_audio_file_writer_flush(writer), JUCE_C_OK, "flush on FLAC is a no-op returning OK");
    juce_c_audio_file_writer_destroy(writer);
    remove(flac);
    CHECK_RESULT(juce_c_audio_file_writer_create(flac, "flac", 48000, 1, 32, 0, &writer), JUCE_C_INVALID_ARGUMENT,
                 "FLAC 32-bit rejected");

    /* overwrite + write_channels + channel-count checks */
    juce_c_audio_buffer* longer = make_sine(2, 1000);
    juce_c_audio_buffer* mono = make_sine(1, 10);
    juce_c_audio_file_writer_create(path, "wav", 48000, 2, 16, 0, &writer);
    juce_c_audio_file_writer_write_buffer(writer, longer, 0, 1000);
    juce_c_audio_file_writer_destroy(writer);
    juce_c_audio_file_writer_create(path, "wav", 48000, 2, 16, 0, &writer);
    CHECK_RESULT(juce_c_audio_file_writer_write_buffer(writer, mono, 0, 10), JUCE_C_INVALID_ARGUMENT,
                 "source with fewer channels than the file rejected");
    CHECK_RESULT(juce_c_audio_file_writer_write_buffer(writer, longer, 900, 200), JUCE_C_OUT_OF_RANGE, "source range past end rejected");
    const float* ptrs[2];
    juce_c_audio_buffer_get_read_pointer(longer, 0, &ptrs[0]);
    juce_c_audio_buffer_get_read_pointer(longer, 1, &ptrs[1]);
    CHECK_RESULT(juce_c_audio_file_writer_write_channels(writer, ptrs, 2, 100), JUCE_C_OK, "write_channels");
    CHECK_RESULT(juce_c_audio_file_writer_write_channels(writer, ptrs, 1, 100), JUCE_C_INVALID_ARGUMENT, "too few channels rejected");
    CHECK_RESULT(juce_c_audio_file_writer_flush(writer), JUCE_C_OK, "flush");
    juce_c_audio_file_writer_destroy(writer);

    juce_c_audio_file_reader* reader = NULL;
    CHECK_RESULT(juce_c_audio_file_reader_open(path, &reader), JUCE_C_OK, "open reader");
    CHECK(juce_c_audio_file_reader_get_length(reader) == 100, "overwritten file has only the new data");
    CHECK(juce_c_audio_file_reader_get_channel_count(reader) == 2 && juce_c_audio_file_reader_get_bits_per_sample(reader) == 16
          && !juce_c_audio_file_reader_is_floating_point(reader) && juce_c_audio_file_reader_get_sample_rate(reader) == 48000,
          "reader info");
    size = sizeof(text);
    juce_c_audio_file_reader_get_format_name(reader, text, &size);
    CHECK(strcmp(text, "WAV file") == 0, "format name");

    /* read past end -> silence; read at offset; mono file into stereo tested in Pascal suite */
    juce_c_audio_buffer* dest = NULL;
    juce_c_audio_buffer_create(2, 64, &dest);
    float* d0 = NULL;
    juce_c_audio_buffer_get_write_pointer(dest, 0, &d0);
    for (int i = 0; i < 64; ++i)
        d0[i] = 9.0f;
    CHECK_RESULT(juce_c_audio_file_reader_read(reader, dest, 0, 64, 80), JUCE_C_OK, "read across end of file");
    CHECK(d0[0] != 9.0f && d0[63] == 0.0f, "frames past the end read as silence");
    CHECK_RESULT(juce_c_audio_file_reader_read(reader, dest, 60, 8, 0), JUCE_C_OUT_OF_RANGE, "destination overflow rejected");
    CHECK_RESULT(juce_c_audio_file_reader_read(reader, dest, 0, 8, -1), JUCE_C_INVALID_ARGUMENT, "negative file position rejected");
    juce_c_audio_file_reader_destroy(reader);
    juce_c_audio_file_reader_destroy(NULL);
    CHECK(juce_c_audio_file_reader_get_length(NULL) == 0, "NULL reader: length 0");

    /* relative paths resolve against the current directory */
    char cwd[1024], dir[1024];
    if (getcwd(cwd, sizeof(cwd)) != NULL)
    {
        temp_path(dir, sizeof(dir), "");
        char* slash = strrchr(dir, '/');
        if (slash != NULL)
            *slash = '\0';
        if (chdir(dir) == 0)
        {
            CHECK_RESULT(juce_c_audio_file_reader_open("juce_c_test_x.wav", &reader), JUCE_C_OK, "relative path opens");
            juce_c_audio_file_reader_destroy(reader);
            chdir(cwd);
        }
    }

    /* Regression: WAV headers describing impossible formats are rejected at
       open. First the file the fuzzer found. */
#ifdef PASCALJUCE_TEST_DATA
    CHECK_RESULT(juce_c_audio_file_reader_open(PASCALJUCE_TEST_DATA "/hostile_wav_frame_overflow.wav", &reader),
                 JUCE_C_JUCE_ERROR, "fuzzer-found hostile WAV (32770 ch, 25600 bits) rejected");
    CHECK(strstr(juce_c_get_last_error_message(), "Malformed") != NULL, "error says Malformed");
#endif
    {
        /* channels, bits field, bytes/sec: frame-size attacks within and beyond 256 channels */
        const struct { int channels, bits, bytes_per_sec; const char* what; } hostile[] = {
            { 200, 100, 6000 * 48000, "200 ch, >64-bit field, 6000-byte frames rejected" },
            { 2, 12, 48000 * 3, "2 ch, 12-bit PCM rejected" },
            { 0, 16, 0, "0 channels rejected" },
            { 300, 16, 600 * 48000, "300 channels rejected" },
        };
        for (size_t k = 0; k < sizeof(hostile) / sizeof(hostile[0]); ++k)
        {
            char hostile_path[1024];
            temp_path(hostile_path, sizeof(hostile_path), "hostile.wav");
            FILE* hf = fopen(hostile_path, "wb");
            if (hf == NULL)
                continue;
            unsigned char h[44 + 64];
            memset(h, 0, sizeof(h));
            const unsigned int data_len = 64, riff_len = 36 + data_len;
            const unsigned short ch = (unsigned short) hostile[k].channels, bits = (unsigned short) hostile[k].bits;
            const unsigned int rate = 48000, bps = (unsigned int) hostile[k].bytes_per_sec, fmt_len = 16;
            memcpy(h, "RIFF", 4); memcpy(h + 4, &riff_len, 4); memcpy(h + 8, "WAVEfmt ", 8);
            memcpy(h + 16, &fmt_len, 4); h[20] = 1; memcpy(h + 22, &ch, 2); memcpy(h + 24, &rate, 4);
            memcpy(h + 28, &bps, 4); memcpy(h + 34, &bits, 2); memcpy(h + 36, "data", 4); memcpy(h + 40, &data_len, 4);
            fwrite(h, 1, sizeof(h), hf);
            fclose(hf);
            juce_c_audio_file_reader* hr = NULL;
            const juce_c_result r = juce_c_audio_file_reader_open(hostile_path, &hr);
            CHECK(r != JUCE_C_OK && hr == NULL, hostile[k].what);
            juce_c_audio_file_reader_destroy(hr);
            remove(hostile_path);
        }
    }

    /* Regression: a tiny WAV claiming ~1 billion frames loads as what it holds,
       instead of allocating gigabytes. */
    {
        char tiny_path[1024];
        temp_path(tiny_path, sizeof(tiny_path), "tiny_liar.wav");
        FILE* tf = fopen(tiny_path, "wb");
        if (tf != NULL)
        {
            unsigned char h[44 + 32];
            memset(h, 0, sizeof(h));
            const unsigned int riff_len = 0xFFFFFFF0u, data_len = 0xFFFFFFF0u, fmt_len = 16, rate = 48000, bps = 48000 * 2;
            const unsigned short ch = 1, bits = 16, align = 2;
            memcpy(h, "RIFF", 4); memcpy(h + 4, &riff_len, 4); memcpy(h + 8, "WAVEfmt ", 8);
            memcpy(h + 16, &fmt_len, 4); h[20] = 1; memcpy(h + 22, &ch, 2); memcpy(h + 24, &rate, 4);
            memcpy(h + 28, &bps, 4); memcpy(h + 32, &align, 2); memcpy(h + 34, &bits, 2);
            memcpy(h + 36, "data", 4); memcpy(h + 40, &data_len, 4);
            fwrite(h, 1, sizeof(h), tf);
            fclose(tf);
            juce_c_audio_buffer* liar = NULL;
            const juce_c_result lr = juce_c_audio_file_load(tiny_path, &liar, NULL);
            CHECK(lr != JUCE_C_OK || juce_c_audio_buffer_get_sample_count(liar) <= 64,
                  "76-byte WAV claiming 2^31 frames does not allocate gigabytes");
            juce_c_audio_buffer_destroy(liar);
            remove(tiny_path);
        }
    }

    test_audio_file_round2();
    test_format_limits();
#ifdef PASCALJUCE_PRIVATE_TESTS
    test_private();
#endif
#ifdef _WIN32
    test_audio_file_reopen_race();
#endif

    /* errors */
    char missing[1024];
    temp_path(missing, sizeof(missing), "missing.wav");
    CHECK_RESULT(juce_c_audio_file_reader_open(missing, &reader), JUCE_C_INVALID_ARGUMENT, "missing file");
    CHECK(strstr(juce_c_get_last_error_message(), "File not found") != NULL, "error says File not found");
    CHECK(reader == NULL, "reader handle cleared on failure");

    char junk[1024];
    temp_path(junk, sizeof(junk), "junk.wav");
    FILE* f = fopen(junk, "wb");
    if (f != NULL)
    {
        fputs("this is not audio", f);
        fclose(f);
    }
    CHECK_RESULT(juce_c_audio_file_reader_open(junk, &reader), JUCE_C_JUCE_ERROR, "non-audio file rejected");
    CHECK_RESULT(juce_c_audio_file_reader_open("", &reader), JUCE_C_INVALID_ARGUMENT, "empty path rejected");
    juce_c_audio_buffer* none = NULL;
    CHECK_RESULT(juce_c_audio_file_load(missing, &none, NULL), JUCE_C_INVALID_ARGUMENT, "load missing file");
    CHECK(none == NULL, "load leaves handle NULL on failure");

    remove(junk);
    remove(path);
    juce_c_audio_buffer_destroy(dest);
    juce_c_audio_buffer_destroy(longer);
    juce_c_audio_buffer_destroy(mono);
}

#ifdef _WIN32
static volatile juce_c_result g_timer_shutdown;
static void CALLBACK timer_shutdown_proc(HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
    (void) hwnd; (void) msg; (void) time;
    KillTimer(NULL, id);
    if (g_timer_shutdown == -100)
        g_timer_shutdown = juce_c_shutdown();
}
#endif

/* ------------------------------------------------------------------------ */
int main(void)
{
    test_library_before_init();
    test_strings();
    test_init_refcount();
    test_audio_buffers();
    test_midi_buffers();
    test_device_manager_closed();
    test_virtual_device();
    test_reentrancy();
    test_nested_managers();
    test_destroy_reentry();
    test_device_manager_hardware();
    test_midi_devices();
    test_audio_files();

    CHECK_RESULT(juce_c_shutdown(), JUCE_C_OK, "shutdown (count 2 -> 1)");
    CHECK(juce_c_is_initialised(), "still initialised");
#ifdef _WIN32
    /* Fable round 4: the last shutdown from a timer pumped by dispatch_messages
       deleted the message loop under itself (use-after-free). */
    g_timer_shutdown = -100;
    {
        const UINT_PTR timer = SetTimer(NULL, 0, 1, timer_shutdown_proc);
        juce_c_dispatch_messages(100);
        KillTimer(NULL, timer);
    }
    CHECK(g_timer_shutdown == JUCE_C_INVALID_STATE, "last shutdown inside dispatch_messages (from a timer) refused");
    CHECK(juce_c_is_initialised(), "still initialised after the refused shutdown");
#endif
    CHECK_RESULT(juce_c_shutdown(), JUCE_C_OK, "last shutdown");
    CHECK(!juce_c_is_initialised(), "fully shut down after balanced shutdowns");
    CHECK_RESULT(juce_c_shutdown(), JUCE_C_OK, "extra shutdown is a harmless no-op");

    printf("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped);
    return failed == 0 ? 0 : 1;
}
