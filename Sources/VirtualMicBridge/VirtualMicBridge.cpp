#include "VirtualMicBridge.h"

#include <algorithm>
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
    uint64_t version;
    uint64_t sequence;
    uint32_t generation;
    uint32_t sampleBits;
    uint32_t reserved[10];
};

struct alignas(64) VMSharedRegion {
    uint64_t magic;
    uint32_t abiVersion;
    uint32_t headerBytes;
    uint64_t totalBytes;
    uint32_t slotBytes;
    uint32_t slotStride;
    uint32_t slotAlignment;
    uint32_t capacityFrames;
    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t reserved0;
    uint32_t reserved1;
    uint64_t writeSequence;
    uint64_t generationStartSequence;
    uint64_t publishedFrames;
    uint64_t silentFrames;
    uint64_t disconnectCount;
    uint64_t muteCount;
    uint64_t ownerEpoch;
    uint64_t ownerToken;
    uint32_t ownerActive;
    uint32_t reserved2;
    uint64_t controlVersion;
    uint64_t controlGate;
    uint64_t reserved3[6];
    VMSlot slots[1];
};

struct VMProducerHandle {
    int fd;
    size_t mappedBytes;
    VMSharedRegion *region;
    uint64_t ownerToken;
    uint64_t ownerEpoch;
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
constexpr uint32_t kAbiVersion = 2U;
constexpr uint32_t kMutedFlag = 1U << 0;
constexpr uint32_t kConnectedFlag = 1U << 1;
constexpr uint32_t kMaxStableReadAttempts = 4U;

static_assert(sizeof(float) == sizeof(uint32_t), "Float32 contract required");
static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0), "uint32 shared atomics must be lock-free");
static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0), "uint64 shared atomics must be lock-free");
static_assert(sizeof(VMSlot) == 64U, "slot ABI size changed");
static_assert(alignof(VMSlot) == 64U, "slot ABI alignment changed");
static_assert((offsetof(VMSharedRegion, slots) % alignof(VMSlot)) == 0U, "slot ABI alignment changed");

template <typename T>
T atomicLoad(const T *ptr, int memoryOrder) {
    T value{};
    __atomic_load(ptr, &value, memoryOrder);
    return value;
}

template <typename T>
void atomicStore(T *ptr, T value, int memoryOrder) {
    __atomic_store(ptr, &value, memoryOrder);
}

template <typename T>
bool atomicCompareExchange(T *ptr, T *expected, T desired, int successOrder, int failureOrder) {
    return __atomic_compare_exchange(ptr, expected, &desired, false, successOrder, failureOrder);
}

template <typename T>
T atomicFetchAdd(T *ptr, T delta, int memoryOrder) {
    return __atomic_fetch_add(ptr, delta, memoryOrder);
}

bool isValidName(const char *shmName) {
    return shmName != nullptr && shmName[0] == '/' && shmName[1] != '\0';
}

bool validateAudioArguments(uint32_t sampleRate) {
    return sampleRate == VM_SAMPLE_RATE;
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
    return (static_cast<uint64_t>(generation) << 32) | static_cast<uint64_t>(flags);
}

uint32_t unpackGeneration(uint64_t gate) {
    return static_cast<uint32_t>(gate >> 32);
}

uint32_t unpackFlags(uint64_t gate) {
    return static_cast<uint32_t>(gate & 0xFFFFFFFFULL);
}

bool checkedAddU64(uint64_t lhs, uint64_t rhs, uint64_t *outValue) {
    if (outValue == nullptr || lhs > UINT64_MAX - rhs) {
        return false;
    }
    *outValue = lhs + rhs;
    return true;
}

bool checkedAddSize(size_t lhs, size_t rhs, size_t *outValue) {
    if (outValue == nullptr || lhs > SIZE_MAX - rhs) {
        return false;
    }
    *outValue = lhs + rhs;
    return true;
}

