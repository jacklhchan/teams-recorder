#include "VirtualMicBridge.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <type_traits>
#include <unistd.h>
#include <vector>

extern "C" int vm_c_header_smoke(void);

static_assert(std::is_standard_layout<VMBridgeStats>::value, "VMBridgeStats must stay C-compatible");
static_assert(std::is_trivially_copyable<VMBridgeStats>::value, "VMBridgeStats must remain POD-like");
static_assert(std::is_same<decltype(VMBridgeStats{}.isMuted), uint32_t>::value, "VMBridgeStats.isMuted must use fixed-width C type");
static_assert(std::is_same<decltype(VMBridgeStats{}.isConnected), uint32_t>::value, "VMBridgeStats.isConnected must use fixed-width C type");
static_assert(sizeof(float) == 4, "Float32 audio contract required");
static_assert(VM_SAMPLE_RATE == 48000, "Sample rate contract changed");
static_assert(VM_CHANNELS == 1, "Channel contract changed");

namespace {

void fail(const char *message, const char *file, int line) {
    std::fprintf(stderr, "%s:%d %s\n", file, line, message);
    std::exit(1);
}

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fail("CHECK failed: " #condition, __FILE__, __LINE__); \
        } \
    } while (false)

#define CHECK_STATUS(expression, expected) \
    do { \
        const VMStatus statusValue = (expression); \
        if (statusValue != (expected)) { \
            std::fprintf(stderr, "%s:%d unexpected status %d for %s\n", __FILE__, __LINE__, (int)statusValue, #expression); \
            std::exit(1); \
        } \
    } while (false)

struct ScopedBridge {
    std::string name;
    VMProducerHandle *producer = nullptr;
    VMConsumerHandle *consumerA = nullptr;
    VMConsumerHandle *consumerB = nullptr;

    explicit ScopedBridge(const char *bridgeName) : name(bridgeName) {
        CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
    }

    ~ScopedBridge() {
        VMConsumerDestroy(consumerB);
        VMConsumerDestroy(consumerA);
        VMProducerDestroy(producer);
        CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
    }
};

std::string makeUniqueBridgeName(const char *label) {
    static std::atomic<uint32_t> counter{0};
    std::ostringstream builder;
    builder << "/vm-" << label << "-" << static_cast<unsigned long long>(::getpid()) << "-" << counter.fetch_add(1, std::memory_order_relaxed);
    return builder.str();
}

void expectAllZero(const std::vector<float> &values) {
    for (float value : values) {
        CHECK(std::isfinite(value));
        CHECK(value == 0.0F);
    }
}

void expectSequence(const std::vector<float> &values, std::initializer_list<float> expected) {
    CHECK(values.size() == expected.size());
    size_t index = 0;
    for (float value : expected) {
        CHECK(std::isfinite(values[index]));
        CHECK(values[index] == value);
        ++index;
    }
}

void testInvalidArgumentsAndSampleRate() {
    const std::string name = makeUniqueBridgeName("invalid-args");
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
    VMProducerHandle *producer = nullptr;
    VMConsumerHandle *consumer = nullptr;
    uint32_t transferred = 0;
    std::array<float, 4> output{};

    CHECK_STATUS(VMProducerCreate(nullptr, 16U, VM_SAMPLE_RATE, &producer), VM_STATUS_INVALID_ARGUMENT);
    CHECK_STATUS(VMProducerCreate("vm-invalid", 16U, VM_SAMPLE_RATE, &producer), VM_STATUS_INVALID_ARGUMENT);
    CHECK_STATUS(VMProducerCreate(name.c_str(), 0U, VM_SAMPLE_RATE, &producer), VM_STATUS_INVALID_ARGUMENT);
    CHECK_STATUS(VMProducerCreate(name.c_str(), 16U, 44100U, &producer), VM_STATUS_INVALID_SAMPLE_RATE);
    CHECK_STATUS(VMConsumerCreate(name.c_str(), 44100U, &consumer), VM_STATUS_INVALID_SAMPLE_RATE);
    CHECK_STATUS(VMProducerCreate(name.c_str(), 16U, VM_SAMPLE_RATE, &producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(name.c_str(), VM_SAMPLE_RATE, &consumer), VM_STATUS_OK);
    CHECK_STATUS(VMProducerWriteFrames(producer, nullptr, 1U, VM_SAMPLE_RATE, &transferred), VM_STATUS_INVALID_ARGUMENT);
    CHECK_STATUS(VMConsumerReadFrames(consumer, output.data(), 4U, 44100U, &transferred), VM_STATUS_INVALID_SAMPLE_RATE);

    VMConsumerDestroy(consumer);
    VMProducerDestroy(producer);
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
}

void testEmptyReadZeroFills() {
    ScopedBridge bridge(makeUniqueBridgeName("empty").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    std::vector<float> output(8, 1.0F);
    uint32_t framesRead = 0;
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, output.data(), 8U, VM_SAMPLE_RATE, &framesRead), VM_STATUS_OK);
    CHECK(framesRead == 8U);
    expectAllZero(output);

    VMBridgeStats stats{};
    CHECK_STATUS(VMConsumerGetStats(bridge.consumerA, &stats), VM_STATUS_OK);
    CHECK(stats.underrunCount >= 8U);
}

void testEmptyReadDoesNotAdvancePastPublishedFrames() {
    ScopedBridge bridge(makeUniqueBridgeName("empty-cursor").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    std::vector<float> firstRead(4, 1.0F);
    uint32_t transferred = 0;
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, firstRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 4U);
    expectAllZero(firstRead);

    const std::array<float, 4> input{{9.0F, 10.0F, 11.0F, 12.0F}};
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, input.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 4U);

    std::vector<float> secondRead(4, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, secondRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 4U);
    expectSequence(secondRead, {9.0F, 10.0F, 11.0F, 12.0F});
}

