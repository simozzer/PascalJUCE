#include "juce_c_audio.h"
#include "juce_c_virtual_device.h"
#include "pascaljuce_riff.h"
#include "pascaljuce_utf8.h"

#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_audio_devices/juce_audio_devices.h>
#include <juce_audio_formats/juce_audio_formats.h>
#include <juce_events/juce_events.h>

#if defined(_WIN32)
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #ifndef WIN32_LEAN_AND_MEAN
        #define WIN32_LEAN_AND_MEAN
    #endif
    #include <windows.h>
#endif

#if JUCE_INTEL
    #include <xmmintrin.h>
    #include <float.h>
#endif

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>
#include <mutex>
#include <new>
#include <stdexcept>
#include <utility>

//==============================================================================
namespace
{
//------------------------------------------------------------------------------
// Errors

thread_local char last_error_message[512] = {};

// Copies at most capacity-1 bytes without splitting a UTF-8 sequence.
size_t utf8_prefix_length(const char* text, size_t length, size_t capacity) noexcept
{
    if (capacity == 0)
        return 0;
    size_t n = std::min(length, capacity - 1);
    if (n < length)
        while (n > 0 && (static_cast<unsigned char>(text[n]) & 0xC0) == 0x80)
            --n; // text[n] is a continuation byte: back off to the lead byte
    return n;
}

void copy_utf8(char* destination, size_t capacity, const char* text) noexcept
{
    if (capacity == 0)
        return;
    const size_t n = utf8_prefix_length(text, std::strlen(text), capacity);
    std::memcpy(destination, text, n);
    destination[n] = '\0';
}

void set_last_error(const char* message) noexcept
{
    copy_utf8(last_error_message, sizeof(last_error_message), message != nullptr ? message : "Unknown error");
}

juce_c_result fail(juce_c_result result, const char* message) noexcept
{
    set_last_error(message);
    return result;
}

juce_c_result fail(juce_c_result result, const juce::String& message) noexcept
{
    set_last_error(message.toRawUTF8());
    return result;
}

juce_c_result ok() noexcept
{
    last_error_message[0] = '\0';
    return JUCE_C_OK;
}

//------------------------------------------------------------------------------
// Floating point: callers (Delphi in particular) may run with FP exceptions
// unmasked; JUCE and drivers assume they are masked.

struct ScopedFpMask
{
#if JUCE_INTEL
    ScopedFpMask() noexcept : saved(_mm_getcsr())
    {
        _mm_setcsr(saved | 0x1F80u);
       #if defined(_M_IX86)
        _controlfp_s(&saved87, 0, 0); // 32-bit x86: the x87 unit has its own exception mask
        unsigned int ignored;
        _controlfp_s(&ignored, _MCW_EM, _MCW_EM);
       #endif
    }
    ~ScopedFpMask() noexcept
    {
       #if defined(_M_IX86)
        unsigned int ignored;
        _controlfp_s(&ignored, saved87, _MCW_EM);
       #endif
        _mm_setcsr(saved);
    }
    unsigned int saved;
   #if defined(_M_IX86)
    unsigned int saved87 = 0;
   #endif
#endif
};

// Thrown by from_utf8 / from_fixed_utf8; guard() turns it into JUCE_C_INVALID_ARGUMENT.
// Malformed UTF-8 must never reach juce::String (see pascaljuce_utf8.h).
struct invalid_text : std::exception
{
    const char* what() const noexcept override { return "Text argument is not valid UTF-8"; }
};

// Runs a body returning juce_c_result with FP exceptions masked, translating
// C++ exceptions into result codes.
template <typename Function>
juce_c_result guard(Function&& function) noexcept
{
    ScopedFpMask fpMask;
    try
    {
        return std::forward<Function>(function)();
    }
    catch (const invalid_text& e)
    {
        return fail(JUCE_C_INVALID_ARGUMENT, e.what());
    }
    catch (const std::bad_alloc&)
    {
        return fail(JUCE_C_OUT_OF_MEMORY, "Memory allocation failed");
    }
    catch (const std::exception& exception)
    {
        return fail(JUCE_C_JUCE_ERROR, exception.what());
    }
    catch (...)
    {
        return fail(JUCE_C_JUCE_ERROR, "Unknown C++ exception");
    }
}

// Same, for functions returning plain values.
template <typename T, typename Function>
T guard_value(T fallback, Function&& function) noexcept
{
    ScopedFpMask fpMask;
    try
    {
        return std::forward<Function>(function)();
    }
    catch (...)
    {
        return fallback;
    }
}

//------------------------------------------------------------------------------
// Strings

juce_c_result write_string(const juce::String& text, char* buffer, size_t* buffer_size) noexcept
{
    if (buffer_size == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer_size must not be null");

    const char* utf8 = text.toRawUTF8();
    const size_t length = std::strlen(utf8);
    const size_t required = length + 1;
    const size_t capacity = *buffer_size;
    *buffer_size = required;

    if (buffer == nullptr)
    {
        last_error_message[0] = '\0'; // a size query is not an error
        return JUCE_C_BUFFER_TOO_SMALL;
    }

    if (capacity < required)
    {
        if (capacity > 0)
        {
            const size_t n = utf8_prefix_length(utf8, length, capacity);
            std::memcpy(buffer, utf8, n);
            buffer[n] = '\0';
        }
        return fail(JUCE_C_BUFFER_TOO_SMALL, "Destination buffer is too small");
    }

    std::memcpy(buffer, utf8, required);
    return ok();
}

juce::String from_utf8(const char* text)
{
    if (text == nullptr)
        return {};
    const size_t length = std::strlen(text);
    if (! pascaljuce::isStrictUtf8(text, length))
        throw invalid_text();
    return juce::String::fromUTF8(text, (int) length);
}

juce::String from_fixed_utf8(const char (&text)[256])
{
    const size_t length = strnlen(text, sizeof(text));
    if (! pascaljuce::isStrictUtf8(text, length))
        throw invalid_text();
    return juce::String::fromUTF8(text, (int) length);
}

//------------------------------------------------------------------------------
// Channel masks (256 channels in 4 x uint64)

void to_mask(const juce::BigInteger& bits, uint64_t (&mask)[4]) noexcept
{
    for (int word = 0; word < 4; ++word)
    {
        mask[word] = 0;
        for (int bit = 0; bit < 64; ++bit)
            if (bits[word * 64 + bit])
                mask[word] |= (uint64_t{1} << bit);
    }
}

juce::BigInteger from_mask(const uint64_t (&mask)[4])
{
    juce::BigInteger bits;
    for (int word = 0; word < 4; ++word)
        for (int bit = 0; bit < 64; ++bit)
            if ((mask[word] & (uint64_t{1} << bit)) != 0)
                bits.setBit(word * 64 + bit);
    return bits;
}

//------------------------------------------------------------------------------
// MIDI validation: exactly one complete message.

constexpr int max_midi_message_bytes = 65529; // one message, SysEx included

bool is_valid_midi(const uint8_t* data, size_t size, juce::String& why)
{
    if (data == nullptr || size == 0)
    {
        why = "MIDI message must not be empty";
        return false;
    }
    if (size > (size_t) max_midi_message_bytes)
    {
        why = "MIDI message is too large (65529 bytes max)";
        return false;
    }

    const uint8_t status = data[0];
    if ((status & 0x80) == 0)
    {
        why = "MIDI message must start with a status byte (running status is not supported)";
        return false;
    }

    if (status == 0xF0)
    {
        if (size < 2 || data[size - 1] != 0xF7)
        {
            why = "SysEx must end with F7";
            return false;
        }
        for (size_t i = 1; i + 1 < size; ++i)
            if ((data[i] & 0x80) != 0)
            {
                why = "SysEx data bytes must be < 0x80";
                return false;
            }
        return true;
    }

    if (status == 0xF7 || status == 0xFF)
    {
        why = "Not a transmittable MIDI message";
        return false;
    }

    const int expected = juce::MidiMessage::getMessageLengthFromFirstByte(status);
    if ((int) size != expected)
    {
        why = "MIDI status " + juce::String::toHexString((int) status).toUpperCase() + " needs "
            + juce::String(expected) + " bytes, got " + juce::String((int) size);
        return false;
    }
    for (size_t i = 1; i < size; ++i)
        if ((data[i] & 0x80) != 0)
        {
            why = "MIDI data bytes must be < 0x80";
            return false;
        }
    return true;
}

juce_c_result make_midi_message(const uint8_t* data, size_t size, double timestamp, juce::MidiMessage& result)
{
    juce::String why;
    if (! is_valid_midi(data, size, why))
        return fail(JUCE_C_INVALID_ARGUMENT, why);
    result = juce::MidiMessage(data, (int) size, timestamp);
    return JUCE_C_OK;
}

//------------------------------------------------------------------------------
// Library state

std::mutex init_mutex;
int init_count = 0;
std::atomic<bool> initialised { false };

// The message thread, recorded by juce_c_initialise and cleared by the final
// juce_c_shutdown. Thread checks compare against this instead of asking JUCE's
// MessageManager, which another thread may be deleting at that moment.
std::atomic<juce::Thread::ThreadID> message_thread_id { nullptr };
#if defined(_WIN32)
HANDLE message_thread_handle = nullptr;
#endif

bool on_message_thread() noexcept
{
    const auto id = message_thread_id.load();
    return id != nullptr && id == juce::Thread::getCurrentThreadId();
}

// > 0 while juce_c_dispatch_messages runs (message thread only). Code it pumps
// (timers, GUI event handlers) must not make the final shutdown: that would
// delete the MessageManager under the running dispatch loop.
int dispatch_depth = 0;
std::atomic<int> live_device_handles { 0 }; // managers + MIDI inputs/outputs

constexpr int midi_storage_bytes = 16384;
constexpr int max_file_channels = 256;
constexpr int max_writer_channels = 255;
constexpr size_t max_midi_buffer_bytes = 256u << 20;     // one MIDI buffer, all events
std::mutex midi_output_mutex; // MIDI output open/destroy, one at a time
constexpr juce::int64 max_compression_ratio = 1024; // samples per file byte, compressed formats
// AudioBuffer limits: a buffer has to fit in memory.
constexpr int max_buffer_channels = 1024;
constexpr int64_t max_buffer_samples = int64_t{1} << 30; // channels x samples, 4 GB of floats
constexpr int max_channel_samples = (1 << 29) - 1; // per channel: what Pascal's TJuceSampleArray can index

bool valid_buffer_size(int channels, int samples) noexcept
{
    return channels > 0 && samples > 0 && channels <= max_buffer_channels && samples <= max_channel_samples
        && (int64_t) channels * samples <= max_buffer_samples;
}

juce_c_result require_message_thread() noexcept
{
    if (! initialised)
        return fail(JUCE_C_NOT_INITIALISED, "Call juce_c_initialise first");
    if (! on_message_thread())
        return fail(JUCE_C_INVALID_STATE, "Must be called on the thread that called juce_c_initialise");
    return JUCE_C_OK;
}

juce_c_result require_initialised() noexcept
{
    return initialised ? JUCE_C_OK : fail(JUCE_C_NOT_INITIALISED, "Call juce_c_initialise first");
}

// For calls into JUCE from any thread that create no handle: hold a live-handle
// reservation for the duration, so a concurrent last juce_c_shutdown refuses.
struct ScopedReservation
{
    ScopedReservation() noexcept { ++live_device_handles; }
    ~ScopedReservation() noexcept { --live_device_handles; }
    bool ok() const noexcept { return initialised.load(); }
};

#define JUCE_C_REQUIRE(expr)               \
    do                                     \
    {                                      \
        const juce_c_result r_ = (expr);   \
        if (r_ != JUCE_C_OK)               \
            return r_;                     \
    } while (false)
} // namespace

//==============================================================================
// Opaque types
//==============================================================================
struct juce_c_audio_buffer
{
    juce::AudioBuffer<float> value;

