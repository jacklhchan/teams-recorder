#include "VirtualMicBridge.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <limits>
#include <sstream>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <type_traits>
#include <unistd.h>
#include <vector>

extern "C" int vm_c_header_smoke(void);

#ifdef VM_BRIDGE_TESTING
extern "C" {
typedef void (*VMBridgeTestHook)(void *);
void VMBridgeTestSetHook(uint32_t hookId, VMBridgeTestHook hook, void *context);
void VMBridgeTestSetForceFinalReadSnapshotFailure(bool enabled);
}
#endif

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

struct PipePair {
    int readFd = -1;
    int writeFd = -1;

    PipePair() {
        int fds[2] = {-1, -1};
        CHECK(pipe(fds) == 0);
        readFd = fds[0];
        writeFd = fds[1];
    }

    ~PipePair() {
        if (readFd >= 0) {
            close(readFd);
        }
        if (writeFd >= 0) {
            close(writeFd);
        }
    }

    PipePair(const PipePair &) = delete;
    PipePair &operator=(const PipePair &) = delete;
};

struct ScopedUmask {
    mode_t previous = 0;

    explicit ScopedUmask(mode_t mask) : previous(umask(mask)) {}

    ~ScopedUmask() {
        umask(previous);
    }

    ScopedUmask(const ScopedUmask &) = delete;
    ScopedUmask &operator=(const ScopedUmask &) = delete;
};

struct SharedMemoryStat {
    mode_t mode = 0;
    dev_t device = 0;
    ino_t inode = 0;
    off_t size = 0;
};

SharedMemoryStat sharedMemoryStat(const char *name) {
    const int fd = shm_open(name, O_RDONLY, 0);
    CHECK(fd >= 0);
    struct stat statBuffer {};
    CHECK(fstat(fd, &statBuffer) == 0);
    close(fd);
    SharedMemoryStat result;
    result.mode = statBuffer.st_mode & 0777;
    result.device = statBuffer.st_dev;
    result.inode = statBuffer.st_ino;
    result.size = statBuffer.st_size;
    return result;
}

mode_t sharedMemoryMode(const char *name) {
    return sharedMemoryStat(name).mode;
}

bool sameSharedMemoryIdentity(const SharedMemoryStat &lhs, const SharedMemoryStat &rhs) {
    return lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size;
}

void expectSharedMemoryMode(const char *name, mode_t expectedMode) {
    const mode_t actualMode = sharedMemoryMode(name);
    if (actualMode != expectedMode) {
        std::fprintf(stderr,
                     "shared memory mode for %s: expected 0%03o, actual 0%03o\n",
                     name,
                     static_cast<unsigned int>(expectedMode),
                     static_cast<unsigned int>(actualMode));
    }
    CHECK(actualMode == expectedMode);
}

void cloneAbiValidSharedMemoryWithMode(const char *targetName, uint32_t capacityFrames, mode_t mode) {
    ScopedBridge source(makeUniqueBridgeName("mode-source").c_str());
    CHECK_STATUS(VMProducerCreate(source.name.c_str(), capacityFrames, VM_SAMPLE_RATE, &source.producer), VM_STATUS_OK);
    VMProducerDestroy(source.producer);
    source.producer = nullptr;

    const int sourceFd = shm_open(source.name.c_str(), O_RDONLY, 0);
    CHECK(sourceFd >= 0);

    struct stat sourceStat {};
    CHECK(fstat(sourceFd, &sourceStat) == 0);
    CHECK(sourceStat.st_size > 0);

    const size_t byteCount = static_cast<size_t>(sourceStat.st_size);
    void *sourceMapping = mmap(nullptr, byteCount, PROT_READ, MAP_SHARED, sourceFd, 0);
    CHECK(sourceMapping != MAP_FAILED);

    int targetFd = -1;
    {
        ScopedUmask permissive(0);
        targetFd = shm_open(targetName, O_RDWR | O_CREAT | O_EXCL, mode);
    }
    CHECK(targetFd >= 0);
    CHECK(ftruncate(targetFd, sourceStat.st_size) == 0);

    void *targetMapping = mmap(nullptr, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, targetFd, 0);
    CHECK(targetMapping != MAP_FAILED);

    std::memcpy(targetMapping, sourceMapping, byteCount);

    CHECK(munmap(targetMapping, byteCount) == 0);
    CHECK(munmap(sourceMapping, byteCount) == 0);
    close(targetFd);
    close(sourceFd);
}