void testPartialReadZeroFill() {
    ScopedBridge bridge(makeUniqueBridgeName("partial").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    const std::array<float, 4> input{{1.0F, 2.0F, 3.0F, 4.0F}};
    uint32_t framesWritten = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, input.data(), 4U, VM_SAMPLE_RATE, &framesWritten), VM_STATUS_OK);
    CHECK(framesWritten == 4U);

    std::vector<float> output(8, 0.0F);
    uint32_t framesRead = 0;
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, output.data(), 8U, VM_SAMPLE_RATE, &framesRead), VM_STATUS_OK);
    CHECK(framesRead == 8U);
    expectSequence(output, {1.0F, 2.0F, 3.0F, 4.0F, 0.0F, 0.0F, 0.0F, 0.0F});
}

void testPartialReadOnlyConsumesPublishedFrames() {
    ScopedBridge bridge(makeUniqueBridgeName("partial-cursor").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    const std::array<float, 4> firstInput{{1.0F, 2.0F, 3.0F, 4.0F}};
    const std::array<float, 4> secondInput{{5.0F, 6.0F, 7.0F, 8.0F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, firstInput.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);

    std::vector<float> firstRead(6, -1.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, firstRead.data(), 6U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 6U);
    expectSequence(firstRead, {1.0F, 2.0F, 3.0F, 4.0F, 0.0F, 0.0F});

    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, secondInput.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 4U);

    std::vector<float> secondRead(4, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, secondRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 4U);
    expectSequence(secondRead, {5.0F, 6.0F, 7.0F, 8.0F});
}

void testMuteUnmuteInvalidatesStaleAudio() {
    ScopedBridge bridge(makeUniqueBridgeName("mute").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    const std::array<float, 4> stale{{10.0F, 11.0F, 12.0F, 13.0F}};
    const std::array<float, 4> fresh{{20.0F, 21.0F, 22.0F, 23.0F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, stale.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK_STATUS(VMProducerSetMuted(bridge.producer, true), VM_STATUS_OK);

    std::vector<float> mutedRead(4, 1.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, mutedRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    expectAllZero(mutedRead);

    CHECK_STATUS(VMProducerSetMuted(bridge.producer, false), VM_STATUS_OK);
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, fresh.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);

    std::vector<float> freshRead(4, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, freshRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    expectSequence(freshRead, {20.0F, 21.0F, 22.0F, 23.0F});
}

void testDisconnectRestartInvalidatesStaleAudio() {
    ScopedBridge bridge(makeUniqueBridgeName("restart").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    const std::array<float, 4> stale{{30.0F, 31.0F, 32.0F, 33.0F}};
    const std::array<float, 4> fresh{{40.0F, 41.0F, 42.0F, 43.0F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, stale.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK_STATUS(VMProducerDisconnect(bridge.producer), VM_STATUS_OK);

    std::vector<float> disconnectedRead(4, 1.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, disconnectedRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    expectAllZero(disconnectedRead);

    VMProducerDestroy(bridge.producer);
    bridge.producer = nullptr;

    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, fresh.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);

    std::vector<float> freshRead(4, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, freshRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    expectSequence(freshRead, {40.0F, 41.0F, 42.0F, 43.0F});
}

void testMultiConsumerReadsIdenticalFrames() {
    ScopedBridge bridge(makeUniqueBridgeName("multi").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 32U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerB), VM_STATUS_OK);

    const std::array<float, 6> input{{1.5F, 2.5F, 3.5F, 4.5F, 5.5F, 6.5F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, input.data(), 6U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);

    std::vector<float> outputA(6, 0.0F);
    std::vector<float> outputB(6, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, outputA.data(), 6U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerB, outputB.data(), 6U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(outputA == outputB);
    expectSequence(outputA, {1.5F, 2.5F, 3.5F, 4.5F, 5.5F, 6.5F});
}

void testOverrunSelfAdvance() {
    ScopedBridge bridge(makeUniqueBridgeName("overrun").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 4U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    const std::array<float, 10> input{{1.0F, 2.0F, 3.0F, 4.0F, 5.0F, 6.0F, 7.0F, 8.0F, 9.0F, 10.0F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, input.data(), 10U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);

    std::vector<float> output(4, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, output.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    expectSequence(output, {7.0F, 8.0F, 9.0F, 10.0F});

    VMBridgeStats stats{};
    CHECK_STATUS(VMConsumerGetStats(bridge.consumerA, &stats), VM_STATUS_OK);
    CHECK(stats.overrunCount >= 6U);
}

void testWraparoundOrder() {
    ScopedBridge bridge(makeUniqueBridgeName("wrap").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 4U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    const std::array<float, 3> first{{1.0F, 2.0F, 3.0F}};
    const std::array<float, 3> second{{4.0F, 5.0F, 6.0F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, first.data(), 3U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);

    std::vector<float> firstRead(3, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, firstRead.data(), 3U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    expectSequence(firstRead, {1.0F, 2.0F, 3.0F});

    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, second.data(), 3U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    std::vector<float> secondRead(3, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, secondRead.data(), 3U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    expectSequence(secondRead, {4.0F, 5.0F, 6.0F});
}

void testConcurrentStressAndFiniteOutput() {
    ScopedBridge bridge(makeUniqueBridgeName("stress").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 4096U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerB), VM_STATUS_OK);

    constexpr uint32_t kTotalFrames = 1024U * 1024U;
    constexpr uint32_t kWriteChunk = 256U;
    constexpr uint32_t kReadChunk = 128U;

    std::atomic<bool> start{false};
    std::atomic<uint64_t> nonZeroA{0};
    std::atomic<uint64_t> nonZeroB{0};

    auto writer = std::thread([&]() {
        std::vector<float> input(kWriteChunk, 0.0F);
        while (!start.load(std::memory_order_acquire)) {
        }
        uint32_t written = 0;
        for (uint32_t base = 0; base < kTotalFrames; base += kWriteChunk) {
            for (uint32_t index = 0; index < kWriteChunk; ++index) {
                input[index] = static_cast<float>((base + index) % 97U) / 97.0F;
            }
            CHECK_STATUS(VMProducerWriteFrames(bridge.producer, input.data(), kWriteChunk, VM_SAMPLE_RATE, &written), VM_STATUS_OK);
            CHECK(written == kWriteChunk);
        }
    });

    auto readerFn = [&](VMConsumerHandle *consumer, std::atomic<uint64_t> &nonZeroCount) {
        std::vector<float> output(kReadChunk, -1.0F);
        uint32_t read = 0;
        while (!start.load(std::memory_order_acquire)) {
        }
        for (uint32_t total = 0; total < kTotalFrames; total += kReadChunk) {
            CHECK_STATUS(VMConsumerReadFrames(consumer, output.data(), kReadChunk, VM_SAMPLE_RATE, &read), VM_STATUS_OK);
            CHECK(read == kReadChunk);
            for (float sample : output) {
                CHECK(std::isfinite(sample));
                if (sample != 0.0F) {
                    nonZeroCount.fetch_add(1, std::memory_order_relaxed);
                }
            }
        }
    };

    auto readerA = std::thread(readerFn, bridge.consumerA, std::ref(nonZeroA));
    auto readerB = std::thread(readerFn, bridge.consumerB, std::ref(nonZeroB));

    start.store(true, std::memory_order_release);
    writer.join();
    readerA.join();
    readerB.join();

    CHECK(nonZeroA.load(std::memory_order_acquire) > 0U);
    CHECK(nonZeroB.load(std::memory_order_acquire) > 0U);

    VMBridgeStats stats{};
    CHECK_STATUS(VMConsumerGetStats(bridge.consumerA, &stats), VM_STATUS_OK);
    CHECK(stats.writeSequence >= kTotalFrames);
}

void testConcurrentMuteAndDisconnectPreserveBothTransitions() {
    for (uint32_t attempt = 0; attempt < 2000U; ++attempt) {
        ScopedBridge bridge(makeUniqueBridgeName("control-race").c_str());
        CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 64U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);

        std::atomic<bool> start{false};
        auto muteThread = std::thread([&]() {
            while (!start.load(std::memory_order_acquire)) {
            }
            CHECK_STATUS(VMProducerSetMuted(bridge.producer, true), VM_STATUS_OK);
        });
        auto disconnectThread = std::thread([&]() {
            while (!start.load(std::memory_order_acquire)) {
            }
            CHECK_STATUS(VMProducerDisconnect(bridge.producer), VM_STATUS_OK);
        });

        start.store(true, std::memory_order_release);
        muteThread.join();
        disconnectThread.join();

        VMBridgeStats stats{};
        CHECK_STATUS(VMProducerGetStats(bridge.producer, &stats), VM_STATUS_OK);
        CHECK(stats.isMuted == 1U);
        CHECK(stats.isConnected == 0U);
        CHECK(stats.muteCount == 1U);
        CHECK(stats.disconnectCount == 1U);
    }
}

void testSecondProducerIsRejectedForActiveRegion() {
    ScopedBridge bridge(makeUniqueBridgeName("owner-reject").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 64U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);

    VMProducerHandle *secondProducer = nullptr;
    const VMStatus status = VMProducerCreate(bridge.name.c_str(), 64U, VM_SAMPLE_RATE, &secondProducer);
    CHECK(status != VM_STATUS_OK);
    CHECK(secondProducer == nullptr);
}

void testForkedStaleProducerCannotWriteIntoNewOwnerRegion() {
    const std::string name = makeUniqueBridgeName("stale-owner");
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);

    VMProducerHandle *producer = nullptr;
    VMConsumerHandle *consumer = nullptr;
    CHECK_STATUS(VMProducerCreate(name.c_str(), 64U, VM_SAMPLE_RATE, &producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(name.c_str(), VM_SAMPLE_RATE, &consumer), VM_STATUS_OK);

    const pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        std::array<float, 2> samples{{91.0F, 92.0F}};
        uint32_t written = 0;
        sleep(1);
        const VMStatus staleStatus = VMProducerWriteFrames(producer, samples.data(), 2U, VM_SAMPLE_RATE, &written);
        VMProducerDestroy(producer);
        _exit(staleStatus == VM_STATUS_OK ? 1 : 0);
    }

    VMProducerDestroy(producer);
    producer = nullptr;

    CHECK_STATUS(VMProducerCreate(name.c_str(), 64U, VM_SAMPLE_RATE, &producer), VM_STATUS_OK);
    std::array<float, 2> fresh{{11.0F, 12.0F}};
    uint32_t written = 0;
    CHECK_STATUS(VMProducerWriteFrames(producer, fresh.data(), 2U, VM_SAMPLE_RATE, &written), VM_STATUS_OK);

    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);

    std::vector<float> output(2, 0.0F);
    uint32_t read = 0;
    CHECK_STATUS(VMConsumerReadFrames(consumer, output.data(), 2U, VM_SAMPLE_RATE, &read), VM_STATUS_OK);
    expectSequence(output, {11.0F, 12.0F});

    VMConsumerDestroy(consumer);
    VMProducerDestroy(producer);
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
}

void testForkedProducerConsumerRoundTrip() {
    const std::string name = makeUniqueBridgeName("fork-roundtrip");
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);

    VMProducerHandle *producer = nullptr;
    CHECK_STATUS(VMProducerCreate(name.c_str(), 256U, VM_SAMPLE_RATE, &producer), VM_STATUS_OK);

    const pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        VMConsumerHandle *consumer = nullptr;
        if (VMConsumerCreate(name.c_str(), VM_SAMPLE_RATE, &consumer) != VM_STATUS_OK) {
            _exit(2);
        }
        std::vector<float> output(32, 0.0F);
        uint32_t read = 0;
        for (int attempt = 0; attempt < 200; ++attempt) {
            if (VMConsumerReadFrames(consumer, output.data(), static_cast<uint32_t>(output.size()), VM_SAMPLE_RATE, &read) != VM_STATUS_OK) {
                VMConsumerDestroy(consumer);
                _exit(3);
            }
            bool anyNonZero = false;
            for (float sample : output) {
                anyNonZero = anyNonZero || (sample != 0.0F);
            }
            if (anyNonZero) {
                for (size_t index = 0; index < output.size(); ++index) {
                    if (output[index] != static_cast<float>(index + 1U)) {
                        VMConsumerDestroy(consumer);
                        _exit(4);
                    }
                }
                VMConsumerDestroy(consumer);
                _exit(0);
            }
            usleep(1000);
        }
        VMConsumerDestroy(consumer);
        _exit(5);
    }

    usleep(1000);
    std::vector<float> input(32, 0.0F);
    for (size_t index = 0; index < input.size(); ++index) {
        input[index] = static_cast<float>(index + 1U);
    }
    uint32_t written = 0;
    CHECK_STATUS(VMProducerWriteFrames(producer, input.data(), static_cast<uint32_t>(input.size()), VM_SAMPLE_RATE, &written), VM_STATUS_OK);
    CHECK(written == input.size());

    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);

    VMProducerDestroy(producer);
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
}

void testDisconnectDuringReadZeroesEntireRequest() {
    for (uint32_t attempt = 0; attempt < 200U; ++attempt) {
        ScopedBridge bridge(makeUniqueBridgeName("disconnect-read").c_str());
        constexpr uint32_t kFrames = 262144U;
        CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), kFrames, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
        CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

        std::vector<float> input(kFrames, 0.0F);
        for (uint32_t index = 0; index < kFrames; ++index) {
            input[index] = static_cast<float>(index + 1U);
        }
        uint32_t written = 0;
        CHECK_STATUS(VMProducerWriteFrames(bridge.producer, input.data(), kFrames, VM_SAMPLE_RATE, &written), VM_STATUS_OK);
        CHECK(written == kFrames);

        std::vector<float> output(kFrames, -1.0F);
        uint32_t read = 0;
        std::atomic<bool> started{false};
        std::thread reader([&]() {
            started.store(true, std::memory_order_release);
            CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, output.data(), kFrames, VM_SAMPLE_RATE, &read), VM_STATUS_OK);
        });

        while (!started.load(std::memory_order_acquire)) {
        }
        CHECK_STATUS(VMProducerDisconnect(bridge.producer), VM_STATUS_OK);
        reader.join();
        CHECK(read == kFrames);
        expectAllZero(output);
    }
}

void testStressDeliversExactOrderedSamplesAcrossWraparound() {
    ScopedBridge bridge(makeUniqueBridgeName("exact-stress").c_str());
    constexpr uint32_t kCapacity = 1024U;
    constexpr uint32_t kTotalFrames = 1024U * 1024U;
    constexpr uint32_t kChunk = 257U;
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), kCapacity, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerB), VM_STATUS_OK);

    std::vector<float> input(kChunk, 0.0F);
    std::vector<float> outputA(kChunk, 0.0F);
    std::vector<float> outputB(kChunk, 0.0F);
    uint32_t transferred = 0;
    uint32_t sequence = 1U;
    for (uint32_t remaining = kTotalFrames; remaining > 0; remaining -= std::min(remaining, kChunk)) {
        const uint32_t chunk = std::min(remaining, kChunk);
        for (uint32_t index = 0; index < chunk; ++index) {
            input[index] = static_cast<float>(sequence + index);
        }
        CHECK_STATUS(VMProducerWriteFrames(bridge.producer, input.data(), chunk, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
        CHECK(transferred == chunk);
        CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, outputA.data(), chunk, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
        CHECK(transferred == chunk);
        CHECK_STATUS(VMConsumerReadFrames(bridge.consumerB, outputB.data(), chunk, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
        CHECK(transferred == chunk);
        for (uint32_t index = 0; index < chunk; ++index) {
            CHECK(std::isfinite(outputA[index]));
            CHECK(std::isfinite(outputB[index]));
            CHECK(outputA[index] == static_cast<float>(sequence + index));
            CHECK(outputB[index] == static_cast<float>(sequence + index));
        }
        CHECK(outputA == outputB);
        sequence += chunk;
    }
}

} // namespace

int main() {
    CHECK(vm_c_header_smoke() >= 0);
    testInvalidArgumentsAndSampleRate();
    testEmptyReadZeroFills();
    testEmptyReadDoesNotAdvancePastPublishedFrames();
    testPartialReadZeroFill();
    testPartialReadOnlyConsumesPublishedFrames();
    testMuteUnmuteInvalidatesStaleAudio();
    testDisconnectRestartInvalidatesStaleAudio();
    testMultiConsumerReadsIdenticalFrames();
    testOverrunSelfAdvance();
    testWraparoundOrder();
    testConcurrentStressAndFiniteOutput();
    testConcurrentMuteAndDisconnectPreserveBothTransitions();
    testSecondProducerIsRejectedForActiveRegion();
    testForkedStaleProducerCannotWriteIntoNewOwnerRegion();
    testForkedProducerConsumerRoundTrip();
    testDisconnectDuringReadZeroesEntireRequest();
    testStressDeliversExactOrderedSamplesAcrossWraparound();
    return 0;
}