    juce_c_audio_buffer(int channels, int samples) : value(channels, samples)
    {
        value.clear();
        value.setNotClear(); // see clear_buffer()
    }
};

namespace
{
/* JUCE's AudioBuffer keeps an "is clear" flag that lets later operations skip
   work. Callers of this API write through cached raw pointers, which JUCE
   cannot see, so the flag would make gain/RMS/copy silently do nothing.
   Always zero the memory and leave the flag false. */
void clear_buffer(juce::AudioBuffer<float>& buffer) noexcept
{
    buffer.clear();
    buffer.setNotClear();
}

bool valid_range(const juce::AudioBuffer<float>& buffer, int start, int count) noexcept
{
    return start >= 0 && count >= 0 && start <= buffer.getNumSamples() && count <= buffer.getNumSamples() - start;
}
}

struct juce_c_midi_buffer
{
    juce::MidiBuffer value;
    int iterating = 0; // > 0 while for_each runs: mutation would invalidate the live iterator
    bool borrowed = false; // owned by a device manager (the block passed to on_audio): never deleted by callers
};

namespace
{
// The manager whose device callback this thread is inside, if any. While a
// callback runs, JUCE cannot close or reconfigure that manager's device (it
// stops callbacks first), so that one device may be read there. Nothing else
// is safe from a callback: MIDI enablement, device-type and device lists change
// on the message thread while the device keeps running, and another manager's
// device can be closed at any moment.
thread_local const void* callback_owner = nullptr;

// Mutating manager calls in progress on this thread (see ManagerBusyScope).
thread_local int mutating_calls = 0;

// Marks a manager busy (its counter) for a scope. Message thread only.
struct BusyScope
{
    explicit BusyScope(int* counterToUse) noexcept : counter(counterToUse)
    {
        if (counter != nullptr)
            ++*counter;
        ++mutating_calls;
    }
    ~BusyScope() noexcept
    {
        if (counter != nullptr)
            --*counter;
        --mutating_calls;
    }
    BusyScope(const BusyScope&) = delete;
    BusyScope& operator=(const BusyScope&) = delete;
    int* counter;
};

// Device start/stop and change notifications that run on the message thread
// mark their manager busy for their whole duration, however deeply other
// managers are called from inside them. That includes the stops and restarts
// JUCE does on its own (device unplugged, sample rate changed in Windows).
struct MessageThreadCallbackScope
{
    explicit MessageThreadCallbackScope(int* counter) noexcept
    {
        if (counter != nullptr && on_message_thread())
            scope = new (storage) BusyScope(counter);
    }
    ~MessageThreadCallbackScope() noexcept
    {
        if (scope != nullptr)
            scope->~BusyScope();
    }
    alignas(BusyScope) unsigned char storage[sizeof(BusyScope)];
    BusyScope* scope = nullptr;
};

struct ScopedDeviceCallback
{
    explicit ScopedDeviceCallback(const void* owner) noexcept : previous(callback_owner) { callback_owner = owner; }
    ~ScopedDeviceCallback() noexcept { callback_owner = previous; }
    const void* previous;
};

// The open device of `owner` may be read on the message thread, or inside that
// manager's own device callback; anywhere else it can be freed concurrently.
bool may_read_device(const void* owner) noexcept
{
    return (owner != nullptr && callback_owner == owner) || on_message_thread();
}

// Lists and settings the message thread changes without stopping the device.
bool may_read_lists() noexcept
{
    return on_message_thread();
}

// Changing or destroying a manager from inside one of its own callbacks
// (on_start, on_stop and the change callback run on the message thread, nested
// inside initialise/close/set_setup/...) would free or rebuild the device that
// the outer call is still using.
bool inside_own_callback(const void* owner) noexcept
{
    return owner != nullptr && callback_owner == owner;
}
}

class CAudioDeviceCallback final : public juce::AudioIODeviceCallback
{
public:
    explicit CAudioDeviceCallback(const juce_c_audio_callbacks* callbacks)
    {
        if (callbacks != nullptr)
        {
            user_data = callbacks->user_data;
            on_audio = callbacks->on_audio;
            on_start = callbacks->on_start;
            on_stop = callbacks->on_stop;
        }
        collector.reset(44100.0);
        collector.ensureStorageAllocated(midi_storage_bytes);
        midi_block.value.ensureSize(midi_storage_bytes);
        midi_block.borrowed = true;
    }

    void audioDeviceIOCallbackWithContext(const float* const* inputChannelData, int numInputChannels,
                                          float* const* outputChannelData, int numOutputChannels, int numSamples,
                                          const juce::AudioIODeviceCallbackContext&) override
    {
        if (numSamples <= 0)
            return; // nothing to do
        ScopedDeviceCallback inCallback(owner);

        for (int channel = 0; channel < numOutputChannels; ++channel)
            if (outputChannelData[channel] != nullptr)
                std::fill_n(outputChannelData[channel], numSamples, 0.0f);

        midi_block.value.clear();
        collector.removeNextBlockOfMessages(midi_block.value, numSamples);

        if (on_audio != nullptr)
        {
            ScopedFpMask fpMask;
            on_audio(user_data, inputChannelData, numInputChannels, outputChannelData, numOutputChannels,
                     numSamples, &midi_block);
        }
    }

    void audioDeviceAboutToStart(juce::AudioIODevice* device) override
    {
        ScopedDeviceCallback inCallback(owner);
        MessageThreadCallbackScope busyScope(busy);
        const double sampleRate = device != nullptr ? device->getCurrentSampleRate() : 44100.0;
        const int blockSize = device != nullptr ? device->getCurrentBufferSizeSamples() : 0;
        collector.reset(sampleRate > 0.0 ? sampleRate : 44100.0);
        running.store(true, std::memory_order_release);

        if (on_start != nullptr)
        {
            ScopedFpMask fpMask;
            on_start(user_data, sampleRate, blockSize);
        }
    }

    void audioDeviceStopped() override
    {
        running.store(false, std::memory_order_release);
        ScopedDeviceCallback inCallback(owner);
        MessageThreadCallbackScope busyScope(busy);
        if (on_stop != nullptr)
        {
            ScopedFpMask fpMask;
            on_stop(user_data);
        }
    }

    void* user_data = nullptr;
    juce_c_audio_callback on_audio = nullptr;
    juce_c_audio_start_callback on_start = nullptr;
    juce_c_audio_stop_callback on_stop = nullptr;
    juce::MidiMessageCollector collector;
    std::atomic<bool> running { false }; // between audioDeviceAboutToStart and audioDeviceStopped
    juce_c_midi_buffer midi_block;
    std::atomic<uint32_t> callback_error_count { 0 };
    const void* owner = nullptr; // the juce_c_audio_device_manager this callback belongs to
    int* busy = nullptr;         // that manager's busy counter
};

class CChangeListener final : public juce::ChangeListener
{
public:
    void changeListenerCallback(juce::ChangeBroadcaster*) override
    {
        if (callback != nullptr)
        {
            ScopedDeviceCallback inCallback(owner);
            MessageThreadCallbackScope busyScope(busy);
            ScopedFpMask fpMask;
            callback(user_data);
        }
    }

    juce_c_change_callback callback = nullptr;
    void* user_data = nullptr;
    const void* owner = nullptr;
    int* busy = nullptr;
};

// Sits between JUCE's MIDI inputs and the manager's collector. Drops messages
// above the API's size limit, and everything while no audio device is running:
// the collector only trims its queue when blocks are taken from it, so input
// arriving with nothing draining it would otherwise grow without bound.
class MidiInputFilter final : public juce::MidiInputCallback
{
public:
    explicit MidiInputFilter(CAudioDeviceCallback& owner) : target(owner) {}

    void handleIncomingMidiMessage(juce::MidiInput* source, const juce::MidiMessage& message) override
    {
        if (message.getRawDataSize() <= 0 || message.getRawDataSize() > max_midi_message_bytes
            || ! target.running.load(std::memory_order_acquire))
            return;
        target.collector.handleIncomingMidiMessage(source, message);
    }

private:
    CAudioDeviceCallback& target;
};

struct juce_c_audio_device_manager

{
    juce::AudioDeviceManager value;
    CAudioDeviceCallback callback;
    MidiInputFilter midi_filter { callback };
    CChangeListener change_listener;
    bool change_listener_registered = false;
    bool virtual_type_added = false;
    int busy = 0; // > 0 while a mutating call is on the stack (message thread only)

    explicit juce_c_audio_device_manager(const juce_c_audio_callbacks* callbacks) : callback(callbacks)
    {
        callback.owner = this;
        change_listener.owner = this;
        callback.busy = &busy;
        change_listener.busy = &busy;
        // Attached for the manager's whole life, whichever way a device gets opened.
        value.addAudioCallback(&callback);
        value.addMidiInputDeviceCallback({}, &midi_filter);
        ++live_device_handles;
    }

    ~juce_c_audio_device_manager()
    {
        value.removeMidiInputDeviceCallback({}, &midi_filter);
        if (change_listener_registered)
            value.removeChangeListener(&change_listener);
        value.closeAudioDevice();
        value.removeAudioCallback(&callback);
        --live_device_handles;
    }

    juce::AudioIODevice* device() const noexcept { return value.getCurrentAudioDevice(); }

    juce::AudioIODeviceType* type_at(int index)
    {
        auto& types = value.getAvailableDeviceTypes();
        return juce::isPositiveAndBelow(index, types.size()) ? types.getUnchecked(index) : nullptr;
    }

    juce::AudioIODeviceType* type_named(const juce::String& name)
    {
        for (auto* type : value.getAvailableDeviceTypes())
            if (type->getTypeName() == name)
                return type;
        return nullptr;
    }
};

struct juce_c_midi_device_list
{
    juce::Array<juce::MidiDeviceInfo> devices;
};

// True on a thread inside any MIDI-input callback. On Windows every input on a
// device shares one client list that JUCE walks while delivering, so opening,
// starting, stopping or destroying ANY input from inside a callback would
// change or free what that walk is using.
thread_local int in_midi_callback = 0;

struct ScopedMidiCallback
{
    ScopedMidiCallback() noexcept { ++in_midi_callback; }
    ~ScopedMidiCallback() noexcept { --in_midi_callback; }
};

constexpr const char* midi_reentry_message = "MIDI inputs cannot be opened, started, stopped or destroyed from inside a MIDI-input callback";

class CMidiInputCallback final : public juce::MidiInputCallback
{
public:
    CMidiInputCallback(juce_c_midi_input_callback callbackToUse, void* data) : callback(callbackToUse), user_data(data) {}

    void handleIncomingMidiMessage(juce::MidiInput*, const juce::MidiMessage& message) override
    {
        // JUCE delivers to every client of a shared device, started or not: gate here so
        // no callback arrives after juce_c_midi_input_stop returns.
        if (callback != nullptr && started.load(std::memory_order_acquire))
        {
            ScopedFpMask fpMask;
            ScopedDeviceCallback inCallback(this); // stop/destroy from inside it would deadlock
            ScopedMidiCallback inMidi;
            callback(user_data, message.getRawData(), message.getRawDataSize(), message.getTimeStamp());
        }
    }

    juce_c_midi_input_callback callback;
    void* user_data;
    std::atomic<bool> started { false };
};

struct juce_c_midi_input
{
    CMidiInputCallback callback;
    std::unique_ptr<juce::MidiInput> device;
    bool started = false;

    juce_c_midi_input(juce_c_midi_input_callback cb, void* data) : callback(cb, data) { ++live_device_handles; }

    ~juce_c_midi_input()
    {
        if (device != nullptr && started)
            device->stop();
        device.reset();
        --live_device_handles;
    }
};

struct juce_c_midi_output
{
    std::unique_ptr<juce::MidiOutput> device;

    juce_c_midi_output() { ++live_device_handles; }