void writeByte(int fd, uint8_t value) {
    const ssize_t written = write(fd, &value, sizeof(value));
    CHECK(written == static_cast<ssize_t>(sizeof(value)));
}

uint8_t readByte(int fd) {
    uint8_t value = 0U;
    const ssize_t bytesRead = read(fd, &value, sizeof(value));
    CHECK(bytesRead == static_cast<ssize_t>(sizeof(value)));
    return value;
}

void writeStatus(int fd, VMStatus status) {
    const int value = static_cast<int>(status);
    const ssize_t written = write(fd, &value, sizeof(value));
    CHECK(written == static_cast<ssize_t>(sizeof(value)));
}

VMStatus readStatus(int fd) {
    int value = -1;
    const ssize_t bytesRead = read(fd, &value, sizeof(value));
    CHECK(bytesRead == static_cast<ssize_t>(sizeof(value)));
    return static_cast<VMStatus>(value);
}

template <typename Operation>
void expectOkWithBusyRetries(Operation operation) {
    for (uint32_t attempt = 0; attempt < 256U; ++attempt) {
        const VMStatus status = operation();
        if (status == VM_STATUS_OK) {
            return;
        }
        CHECK(status == VM_STATUS_BUSY);
        if ((attempt + 1U) % 8U == 0U) {
            std::this_thread::sleep_for(std::chrono::microseconds(50));
        } else {
            std::this_thread::yield();
        }
    }
    fail("operation stayed BUSY after bounded retries", __FILE__, __LINE__);
}

#ifdef VM_BRIDGE_TESTING
enum : uint32_t {
    VM_BRIDGE_TEST_HOOK_WRITE_AFTER_SNAPSHOT = 1U
};

struct BlockingHookContext {
    PipePair ready;
    PipePair resume;
};

