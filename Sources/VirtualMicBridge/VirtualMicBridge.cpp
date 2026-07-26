#include "VirtualMicBridge.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <new>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct alignas(64) VMSlot {
    std::atomic<uint64_t> sequence;
    std::atomic<uint32_t> generation;
    std::atomic<uint32_t> sampleBits;
    uint32_t reserved;
};

struct alignas(64) VMSharedRegion {
    uint64_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t reserved0;
    std::atomic<uint64_t> writeSequence;
    std::atomic<uint64_t> generationStartSequence;
    std::atomic<uint64_t> publishedFrames;
    std::atomic<uint64_t> silentFrames;
    std::atomic<uint64_t> disconnectCount;
    std::atomic<uint64_t> muteCount;
    std::atomic<uint64_t> controlGate;
    std::atomic<uint64_t> reserved1;
    VMSlot slots[1];
};

struct VMProducerHandle {
    int fd;
    size_t mappedBytes;
    VMSharedRegion *region;
};

struct VMConsumerHandle {
    int fd;
    size_t mappedBytes;
    const VMSharedRegion *region;
    uint64_t readCursor;
    uint32_t generation;
    uint64_t overrunCount;
    uint64_t underrunCount;
};

namespace {

constexpr uint64_t kMagic = 0x564D424249444745ULL;
constexpr uint32_t kVersion = 1;
constexpr uint32_t kMutedFlag = 1U << 0;
constexpr uint32_t kConnectedFlag = 1U << 1;
constexpr uint64_t kUnpublishedSequence = UINT64_MAX;

static_assert(sizeof(float) == sizeof(uint32_t), "Float32 contract required");
static_assert(std::atomic<uint32_t>::is_always_lock_free, "uint32 atomics must be lock-free");
static_assert(std::atomic<uint64_t>::is_always_lock_free, "uint64 atomics must be lock-free");
static_assert(offsetof(VMSharedRegion, slots) % alignof(VMSlot) == 0, "slot alignment");

bool isValidName(const char *shmName) {
    return shmName != nullptr && shmName[0] == '/' && shmName[1] != '\0';
}

bool validateAudioArguments(uint32_t sampleRate) {
    return sampleRate == VM_SAMPLE_RATE;
}

size_t regionSizeForCapacity(uint32_t capacityFrames) {
    if (capacityFrames == 0) {
        return 0;
    }
    return offsetof(VMSharedRegion, slots) + (sizeof(VMSlot) * static_cast<size_t>(capacityFrames));
}

uint32_t floatToBits(float sample) {
    uint32_t bits = 0;
    std::memcpy(&bits, &sample, sizeof(bits));
    return bits;
}

float bitsToFloat(uint32_t bits) {
    float sample = 0.0F;
    std::memcpy(&sample, &bits, sizeof(sample));
    return sample;
}

uint64_t packControlGate(uint32_t generation, uint32_t flags) {
    return (static_cast<uint64_t>(generation) << 32) | flags;
}

uint32_t unpackGeneration(uint64_t gate) {
    return static_cast<uint32_t>(gate >> 32);
}

uint32_t unpackFlags(uint64_t gate) {
    return static_cast<uint32_t>(gate & 0xFFFFFFFFULL);
}

void closeFdIfNeeded(int fd) {
    if (fd >= 0) {
        close(fd);
    }
}

void destroyProducerHandle(VMProducerHandle *producer) {
    if (producer == nullptr) {
        return;
    }
    if (producer->region != nullptr) {
        VMSharedRegion *region = producer->region;
        const uint64_t writeSequence = region->writeSequence.load(std::memory_order_acquire);
        const uint64_t currentGate = region->controlGate.load(std::memory_order_acquire);
        const uint32_t nextGeneration = unpackGeneration(currentGate) + 1U;
        region->generationStartSequence.store(writeSequence, std::memory_order_release);
        region->controlGate.store(packControlGate(nextGeneration, 0U), std::memory_order_release);
        munmap(region, producer->mappedBytes);
    }
    closeFdIfNeeded(producer->fd);
    delete producer;
}

void destroyConsumerHandle(VMConsumerHandle *consumer) {
    if (consumer == nullptr) {
        return;
    }
    if (consumer->region != nullptr) {
        munmap(const_cast<VMSharedRegion *>(consumer->region), consumer->mappedBytes);
    }
    closeFdIfNeeded(consumer->fd);
    delete consumer;
}

VMStatus createOrOpenProducerRegion(const char *shmName,
                                    size_t expectedBytes,
                                    int *outFd,
                                    VMSharedRegion **outRegion,
                                    size_t *outMappedBytes,
                                    bool *outCreated) {
    if (outFd == nullptr || outRegion == nullptr || outMappedBytes == nullptr || outCreated == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    bool created = false;
    int fd = shm_open(shmName, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) {
        created = true;
        if (ftruncate(fd, static_cast<off_t>(expectedBytes)) != 0) {
            close(fd);
            shm_unlink(shmName);
            return VM_STATUS_SYSTEM_ERROR;
        }
    } else if (errno == EEXIST) {
        fd = shm_open(shmName, O_RDWR, 0600);
        if (fd < 0) {
            return VM_STATUS_SYSTEM_ERROR;
        }
    } else {
        return VM_STATUS_SYSTEM_ERROR;
    }

    struct stat statBuffer {};
    if (fstat(fd, &statBuffer) != 0 || statBuffer.st_size <= 0) {
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return VM_STATUS_SYSTEM_ERROR;
    }

    void *mapping = mmap(nullptr,
                         static_cast<size_t>(statBuffer.st_size),
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED,
                         fd,
                         0);
    if (mapping == MAP_FAILED) {
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return VM_STATUS_SYSTEM_ERROR;
    }

    *outFd = fd;
    *outRegion = static_cast<VMSharedRegion *>(mapping);
    *outMappedBytes = static_cast<size_t>(statBuffer.st_size);
    *outCreated = created;
    return VM_STATUS_OK;
}

VMStatus openConsumerRegion(const char *shmName,
                            int *outFd,
                            VMSharedRegion **outRegion,
                            size_t *outMappedBytes) {
    if (outFd == nullptr || outRegion == nullptr || outMappedBytes == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    const int fd = shm_open(shmName, O_RDWR, 0600);
    if (fd < 0) {
        return VM_STATUS_SYSTEM_ERROR;
    }

    struct stat statBuffer {};
    if (fstat(fd, &statBuffer) != 0 || statBuffer.st_size <= 0) {
        close(fd);
        return VM_STATUS_SYSTEM_ERROR;
    }

    void *mapping = mmap(nullptr,
                         static_cast<size_t>(statBuffer.st_size),
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED,
                         fd,
                         0);
    if (mapping == MAP_FAILED) {
        close(fd);
        return VM_STATUS_SYSTEM_ERROR;
    }

    *outFd = fd;
    *outRegion = static_cast<VMSharedRegion *>(mapping);
    *outMappedBytes = static_cast<size_t>(statBuffer.st_size);
    return VM_STATUS_OK;
}

void initializeRegion(VMSharedRegion *region, uint32_t capacityFrames) {
    region->magic = kMagic;
    region->version = kVersion;
    region->sampleRate = VM_SAMPLE_RATE;
    region->channelCount = VM_CHANNELS;
    region->capacityFrames = capacityFrames;
    region->reserved0 = 0;
    region->writeSequence.store(0, std::memory_order_relaxed);
    region->generationStartSequence.store(0, std::memory_order_relaxed);
    region->publishedFrames.store(0, std::memory_order_relaxed);
    region->silentFrames.store(0, std::memory_order_relaxed);
    region->disconnectCount.store(0, std::memory_order_relaxed);
    region->muteCount.store(0, std::memory_order_relaxed);
    region->controlGate.store(packControlGate(1U, kConnectedFlag), std::memory_order_relaxed);
    region->reserved1.store(0, std::memory_order_relaxed);
    for (uint32_t index = 0; index < capacityFrames; ++index) {
        region->slots[index].sequence.store(kUnpublishedSequence, std::memory_order_relaxed);
        region->slots[index].generation.store(0, std::memory_order_relaxed);
        region->slots[index].sampleBits.store(floatToBits(0.0F), std::memory_order_relaxed);
        region->slots[index].reserved = 0;
    }
}

VMStatus validateRegion(const VMSharedRegion *region, size_t mappedBytes) {
    if (region == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (region->magic != kMagic || region->version != kVersion) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    if (region->sampleRate != VM_SAMPLE_RATE ||
        region->channelCount != VM_CHANNELS ||
        region->capacityFrames == 0) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    const size_t expectedBytes = regionSizeForCapacity(region->capacityFrames);
    if (expectedBytes == 0 || mappedBytes < expectedBytes) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    return VM_STATUS_OK;
}

VMSlot *slotForSequence(VMSharedRegion *region, uint64_t sequence) {
    return &region->slots[sequence % region->capacityFrames];
}

const VMSlot *slotForSequence(const VMSharedRegion *region, uint64_t sequence) {
    return &region->slots[sequence % region->capacityFrames];
}

VMStatus setControlFlags(VMSharedRegion *region, uint32_t expectedFlagMask, uint32_t desiredFlags, std::atomic<uint64_t> *counter) {
    const uint64_t currentGate = region->controlGate.load(std::memory_order_acquire);
    const uint32_t currentFlags = unpackFlags(currentGate);
    if ((currentFlags & expectedFlagMask) == (desiredFlags & expectedFlagMask)) {
        return VM_STATUS_OK;
    }

    const uint32_t nextFlags = (currentFlags & ~expectedFlagMask) | (desiredFlags & expectedFlagMask);
    const uint32_t nextGeneration = unpackGeneration(currentGate) + 1U;
    const uint64_t writeSequence = region->writeSequence.load(std::memory_order_acquire);
    region->generationStartSequence.store(writeSequence, std::memory_order_release);
    if (counter != nullptr) {
        counter->fetch_add(1, std::memory_order_acq_rel);
    }
    region->controlGate.store(packControlGate(nextGeneration, nextFlags), std::memory_order_release);
    return VM_STATUS_OK;
}

void fillProducerStats(const VMSharedRegion *region, VMBridgeStats *outStats) {
    const uint64_t writeSequence = region->writeSequence.load(std::memory_order_acquire);
    const uint64_t controlGate = region->controlGate.load(std::memory_order_acquire);
    outStats->writeSequence = writeSequence;
    outStats->generation = unpackGeneration(controlGate);
    outStats->publishedFrames = region->publishedFrames.load(std::memory_order_acquire);
    outStats->silentFrames = region->silentFrames.load(std::memory_order_acquire);
    outStats->overrunCount = 0;
    outStats->underrunCount = 0;
    outStats->disconnectCount = region->disconnectCount.load(std::memory_order_acquire);
    outStats->muteCount = region->muteCount.load(std::memory_order_acquire);
    outStats->capacityFrames = region->capacityFrames;
    outStats->availableFrames = static_cast<uint32_t>(std::min<uint64_t>(writeSequence, region->capacityFrames));
    outStats->isMuted = ((unpackFlags(controlGate) & kMutedFlag) != 0U) ? 1U : 0U;
    outStats->isConnected = ((unpackFlags(controlGate) & kConnectedFlag) != 0U) ? 1U : 0U;
}

void fillConsumerStats(const VMConsumerHandle *consumer, VMBridgeStats *outStats) {
    fillProducerStats(consumer->region, outStats);
    const uint64_t writeSequence = outStats->writeSequence;
    const uint64_t backlog = (writeSequence > consumer->readCursor) ? (writeSequence - consumer->readCursor) : 0;
    outStats->availableFrames = static_cast<uint32_t>(std::min<uint64_t>(backlog, consumer->region->capacityFrames));
    outStats->overrunCount = consumer->overrunCount;
    outStats->underrunCount = consumer->underrunCount;
}

} // namespace

extern "C" {

VMStatus VMSharedMemoryUnlink(const char *shmName) {
    if (!isValidName(shmName)) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (shm_unlink(shmName) != 0 && errno != ENOENT) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    return VM_STATUS_OK;
}

VMStatus VMProducerCreate(const char *shmName,
                          uint32_t capacityFrames,
                          uint32_t sampleRate,
                          VMProducerHandle **outProducer) {
    if (!isValidName(shmName) || outProducer == nullptr || capacityFrames == 0) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }

    const size_t expectedBytes = regionSizeForCapacity(capacityFrames);
    if (expectedBytes == 0) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    int fd = -1;
    VMSharedRegion *region = nullptr;
    size_t mappedBytes = 0;
    bool created = false;
    VMStatus status = createOrOpenProducerRegion(shmName,
                                                 expectedBytes,
                                                 &fd,
                                                 &region,
                                                 &mappedBytes,
                                                 &created);
    if (status != VM_STATUS_OK) {
        return status;
    }

    if (created) {
        initializeRegion(region, capacityFrames);
    }

    status = validateRegion(region, mappedBytes);
    if (status != VM_STATUS_OK || region->capacityFrames != capacityFrames) {
        munmap(region, mappedBytes);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return (status == VM_STATUS_OK) ? VM_STATUS_INVALID_ARGUMENT : status;
    }

    const uint64_t currentGate = region->controlGate.load(std::memory_order_acquire);
    const uint32_t nextGeneration = unpackGeneration(currentGate) + 1U;
    const uint64_t writeSequence = region->writeSequence.load(std::memory_order_acquire);
    region->generationStartSequence.store(writeSequence, std::memory_order_release);
    region->controlGate.store(packControlGate(nextGeneration, kConnectedFlag), std::memory_order_release);

    VMProducerHandle *producer = new (std::nothrow) VMProducerHandle{fd, mappedBytes, region};
    if (producer == nullptr) {
        munmap(region, mappedBytes);
        close(fd);
        return VM_STATUS_SYSTEM_ERROR;
    }

    *outProducer = producer;
    return VM_STATUS_OK;
}

void VMProducerDestroy(VMProducerHandle *producer) {
    destroyProducerHandle(producer);
}

VMStatus VMProducerSetMuted(VMProducerHandle *producer, bool muted) {
    if (producer == nullptr || producer->region == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    const uint32_t desiredFlags = muted ? kMutedFlag : 0U;
    return setControlFlags(producer->region, kMutedFlag, desiredFlags, &producer->region->muteCount);
}

VMStatus VMProducerDisconnect(VMProducerHandle *producer) {
    if (producer == nullptr || producer->region == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    return setControlFlags(producer->region, kConnectedFlag, 0U, &producer->region->disconnectCount);
}

VMStatus VMProducerWriteFrames(VMProducerHandle *producer,
                               const float *frames,
                               uint32_t frameCount,
                               uint32_t sampleRate,
                               uint32_t *framesWritten) {
    if (producer == nullptr || producer->region == nullptr || framesWritten == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }
    if (frameCount > 0 && frames == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    VMSharedRegion *region = producer->region;
    const uint64_t controlGate = region->controlGate.load(std::memory_order_acquire);
    const uint32_t generation = unpackGeneration(controlGate);
    const uint32_t flags = unpackFlags(controlGate);
    const bool shouldSilence = (flags & kConnectedFlag) == 0U || (flags & kMutedFlag) != 0U;
    const uint64_t baseSequence = region->writeSequence.load(std::memory_order_relaxed);

    for (uint32_t index = 0; index < frameCount; ++index) {
        VMSlot *slot = slotForSequence(region, baseSequence + index);
        const float sample = shouldSilence ? 0.0F : frames[index];
        slot->sampleBits.store(floatToBits(sample), std::memory_order_relaxed);
        slot->generation.store(generation, std::memory_order_relaxed);
        slot->sequence.store(baseSequence + index, std::memory_order_release);
    }

    region->writeSequence.store(baseSequence + frameCount, std::memory_order_release);
    region->publishedFrames.fetch_add(frameCount, std::memory_order_acq_rel);
    if (shouldSilence) {
        region->silentFrames.fetch_add(frameCount, std::memory_order_acq_rel);
    }

    *framesWritten = frameCount;
    return VM_STATUS_OK;
}

VMStatus VMProducerGetStats(const VMProducerHandle *producer, VMBridgeStats *outStats) {
    if (producer == nullptr || producer->region == nullptr || outStats == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    fillProducerStats(producer->region, outStats);
    return VM_STATUS_OK;
}

VMStatus VMConsumerCreate(const char *shmName,
                          uint32_t sampleRate,
                          VMConsumerHandle **outConsumer) {
    if (!isValidName(shmName) || outConsumer == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }

    int fd = -1;
    VMSharedRegion *region = nullptr;
    size_t mappedBytes = 0;
    VMStatus status = openConsumerRegion(shmName, &fd, &region, &mappedBytes);
    if (status != VM_STATUS_OK) {
        return status;
    }

    status = validateRegion(region, mappedBytes);
    if (status != VM_STATUS_OK) {
        munmap(region, mappedBytes);
        close(fd);
        return status;
    }

    const uint64_t controlGate = region->controlGate.load(std::memory_order_acquire);
    const uint64_t writeSequence = region->writeSequence.load(std::memory_order_acquire);
    VMConsumerHandle *consumer = new (std::nothrow) VMConsumerHandle{
        fd,
        mappedBytes,
        region,
        writeSequence,
        unpackGeneration(controlGate),
        0,
        0};
    if (consumer == nullptr) {
        munmap(region, mappedBytes);
        close(fd);
        return VM_STATUS_SYSTEM_ERROR;
    }

    *outConsumer = consumer;
    return VM_STATUS_OK;
}

void VMConsumerDestroy(VMConsumerHandle *consumer) {
    destroyConsumerHandle(consumer);
}

VMStatus VMConsumerReadFrames(VMConsumerHandle *consumer,
                              float *outFrames,
                              uint32_t frameCount,
                              uint32_t sampleRate,
                              uint32_t *framesRead) {
    if (consumer == nullptr || consumer->region == nullptr || outFrames == nullptr || framesRead == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }

    std::fill_n(outFrames, frameCount, 0.0F);

    const VMSharedRegion *region = consumer->region;
    const uint64_t controlGate = region->controlGate.load(std::memory_order_acquire);
    const uint32_t generation = unpackGeneration(controlGate);

    if (generation != consumer->generation) {
        const uint64_t startSequence = region->generationStartSequence.load(std::memory_order_acquire);
        consumer->readCursor = std::max(consumer->readCursor, startSequence);
        consumer->generation = generation;
    }

    const uint64_t writeSequence = region->writeSequence.load(std::memory_order_acquire);
    const uint64_t oldestSequence = (writeSequence > region->capacityFrames)
        ? (writeSequence - region->capacityFrames)
        : 0;
    if (consumer->readCursor < oldestSequence) {
        consumer->overrunCount += oldestSequence - consumer->readCursor;
        consumer->readCursor = oldestSequence;
    }

    const uint64_t availableFrames = (writeSequence > consumer->readCursor)
        ? (writeSequence - consumer->readCursor)
        : 0;
    const uint32_t readableFrames = static_cast<uint32_t>(std::min<uint64_t>(availableFrames, frameCount));
    uint32_t consumedFrames = 0;

    for (; consumedFrames < readableFrames; ++consumedFrames) {
        const uint64_t sequence = consumer->readCursor + consumedFrames;
        const VMSlot *slot = slotForSequence(region, sequence);
        const uint64_t firstSequence = slot->sequence.load(std::memory_order_acquire);
        if (firstSequence != sequence) {
            break;
        }
        const uint32_t slotGeneration = slot->generation.load(std::memory_order_relaxed);
        const uint32_t sampleBits = slot->sampleBits.load(std::memory_order_relaxed);
        const uint64_t secondSequence = slot->sequence.load(std::memory_order_acquire);
        if (secondSequence != sequence || slotGeneration != generation) {
            break;
        }
        outFrames[consumedFrames] = bitsToFloat(sampleBits);
    }

    consumer->readCursor += consumedFrames;
    if (frameCount > consumedFrames) {
        consumer->underrunCount += static_cast<uint64_t>(frameCount - consumedFrames);
    }

    *framesRead = frameCount;
    return VM_STATUS_OK;
}

VMStatus VMConsumerGetStats(const VMConsumerHandle *consumer, VMBridgeStats *outStats) {
    if (consumer == nullptr || consumer->region == nullptr || outStats == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    fillConsumerStats(consumer, outStats);
    return VM_STATUS_OK;
}

} // extern "C"