    ~juce_c_midi_output()
    {
        if (device != nullptr)
        {
            device->clearAllPendingMessages();
            device->stopBackgroundThread();
        }
        {
            const std::lock_guard<std::mutex> lock(midi_output_mutex); // see juce_c_midi_output_open
            device.reset();
        }
        --live_device_handles;
    }
};

struct juce_c_audio_file_reader
{
    std::unique_ptr<juce::AudioFormatReader> reader;
    bool lengthCapped = false; // the header claimed more audio than the file can hold
};

struct juce_c_audio_file_writer
{
    std::unique_ptr<juce::AudioFormatWriter> writer;
    bool flushable = false;
};

namespace
{
juce::AudioFormatManager& format_manager()
{
    static std::once_flag once;
    static juce::AudioFormatManager manager;
    // Only formats whose parsing this library controls or has fuzzed: WAV and AIFF
    // (re-framed, see pascaljuce_riff.h), FLAC and Ogg Vorbis. Windows Media and
    // Core Audio are not registered: their readers were not reviewed.
    std::call_once(once, []
    {
        manager.registerFormat(new juce::WavAudioFormat(), true);
        manager.registerFormat(new juce::AiffAudioFormat(), false);
        manager.registerFormat(new juce::FlacAudioFormat(), false);
        manager.registerFormat(new juce::OggVorbisAudioFormat(), false);
    });
    return manager;
}

// A synthesized header (see pascaljuce_riff.h) followed by a window onto the
// audio bytes of the original file. Reads never go outside that window.
class SplicedInputStream final : public juce::InputStream
{
public:
    SplicedInputStream(std::vector<uint8_t> headerBytes, std::unique_ptr<juce::InputStream> sourceStream,
                       juce::int64 offset, juce::int64 length)
        : header(std::move(headerBytes)), source(std::move(sourceStream)), dataOffset(offset), dataLength(length)
    {
    }

    juce::int64 getTotalLength() override { return (juce::int64) header.size() + dataLength; }
    bool isExhausted() override { return position >= getTotalLength(); }
    juce::int64 getPosition() override { return position; }

    bool setPosition(juce::int64 newPosition) override
    {
        position = juce::jlimit<juce::int64>(0, getTotalLength(), newPosition);
        return true;
    }

    int read(void* destBuffer, int maxBytesToRead) override
    {
        auto* out = static_cast<char*>(destBuffer);
        int done = 0;
        const auto headerSize = (juce::int64) header.size();
        while (done < maxBytesToRead && position < getTotalLength())
        {
            const int wanted = maxBytesToRead - done;
            if (position < headerSize)
            {
                const int n = (int) std::min<juce::int64>(wanted, headerSize - position);
                std::memcpy(out + done, header.data() + position, (size_t) n);
                done += n;
                position += n;
                continue;
            }
            const juce::int64 inData = position - headerSize;
            const int n = (int) std::min<juce::int64>(wanted, dataLength - inData);
            if (! source->setPosition(dataOffset + inData))
                break;
            const int got = source->read(out + done, n);
            if (got <= 0)
                break;
            done += got;
            position += got;
        }
        return done;
    }

private:
    std::vector<uint8_t> header;
    std::unique_ptr<juce::InputStream> source;
    juce::int64 dataOffset, dataLength, position = 0;
};

// Forwards to another stream; optionally owns it.
class BorrowedInputStream final : public juce::InputStream
{
public:
    explicit BorrowedInputStream(juce::InputStream& targetStream) : target(targetStream) {}
    void adopt(std::unique_ptr<juce::InputStream> stream) { owned = std::move(stream); }

    juce::int64 getTotalLength() override { return target.getTotalLength(); }
    bool isExhausted() override { return target.isExhausted(); }
    int read(void* destBuffer, int maxBytesToRead) override { return target.read(destBuffer, maxBytesToRead); }
    juce::int64 getPosition() override { return target.getPosition(); }
    bool setPosition(juce::int64 newPosition) override { return target.setPosition(newPosition); }

private:
    juce::InputStream& target;
    std::unique_ptr<juce::InputStream> owned;
};

// Opens a reader. WAV and AIFF files are re-framed first, so JUCE's metadata
// parsers never see attacker-controlled chunks (see pascaljuce_riff.h).
juce::AudioFormatReader* create_reader(const juce::File& file, juce::String& problem)
{
    auto stream = file.createInputStream();
    if (stream == nullptr)
    {
        problem = "cannot open file";
        return nullptr;
    }
    const juce::int64 size = stream->getTotalLength();
    auto readAt = [&](int64_t offset, void* dest, size_t bytes)
    {
        return offset >= 0 && stream->setPosition(offset) && stream->read(dest, (int) bytes) == (int) bytes;
    };

    pascaljuce::riff::Plan plan;
    std::string why;
    switch (pascaljuce::riff::plan(readAt, size, plan, why))
    {
        case pascaljuce::riff::Result::malformed:
            problem = juce::String(why);
            return nullptr;

        case pascaljuce::riff::Result::notContainer:
        {
            // Same stream, never reopened by path: the file may change between two
            // opens (JUCE shares files for writing), and a file that turned into a WAV
            // in between would reach JUCE's unprotected chunk parsers. WAV and AIFF
            // readers only ever get re-framed streams, so they are skipped here.
            auto& manager = format_manager();
            for (int i = 0; i < manager.getNumKnownFormats(); ++i)
            {
                auto* format = manager.getKnownFormat(i);
                if (dynamic_cast<juce::WavAudioFormat*>(format) != nullptr
                    || dynamic_cast<juce::AiffAudioFormat*>(format) != nullptr)
                    continue;
                if (! stream->setPosition(0))
                    break;
                // JUCE's reader base class deletes its stream even when a codec's
                // constructor throws, so each attempt gets a forwarding wrapper. The
                // real stream moves into the wrapper only once a reader exists. If a
                // codec throws (out of memory), the wrapper may or may not have been
                // deleted: leak it rather than risk freeing it twice.
                auto* attempt = new BorrowedInputStream(*stream);
                auto* reader = format->createReaderFor(attempt, false);
                if (reader != nullptr)
                {
                    attempt->adopt(std::move(stream)); // freed with the reader
                    return reader;
                }
                delete attempt; // failed open: the format did not keep it
            }
            return nullptr;
        }

        case pascaljuce::riff::Result::ok:
            break;
    }

    const bool isWav = plan.header.size() >= 4 && plan.header[0] != 'F';
    auto* format = format_manager().findFormatForFileExtension(isWav ? ".wav" : ".aiff");
    if (format == nullptr)
        return nullptr;
    auto spliced = std::make_unique<SplicedInputStream>(std::move(plan.header), std::move(stream), plan.dataOffset,
                                                        plan.dataLength);
    // From here JUCE owns the stream: the reader deletes it, and so does a failed open
    // (deleteStreamIfOpeningFails), including one that throws once the base reader exists.
    return format->createReaderFor(spliced.release(), true);
}

juce::File resolve_path(const char* path)
{
    const auto text = from_utf8(path);
    return juce::File::isAbsolutePath(text) ? juce::File(text)
                                            : juce::File::getCurrentWorkingDirectory().getChildFile(text);
}

// Reads into dest[*][destStart..]; mono sources go to every channel. Frames
// past the end of the file read as 0.
bool read_into(juce::AudioFormatReader& reader, juce::AudioBuffer<float>& dest, int destStart, int count,
               juce::int64 readerStart)
{
    // Frames past the end are zero-filled here; the reader is only asked for frames the file has.
    const juce::int64 length = std::max<juce::int64>(0, reader.lengthInSamples);
    const int available = readerStart >= length ? 0 : (int) std::min<juce::int64>(count, length - readerStart);
    if (available < count)
    {
        dest.clear(destStart + available, count - available);
        dest.setNotClear();
        count = available;
        if (count == 0)
            return true;
    }

    const int destChannels = dest.getNumChannels();
    const int sourceChannels = (int) reader.numChannels;
    const int channelsToRead = std::min({ destChannels, std::max(1, sourceChannels), max_file_channels });

    float* pointers[max_file_channels] = {};
    for (int ch = 0; ch < channelsToRead; ++ch)
        pointers[ch] = dest.getWritePointer(ch, destStart);

    if (! reader.read(pointers, channelsToRead, readerStart, count))
        return false;

    for (int ch = channelsToRead; ch < destChannels; ++ch)
    {
        if (sourceChannels == 1)
            dest.copyFrom(ch, destStart, dest, 0, destStart, count);
        else
            dest.clear(ch, destStart, count);
    }
    dest.setNotClear();
    return true;
}

template <typename T, typename Getter>
T device_value(const juce_c_audio_device_manager* manager, T fallback, Getter&& getter) noexcept
{
    if (! may_read_device(manager))
        return fallback;
    auto* device = manager != nullptr ? manager->device() : nullptr;
    if (device == nullptr)
        return fallback;
    return guard_value(fallback, [&] { return (T) getter(*device); });
}

/* Rejects files whose header describes a format no real file has, before
   any samples are read. Found by fuzzing JUCE 8.0.6: a WAV declaring 32770
   channels and >64 "bits per sample" makes JUCE derive a frame size larger
   than its fixed 5760-byte read buffer, after which WavAudioFormatReader's
   read loop makes no progress and the process crashes. With <= 256 channels
   and a standard PCM width, a WAV/AIFF frame is at most 2048 bytes. */
juce::String implausible_format(const juce::AudioFormatReader& r)
{
    if (r.numChannels < 1 || r.numChannels > (unsigned int) max_file_channels)
        return "unsupported channel count " + juce::String((int) r.numChannels);
    if (r.bitsPerSample < 1 || r.bitsPerSample > 64)
        return "unsupported sample width " + juce::String((int) r.bitsPerSample) + " bits";
    if (! std::isfinite(r.sampleRate) || r.sampleRate < 1.0 || r.sampleRate > 10.0e6)
        return "implausible sample rate";
    if (r.lengthInSamples < 0)
        return "negative length";
    const auto name = r.getFormatName();
    if (name == "WAV file" || name == "AIFF file")
    {
        const auto bits = r.bitsPerSample;
        if (bits != 8 && bits != 16 && bits != 24 && bits != 32 && bits != 64)
            return "non-standard PCM sample width " + juce::String((int) bits) + " bits";
    }
    return {};
}

bool midi_device_exists(bool isInput, const juce::String& identifier)
{
    const auto devices = isInput ? juce::MidiInput::getAvailableDevices() : juce::MidiOutput::getAvailableDevices();
    for (const auto& info : devices)
        if (info.identifier == identifier)
            return true;
    return false;
}
}

namespace
{
// Calls into a manager can nest through callbacks: A's on_start may initialise
// B, whose on_start closes A, while A's own initialise is still running. Every
// mutating call therefore marks its manager busy for its whole duration, and
// any mutation or destroy of a busy manager is refused, whichever callback it
// comes from. Message dispatch is refused inside such calls too: it could run
// a change callback that does the same.
struct ManagerBusyScope : BusyScope
{
    explicit ManagerBusyScope(juce_c_audio_device_manager* m) noexcept : BusyScope(m != nullptr ? &m->busy : nullptr) {}
};

bool manager_busy(const juce_c_audio_device_manager* m) noexcept
{
    return m != nullptr && (m->busy > 0 || inside_own_callback(m));
}
}

#define JUCE_C_REFUSE_IF_BUSY(m)                                                                              \
    if (manager_busy(m))                                                                                      \
        return fail(JUCE_C_INVALID_STATE, "Cannot change or destroy a device manager while one of its own " \
                                          "calls or callbacks is running");
#define JUCE_C_MANAGER_MUTATOR(m) \
    JUCE_C_REFUSE_IF_BUSY(m)      \
    ManagerBusyScope busyScope(m);


//==============================================================================
extern "C"
{
//==============================================================================
// Library
//==============================================================================
int32_t juce_c_get_abi_version(void)
{
    return JUCE_C_AUDIO_ABI_VERSION;
}

const char* juce_c_get_last_error_message(void)
{
    return last_error_message;
}

juce_c_result juce_c_get_juce_version(char* buffer, size_t* buffer_size)
{
    return guard([&] { return write_string(juce::SystemStats::getJUCEVersion(), buffer, buffer_size); });
}

juce_c_result juce_c_initialise(void)
{
    return guard([&]
    {
        std::lock_guard<std::mutex> lock(init_mutex);
        if (init_count > 0)
        {
            if (! on_message_thread())
                return fail(JUCE_C_INVALID_STATE, "Already initialised on another thread");
            ++init_count;
            return ok();
        }

       #if defined(_WIN32)
        HMODULE module = nullptr;
        if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCWSTR>(&juce_c_initialise), &module))
            juce::Process::setCurrentModuleInstanceHandle(module);
       #endif
        juce::initialiseJuce_GUI();
        juce::MessageManager::getInstance(); // the calling thread becomes the message thread
        message_thread_id.store(juce::Thread::getCurrentThreadId());
       #if defined(_WIN32)
        // Hold the thread open: while a handle exists its id cannot be reused, so an
        // unrelated thread can never pass the message-thread checks after it exits.
        DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &message_thread_handle,
                        SYNCHRONIZE, FALSE, 0);
       #endif
        init_count = 1;
        initialised = true;
        return ok();
    });
}