void blockingWriteHook(void *context) {
    auto *hookContext = static_cast<BlockingHookContext *>(context);
    writeByte(hookContext->ready.writeFd, 1U);
    CHECK(readByte(hookContext->resume.readFd) == 1U);
}
#endif

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
            expectOkWithBusyRetries([&]() {
                return VMProducerSetMuted(bridge.producer, true);
            });
        });
        auto disconnectThread = std::thread([&]() {
            while (!start.load(std::memory_order_acquire)) {
            }
            expectOkWithBusyRetries([&]() {
                return VMProducerDisconnect(bridge.producer);
            });
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
    CHECK(status == VM_STATUS_BUSY);
    CHECK(secondProducer == nullptr);
}

void testProducerCreateSetsNewSharedMemoryModeToOwnerWriteWorldReadableUnderRestrictiveUmask() {
    ScopedBridge bridge(makeUniqueBridgeName("mode-new").c_str());

    VMStatus createStatus = VM_STATUS_SYSTEM_ERROR;
    {
        ScopedUmask restrictive(0077);
        createStatus = VMProducerCreate(bridge.name.c_str(), 64U, VM_SAMPLE_RATE, &bridge.producer);
    }

    CHECK_STATUS(createStatus, VM_STATUS_OK);
    expectSharedMemoryMode(bridge.name.c_str(), 0644);
}

void testProducerCreateRejectsExistingSharedMemoryWithWrongModeWithoutReplacingIt() {
    const mode_t existingModes[] = {0600, 0666};

    for (mode_t existingMode : existingModes) {
        ScopedBridge bridge(makeUniqueBridgeName("mode-reuse").c_str());
        cloneAbiValidSharedMemoryWithMode(bridge.name.c_str(), 64U, existingMode);
        expectSharedMemoryMode(bridge.name.c_str(), existingMode);
        const SharedMemoryStat before = sharedMemoryStat(bridge.name.c_str());

        VMProducerHandle *producer = nullptr;
        const VMStatus status = VMProducerCreate(bridge.name.c_str(), 64U, VM_SAMPLE_RATE, &producer);
        CHECK_STATUS(status, VM_STATUS_PERMISSION_ERROR);
        CHECK(producer == nullptr);

        const SharedMemoryStat after = sharedMemoryStat(bridge.name.c_str());
        CHECK(after.mode == existingMode);
        CHECK(sameSharedMemoryIdentity(before, after));
    }
}

void testForkInheritedProducerImmediatelyReturnsBusy() {
    const std::string name = makeUniqueBridgeName("forkinh");
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);

    VMProducerHandle *producer = nullptr;
    VMConsumerHandle *consumer = nullptr;
    CHECK_STATUS(VMProducerCreate(name.c_str(), 64U, VM_SAMPLE_RATE, &producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(name.c_str(), VM_SAMPLE_RATE, &consumer), VM_STATUS_OK);

    PipePair childStatus;
    const pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        std::array<float, 2> samples{{91.0F, 92.0F}};
        uint32_t written = 0;
        close(childStatus.readFd);
        const VMStatus status = VMProducerWriteFrames(producer, samples.data(), 2U, VM_SAMPLE_RATE, &written);
        writeStatus(childStatus.writeFd, status);
        _exit(0);
    }

    close(childStatus.writeFd);
    childStatus.writeFd = -1;
    CHECK(readStatus(childStatus.readFd) == VM_STATUS_BUSY);

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
    const std::string name = makeUniqueBridgeName("forkrt");
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);

    VMProducerHandle *producer = nullptr;
    CHECK_STATUS(VMProducerCreate(name.c_str(), 256U, VM_SAMPLE_RATE, &producer), VM_STATUS_OK);

    PipePair childReady;
    PipePair parentWrote;
    const pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(childReady.readFd);
        close(parentWrote.writeFd);
        VMConsumerHandle *consumer = nullptr;
        if (VMConsumerCreate(name.c_str(), VM_SAMPLE_RATE, &consumer) != VM_STATUS_OK) {
            _exit(2);
        }
        writeByte(childReady.writeFd, 1U);
        CHECK(readByte(parentWrote.readFd) == 1U);

        std::vector<float> output(32, 0.0F);
        uint32_t read = 0;
        if (VMConsumerReadFrames(consumer, output.data(), static_cast<uint32_t>(output.size()), VM_SAMPLE_RATE, &read) != VM_STATUS_OK) {
            VMConsumerDestroy(consumer);
            _exit(3);
        }
        if (read != output.size()) {
            VMConsumerDestroy(consumer);
            _exit(4);
        }
        for (size_t index = 0; index < output.size(); ++index) {
            if (output[index] != static_cast<float>(index + 1U)) {
                VMConsumerDestroy(consumer);
                _exit(5);
            }
        }
        VMConsumerDestroy(consumer);
        _exit(0);
    }

    close(childReady.writeFd);
    childReady.writeFd = -1;
    close(parentWrote.readFd);
    parentWrote.readFd = -1;
    CHECK(readByte(childReady.readFd) == 1U);

    std::vector<float> input(32, 0.0F);
    for (size_t index = 0; index < input.size(); ++index) {
        input[index] = static_cast<float>(index + 1U);
    }
    uint32_t written = 0;
    CHECK_STATUS(VMProducerWriteFrames(producer, input.data(), static_cast<uint32_t>(input.size()), VM_SAMPLE_RATE, &written), VM_STATUS_OK);
    CHECK(written == input.size());
    writeByte(parentWrote.writeFd, 1U);

    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);

    VMProducerDestroy(producer);
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
}