bool checkedMultiplySize(size_t lhs, size_t rhs, size_t *outValue) {
    if (outValue == nullptr || lhs == 0U || rhs == 0U) {
        if (outValue != nullptr) {
            *outValue = 0U;
        }
        return outValue != nullptr;
    }
    if (lhs > SIZE_MAX / rhs) {
        return false;
    }
    *outValue = lhs * rhs;
    return true;
}

size_t regionSizeForCapacity(uint32_t capacityFrames) {
    if (capacityFrames == 0U) {
        return 0U;
    }
    size_t slotsBytes = 0U;
    size_t totalBytes = 0U;
    if (!checkedMultiplySize(sizeof(VMSlot), static_cast<size_t>(capacityFrames), &slotsBytes) ||
        !checkedAddSize(offsetof(VMSharedRegion, slots), slotsBytes, &totalBytes)) {
        return 0U;
    }
    return totalBytes;
}

void closeFdIfNeeded(int fd) {
    if (fd >= 0) {
        close(fd);
    }
}

uint64_t makeOwnerToken() {
    static uint64_t processCounter = 0U;
    processCounter += 1U;
    return (static_cast<uint64_t>(getpid()) << 32) ^ processCounter ^ 0x9E3779B97F4A7C15ULL;
}

VMSlot *slotForSequence(VMSharedRegion *region, uint64_t sequence) {
    return &region->slots[sequence % region->capacityFrames];
}

const VMSlot *slotForSequence(const VMSharedRegion *region, uint64_t sequence) {
    return &region->slots[sequence % region->capacityFrames];
}

bool tryReadControlSnapshot(const VMSharedRegion *region,
                            uint64_t *outGate,
                            uint64_t *outStartSequence,
                            uint32_t maxAttempts) {
    if (region == nullptr || outGate == nullptr || outStartSequence == nullptr) {
        return false;
    }

    for (uint32_t attempt = 0; attempt < maxAttempts; ++attempt) {
        const uint64_t versionBefore = atomicLoad(&region->controlVersion, __ATOMIC_ACQUIRE);
        if ((versionBefore & 1U) != 0U) {
            continue;
        }
        const uint64_t gate = atomicLoad(&region->controlGate, __ATOMIC_ACQUIRE);
        const uint64_t startSequence = atomicLoad(&region->generationStartSequence, __ATOMIC_ACQUIRE);
        const uint64_t versionAfter = atomicLoad(&region->controlVersion, __ATOMIC_ACQUIRE);
        if (versionBefore == versionAfter && (versionAfter & 1U) == 0U) {
            *outGate = gate;
            *outStartSequence = startSequence;
            return true;
        }
    }

    return false;
}

bool readControlSnapshotBlocking(const VMSharedRegion *region,
                                 uint64_t *outGate,
                                 uint64_t *outStartSequence) {
    for (uint32_t attempt = 0; attempt < 1024U; ++attempt) {
        if (tryReadControlSnapshot(region, outGate, outStartSequence, kMaxStableReadAttempts)) {
            return true;
        }
    }
    return false;
}