juce_c_result juce_c_shutdown(void)
{
    return guard([&]
    {
        std::lock_guard<std::mutex> lock(init_mutex);
        if (init_count <= 0)
            return ok();
        if (! on_message_thread())
            return fail(JUCE_C_INVALID_STATE, "juce_c_shutdown must be called on the thread that called juce_c_initialise");
        if (init_count == 1)
        {
            if (dispatch_depth > 0)
                return fail(JUCE_C_INVALID_STATE, "The final juce_c_shutdown cannot run inside juce_c_dispatch_messages "
                                                  "(from a timer or event handler it pumped)");
            // Handshake with handle creation on other threads (seq_cst atomics): we clear
            // `initialised` and then look for handles; creators register a handle and then
            // check `initialised`. At least one side sees the other, so no handle can be
            // created while JUCE shuts down.
            initialised = false;
            const int live = live_device_handles.load();
            if (live > 0)
            {
                initialised = true;
                return fail(JUCE_C_INVALID_STATE, juce::String(live)
                                                      + " device manager(s) / MIDI device(s) still open, or calls still in progress on other threads: "
                                                      "destroy them (and let those calls finish) first");
            }
        }

        if (--init_count == 0)
        {
            message_thread_id.store(nullptr);
           #if defined(_WIN32)
            if (message_thread_handle != nullptr)
            {
                CloseHandle(message_thread_handle);
                message_thread_handle = nullptr;
            }
           #endif
                juce::shutdownJuce_GUI();
        }
        return ok();
    });
}

int32_t juce_c_is_initialised(void)
{
    return initialised ? 1 : 0;
}

juce_c_result juce_c_dispatch_messages(int32_t milliseconds)
{
    JUCE_C_REQUIRE(require_message_thread());
    if (mutating_calls > 0)
        return fail(JUCE_C_INVALID_STATE, "Cannot dispatch messages from inside a device-manager call or callback");
    return guard([&]
    {
        struct Depth
        {
            Depth() noexcept { ++dispatch_depth; }
            ~Depth() noexcept { --dispatch_depth; }
        } depth;
        juce::MessageManager::getInstance()->runDispatchLoopUntil(std::max(0, (int) milliseconds));
        return ok();
    });
}

double juce_c_get_millisecond_counter_hires(void)
{
    return juce::Time::getMillisecondCounterHiRes();
}

//==============================================================================
// Audio buffers
//==============================================================================
juce_c_result juce_c_audio_buffer_create(int32_t channel_count, int32_t sample_count, juce_c_audio_buffer** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    if (! valid_buffer_size(channel_count, sample_count))
        return fail(JUCE_C_INVALID_ARGUMENT, "Channel and sample counts must be positive, at most 1024 channels "
                                             "and 2^30 samples in total");

    return guard([&]
    {
        *result = new juce_c_audio_buffer(channel_count, sample_count);
        return ok();
    });
}

void juce_c_audio_buffer_destroy(juce_c_audio_buffer* buffer)
{
    delete buffer;
}

int32_t juce_c_audio_buffer_get_channel_count(const juce_c_audio_buffer* buffer)
{
    return buffer != nullptr ? buffer->value.getNumChannels() : 0;
}

int32_t juce_c_audio_buffer_get_sample_count(const juce_c_audio_buffer* buffer)
{
    return buffer != nullptr ? buffer->value.getNumSamples() : 0;
}

juce_c_result juce_c_audio_buffer_set_size(juce_c_audio_buffer* buffer, int32_t channel_count, int32_t sample_count,
                                           int32_t keep_existing_content)
{
    if (buffer == nullptr || ! valid_buffer_size(channel_count, sample_count))
        return fail(JUCE_C_INVALID_ARGUMENT, "Invalid buffer or size (at most 1024 channels, 2^30 samples in total)");

    return guard([&]
    {
        buffer->value.setSize(channel_count, sample_count, keep_existing_content != 0, true);
        buffer->value.setNotClear();
        return ok();
    });
}