#ifdef VM_BRIDGE_TESTING
void testActiveWriterMakesControlTransitionReturnBusyUntilWriterCompletes() {
    ScopedBridge bridge(makeUniqueBridgeName("wrctl").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 64U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    BlockingHookContext hookContext;

    const std::array<float, 4> samples{{1.0F, 2.0F, 3.0F, 4.0F}};
    uint32_t written = 0;
    VMStatus writeStatus = VM_STATUS_SYSTEM_ERROR;
    VMBridgeTestSetHook(VM_BRIDGE_TEST_HOOK_WRITE_AFTER_SNAPSHOT, blockingWriteHook, &hookContext);
    std::thread writer([&]() {
        writeStatus = VMProducerWriteFrames(bridge.producer, samples.data(), 4U, VM_SAMPLE_RATE, &written);
    });

    CHECK(readByte(hookContext.ready.readFd) == 1U);
    CHECK(VMProducerSetMuted(bridge.producer, true) == VM_STATUS_BUSY);
    writeByte(hookContext.resume.writeFd, 1U);
    writer.join();
    VMBridgeTestSetHook(VM_BRIDGE_TEST_HOOK_WRITE_AFTER_SNAPSHOT, nullptr, nullptr);
    CHECK(writeStatus == VM_STATUS_OK);
    CHECK(written == 4U);

    CHECK_STATUS(VMProducerSetMuted(bridge.producer, true), VM_STATUS_OK);
    std::vector<float> output(4, -1.0F);
    uint32_t read = 0;
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, output.data(), 4U, VM_SAMPLE_RATE, &read), VM_STATUS_OK);
    CHECK(read == 4U);
    expectAllZero(output);
}