VMStatus validateRegion(const VMSharedRegion *region, size_t mappedBytes) {
    if (region == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (region->magic != kMagic ||
        region->abiVersion != kAbiVersion ||
        region->headerBytes != offsetof(VMSharedRegion, slots) ||
        region->slotBytes != sizeof(VMSlot) ||
        region->slotStride != sizeof(VMSlot) ||
        region->slotAlignment != alignof(VMSlot) ||
        region->sampleRate != VM_SAMPLE_RATE ||
        region->channelCount != VM_CHANNELS ||
        region->capacityFrames == 0U) {
        return VM_STATUS_ABI_MISMATCH;
    }

    const size_t expectedBytes = regionSizeForCapacity(region->capacityFrames);
    if (expectedBytes == 0U ||
        region->totalBytes != expectedBytes ||
        mappedBytes < expectedBytes) {
        return VM_STATUS_ABI_MISMATCH;
    }

    return VM_STATUS_OK;
}

void initializeRegion(VMSharedRegion *region, size_t mappedBytes, size_t totalBytes, uint32_t capacityFrames) {
    std::memset(region, 0, mappedBytes);
    region->magic = kMagic;
    region->abiVersion = kAbiVersion;
    region->headerBytes = static_cast<uint32_t>(offsetof(VMSharedRegion, slots));
    region->totalBytes = totalBytes;
    region->slotBytes = sizeof(VMSlot);
    region->slotStride = sizeof(VMSlot);
    region->slotAlignment = alignof(VMSlot);
    region->capacityFrames = capacityFrames;
    region->sampleRate = VM_SAMPLE_RATE;
    region->channelCount = VM_CHANNELS;
    atomicStore(&region->writeSequence, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->generationStartSequence, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->publishedFrames, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->silentFrames, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->disconnectCount, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->muteCount, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->ownerEpoch, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->ownerToken, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->ownerActive, uint32_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->controlVersion, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->controlGate, packControlGate(1U, 0U), __ATOMIC_RELAXED);

    for (uint32_t index = 0; index < capacityFrames; ++index) {
        atomicStore(&region->slots[index].version, uint64_t{0}, __ATOMIC_RELAXED);
        atomicStore(&region->slots[index].sequence, uint64_t{0}, __ATOMIC_RELAXED);
        atomicStore(&region->slots[index].generation, uint32_t{0}, __ATOMIC_RELAXED);
        atomicStore(&region->slots[index].sampleBits, floatToBits(0.0F), __ATOMIC_RELAXED);
        std::memset(region->slots[index].reserved, 0, sizeof(region->slots[index].reserved));
    }
}

bool producerOwnsRegion(const VMProducerHandle *producer) {
    if (producer == nullptr || producer->region == nullptr) {
        return false;
    }
    const VMSharedRegion *region = producer->region;
    return atomicLoad(&region->ownerActive, __ATOMIC_ACQUIRE) == 1U &&
           atomicLoad(&region->ownerToken, __ATOMIC_ACQUIRE) == producer->ownerToken &&
           atomicLoad(&region->ownerEpoch, __ATOMIC_ACQUIRE) == producer->ownerEpoch;
}

VMStatus acquireProducerOwnership(VMSharedRegion *region,
                                  uint64_t ownerToken,
                                  uint64_t *outOwnerEpoch) {
    if (region == nullptr || outOwnerEpoch == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    uint32_t expectedActive = 0U;
    if (!atomicCompareExchange(&region->ownerActive,
                               &expectedActive,
                               uint32_t{1},
                               __ATOMIC_ACQ_REL,
                               __ATOMIC_ACQUIRE)) {
        return VM_STATUS_BUSY;
    }

    const uint64_t currentToken = atomicLoad(&region->ownerToken, __ATOMIC_ACQUIRE);
    if (currentToken != 0U) {
        atomicStore(&region->ownerActive, uint32_t{0}, __ATOMIC_RELEASE);
        return VM_STATUS_BUSY;
    }

    const uint64_t previousEpoch = atomicLoad(&region->ownerEpoch, __ATOMIC_ACQUIRE);
    if (previousEpoch == UINT64_MAX) {
        atomicStore(&region->ownerActive, uint32_t{0}, __ATOMIC_RELEASE);
        return VM_STATUS_SYSTEM_ERROR;
    }

    const uint64_t nextEpoch = previousEpoch + 1U;
    atomicStore(&region->ownerEpoch, nextEpoch, __ATOMIC_RELEASE);
    atomicStore(&region->ownerToken, ownerToken, __ATOMIC_RELEASE);
    *outOwnerEpoch = nextEpoch;
    return VM_STATUS_OK;
}

void releaseProducerOwnership(VMProducerHandle *producer) {
    if (!producerOwnsRegion(producer)) {
        return;
    }

    VMSharedRegion *region = producer->region;
    atomicStore(&region->ownerToken, uint64_t{0}, __ATOMIC_RELEASE);
    atomicStore(&region->ownerActive, uint32_t{0}, __ATOMIC_RELEASE);
}

VMStatus applyControlTransition(VMSharedRegion *region,
                                uint32_t mask,
                                uint32_t desiredBits,
                                uint64_t *counter) {
    if (region == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    for (;;) {
        const uint64_t version = atomicLoad(&region->controlVersion, __ATOMIC_ACQUIRE);
        if ((version & 1U) != 0U) {
            continue;
        }

        const uint64_t currentGate = atomicLoad(&region->controlGate, __ATOMIC_ACQUIRE);
        const uint32_t currentGeneration = unpackGeneration(currentGate);
        const uint32_t currentFlags = unpackFlags(currentGate);
        const uint32_t nextFlags = (currentFlags & ~mask) | (desiredBits & mask);
        if (nextFlags == currentFlags) {
            return VM_STATUS_OK;
        }
        if (currentGeneration == UINT32_MAX) {
            return VM_STATUS_SYSTEM_ERROR;
        }

        uint64_t expectedVersion = version;
        if (!atomicCompareExchange(&region->controlVersion,
                                   &expectedVersion,
                                   version + 1U,
                                   __ATOMIC_ACQ_REL,
                                   __ATOMIC_ACQUIRE)) {
            continue;
        }

        const uint64_t writeSequence = atomicLoad(&region->writeSequence, __ATOMIC_ACQUIRE);
        atomicStore(&region->generationStartSequence, writeSequence, __ATOMIC_RELEASE);
        if (counter != nullptr) {
            atomicFetchAdd(counter, uint64_t{1}, __ATOMIC_ACQ_REL);
        }
        atomicStore(&region->controlGate,
                    packControlGate(currentGeneration + 1U, nextFlags),
                    __ATOMIC_RELEASE);
        atomicStore(&region->controlVersion, version + 2U, __ATOMIC_RELEASE);
        return VM_STATUS_OK;
    }
}

void publishSlot(VMSlot *slot, uint64_t sequence, uint32_t generation, float sample) {
    const uint64_t currentVersion = atomicLoad(&slot->version, __ATOMIC_RELAXED);
    const uint64_t pendingVersion = currentVersion + 1U;
    const uint64_t finalVersion = currentVersion + 2U;
    atomicStore(&slot->version, pendingVersion, __ATOMIC_SEQ_CST);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    atomicStore(&slot->sequence, sequence, __ATOMIC_RELAXED);
    atomicStore(&slot->generation, generation, __ATOMIC_RELAXED);
    atomicStore(&slot->sampleBits, floatToBits(sample), __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    atomicStore(&slot->version, finalVersion, __ATOMIC_RELEASE);
}

bool tryReadSlotSample(const VMSlot *slot, uint64_t expectedSequence, uint32_t expectedGeneration, float *outSample) {
    if (slot == nullptr || outSample == nullptr) {
        return false;
    }

    const uint64_t versionBefore = atomicLoad(&slot->version, __ATOMIC_ACQUIRE);
    if ((versionBefore & 1U) != 0U) {
        return false;
    }

    const uint64_t sequence = atomicLoad(&slot->sequence, __ATOMIC_RELAXED);
    const uint32_t generation = atomicLoad(&slot->generation, __ATOMIC_RELAXED);
    const uint32_t sampleBits = atomicLoad(&slot->sampleBits, __ATOMIC_RELAXED);
    const uint64_t versionAfter = atomicLoad(&slot->version, __ATOMIC_ACQUIRE);
    if (versionBefore != versionAfter ||
        (versionAfter & 1U) != 0U ||
        sequence != expectedSequence ||
        generation != expectedGeneration) {
        return false;
    }

    *outSample = bitsToFloat(sampleBits);
    return true;
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

    const int fd = shm_open(shmName, O_RDONLY, 0600);
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
                         PROT_READ,
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

void fillProducerStats(const VMSharedRegion *region, VMBridgeStats *outStats) {
    uint64_t controlGate = 0U;
    uint64_t generationStart = 0U;
    if (!readControlSnapshotBlocking(region, &controlGate, &generationStart)) {
        controlGate = atomicLoad(&region->controlGate, __ATOMIC_ACQUIRE);
        generationStart = atomicLoad(&region->generationStartSequence, __ATOMIC_ACQUIRE);
    }
    (void)generationStart;

    const uint64_t writeSequence = atomicLoad(&region->writeSequence, __ATOMIC_ACQUIRE);
    outStats->writeSequence = writeSequence;
    outStats->generation = unpackGeneration(controlGate);
    outStats->publishedFrames = atomicLoad(&region->publishedFrames, __ATOMIC_ACQUIRE);
    outStats->silentFrames = atomicLoad(&region->silentFrames, __ATOMIC_ACQUIRE);
    outStats->overrunCount = 0U;
    outStats->underrunCount = 0U;
    outStats->disconnectCount = atomicLoad(&region->disconnectCount, __ATOMIC_ACQUIRE);
    outStats->muteCount = atomicLoad(&region->muteCount, __ATOMIC_ACQUIRE);
    outStats->capacityFrames = region->capacityFrames;
    outStats->availableFrames = static_cast<uint32_t>(std::min<uint64_t>(writeSequence, region->capacityFrames));
    outStats->isMuted = ((unpackFlags(controlGate) & kMutedFlag) != 0U) ? 1U : 0U;
    outStats->isConnected = ((unpackFlags(controlGate) & kConnectedFlag) != 0U) ? 1U : 0U;
}

void fillConsumerStats(const VMConsumerHandle *consumer, VMBridgeStats *outStats) {
    fillProducerStats(consumer->region, outStats);
    const uint64_t writeSequence = outStats->writeSequence;
    const uint64_t backlog = (writeSequence > consumer->readCursor) ? (writeSequence - consumer->readCursor) : 0U;
    outStats->availableFrames = static_cast<uint32_t>(std::min<uint64_t>(backlog, consumer->region->capacityFrames));
    outStats->overrunCount = consumer->overrunCount;
    outStats->underrunCount = consumer->underrunCount;
}

void destroyProducerHandle(VMProducerHandle *producer) {
    if (producer == nullptr) {
        return;
    }

    if (producer->region != nullptr) {
        if (producerOwnsRegion(producer)) {
            (void)applyControlTransition(producer->region,
                                         kConnectedFlag | kMutedFlag,
                                         0U,
                                         &producer->region->disconnectCount);
            releaseProducerOwnership(producer);
        }
        munmap(producer->region, producer->mappedBytes);
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
    if (outProducer != nullptr) {
        *outProducer = nullptr;
    }
    if (!isValidName(shmName) || outProducer == nullptr || capacityFrames == 0U) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }

    const size_t expectedBytes = regionSizeForCapacity(capacityFrames);
    if (expectedBytes == 0U) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    int fd = -1;
    VMSharedRegion *region = nullptr;
    size_t mappedBytes = 0U;
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
        initializeRegion(region, mappedBytes, expectedBytes, capacityFrames);
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

    const uint64_t ownerToken = makeOwnerToken();
    uint64_t ownerEpoch = 0U;
    status = acquireProducerOwnership(region, ownerToken, &ownerEpoch);
    if (status != VM_STATUS_OK) {
        munmap(region, mappedBytes);
        close(fd);
        return status;
    }

    status = applyControlTransition(region,
                                    kConnectedFlag | kMutedFlag,
                                    kConnectedFlag,
                                    nullptr);
    if (status != VM_STATUS_OK) {
        atomicStore(&region->ownerToken, uint64_t{0}, __ATOMIC_RELEASE);
        atomicStore(&region->ownerActive, uint32_t{0}, __ATOMIC_RELEASE);
        munmap(region, mappedBytes);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return status;
    }

    VMProducerHandle *producer = new (std::nothrow) VMProducerHandle{fd, mappedBytes, region, ownerToken, ownerEpoch};
    if (producer == nullptr) {
        atomicStore(&region->ownerToken, uint64_t{0}, __ATOMIC_RELEASE);
        atomicStore(&region->ownerActive, uint32_t{0}, __ATOMIC_RELEASE);
        munmap(region, mappedBytes);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
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
    if (!producerOwnsRegion(producer)) {
        return VM_STATUS_BUSY;
    }

    const uint32_t desiredFlags = muted ? kMutedFlag : 0U;
    return applyControlTransition(producer->region, kMutedFlag, desiredFlags, &producer->region->muteCount);
}

VMStatus VMProducerDisconnect(VMProducerHandle *producer) {
    if (producer == nullptr || producer->region == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!producerOwnsRegion(producer)) {
        return VM_STATUS_BUSY;
    }

    return applyControlTransition(producer->region, kConnectedFlag, 0U, &producer->region->disconnectCount);
}

VMStatus VMProducerWriteFrames(VMProducerHandle *producer,
                               const float *frames,
                               uint32_t frameCount,
                               uint32_t sampleRate,
                               uint32_t *framesWritten) {
    if (framesWritten != nullptr) {
        *framesWritten = 0U;
    }
    if (producer == nullptr || producer->region == nullptr || framesWritten == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }
    if (frameCount > 0U && frames == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!producerOwnsRegion(producer)) {
        return VM_STATUS_BUSY;
    }
    if (frameCount == 0U) {
        return VM_STATUS_OK;
    }

    uint64_t controlGate = 0U;
    uint64_t generationStart = 0U;
    if (!tryReadControlSnapshot(producer->region, &controlGate, &generationStart, kMaxStableReadAttempts)) {
        return VM_STATUS_BUSY;
    }
    (void)generationStart;

    const uint32_t generation = unpackGeneration(controlGate);
    const uint32_t flags = unpackFlags(controlGate);
    const bool shouldSilence = ((flags & kConnectedFlag) == 0U) || ((flags & kMutedFlag) != 0U);
    const uint64_t baseSequence = atomicLoad(&producer->region->writeSequence, __ATOMIC_ACQUIRE);
    uint64_t endSequence = 0U;
    if (!checkedAddU64(baseSequence, frameCount, &endSequence)) {
        return VM_STATUS_SYSTEM_ERROR;
    }

    for (uint32_t index = 0; index < frameCount; ++index) {
        VMSlot *slot = slotForSequence(producer->region, baseSequence + index);
        const uint64_t slotVersion = atomicLoad(&slot->version, __ATOMIC_RELAXED);
        if (slotVersion >= UINT64_MAX - 2U) {
            return VM_STATUS_SYSTEM_ERROR;
        }
        const float sample = shouldSilence ? 0.0F : frames[index];
        publishSlot(slot, baseSequence + index, generation, sample);
    }

    if (!producerOwnsRegion(producer)) {
        return VM_STATUS_BUSY;
    }

    atomicStore(&producer->region->writeSequence, endSequence, __ATOMIC_RELEASE);
    atomicFetchAdd(&producer->region->publishedFrames, static_cast<uint64_t>(frameCount), __ATOMIC_ACQ_REL);
    if (shouldSilence) {
        atomicFetchAdd(&producer->region->silentFrames, static_cast<uint64_t>(frameCount), __ATOMIC_ACQ_REL);
    }

    *framesWritten = frameCount;
    return VM_STATUS_OK;
}

VMStatus VMProducerGetStats(const VMProducerHandle *producer, VMBridgeStats *outStats) {
    if (producer == nullptr || producer->region == nullptr || outStats == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!producerOwnsRegion(producer)) {
        return VM_STATUS_BUSY;
    }
    fillProducerStats(producer->region, outStats);
    return VM_STATUS_OK;
}

VMStatus VMConsumerCreate(const char *shmName,
                          uint32_t sampleRate,
                          VMConsumerHandle **outConsumer) {
    if (outConsumer != nullptr) {
        *outConsumer = nullptr;
    }
    if (!isValidName(shmName) || outConsumer == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }

    int fd = -1;
    VMSharedRegion *region = nullptr;
    size_t mappedBytes = 0U;
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

    uint64_t controlGate = 0U;
    uint64_t generationStart = 0U;
    if (!readControlSnapshotBlocking(region, &controlGate, &generationStart)) {
        munmap(region, mappedBytes);
        close(fd);
        return VM_STATUS_SYSTEM_ERROR;
    }
    const uint64_t writeSequence = atomicLoad(&region->writeSequence, __ATOMIC_ACQUIRE);
    (void)generationStart;

    VMConsumerHandle *consumer = new (std::nothrow) VMConsumerHandle{
        fd,
        mappedBytes,
        region,
        writeSequence,
        unpackGeneration(controlGate),
        0U,
        0U};
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
    if (framesRead != nullptr) {
        *framesRead = 0U;
    }
    if (consumer == nullptr || consumer->region == nullptr || outFrames == nullptr || framesRead == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (!validateAudioArguments(sampleRate)) {
        return VM_STATUS_INVALID_SAMPLE_RATE;
    }

    std::fill_n(outFrames, frameCount, 0.0F);

    const VMSharedRegion *region = consumer->region;
    uint64_t gateBefore = 0U;
    uint64_t startBefore = 0U;
    if (!tryReadControlSnapshot(region, &gateBefore, &startBefore, kMaxStableReadAttempts)) {
        *framesRead = frameCount;
        return VM_STATUS_OK;
    }

    const uint32_t generationBefore = unpackGeneration(gateBefore);
    if (generationBefore != consumer->generation) {
        consumer->readCursor = std::max(consumer->readCursor, startBefore);
        consumer->generation = generationBefore;
    }

    const uint64_t writeSequence = atomicLoad(&region->writeSequence, __ATOMIC_ACQUIRE);
    const uint64_t oldestSequence = (writeSequence > region->capacityFrames)
        ? (writeSequence - region->capacityFrames)
        : 0U;
    if (consumer->readCursor < oldestSequence) {
        consumer->overrunCount += oldestSequence - consumer->readCursor;
        consumer->readCursor = oldestSequence;
    }

    const uint64_t availableFrames = (writeSequence > consumer->readCursor)
        ? (writeSequence - consumer->readCursor)
        : 0U;
    const uint32_t readableFrames = static_cast<uint32_t>(std::min<uint64_t>(availableFrames, frameCount));
    uint32_t consumedFrames = 0U;
    for (; consumedFrames < readableFrames; ++consumedFrames) {
        const uint64_t sequence = consumer->readCursor + consumedFrames;
        const VMSlot *slot = slotForSequence(region, sequence);
        float sample = 0.0F;
        if (!tryReadSlotSample(slot, sequence, generationBefore, &sample)) {
            break;
        }
        outFrames[consumedFrames] = sample;
    }

    const uint64_t newCursor = consumer->readCursor + consumedFrames;
    uint64_t gateAfter = 0U;
    uint64_t startAfter = 0U;
    if (!tryReadControlSnapshot(region, &gateAfter, &startAfter, kMaxStableReadAttempts)) {
        gateAfter = gateBefore;
        startAfter = startBefore;
    }

    if (gateAfter != gateBefore) {
        std::fill_n(outFrames, frameCount, 0.0F);
        consumer->readCursor = std::max(newCursor, startAfter);
        consumer->generation = unpackGeneration(gateAfter);
        *framesRead = frameCount;
        return VM_STATUS_OK;
    }

    consumer->readCursor = newCursor;
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