juce_c_result juce_c_audio_buffer_get_read_pointer(const juce_c_audio_buffer* buffer, int32_t channel,
                                                   const float** result)
{
    if (buffer == nullptr || result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer and result must not be null");
    if (! juce::isPositiveAndBelow(channel, buffer->value.getNumChannels()))
        return fail(JUCE_C_OUT_OF_RANGE, "Channel index is out of range");

    *result = buffer->value.getReadPointer(channel);
    return ok();
}

juce_c_result juce_c_audio_buffer_get_write_pointer(juce_c_audio_buffer* buffer, int32_t channel, float** result)
{
    if (buffer == nullptr || result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer and result must not be null");
    if (! juce::isPositiveAndBelow(channel, buffer->value.getNumChannels()))
        return fail(JUCE_C_OUT_OF_RANGE, "Channel index is out of range");

    *result = buffer->value.getWritePointer(channel);
    return ok();
}

juce_c_result juce_c_audio_buffer_clear(juce_c_audio_buffer* buffer)
{
    if (buffer == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer must not be null");
    clear_buffer(buffer->value);
    return ok();
}

juce_c_result juce_c_audio_buffer_clear_region(juce_c_audio_buffer* buffer, int32_t start_sample, int32_t sample_count)
{
    if (buffer == nullptr || start_sample < 0 || sample_count < 0)
        return fail(JUCE_C_INVALID_ARGUMENT, "Invalid buffer or sample range");
    if (! valid_range(buffer->value, start_sample, sample_count))
        return fail(JUCE_C_OUT_OF_RANGE, "Sample range is out of bounds");

    buffer->value.clear(start_sample, sample_count);
    buffer->value.setNotClear();
    return ok();
}

juce_c_result juce_c_audio_buffer_apply_gain(juce_c_audio_buffer* buffer, float gain)
{
    if (buffer == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer must not be null");
    ScopedFpMask fpMask;
    buffer->value.applyGain(gain);
    return ok();
}

juce_c_result juce_c_audio_buffer_apply_gain_ramp(juce_c_audio_buffer* buffer, int32_t start_sample,
                                                  int32_t sample_count, float start_gain, float end_gain)
{
    if (buffer == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer must not be null");
    if (! valid_range(buffer->value, start_sample, sample_count))
        return fail(JUCE_C_OUT_OF_RANGE, "Sample range is out of bounds");

    ScopedFpMask fpMask;
    buffer->value.applyGainRamp(start_sample, sample_count, start_gain, end_gain);
    return ok();
}

static juce_c_result check_copy_args(const juce_c_audio_buffer* dest, int dest_channel, int dest_start,
                                     const juce_c_audio_buffer* source, int source_channel, int source_start,
                                     int sample_count) noexcept
{
    if (dest == nullptr || source == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "dest and source must not be null");
    if (! juce::isPositiveAndBelow(dest_channel, dest->value.getNumChannels())
        || ! juce::isPositiveAndBelow(source_channel, source->value.getNumChannels()))
        return fail(JUCE_C_OUT_OF_RANGE, "Channel index is out of range");
    if (! valid_range(dest->value, dest_start, sample_count) || ! valid_range(source->value, source_start, sample_count))
        return fail(JUCE_C_OUT_OF_RANGE, "Sample range is out of bounds");
    return JUCE_C_OK;
}

juce_c_result juce_c_audio_buffer_add_from(juce_c_audio_buffer* dest, int32_t dest_channel, int32_t dest_start_sample,
                                           const juce_c_audio_buffer* source, int32_t source_channel,
                                           int32_t source_start_sample, int32_t sample_count, float gain)
{
    JUCE_C_REQUIRE(check_copy_args(dest, dest_channel, dest_start_sample, source, source_channel,
                                   source_start_sample, sample_count));
    ScopedFpMask fpMask;
    dest->value.addFrom(dest_channel, dest_start_sample, source->value, source_channel, source_start_sample,
                        sample_count, gain);
    return ok();
}

juce_c_result juce_c_audio_buffer_copy_from(juce_c_audio_buffer* dest, int32_t dest_channel, int32_t dest_start_sample,
                                            const juce_c_audio_buffer* source, int32_t source_channel,
                                            int32_t source_start_sample, int32_t sample_count)
{
    JUCE_C_REQUIRE(check_copy_args(dest, dest_channel, dest_start_sample, source, source_channel,
                                   source_start_sample, sample_count));
    dest->value.copyFrom(dest_channel, dest_start_sample, source->value, source_channel, source_start_sample,
                         sample_count);
    return ok();
}

juce_c_result juce_c_audio_buffer_get_magnitude(const juce_c_audio_buffer* buffer, int32_t channel,
                                                int32_t start_sample, int32_t sample_count, float* result)
{
    if (buffer == nullptr || result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer and result must not be null");
    if (! juce::isPositiveAndBelow(channel, buffer->value.getNumChannels()))
        return fail(JUCE_C_OUT_OF_RANGE, "Channel index is out of range");
    if (! valid_range(buffer->value, start_sample, sample_count))
        return fail(JUCE_C_OUT_OF_RANGE, "Sample range is out of bounds");

    ScopedFpMask fpMask;
    *result = buffer->value.getMagnitude(channel, start_sample, sample_count);
    return ok();
}

juce_c_result juce_c_audio_buffer_get_rms_level(const juce_c_audio_buffer* buffer, int32_t channel,
                                                int32_t start_sample, int32_t sample_count, float* result)
{
    if (buffer == nullptr || result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer and result must not be null");
    if (! juce::isPositiveAndBelow(channel, buffer->value.getNumChannels()))
        return fail(JUCE_C_OUT_OF_RANGE, "Channel index is out of range");
    if (! valid_range(buffer->value, start_sample, sample_count))
        return fail(JUCE_C_OUT_OF_RANGE, "Sample range is out of bounds");

    ScopedFpMask fpMask;
    *result = buffer->value.getRMSLevel(channel, start_sample, sample_count);
    return ok();
}

//==============================================================================
// MIDI buffers / messages
//==============================================================================
juce_c_result juce_c_midi_buffer_create(juce_c_midi_buffer** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    return guard([&]
    {
        *result = new juce_c_midi_buffer();
        return ok();
    });
}

void juce_c_midi_buffer_destroy(juce_c_midi_buffer* buffer)
{
    // Not while its own for_each runs: the live iterator points into it. Leaking
    // (the documented outcome) is better than a use-after-free.
    if (buffer != nullptr && (buffer->iterating > 0 || buffer->borrowed))
        return; // also never the on_audio block, which belongs to its manager
    delete buffer;
}

juce_c_result juce_c_midi_buffer_clear(juce_c_midi_buffer* buffer)
{
    if (buffer == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer must not be null");
    if (buffer->iterating > 0)
        return fail(JUCE_C_INVALID_STATE, "MIDI buffer cannot be changed from inside its own for_each");
    buffer->value.clear();
    return ok();
}

int32_t juce_c_midi_buffer_get_event_count(const juce_c_midi_buffer* buffer)
{
    return buffer != nullptr ? buffer->value.getNumEvents() : 0;
}

juce_c_result juce_c_midi_buffer_add_event(juce_c_midi_buffer* buffer, const uint8_t* message, size_t message_size,
                                           int32_t sample_position)
{
    if (buffer == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer must not be null");
    if (buffer->iterating > 0)
        return fail(JUCE_C_INVALID_STATE, "MIDI buffer cannot be changed from inside its own for_each");
    juce::String why;
    if (! is_valid_midi(message, message_size, why))
        return fail(JUCE_C_INVALID_ARGUMENT, why);
    // Cap a buffer well below the sizes JUCE's int-indexed arrays can handle.
    if ((size_t) buffer->value.data.size() + message_size + 6 > max_midi_buffer_bytes)
        return fail(JUCE_C_OUT_OF_RANGE, "MIDI buffer is full (256 MB max)");

    return guard([&]
    {
        if (! buffer->value.addEvent(message, (int) message_size, std::max(0, (int) sample_position)))
            return fail(JUCE_C_OUT_OF_MEMORY, "Could not add the MIDI event");
        return ok();
    });
}

juce_c_result juce_c_midi_buffer_get_event(const juce_c_midi_buffer* buffer, int32_t event_index, uint8_t* message,
                                           size_t* message_size, int32_t* sample_position)
{
    if (buffer == nullptr || message_size == nullptr || sample_position == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer, message_size and sample_position are required");
    if (! juce::isPositiveAndBelow(event_index, buffer->value.getNumEvents()))
        return fail(JUCE_C_OUT_OF_RANGE, "MIDI event index is out of range");

    int index = 0;
    for (const auto metadata : buffer->value)
    {
        if (index++ != event_index)
            continue;

        const auto requiredSize = (size_t) metadata.numBytes;
        *sample_position = metadata.samplePosition;
        if (message == nullptr || *message_size < requiredSize)
        {
            *message_size = requiredSize;
            if (message == nullptr)
            {
                last_error_message[0] = '\0';
                return JUCE_C_BUFFER_TOO_SMALL;
            }
            return fail(JUCE_C_BUFFER_TOO_SMALL, "MIDI message destination is too small");
        }

        std::memcpy(message, metadata.data, requiredSize);
        *message_size = requiredSize;
        return ok();
    }

    return fail(JUCE_C_OUT_OF_RANGE, "MIDI event index is out of range");
}

juce_c_result juce_c_midi_buffer_for_each(const juce_c_midi_buffer* buffer, juce_c_midi_event_visitor visitor,
                                          void* user_data)
{
    if (buffer == nullptr || visitor == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "buffer and visitor must not be null");

    auto* mutableBuffer = const_cast<juce_c_midi_buffer*>(buffer);
    ++mutableBuffer->iterating;
    for (const auto metadata : buffer->value)
        if (visitor(user_data, metadata.data, metadata.numBytes, metadata.samplePosition) != 0)
            break;
    --mutableBuffer->iterating;

    return ok();
}

juce_c_result juce_c_midi_message_get_description(const uint8_t* message, size_t message_size, char* buffer,
                                                  size_t* buffer_size)
{
    return guard([&]
    {
        juce::MidiMessage midi;
        JUCE_C_REQUIRE(make_midi_message(message, message_size, 0.0, midi));
        return write_string(midi.getDescription(), buffer, buffer_size);
    });
}

juce_c_result juce_c_midi_get_note_name(int32_t note_number, int32_t use_sharps, int32_t include_octave,
                                        int32_t middle_c_octave, char* buffer, size_t* buffer_size)
{
    if (! juce::isPositiveAndBelow(note_number, 128))
        return fail(JUCE_C_OUT_OF_RANGE, "Note number must be 0..127");

    return guard([&]
    {
        return write_string(juce::MidiMessage::getMidiNoteName(note_number, use_sharps != 0, include_octave != 0,
                                                                middle_c_octave),
                            buffer, buffer_size);
    });
}

double juce_c_midi_get_note_frequency(int32_t note_number, double frequency_of_a)
{
    return guard_value(0.0, [&] { return juce::MidiMessage::getMidiNoteInHertz(note_number, frequency_of_a); });
}

//==============================================================================
// Audio device manager
//==============================================================================
int32_t juce_c_audio_device_setup_size(void)
{
    return (int32_t) sizeof(juce_c_audio_device_setup);
}

juce_c_result juce_c_audio_device_manager_create(const juce_c_audio_callbacks* callbacks,
                                                 juce_c_audio_device_manager** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    if (callbacks != nullptr && callbacks->struct_size < (int32_t) sizeof(juce_c_audio_callbacks))
        return fail(JUCE_C_INVALID_ARGUMENT, "callbacks->struct_size is too small");
    JUCE_C_REQUIRE(require_message_thread());

    return guard([&]
    {
        *result = new juce_c_audio_device_manager(callbacks);
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_destroy(juce_c_audio_device_manager* manager)
{
    if (manager == nullptr)
        return ok();
    // Destroying off the message thread would race JUCE delivering change
    // messages to this manager: refuse (the handle stays valid) instead.
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_REFUSE_IF_BUSY(manager)
    if (manager != nullptr)
        ++manager->busy; // for its whole destructor, which runs on_stop: nothing may re-enter it
    struct DestroyScope
    {
        DestroyScope() noexcept { ++mutating_calls; }
        ~DestroyScope() noexcept { --mutating_calls; }
    } destroyScope;
    return guard([&]
    {
        delete manager;
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_set_change_callback(juce_c_audio_device_manager* manager,
                                                              juce_c_change_callback callback, void* user_data)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)

    return guard([&]
    {
        manager->change_listener.callback = callback;
        manager->change_listener.user_data = user_data;

        if (callback != nullptr && ! manager->change_listener_registered)
        {
            manager->value.addChangeListener(&manager->change_listener);
            manager->change_listener_registered = true;
        }
        else if (callback == nullptr && manager->change_listener_registered)
        {
            manager->value.removeChangeListener(&manager->change_listener);
            manager->change_listener_registered = false;
        }
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_add_virtual_device_type(juce_c_audio_device_manager* manager,
                                                                  const juce_c_virtual_device_options* options)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    if (options != nullptr && options->struct_size < (int32_t) sizeof(juce_c_virtual_device_options))
        return fail(JUCE_C_INVALID_ARGUMENT, "options->struct_size is too small");
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)
    if (manager->virtual_type_added)
        return fail(JUCE_C_INVALID_STATE, "The Virtual device type is already registered");

    return guard([&]
    {
        juce_c::VirtualDeviceOptions opts;
        if (options != nullptr)
        {
            opts.realtime = options->realtime != 0;
            opts.inputSignal = options->input_signal;
        }
        // Create the platform types first: JUCE only creates them while the list is empty.
        manager->value.getAvailableDeviceTypes();
        manager->value.addAudioDeviceType(std::make_unique<juce_c::VirtualAudioIODeviceType>(opts));
        manager->virtual_type_added = true;
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_simulate_xrun(juce_c_audio_device_manager* manager)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());
    auto* device = dynamic_cast<juce_c::VirtualAudioIODevice*>(manager->device());
    if (device == nullptr)
        return fail(JUCE_C_INVALID_STATE, "The open device is not a Virtual device");
    device->simulateXRun();
    return ok();
}

static juce::AudioDeviceManager::AudioDeviceSetup to_juce_setup(const juce_c_audio_device_setup& setup)
{
    juce::AudioDeviceManager::AudioDeviceSetup result;
    result.outputDeviceName = from_fixed_utf8(setup.output_device_name);
    result.inputDeviceName = from_fixed_utf8(setup.input_device_name);
    result.sampleRate = setup.sample_rate;
    result.bufferSize = setup.buffer_size;
    result.inputChannels = from_mask(setup.input_channels);
    result.outputChannels = from_mask(setup.output_channels);
    result.useDefaultInputChannels = setup.use_default_input_channels != 0;
    result.useDefaultOutputChannels = setup.use_default_output_channels != 0;
    return result;
}

static juce_c_result check_setup(const juce_c_audio_device_setup* setup)
{
    if (setup != nullptr && setup->struct_size < (int32_t) sizeof(juce_c_audio_device_setup))
        return fail(JUCE_C_INVALID_ARGUMENT, "setup->struct_size is too small (set it to sizeof(juce_c_audio_device_setup))");
    return JUCE_C_OK;
}

juce_c_result juce_c_audio_device_manager_initialize(juce_c_audio_device_manager* manager,
                                                     int32_t input_channel_count, int32_t output_channel_count)
{
    return juce_c_audio_device_manager_initialize_with_setup(manager, input_channel_count, output_channel_count,
                                                             nullptr, nullptr);
}

juce_c_result juce_c_audio_device_manager_initialize_with_setup(juce_c_audio_device_manager* manager,
                                                                int32_t input_channel_count,
                                                                int32_t output_channel_count,
                                                                const char* device_type,
                                                                const juce_c_audio_device_setup* preferred)
{
    if (manager == nullptr || input_channel_count < 0 || output_channel_count < 0
        || (input_channel_count == 0 && output_channel_count == 0) || input_channel_count > 256
        || output_channel_count > 256)
        return fail(JUCE_C_INVALID_ARGUMENT, "Invalid device manager or channel counts");
    JUCE_C_REQUIRE(check_setup(preferred));
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)

    return guard([&]
    {
        const auto typeName = from_utf8(device_type);
        juce::String error;

        if (typeName.isEmpty())
        {
            if (preferred != nullptr)
            {
                const auto setup = to_juce_setup(*preferred);
                error = manager->value.initialise(input_channel_count, output_channel_count, nullptr, true, {}, &setup);
            }
            else
            {
                error = manager->value.initialise(input_channel_count, output_channel_count, nullptr, true);
            }
        }
        else
        {
            auto* type = manager->type_named(typeName);
            if (type == nullptr)
                return fail(JUCE_C_INVALID_ARGUMENT, "Unknown audio device type: " + typeName);

            auto setup = preferred != nullptr ? to_juce_setup(*preferred) : juce::AudioDeviceManager::AudioDeviceSetup();
            type->scanForDevices();
            for (const bool isInput : { false, true })
            {
                auto& name = isInput ? setup.inputDeviceName : setup.outputDeviceName;
                const int needed = isInput ? input_channel_count : output_channel_count;
                if (name.isEmpty() && needed > 0)
                {
                    const auto names = type->getDeviceNames(isInput);
                    const int index = type->getDefaultDeviceIndex(isInput);
                    if (! names.isEmpty())
                        name = names[juce::isPositiveAndBelow(index, names.size()) ? index : 0];
                }
            }
            if (setup.inputDeviceName.isEmpty() && setup.outputDeviceName.isEmpty())
                return fail(JUCE_C_JUCE_ERROR, "No devices of type " + typeName + " are available");

            // Restoring from XML selects the type and opens the device once, with no fallback.
            juce::XmlElement xml("DEVICESETUP");
            xml.setAttribute("deviceType", typeName);
            xml.setAttribute("audioOutputDeviceName", setup.outputDeviceName);
            xml.setAttribute("audioInputDeviceName", setup.inputDeviceName);
            if (setup.sampleRate > 0)
                xml.setAttribute("audioDeviceRate", setup.sampleRate);
            if (setup.bufferSize > 0)
                xml.setAttribute("audioDeviceBufferSize", setup.bufferSize);
            if (! setup.useDefaultInputChannels)
                xml.setAttribute("audioDeviceInChans", setup.inputChannels.toString(2));
            if (! setup.useDefaultOutputChannels)
                xml.setAttribute("audioDeviceOutChans", setup.outputChannels.toString(2));

            error = manager->value.initialise(input_channel_count, output_channel_count, &xml, false);
            if (error.isEmpty() && manager->value.getCurrentAudioDeviceType() != typeName)
                error = "Could not select device type " + typeName;
        }

        if (error.isNotEmpty())
            return fail(JUCE_C_JUCE_ERROR, error);
        if (manager->device() == nullptr)
            return fail(JUCE_C_JUCE_ERROR, "No audio device could be opened");
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_close(juce_c_audio_device_manager* manager)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)

    return guard([&]
    {
        manager->value.closeAudioDevice();
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_restart(juce_c_audio_device_manager* manager)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)

    return guard([&]
    {
        manager->value.restartLastAudioDevice();
        if (manager->device() == nullptr)
            return fail(JUCE_C_JUCE_ERROR, "Could not reopen the audio device");
        return ok();
    });
}

int32_t juce_c_audio_device_manager_get_device_type_count(juce_c_audio_device_manager* manager)
{
    if (manager == nullptr || ! may_read_lists())
        return 0;
    return guard_value(0, [&] { return manager->value.getAvailableDeviceTypes().size(); });
}

juce_c_result juce_c_audio_device_manager_get_device_type_name(juce_c_audio_device_manager* manager,
                                                               int32_t type_index, char* buffer, size_t* buffer_size)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());

    return guard([&]
    {
        auto* type = manager->type_at(type_index);
        if (type == nullptr)
            return fail(JUCE_C_OUT_OF_RANGE, "Device type index is out of range");
        return write_string(type->getTypeName(), buffer, buffer_size);
    });
}

juce_c_result juce_c_audio_device_manager_get_current_device_type(const juce_c_audio_device_manager* manager,
                                                                  char* buffer, size_t* buffer_size)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());
    return guard([&] { return write_string(manager->value.getCurrentAudioDeviceType(), buffer, buffer_size); });
}

juce_c_result juce_c_audio_device_manager_set_current_device_type(juce_c_audio_device_manager* manager,
                                                                  const char* type_name,
                                                                  int32_t treat_as_chosen_device)
{
    if (manager == nullptr || type_name == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager and type_name must not be null");
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)

    return guard([&]
    {
        const auto type = from_utf8(type_name);
        if (manager->type_named(type) == nullptr)
            return fail(JUCE_C_INVALID_ARGUMENT, "Unknown audio device type: " + type);
        manager->value.setCurrentAudioDeviceType(type, treat_as_chosen_device != 0);
        if (manager->value.getCurrentAudioDeviceType() != type)
            return fail(JUCE_C_JUCE_ERROR, "Could not select device type " + type);
        if (manager->device() == nullptr)
            return fail(JUCE_C_JUCE_ERROR, "No device of type " + type + " could be opened");
        return ok();
    });
}

int32_t juce_c_audio_device_manager_get_device_count(juce_c_audio_device_manager* manager, int32_t type_index,
                                                     int32_t is_input)
{
    if (manager == nullptr || ! may_read_lists())
        return 0;
    return guard_value(0, [&]
    {
        auto* type = manager->type_at(type_index);
        return type != nullptr ? type->getDeviceNames(is_input != 0).size() : 0;
    });
}

juce_c_result juce_c_audio_device_manager_get_device_name(juce_c_audio_device_manager* manager, int32_t type_index,
                                                          int32_t is_input, int32_t device_index, char* buffer,
                                                          size_t* buffer_size)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());

    return guard([&]
    {
        auto* type = manager->type_at(type_index);
        if (type == nullptr)
            return fail(JUCE_C_OUT_OF_RANGE, "Device type index is out of range");
        const auto names = type->getDeviceNames(is_input != 0);
        if (! juce::isPositiveAndBelow(device_index, names.size()))
            return fail(JUCE_C_OUT_OF_RANGE, "Device index is out of range");
        return write_string(names[device_index], buffer, buffer_size);
    });
}

int32_t juce_c_audio_device_manager_get_default_device_index(juce_c_audio_device_manager* manager, int32_t type_index,
                                                             int32_t is_input)
{
    if (manager == nullptr || ! may_read_lists())
        return -1;
    return guard_value(-1, [&]
    {
        auto* type = manager->type_at(type_index);
        return type != nullptr ? type->getDefaultDeviceIndex(is_input != 0) : -1;
    });
}

juce_c_result juce_c_audio_device_manager_get_setup(const juce_c_audio_device_manager* manager,
                                                    juce_c_audio_device_setup* setup)
{
    if (manager == nullptr || setup == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager and setup must not be null");
    JUCE_C_REQUIRE(check_setup(setup));
    JUCE_C_REQUIRE(require_message_thread());

    return guard([&]
    {
        const auto current = manager->value.getAudioDeviceSetup();
        const int32_t size = setup->struct_size;
        std::memset(setup, 0, sizeof(*setup));
        setup->struct_size = size;
        setup->sample_rate = current.sampleRate;
        setup->buffer_size = current.bufferSize;
        to_mask(current.inputChannels, setup->input_channels);
        to_mask(current.outputChannels, setup->output_channels);
        setup->use_default_input_channels = current.useDefaultInputChannels ? 1 : 0;
        setup->use_default_output_channels = current.useDefaultOutputChannels ? 1 : 0;
        copy_utf8(setup->output_device_name, sizeof(setup->output_device_name), current.outputDeviceName.toRawUTF8());
        copy_utf8(setup->input_device_name, sizeof(setup->input_device_name), current.inputDeviceName.toRawUTF8());
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_set_setup(juce_c_audio_device_manager* manager,
                                                    const juce_c_audio_device_setup* setup,
                                                    int32_t treat_as_chosen_device)
{
    if (manager == nullptr || setup == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager and setup must not be null");
    JUCE_C_REQUIRE(check_setup(setup));
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)

    return guard([&]
    {
        const auto error = manager->value.setAudioDeviceSetup(to_juce_setup(*setup), treat_as_chosen_device != 0);
        if (error.isNotEmpty())
            return fail(JUCE_C_JUCE_ERROR, error);
        return ok();
    });
}

int32_t juce_c_audio_device_manager_is_device_open(const juce_c_audio_device_manager* manager)
{
    auto* device = manager != nullptr && may_read_device(manager) ? manager->device() : nullptr;
    return device != nullptr && device->isOpen() ? 1 : 0;
}

juce_c_result juce_c_audio_device_manager_get_device_name_current(const juce_c_audio_device_manager* manager,
                                                                  char* buffer, size_t* buffer_size)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());

    return guard([&]
    {
        auto* device = manager->device();
        return write_string(device != nullptr ? device->getName() : juce::String(), buffer, buffer_size);
    });
}

double juce_c_audio_device_manager_get_sample_rate(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0.0, [](juce::AudioIODevice& d) { return d.getCurrentSampleRate(); });
}

int32_t juce_c_audio_device_manager_get_block_size(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getCurrentBufferSizeSamples(); });
}

int32_t juce_c_audio_device_manager_get_bit_depth(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getCurrentBitDepth(); });
}

int32_t juce_c_audio_device_manager_get_input_latency(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getInputLatencyInSamples(); });
}

int32_t juce_c_audio_device_manager_get_output_latency(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getOutputLatencyInSamples(); });
}

int32_t juce_c_audio_device_manager_get_active_input_channel_count(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getActiveInputChannels().countNumberOfSetBits(); });
}

int32_t juce_c_audio_device_manager_get_active_output_channel_count(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getActiveOutputChannels().countNumberOfSetBits(); });
}