void testFinalReadSnapshotFailureZeroesOutputAndDoesNotAdvanceCursor() {
    ScopedBridge bridge(makeUniqueBridgeName("rdfail").c_str());
    CHECK_STATUS(VMProducerCreate(bridge.name.c_str(), 64U, VM_SAMPLE_RATE, &bridge.producer), VM_STATUS_OK);
    CHECK_STATUS(VMConsumerCreate(bridge.name.c_str(), VM_SAMPLE_RATE, &bridge.consumerA), VM_STATUS_OK);

    const std::array<float, 4> samples{{21.0F, 22.0F, 23.0F, 24.0F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(bridge.producer, samples.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);

    VMBridgeTestSetForceFinalReadSnapshotFailure(true);
    std::vector<float> failedRead(4, -1.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, failedRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    VMBridgeTestSetForceFinalReadSnapshotFailure(false);
    CHECK(transferred == 4U);
    expectAllZero(failedRead);

    std::vector<float> retryRead(4, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(bridge.consumerA, retryRead.data(), 4U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 4U);
    expectSequence(retryRead, {21.0F, 22.0F, 23.0F, 24.0F});
}
#endif

void testProducerCrashAllowsRestartAndInvalidatesOldSpeech() {
    const std::string name = makeUniqueBridgeName("crash");
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);

    PipePair childCreated;
    PipePair parentConsumerReady;
    PipePair childWrote;
    const pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(childCreated.readFd);
        close(parentConsumerReady.writeFd);
        close(childWrote.readFd);

        VMProducerHandle *producer = nullptr;
        if (VMProducerCreate(name.c_str(), 64U, VM_SAMPLE_RATE, &producer) != VM_STATUS_OK) {
            _exit(2);
        }
        writeByte(childCreated.writeFd, 1U);
        CHECK(readByte(parentConsumerReady.readFd) == 1U);

        const std::array<float, 2> stale{{70.0F, 71.0F}};
        uint32_t written = 0;
        if (VMProducerWriteFrames(producer, stale.data(), 2U, VM_SAMPLE_RATE, &written) != VM_STATUS_OK || written != 2U) {
            _exit(3);
        }
        writeByte(childWrote.writeFd, 1U);
        _exit(0);
    }

    close(childCreated.writeFd);
    childCreated.writeFd = -1;
    close(parentConsumerReady.readFd);
    parentConsumerReady.readFd = -1;
    close(childWrote.writeFd);
    childWrote.writeFd = -1;

    CHECK(readByte(childCreated.readFd) == 1U);
    VMConsumerHandle *consumer = nullptr;
    CHECK_STATUS(VMConsumerCreate(name.c_str(), VM_SAMPLE_RATE, &consumer), VM_STATUS_OK);
    writeByte(parentConsumerReady.writeFd, 1U);
    CHECK(readByte(childWrote.readFd) == 1U);

    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);

    VMProducerHandle *producer = nullptr;
    CHECK_STATUS(VMProducerCreate(name.c_str(), 64U, VM_SAMPLE_RATE, &producer), VM_STATUS_OK);
    const std::array<float, 2> fresh{{80.0F, 81.0F}};
    uint32_t transferred = 0;
    CHECK_STATUS(VMProducerWriteFrames(producer, fresh.data(), 2U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 2U);

    std::vector<float> output(2, 0.0F);
    CHECK_STATUS(VMConsumerReadFrames(consumer, output.data(), 2U, VM_SAMPLE_RATE, &transferred), VM_STATUS_OK);
    CHECK(transferred == 2U);
    expectSequence(output, {80.0F, 81.0F});

    VMConsumerDestroy(consumer);
    VMProducerDestroy(producer);
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);
}

void testTruncatedSharedMemoryReturnsAbiMismatchWithoutSignal() {
    const std::string name = makeUniqueBridgeName("truncated");
    CHECK_STATUS(VMSharedMemoryUnlink(name.c_str()), VM_STATUS_OK);

    int fd = -1;
    {
        ScopedUmask permissive(0);
        fd = shm_open(name.c_str(), O_RDWR | O_CREAT | O_EXCL, 0644);
    }
    CHECK(fd >= 0);
    CHECK(ftruncate(fd, 1) == 0);
    close(fd);

    PipePair childStatus;
    const pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(childStatus.readFd);
        VMConsumerHandle *consumer = nullptr;
        const VMStatus consumerStatus = VMConsumerCreate(name.c_str(), VM_SAMPLE_RATE, &consumer);
        VMConsumerDestroy(consumer);
        if (consumerStatus != VM_STATUS_ABI_MISMATCH) {
            writeStatus(childStatus.writeFd, consumerStatus);
            _exit(2);
        }

        VMProducerHandle *producer = nullptr;
        const VMStatus producerStatus = VMProducerCreate(name.c_str(), 64U, VM_SAMPLE_RATE, &producer);
        VMProducerDestroy(producer);
        writeStatus(childStatus.writeFd, producerStatus);
        _exit(producerStatus == VM_STATUS_ABI_MISMATCH ? 0 : 3);
    }

    close(childStatus.writeFd);
    childStatus.writeFd = -1;
    CHECK(readStatus(childStatus.readFd) == VM_STATUS_ABI_MISMATCH);

    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status));
    CHECK(WEXITSTATUS(status) == 0);
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
    constexpr uint32_t kTotalFrames = 1000000U;
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
    testProducerCreateSetsNewSharedMemoryModeToOwnerWriteWorldReadableUnderRestrictiveUmask();
    testProducerCreateRejectsExistingSharedMemoryWithWrongModeWithoutReplacingIt();
    testForkInheritedProducerImmediatelyReturnsBusy();
    testForkedProducerConsumerRoundTrip();
#ifdef VM_BRIDGE_TESTING
    testActiveWriterMakesControlTransitionReturnBusyUntilWriterCompletes();
    testFinalReadSnapshotFailureZeroesOutputAndDoesNotAdvanceCursor();
#endif
    testProducerCrashAllowsRestartAndInvalidatesOldSpeech();
    testTruncatedSharedMemoryReturnsAbiMismatchWithoutSignal();
    testDisconnectDuringReadZeroesEntireRequest();
    testStressDeliversExactOrderedSamplesAcrossWraparound();
    return 0;
}
