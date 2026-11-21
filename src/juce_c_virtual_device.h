/*
    A virtual audio device type ("Virtual") for juce_c_audio.

    Uses: tests and CI machines without a sound card, headless servers, and
    offline rendering (non-real-time mode runs the callback as fast as the
    CPU allows). The device has 8 inputs and 8 outputs; inputs carry
    silence or a test tone; outputs are discarded.
*/
#pragma once

#include <juce_audio_devices/juce_audio_devices.h>

#include <atomic>
#include <cmath>
#include <vector>

namespace juce_c
{
struct VirtualDeviceOptions
{
    bool realtime = true;      // pace blocks at the sample rate
    int inputSignal = 0;       // 0 = silence, 1 = 440 Hz sine at 0.25, 2 = loopback of the previous block's outputs
};

class VirtualAudioIODevice final : public juce::AudioIODevice, private juce::Thread
{
public:
    static constexpr int numChannels = 8;

    VirtualAudioIODevice(const juce::String& name, VirtualDeviceOptions opts)
        : AudioIODevice(name, "Virtual"), Thread("juce_c virtual audio"), options(opts)
    {
    }

    ~VirtualAudioIODevice() override { close(); }

    juce::StringArray getOutputChannelNames() override { return names("Virtual Out "); }
    juce::StringArray getInputChannelNames() override { return names("Virtual In "); }
    juce::Array<double> getAvailableSampleRates() override { return { 22050.0, 44100.0, 48000.0, 88200.0, 96000.0, 192000.0 }; }
    juce::Array<int> getAvailableBufferSizes() override { return { 16, 32, 64, 128, 256, 480, 512, 1024, 2048, 4096 }; }
    int getDefaultBufferSize() override { return 512; }

    juce::String open(const juce::BigInteger& inputChannels, const juce::BigInteger& outputChannels,
                      double sampleRate, int bufferSizeSamples) override
    {
        close();
        activeInputs = inputChannels;
        activeInputs.setRange(numChannels, juce::jmax(0, activeInputs.getHighestBit() + 1 - numChannels), false);
        activeOutputs = outputChannels;
        activeOutputs.setRange(numChannels, juce::jmax(0, activeOutputs.getHighestBit() + 1 - numChannels), false);
        rate = sampleRate > 0 ? sampleRate : 48000.0;
        blockSize = bufferSizeSamples > 0 ? bufferSizeSamples : getDefaultBufferSize();

        inputData.assign((size_t) activeInputs.countNumberOfSetBits(), std::vector<float>((size_t) blockSize));
        outputData.assign((size_t) activeOutputs.countNumberOfSetBits(), std::vector<float>((size_t) blockSize));
        inputPointers.clear();
        outputPointers.clear();
        for (auto& channel : inputData)
            inputPointers.push_back(channel.data());
        for (auto& channel : outputData)
            outputPointers.push_back(channel.data());

        opened = true;
        return {};
    }

    void close() override
    {
        stop();
        opened = false;
    }

    bool isOpen() override { return opened; }

    void start(juce::AudioIODeviceCallback* newCallback) override
    {
        if (! opened || newCallback == nullptr)
            return;
        stop();
        newCallback->audioDeviceAboutToStart(this);
        {
            const juce::ScopedLock lock(callbackLock);
            callback = newCallback;
        }
        // Offline rendering needs no priority, and at the highest one several offline
        // devices starved the message thread (the only one allowed to close them).
        startThread(options.realtime ? juce::Thread::Priority::highest : juce::Thread::Priority::normal);
    }

    void stop() override
    {
        juce::AudioIODeviceCallback* old = nullptr;
        {
            const juce::ScopedLock lock(callbackLock);
            old = callback;
            callback = nullptr;
        }
        stopThread(-1); // wait for a running callback: a forced kill could leave its locks held
        if (old != nullptr)
            old->audioDeviceStopped();
    }

    bool isPlaying() override { return isThreadRunning(); }
    juce::String getLastError() override { return {}; }
    int getCurrentBufferSizeSamples() override { return blockSize; }
    double getCurrentSampleRate() override { return rate; }
    int getCurrentBitDepth() override { return 32; }
    juce::BigInteger getActiveOutputChannels() const override { return activeOutputs; }
    juce::BigInteger getActiveInputChannels() const override { return activeInputs; }
    int getOutputLatencyInSamples() override { return 0; }
    int getInputLatencyInSamples() override { return 0; }
    int getXRunCount() const noexcept override { return xruns.load(); }