int32_t juce_c_audio_device_manager_get_channel_name_count(const juce_c_audio_device_manager* manager, int32_t is_input)
{
    return device_value(manager, 0, [&](juce::AudioIODevice& d)
    {
        return (is_input != 0 ? d.getInputChannelNames() : d.getOutputChannelNames()).size();
    });
}

juce_c_result juce_c_audio_device_manager_get_channel_name(const juce_c_audio_device_manager* manager,
                                                           int32_t is_input, int32_t channel_index, char* buffer,
                                                           size_t* buffer_size)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());

    return guard([&]
    {
        auto* device = manager->device();
        if (device == nullptr)
            return fail(JUCE_C_INVALID_STATE, "No audio device is open");
        const auto names = is_input != 0 ? device->getInputChannelNames() : device->getOutputChannelNames();
        if (! juce::isPositiveAndBelow(channel_index, names.size()))
            return fail(JUCE_C_OUT_OF_RANGE, "Channel index is out of range");
        return write_string(names[channel_index], buffer, buffer_size);
    });
}

int32_t juce_c_audio_device_manager_get_available_sample_rate_count(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getAvailableSampleRates().size(); });
}

double juce_c_audio_device_manager_get_available_sample_rate(const juce_c_audio_device_manager* manager, int32_t index)
{
    return device_value(manager, 0.0, [&](juce::AudioIODevice& d)
    {
        const auto rates = d.getAvailableSampleRates();
        return juce::isPositiveAndBelow(index, rates.size()) ? rates[index] : 0.0;
    });
}

int32_t juce_c_audio_device_manager_get_available_buffer_size_count(const juce_c_audio_device_manager* manager)
{
    return device_value(manager, 0, [](juce::AudioIODevice& d) { return d.getAvailableBufferSizes().size(); });
}

int32_t juce_c_audio_device_manager_get_available_buffer_size(const juce_c_audio_device_manager* manager, int32_t index)
{
    return device_value(manager, 0, [&](juce::AudioIODevice& d)
    {
        const auto sizes = d.getAvailableBufferSizes();
        return juce::isPositiveAndBelow(index, sizes.size()) ? sizes[index] : 0;
    });
}

double juce_c_audio_device_manager_get_cpu_usage(const juce_c_audio_device_manager* manager)
{
    return manager != nullptr && may_read_device(manager) ? manager->value.getCpuUsage() : 0.0;
}

int32_t juce_c_audio_device_manager_get_xrun_count(const juce_c_audio_device_manager* manager)
{
    return manager != nullptr && may_read_device(manager) ? manager->value.getXRunCount() : 0;
}

juce_c_result juce_c_audio_device_manager_play_test_sound(juce_c_audio_device_manager* manager)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)
    if (manager->device() == nullptr)
        return fail(JUCE_C_INVALID_STATE, "No audio device is open");

    return guard([&]
    {
        manager->value.playTestSound();
        return ok();
    });
}

juce_c_result juce_c_audio_device_manager_set_midi_input_enabled(juce_c_audio_device_manager* manager,
                                                                 const char* device_identifier, int32_t enabled)
{
    if (manager == nullptr || device_identifier == nullptr || *device_identifier == '\0')
        return fail(JUCE_C_INVALID_ARGUMENT, "manager and device_identifier are required");
    JUCE_C_REQUIRE(require_message_thread());
    JUCE_C_MANAGER_MUTATOR(manager)

    return guard([&]
    {
        const auto id = from_utf8(device_identifier);
        if (enabled != 0 && ! midi_device_exists(true, id))
            return fail(JUCE_C_JUCE_ERROR, "No MIDI input with identifier " + id);
        manager->value.setMidiInputDeviceEnabled(id, enabled != 0);
        if (enabled != 0 && ! manager->value.isMidiInputDeviceEnabled(id))
            return fail(JUCE_C_JUCE_ERROR, "Could not open MIDI input " + id);
        return ok();
    });
}

int32_t juce_c_audio_device_manager_is_midi_input_enabled(const juce_c_audio_device_manager* manager,
                                                          const char* device_identifier)
{
    if (manager == nullptr || device_identifier == nullptr || ! may_read_lists())
        return 0;
    return guard_value(0, [&] { return manager->value.isMidiInputDeviceEnabled(from_utf8(device_identifier)) ? 1 : 0; });
}

juce_c_result juce_c_audio_device_manager_add_midi_message(juce_c_audio_device_manager* manager,
                                                           const uint8_t* message, size_t message_size)
{
    if (manager == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "manager must not be null");

    return guard([&]
    {
        juce::MidiMessage midi;
        JUCE_C_REQUIRE(make_midi_message(message, message_size, juce::Time::getMillisecondCounterHiRes() * 0.001, midi));
        if (! manager->callback.running.load(std::memory_order_acquire))
            return ok(); // documented: dropped while no device runs (nothing would drain the queue)
        manager->callback.collector.addMessageToQueue(midi);
        return ok();
    });
}

void juce_c_audio_device_manager_report_callback_error(juce_c_audio_device_manager* manager)
{
    if (manager != nullptr)
        manager->callback.callback_error_count.fetch_add(1, std::memory_order_relaxed);
}

uint32_t juce_c_audio_device_manager_consume_callback_error_count(juce_c_audio_device_manager* manager)
{
    return manager != nullptr ? manager->callback.callback_error_count.exchange(0, std::memory_order_relaxed) : 0;
}

//==============================================================================
// MIDI devices
//==============================================================================
juce_c_result juce_c_midi_device_list_create(int32_t is_input, juce_c_midi_device_list** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    ScopedReservation reservation;
    if (! reservation.ok())
        return fail(JUCE_C_NOT_INITIALISED, "Call juce_c_initialise first");

    return guard([&]
    {
        auto list = std::make_unique<juce_c_midi_device_list>();
        list->devices = is_input != 0 ? juce::MidiInput::getAvailableDevices() : juce::MidiOutput::getAvailableDevices();
        *result = list.release();
        return ok();
    });
}

void juce_c_midi_device_list_destroy(juce_c_midi_device_list* list)
{
    delete list;
}

int32_t juce_c_midi_device_list_get_count(const juce_c_midi_device_list* list)
{
    return list != nullptr ? list->devices.size() : 0;
}

juce_c_result juce_c_midi_device_list_get_name(const juce_c_midi_device_list* list, int32_t index, char* buffer,
                                               size_t* buffer_size)
{
    if (list == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "list must not be null");
    if (! juce::isPositiveAndBelow(index, list->devices.size()))
        return fail(JUCE_C_OUT_OF_RANGE, "Device index is out of range");
    return guard([&] { return write_string(list->devices.getReference(index).name, buffer, buffer_size); });
}

juce_c_result juce_c_midi_device_list_get_identifier(const juce_c_midi_device_list* list, int32_t index,
                                                     char* buffer, size_t* buffer_size)
{
    if (list == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "list must not be null");
    if (! juce::isPositiveAndBelow(index, list->devices.size()))
        return fail(JUCE_C_OUT_OF_RANGE, "Device index is out of range");
    return guard([&] { return write_string(list->devices.getReference(index).identifier, buffer, buffer_size); });
}

juce_c_result juce_c_midi_get_default_device_identifier(int32_t is_input, char* buffer, size_t* buffer_size)
{
    ScopedReservation reservation;
    if (! reservation.ok())
        return fail(JUCE_C_NOT_INITIALISED, "Call juce_c_initialise first");
    return guard([&]
    {
        const auto info = is_input != 0 ? juce::MidiInput::getDefaultDevice() : juce::MidiOutput::getDefaultDevice();
        return write_string(info.identifier, buffer, buffer_size);
    });
}

juce_c_result juce_c_midi_input_open(const char* device_identifier, juce_c_midi_input_callback callback,
                                     void* user_data, juce_c_midi_input** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    if (device_identifier == nullptr || *device_identifier == '\0' || callback == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "device_identifier and callback are required");
    if (in_midi_callback > 0)
        return fail(JUCE_C_INVALID_STATE, midi_reentry_message);
    JUCE_C_REQUIRE(require_initialised());

    return guard([&]
    {
        const auto id = from_utf8(device_identifier);
        auto input = std::make_unique<juce_c_midi_input>(callback, user_data);
        if (! initialised) // re-check after registering the handle (see juce_c_shutdown)
            return fail(JUCE_C_NOT_INITIALISED, "JUCE was shut down");
        if (! midi_device_exists(true, id))
            return fail(JUCE_C_JUCE_ERROR, "No MIDI input with identifier " + id);
        input->device = juce::MidiInput::openDevice(id, &input->callback);
        if (input->device == nullptr)
            return fail(JUCE_C_JUCE_ERROR, "Could not open MIDI input " + id);
        *result = input.release();
        return ok();
    });
}

juce_c_result juce_c_midi_input_destroy(juce_c_midi_input* input)
{
    if (input == nullptr)
        return ok();
    if (in_midi_callback > 0)
        return fail(JUCE_C_INVALID_STATE, midi_reentry_message);
    ScopedFpMask fpMask;
    try
    {
        delete input;
    }
    catch (...)
    {
    }
    return ok();
}

juce_c_result juce_c_midi_input_start(juce_c_midi_input* input)
{
    if (input == nullptr || input->device == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "input must not be null");
    if (in_midi_callback > 0)
        return fail(JUCE_C_INVALID_STATE, midi_reentry_message);

    return guard([&]
    {
        input->callback.started.store(true, std::memory_order_release);
        input->device->start();
        input->started = true;
        return ok();
    });
}

juce_c_result juce_c_midi_input_stop(juce_c_midi_input* input)
{
    if (input == nullptr || input->device == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "input must not be null");
    if (in_midi_callback > 0)
        return fail(JUCE_C_INVALID_STATE, midi_reentry_message);

    return guard([&]
    {
        input->callback.started.store(false, std::memory_order_release); // before stop(): JUCE waits for an in-flight callback
        input->device->stop();
        input->started = false;
        return ok();
    });
}

juce_c_result juce_c_midi_input_get_name(const juce_c_midi_input* input, char* buffer, size_t* buffer_size)
{
    if (input == nullptr || input->device == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "input must not be null");
    return guard([&] { return write_string(input->device->getName(), buffer, buffer_size); });
}

juce_c_result juce_c_midi_output_open(const char* device_identifier, juce_c_midi_output** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    if (device_identifier == nullptr || *device_identifier == '\0')
        return fail(JUCE_C_INVALID_ARGUMENT, "device_identifier is required");
    JUCE_C_REQUIRE(require_initialised());

    return guard([&]
    {
        const auto id = from_utf8(device_identifier);
        // Some back ends (Windows MIDI Services) "open" unknown identifiers.
        auto output = std::make_unique<juce_c_midi_output>();
        if (! initialised) // re-check after registering the handle (see juce_c_shutdown)
            return fail(JUCE_C_NOT_INITIALISED, "JUCE was shut down");
        if (! midi_device_exists(false, id))
            return fail(JUCE_C_JUCE_ERROR, "No MIDI output with identifier " + id);
        {
            // Output open/close is serialised across threads.
            const std::lock_guard<std::mutex> lock(midi_output_mutex);
            output->device = juce::MidiOutput::openDevice(id);
        }
        if (output->device == nullptr)
            return fail(JUCE_C_JUCE_ERROR, "Could not open MIDI output " + id);
        output->device->startBackgroundThread();
        *result = output.release();
        return ok();
    });
}

void juce_c_midi_output_destroy(juce_c_midi_output* output)
{
    if (output == nullptr)
        return;
    ScopedFpMask fpMask;
    try
    {
        delete output;
    }
    catch (...)
    {
    }
}

juce_c_result juce_c_midi_output_get_name(const juce_c_midi_output* output, char* buffer, size_t* buffer_size)
{
    if (output == nullptr || output->device == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "output must not be null");
    return guard([&] { return write_string(output->device->getName(), buffer, buffer_size); });
}

juce_c_result juce_c_midi_output_send(juce_c_midi_output* output, const uint8_t* message, size_t message_size)
{
    if (output == nullptr || output->device == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "output must not be null");

    return guard([&]
    {
        juce::MidiMessage midi;
        JUCE_C_REQUIRE(make_midi_message(message, message_size, 0.0, midi));
        output->device->sendMessageNow(midi);
        return ok();
    });
}

juce_c_result juce_c_midi_output_send_block(juce_c_midi_output* output, const juce_c_midi_buffer* buffer,
                                            double start_time_ms, double sample_rate)
{
    if (output == nullptr || output->device == nullptr || buffer == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "output and buffer are required");
    if (! std::isfinite(sample_rate) || sample_rate < 1.0 || sample_rate > 10.0e6 || ! std::isfinite(start_time_ms))
        return fail(JUCE_C_INVALID_ARGUMENT, "sample_rate must be 1 Hz .. 10 MHz and start_time_ms finite");
    if (start_time_ms > juce::Time::getMillisecondCounterHiRes() + 86400000.0)
        return fail(JUCE_C_INVALID_ARGUMENT, "start_time_ms is more than a day in the future");
    // JUCE inserts each event into a sorted list: 65536 blocked the caller ~6 s.
    if (buffer->value.getNumEvents() > 8192)
        return fail(JUCE_C_INVALID_ARGUMENT, "At most 8192 events per send_block");
    // The last event's time, not just the start, must be within a day (position
    // 2^31 at 1 Hz scheduled 68 years ahead and sat in the queue for good).
    if (buffer->value.getNumEvents() > 0)
    {
        const double lastMs = (double) buffer->value.getLastEventTime() * 1000.0 / sample_rate;
        const double startMs = start_time_ms <= 0.0 ? juce::Time::getMillisecondCounterHiRes() : start_time_ms;
        if (startMs + lastMs > juce::Time::getMillisecondCounterHiRes() + 86400000.0)
            return fail(JUCE_C_INVALID_ARGUMENT, "The block's last event is more than a day in the future");
    }

    return guard([&]
    {
        // MidiOutput schedules on Time::getMillisecondCounter(), a different
        // clock from the hi-res one this API uses: translate.
        const double nowHiRes = juce::Time::getMillisecondCounterHiRes();
        const double startHiRes = start_time_ms <= 0.0 ? nowHiRes : start_time_ms;
        const double start = (double) juce::Time::getMillisecondCounter() + (startHiRes - nowHiRes);
        output->device->sendBlockOfMessages(buffer->value, std::max(1.0, start), sample_rate);
        return ok();
    });
}

juce_c_result juce_c_midi_output_clear_pending(juce_c_midi_output* output)
{
    if (output == nullptr || output->device == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "output must not be null");

    return guard([&]
    {
        output->device->clearAllPendingMessages();
        return ok();
    });
}

//==============================================================================
// Audio files
//==============================================================================
juce_c_result juce_c_audio_file_get_wildcard(char* buffer, size_t* buffer_size)
{
    return guard([&] { return write_string(format_manager().getWildcardForAllFormats(), buffer, buffer_size); });
}

juce_c_result juce_c_audio_file_reader_open(const char* path, juce_c_audio_file_reader** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    if (path == nullptr || *path == '\0')
        return fail(JUCE_C_INVALID_ARGUMENT, "path is required");

    return guard([&]
    {
        const auto file = resolve_path(path);
        if (! file.existsAsFile())
            return fail(JUCE_C_INVALID_ARGUMENT, "File not found: " + file.getFullPathName());

        auto reader = std::make_unique<juce_c_audio_file_reader>();
        juce::String problem;
        reader->reader.reset(create_reader(file, problem));
        if (reader->reader == nullptr)
            return fail(JUCE_C_JUCE_ERROR, (problem.isNotEmpty() ? "Malformed audio file (" + problem + "): "
                                                                 : juce::String("Unsupported or unreadable audio file: "))
                                               + file.getFullPathName());
        problem = implausible_format(*reader->reader);
        if (problem.isNotEmpty())
            return fail(JUCE_C_JUCE_ERROR, "Malformed audio file (" + problem + "): " + file.getFullPathName());

        // Compressed formats take their length from the header, which can claim far
        // more than the file holds. Cap it as load does, at 1024 samples per byte of file.
        auto& r = *reader->reader;
        const auto name = r.getFormatName();
        if (name != "WAV file" && name != "AIFF file")
        {
            const juce::int64 fileBytes = r.input != nullptr ? std::max<juce::int64>(1, r.input->getTotalLength()) : 1;
            const juce::int64 channelCount = std::max<juce::int64>(1, (juce::int64) r.numChannels);
            const juce::int64 maxFrames = std::max<juce::int64>(1 << 20, fileBytes * max_compression_ratio) / channelCount;
            if (r.lengthInSamples > maxFrames)
            {
                r.lengthInSamples = maxFrames;
                reader->lengthCapped = true;
            }
        }
        *result = reader.release();
        return ok();
    });
}