    void simulateXRun() noexcept { ++xruns; }
    juce::int64 getBlocksProcessed() const noexcept { return blocksProcessed.load(); }

private:
    static juce::StringArray names(const juce::String& prefix)
    {
        juce::StringArray result;
        for (int i = 1; i <= numChannels; ++i)
            result.add(prefix + juce::String(i));
        return result;
    }

    void run() override
    {
        juce::AudioIODeviceCallbackContext context;
        double nextBlockTime = juce::Time::getMillisecondCounterHiRes();
        double phase = 0.0;

        while (! threadShouldExit())
        {
            if (options.inputSignal == 1)
            {
                const double delta = 2.0 * juce::MathConstants<double>::pi * 440.0 / rate;
                for (int i = 0; i < blockSize; ++i)
                {
                    const float s = (float) (0.25 * std::sin(phase));
                    phase += delta;
                    for (auto& channel : inputData)
                        channel[(size_t) i] = s;
                }
                phase = std::fmod(phase, 2.0 * juce::MathConstants<double>::pi);
            }

            {
                const juce::ScopedLock lock(callbackLock);
                if (callback != nullptr)
                    callback->audioDeviceIOCallbackWithContext(inputPointers.data(), (int) inputPointers.size(),
                                                              outputPointers.data(), (int) outputPointers.size(),
                                                              blockSize, context);
            }
            if (options.inputSignal == 2) // loopback: next block's inputs = this block's outputs
            {
                for (size_t ch = 0; ch < inputData.size(); ++ch)
                {
                    if (ch < outputData.size())
                        std::copy(outputData[ch].begin(), outputData[ch].end(), inputData[ch].begin());
                    else
                        std::fill(inputData[ch].begin(), inputData[ch].end(), 0.0f);
                }
            }
            ++blocksProcessed;

            if (options.realtime)
            {
                nextBlockTime += 1000.0 * blockSize / rate;
                // After a stall (slow callback, debugger) do not race to repay the backlog
                // at the highest priority: start counting again from now.
                const double behind = juce::Time::getMillisecondCounterHiRes() - nextBlockTime;
                if (behind > 4.0 * 1000.0 * blockSize / rate)
                    nextBlockTime = juce::Time::getMillisecondCounterHiRes();
                for (;;)
                {
                    const double remaining = nextBlockTime - juce::Time::getMillisecondCounterHiRes();
                    if (remaining <= 0.0 || threadShouldExit())
                        break;
                    if (remaining > 2.0)
                        wait(1);
                    else
                        juce::Thread::yield();
                }
            }
            else if ((blocksProcessed.load() & 63) == 0)
            {
                wait(1); // a real pause: yield() never gives way to lower-priority threads
            }
        }
    }

    VirtualDeviceOptions options;
    juce::BigInteger activeInputs, activeOutputs;
    double rate = 48000.0;
    int blockSize = 512;
    bool opened = false;
    std::vector<std::vector<float>> inputData, outputData;
    std::vector<const float*> inputPointers;
    std::vector<float*> outputPointers;
    juce::CriticalSection callbackLock;
    juce::AudioIODeviceCallback* callback = nullptr;
    std::atomic<int> xruns { 0 };
    std::atomic<juce::int64> blocksProcessed { 0 };
};

class VirtualAudioIODeviceType final : public juce::AudioIODeviceType
{
public:
    explicit VirtualAudioIODeviceType(VirtualDeviceOptions opts) : AudioIODeviceType("Virtual"), options(opts) {}

    void scanForDevices() override {}
    juce::StringArray getDeviceNames(bool) const override { return { "Virtual Device" }; }
    int getDefaultDeviceIndex(bool) const override { return 0; }
    int getIndexOfDevice(juce::AudioIODevice* device, bool) const override
    {
        return dynamic_cast<VirtualAudioIODevice*>(device) != nullptr ? 0 : -1;
    }
    bool hasSeparateInputsAndOutputs() const override { return false; }

    juce::AudioIODevice* createDevice(const juce::String& outputDeviceName, const juce::String& inputDeviceName) override
    {
        const auto name = outputDeviceName.isNotEmpty() ? outputDeviceName : inputDeviceName;
        if (name.isNotEmpty() && name != "Virtual Device")
            return nullptr;
        return new VirtualAudioIODevice("Virtual Device", options);
    }

private:
    VirtualDeviceOptions options;
};
} // namespace juce_c