void juce_c_audio_file_reader_destroy(juce_c_audio_file_reader* reader)
{
    ScopedFpMask fpMask;
    delete reader;
}

double juce_c_audio_file_reader_get_sample_rate(const juce_c_audio_file_reader* reader)
{
    return reader != nullptr ? reader->reader->sampleRate : 0.0;
}

int32_t juce_c_audio_file_reader_get_channel_count(const juce_c_audio_file_reader* reader)
{
    return reader != nullptr ? (int32_t) reader->reader->numChannels : 0;
}

int64_t juce_c_audio_file_reader_get_length(const juce_c_audio_file_reader* reader)
{
    return reader != nullptr ? (int64_t) reader->reader->lengthInSamples : 0;
}

int32_t juce_c_audio_file_reader_get_bits_per_sample(const juce_c_audio_file_reader* reader)
{
    return reader != nullptr ? (int32_t) reader->reader->bitsPerSample : 0;
}

int32_t juce_c_audio_file_reader_is_floating_point(const juce_c_audio_file_reader* reader)
{
    return reader != nullptr && reader->reader->usesFloatingPointData ? 1 : 0;
}

juce_c_result juce_c_audio_file_reader_get_format_name(const juce_c_audio_file_reader* reader, char* buffer,
                                                       size_t* buffer_size)
{
    if (reader == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "reader must not be null");
    return guard([&] { return write_string(reader->reader->getFormatName(), buffer, buffer_size); });
}

juce_c_result juce_c_audio_file_reader_read(juce_c_audio_file_reader* reader, juce_c_audio_buffer* dest,
                                            int32_t dest_start_sample, int32_t sample_count,
                                            int64_t reader_start_sample)
{
    if (reader == nullptr || dest == nullptr || reader_start_sample < 0)
        return fail(JUCE_C_INVALID_ARGUMENT, "reader and dest are required; reader_start_sample must be >= 0");
    if (! valid_range(dest->value, dest_start_sample, sample_count))
        return fail(JUCE_C_OUT_OF_RANGE, "Destination range is out of bounds");

    return guard([&]
    {
        if (! read_into(*reader->reader, dest->value, dest_start_sample, sample_count, reader_start_sample))
            return fail(JUCE_C_JUCE_ERROR, "Read failed");
        return ok();
    });
}

juce_c_result juce_c_audio_file_load(const char* path, juce_c_audio_buffer** result, double* sample_rate)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;

    juce_c_audio_file_reader* reader = nullptr;
    JUCE_C_REQUIRE(juce_c_audio_file_reader_open(path, &reader));
    std::unique_ptr<juce_c_audio_file_reader> owner(reader);

    return guard([&]
    {
        auto& r = *owner->reader;
        juce::int64 frames = r.lengthInSamples;
        // Size of what was actually opened (not the path again: it may have changed).
        const juce::int64 openedBytes = r.input != nullptr ? std::max<juce::int64>(0, r.input->getTotalLength()) : 0;

        // A header can claim any length: for uncompressed formats it cannot hold more
        // frames than the file has bytes for, so a 44-byte "2-billion-frame" WAV loads
        // as the few frames it really contains instead of allocating gigabytes.
        const auto name = r.getFormatName();
        if (name == "WAV file" || name == "AIFF file")
        {
            const juce::int64 bytesPerFrame = juce::jmax<juce::int64>(1, (juce::int64) r.numChannels * r.bitsPerSample / 8);
            frames = juce::jmin(frames, openedBytes / bytesPerFrame + 1);
        }
        else
        {
            // Compressed formats (FLAC, Ogg, MP3, ...) also take their length from the
            // header, and decoders pad a short stream with silence, so a 42-byte FLAC
            // can claim 2^30 frames. Real codecs need well over a byte per 1024 samples
            // (FLAC digital silence: about 1 per 400), so anything denser is refused.
            const juce::int64 fileBytes = std::max<juce::int64>(1, openedBytes);
            const juce::int64 channelCount = std::max<juce::int64>(1, (juce::int64) r.numChannels);
            const juce::int64 maxSamples = std::max<juce::int64>(1 << 20, fileBytes * max_compression_ratio);
            if (owner->lengthCapped || frames > maxSamples / channelCount) // open already capped a lying header
                return fail(JUCE_C_OUT_OF_RANGE, "The file's header claims more audio than the file can hold; "
                                                 "read it in blocks with a reader instead");
        }

        const int channels = std::clamp((int) r.numChannels, 1, max_file_channels);
        if (frames > max_channel_samples || frames * channels > max_buffer_samples)
            return fail(JUCE_C_OUT_OF_RANGE, "File is too long to load into one buffer (more than 2^29 - 1 frames or 2^30 samples); "
                                             "read it in blocks with a reader instead");

        const int length = std::max(1, (int) frames);
        auto buffer = std::make_unique<juce_c_audio_buffer>(channels, length);
        if (! read_into(r, buffer->value, 0, (int) frames, 0))
            return fail(JUCE_C_JUCE_ERROR, "Read failed");

        if (sample_rate != nullptr)
            *sample_rate = r.sampleRate;
        *result = buffer.release();
        return ok();
    });
}

juce_c_result juce_c_audio_file_writer_create(const char* path, const char* format_name, double sample_rate,
                                              int32_t channel_count, int32_t bits_per_sample, int32_t quality_index,
                                              juce_c_audio_file_writer** result)
{
    if (result == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "result must not be null");
    *result = nullptr;
    if (path == nullptr || *path == '\0')
        return fail(JUCE_C_INVALID_ARGUMENT, "path is required");
    if (! std::isfinite(sample_rate) || sample_rate < 1.0 || sample_rate > 10.0e6)
        return fail(JUCE_C_INVALID_ARGUMENT, "sample_rate must be 1 Hz to 10 MHz");
    // 255, not 256: JUCE 8.0.6 AudioFormatWriter::writeFromFloatArrays NUL-terminates a
    // 256-entry channel table at [numChannels], a heap overflow for 256 channels.
    if (channel_count <= 0 || channel_count > max_writer_channels)
        return fail(JUCE_C_INVALID_ARGUMENT, "channel_count must be 1..255");

    return guard([&]
    {
        const auto file = resolve_path(path);
        auto formatText = from_utf8(format_name).trim().toLowerCase();
        if (formatText.isEmpty())
            formatText = file.getFileExtension().trimCharactersAtStart(".").toLowerCase();
        if (formatText == "aif")
            formatText = "aiff";
        if (formatText == "oga")
            formatText = "ogg";

        auto* format = format_manager().findFormatForFileExtension("." + formatText);
        if (format == nullptr || ! format->canHandleFile(juce::File("x." + formatText))
            || formatText == "mp3" || formatText == "wma")
            return fail(JUCE_C_INVALID_ARGUMENT, "Cannot write audio format: " + formatText);

        int bits = bits_per_sample;
        const auto depths = format->getPossibleBitDepths();
        if (depths.size() == 1)
            bits = depths[0]; // e.g. Ogg: depth is meaningless for lossy formats
        else if (! depths.contains(bits))
            return fail(JUCE_C_INVALID_ARGUMENT,
                        juce::String(bits_per_sample) + "-bit is not supported by " + format->getFormatName());

        const auto quality = std::max(0, (int) quality_index);

        // Dry run into memory, so a rejected configuration never touches an existing file.
        {
            auto probe = std::make_unique<juce::MemoryOutputStream>();
            std::unique_ptr<juce::AudioFormatWriter> test(
                format->createWriterFor(probe.get(), sample_rate, (unsigned int) channel_count, bits, {}, quality));
            if (test == nullptr)
                return fail(JUCE_C_INVALID_ARGUMENT, format->getFormatName() + " cannot write "
                                                         + juce::String(channel_count) + " channel(s) at "
                                                         + juce::String(sample_rate) + " Hz, " + juce::String(bits) + "-bit");
            probe.release(); // owned (and freed) by the test writer
        }

        auto stream = std::make_unique<juce::FileOutputStream>(file);
        if (! stream->openedOk())
            return fail(JUCE_C_JUCE_ERROR, "Cannot create " + file.getFullPathName());
        stream->setPosition(0);
        stream->truncate();

        std::unique_ptr<juce::AudioFormatWriter> writer(
            format->createWriterFor(stream.get(), sample_rate, (unsigned int) channel_count, bits, {}, quality));
        if (writer == nullptr)
            return fail(JUCE_C_JUCE_ERROR, format->getFormatName() + " cannot write with these settings");
        stream.release(); // now owned by the writer

        auto handle = std::make_unique<juce_c_audio_file_writer>();
        handle->flushable = formatText == "wav";
        handle->writer = std::move(writer);
        *result = handle.release();
        return ok();
    });
}

void juce_c_audio_file_writer_destroy(juce_c_audio_file_writer* writer)
{
    if (writer == nullptr)
        return;
    ScopedFpMask fpMask;
    try
    {
        delete writer;
    }
    catch (...)
    {
    }
}

static juce_c_result write_pointers(juce_c_audio_file_writer* writer, const float* const* channels, int sample_count)
{
    if (! writer->writer->writeFromFloatArrays(channels, (int) writer->writer->getNumChannels(), sample_count))
        return fail(JUCE_C_JUCE_ERROR, "Write failed");
    return ok();
}

juce_c_result juce_c_audio_file_writer_write_buffer(juce_c_audio_file_writer* writer,
                                                    const juce_c_audio_buffer* source, int32_t start_sample,
                                                    int32_t sample_count)
{
    if (writer == nullptr || source == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "writer and source are required");
    if (! valid_range(source->value, start_sample, sample_count))
        return fail(JUCE_C_OUT_OF_RANGE, "Sample range is out of bounds");
    const int fileChannels = (int) writer->writer->getNumChannels();
    if (source->value.getNumChannels() < fileChannels)
        return fail(JUCE_C_INVALID_ARGUMENT, "Source has fewer channels than the file");

    return guard([&]
    {
        const float* pointers[max_file_channels] = {};
        for (int ch = 0; ch < fileChannels; ++ch)
            pointers[ch] = source->value.getReadPointer(ch, start_sample);
        return write_pointers(writer, pointers, sample_count);
    });
}

juce_c_result juce_c_audio_file_writer_write_channels(juce_c_audio_file_writer* writer, const float* const* channels,
                                                      int32_t channel_count, int32_t sample_count)
{
    if (writer == nullptr || channels == nullptr || sample_count < 0)
        return fail(JUCE_C_INVALID_ARGUMENT, "writer and channels are required; sample_count must be >= 0");
    const int fileChannels = (int) writer->writer->getNumChannels();
    if (channel_count < fileChannels)
        return fail(JUCE_C_INVALID_ARGUMENT, "Fewer channels supplied than the file has");
    for (int ch = 0; ch < fileChannels; ++ch)
        if (channels[ch] == nullptr)
            return fail(JUCE_C_INVALID_ARGUMENT, "Channel pointer " + juce::String(ch) + " is null");

    return guard([&] { return write_pointers(writer, channels, sample_count); });
}

juce_c_result juce_c_audio_file_writer_flush(juce_c_audio_file_writer* writer)
{
    if (writer == nullptr)
        return fail(JUCE_C_INVALID_ARGUMENT, "writer must not be null");

    return guard([&]
    {
        if (writer->flushable && ! writer->writer->flush())
            return fail(JUCE_C_JUCE_ERROR, "Flush failed");
        return ok();
    });
}
}
