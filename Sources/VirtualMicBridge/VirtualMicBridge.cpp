#include "VirtualMicBridge.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <new>
#include <pthread.h>
#include <cstdio>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__)
static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "shared ABI requires little-endian layout");
#endif

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
    uint32_t writeActive;
    uint64_t controlVersion;
    uint64_t controlGate;
    uint64_t reserved3[6];
    VMSlot slots[1];
};

struct VMProducerHandle {
    int fd;
    int lockFd;
    size_t mappedBytes;
    VMSharedRegion *region;
    uint64_t ownerToken;
    uint64_t ownerEpoch;
    uint64_t processGeneration;
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
constexpr uint32_t kMaxControlTransitionAttempts = 8U;
constexpr size_t kSharedHeaderBytes = offsetof(VMSharedRegion, slots);
constexpr mode_t kSharedMemoryPermissions = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH;

static_assert(sizeof(float) == sizeof(uint32_t), "Float32 contract required");
static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0), "uint32 shared atomics must be lock-free");
static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0), "uint64 shared atomics must be lock-free");
static_assert(sizeof(VMSlot) == 64U, "slot ABI size changed");
static_assert(alignof(VMSlot) == 64U, "slot ABI alignment changed");
static_assert((offsetof(VMSharedRegion, slots) % alignof(VMSlot)) == 0U, "slot ABI alignment changed");
static_assert(offsetof(VMSharedRegion, magic) == 0U, "magic ABI offset changed");
static_assert(offsetof(VMSharedRegion, abiVersion) == 8U, "abiVersion ABI offset changed");
static_assert(offsetof(VMSharedRegion, headerBytes) == 12U, "headerBytes ABI offset changed");
static_assert(offsetof(VMSharedRegion, totalBytes) == 16U, "totalBytes ABI offset changed");
static_assert(offsetof(VMSharedRegion, writeSequence) == 56U, "writeSequence ABI offset changed");
static_assert(offsetof(VMSharedRegion, ownerActive) == 120U, "ownerActive ABI offset changed");
static_assert(offsetof(VMSharedRegion, writeActive) == 124U, "writeActive ABI offset changed");
static_assert(offsetof(VMSharedRegion, controlVersion) == 128U, "controlVersion ABI offset changed");
static_assert(kSharedHeaderBytes == 192U, "shared header ABI size changed");

uint64_t gProcessGeneration = 1U;
pthread_once_t gAtForkOnce = PTHREAD_ONCE_INIT;
int gAtForkStatus = 0;
pthread_mutex_t gLocalOwnerTokensMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t gSharedMemoryCreateMutex = PTHREAD_MUTEX_INITIALIZER;
uint64_t gLocalOwnerTokens[256] = {};

void atForkPrepare() {
    (void)pthread_mutex_lock(&gSharedMemoryCreateMutex);
}

void atForkParent() {
    (void)pthread_mutex_unlock(&gSharedMemoryCreateMutex);
}

void atForkChild() {
    (void)pthread_mutex_unlock(&gSharedMemoryCreateMutex);
    (void)__atomic_fetch_add(&gProcessGeneration, uint64_t{1}, __ATOMIC_RELAXED);
}

void registerAtForkOnce() {
    gAtForkStatus = pthread_atfork(atForkPrepare, atForkParent, atForkChild);
}

VMStatus ensureAtForkRegistered() {
    if (pthread_once(&gAtForkOnce, registerAtForkOnce) != 0 || gAtForkStatus != 0) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    return VM_STATUS_OK;
}

uint64_t currentProcessGeneration() {
    uint64_t value = 0U;
    __atomic_load(&gProcessGeneration, &value, __ATOMIC_ACQUIRE);
    return value;
}

bool localOwnerTokenExists(uint64_t ownerToken) {
    if (ownerToken == 0U) {
        return false;
    }
    pthread_mutex_lock(&gLocalOwnerTokensMutex);
    bool found = false;
    for (uint64_t token : gLocalOwnerTokens) {
        if (token == ownerToken) {
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&gLocalOwnerTokensMutex);
    return found;
}

bool registerLocalOwnerToken(uint64_t ownerToken) {
    if (ownerToken == 0U) {
        return false;
    }
    pthread_mutex_lock(&gLocalOwnerTokensMutex);
    bool inserted = false;
    for (uint64_t &token : gLocalOwnerTokens) {
        if (token == ownerToken) {
            inserted = true;
            break;
        }
        if (token == 0U) {
            token = ownerToken;
            inserted = true;
            break;
        }
    }
    pthread_mutex_unlock(&gLocalOwnerTokensMutex);
    return inserted;
}

void unregisterLocalOwnerToken(uint64_t ownerToken) {
    if (ownerToken == 0U) {
        return;
    }
    pthread_mutex_lock(&gLocalOwnerTokensMutex);
    for (uint64_t &token : gLocalOwnerTokens) {
        if (token == ownerToken) {
            token = 0U;
            break;
        }
    }
    pthread_mutex_unlock(&gLocalOwnerTokensMutex);
}

#ifdef VM_BRIDGE_TESTING
using VMBridgeTestHook = void (*)(void *);
constexpr uint32_t kTestHookWriteAfterSnapshot = 1U;
std::atomic<VMBridgeTestHook> gWriteAfterSnapshotHook{nullptr};
std::atomic<void *> gWriteAfterSnapshotContext{nullptr};
std::atomic<bool> gForceFinalReadSnapshotFailure{false};

void runWriteAfterSnapshotHook() {
    VMBridgeTestHook hook = gWriteAfterSnapshotHook.load(std::memory_order_acquire);
    if (hook != nullptr) {
        hook(gWriteAfterSnapshotContext.load(std::memory_order_acquire));
    }
}
#endif

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

VMStatus verifySharedMemoryMode(int fd) {
    struct stat statBuffer {};
    if (fstat(fd, &statBuffer) != 0) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    return ((statBuffer.st_mode & 0777) == kSharedMemoryPermissions)
               ? VM_STATUS_OK
               : VM_STATUS_PERMISSION_ERROR;
}

VMStatus normalizeCreatedSharedMemoryPermissions(int fd) {
    if (fd < 0) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (fchmod(fd, kSharedMemoryPermissions) != 0) {
        const int chmodErrno = errno;
#if defined(__APPLE__)
        if (chmodErrno == EINVAL) {
            return verifySharedMemoryMode(fd);
        }
#endif
        return VM_STATUS_SYSTEM_ERROR;
    }

    return verifySharedMemoryMode(fd);
}

VMStatus validateExistingSharedMemoryPermissions(int fd) {
    if (fd < 0) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    return verifySharedMemoryMode(fd);
}

int createSharedMemoryObjectWithExactMode(const char *shmName) {
    const int lockStatus = pthread_mutex_lock(&gSharedMemoryCreateMutex);
    if (lockStatus != 0) {
        errno = lockStatus;
        return -1;
    }
    const mode_t previousMask = umask(0);
    const int fd = shm_open(shmName, O_RDWR | O_CREAT | O_EXCL, kSharedMemoryPermissions);
    const int savedErrno = errno;
    (void)umask(previousMask);
    (void)pthread_mutex_unlock(&gSharedMemoryCreateMutex);
    errno = savedErrno;
    return fd;
}

uint64_t makeOwnerToken() {
    static uint64_t processCounter = 0U;
    const uint64_t counter = atomicFetchAdd(&processCounter, uint64_t{1}, __ATOMIC_RELAXED) + 1U;
    return (static_cast<uint64_t>(getpid()) << 32) ^ counter ^ 0x9E3779B97F4A7C15ULL;
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
    if (mappedBytes < kSharedHeaderBytes) {
        return VM_STATUS_ABI_MISMATCH;
    }
    if (atomicLoad(&region->magic, __ATOMIC_ACQUIRE) != kMagic ||
        region->abiVersion != kAbiVersion ||
        region->headerBytes != kSharedHeaderBytes ||
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
    region->abiVersion = kAbiVersion;
    region->headerBytes = static_cast<uint32_t>(kSharedHeaderBytes);
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
    atomicStore(&region->writeActive, uint32_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->controlVersion, uint64_t{0}, __ATOMIC_RELAXED);
    atomicStore(&region->controlGate, packControlGate(1U, 0U), __ATOMIC_RELAXED);

    for (uint32_t index = 0; index < capacityFrames; ++index) {
        atomicStore(&region->slots[index].version, uint64_t{0}, __ATOMIC_RELAXED);
        atomicStore(&region->slots[index].sequence, uint64_t{0}, __ATOMIC_RELAXED);
        atomicStore(&region->slots[index].generation, uint32_t{0}, __ATOMIC_RELAXED);
        atomicStore(&region->slots[index].sampleBits, floatToBits(0.0F), __ATOMIC_RELAXED);
        std::memset(region->slots[index].reserved, 0, sizeof(region->slots[index].reserved));
    }
    atomicStore(&region->magic, kMagic, __ATOMIC_RELEASE);
}

bool producerOwnsRegion(const VMProducerHandle *producer) {
    if (producer == nullptr || producer->region == nullptr) {
        return false;
    }
    if (producer->processGeneration != currentProcessGeneration()) {
        return false;
    }
    const VMSharedRegion *region = producer->region;
    return atomicLoad(&region->ownerActive, __ATOMIC_ACQUIRE) == 1U &&
           atomicLoad(&region->ownerToken, __ATOMIC_ACQUIRE) == producer->ownerToken &&
           atomicLoad(&region->ownerEpoch, __ATOMIC_ACQUIRE) == producer->ownerEpoch;
}

VMStatus tryLockFd(int fd) {
    if (fd < 0) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
        return VM_STATUS_OK;
    }
    if (errno == EWOULDBLOCK || errno == EAGAIN || errno == EACCES) {
        return VM_STATUS_BUSY;
    }

    struct flock lock {};
    lock.l_type = F_WRLCK;
    lock.l_whence = SEEK_SET;
    lock.l_start = 0;
    lock.l_len = 0;
    if (fcntl(fd, F_SETLK, &lock) == 0) {
        return VM_STATUS_OK;
    }
    if (errno == EWOULDBLOCK || errno == EAGAIN || errno == EACCES) {
        return VM_STATUS_BUSY;
    }
    return VM_STATUS_SYSTEM_ERROR;
}

uint64_t hashShmName(const char *shmName) {
    uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char *cursor = reinterpret_cast<const unsigned char *>(shmName);
         cursor != nullptr && *cursor != 0U;
         ++cursor) {
        hash ^= static_cast<uint64_t>(*cursor);
        hash *= 1099511628211ULL;
    }
    return hash;
}

VMStatus acquireProducerLease(const char *shmName, int shmFd, int *outLockFd) {
    if (!isValidName(shmName) || shmFd < 0 || outLockFd == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }
    *outLockFd = -1;

    VMStatus status = tryLockFd(shmFd);
    if (status == VM_STATUS_OK || status == VM_STATUS_BUSY) {
        return status;
    }

    char lockPath[PATH_MAX] = {};
    const int pathLength = std::snprintf(lockPath,
                                         sizeof(lockPath),
                                         "/tmp/vm-bridge-%016llx.lock",
                                         static_cast<unsigned long long>(hashShmName(shmName)));
    if (pathLength <= 0 || static_cast<size_t>(pathLength) >= sizeof(lockPath)) {
        return VM_STATUS_SYSTEM_ERROR;
    }

    const int lockFd = open(lockPath, O_RDWR | O_CREAT, 0600);
    if (lockFd < 0) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    status = tryLockFd(lockFd);
    if (status != VM_STATUS_OK) {
        close(lockFd);
        return status;
    }

    *outLockFd = lockFd;
    return VM_STATUS_OK;
}

VMStatus recoverAndAcquireProducerOwnership(VMSharedRegion *region,
                                            uint64_t ownerToken,
                                            uint64_t *outOwnerEpoch) {
    if (region == nullptr || outOwnerEpoch == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    const uint64_t currentGate = atomicLoad(&region->controlGate, __ATOMIC_ACQUIRE);
    const uint32_t currentGeneration = unpackGeneration(currentGate);
    const uint64_t currentVersion = atomicLoad(&region->controlVersion, __ATOMIC_ACQUIRE);
    if (currentGeneration == UINT32_MAX || currentVersion > UINT64_MAX - 2U) {
        return VM_STATUS_SYSTEM_ERROR;
    }
    const uint64_t previousEpoch = atomicLoad(&region->ownerEpoch, __ATOMIC_ACQUIRE);
    if (previousEpoch == UINT64_MAX) {
        return VM_STATUS_SYSTEM_ERROR;
    }

    atomicStore(&region->ownerActive, uint32_t{0}, __ATOMIC_RELEASE);
    atomicStore(&region->ownerToken, uint64_t{0}, __ATOMIC_RELEASE);
    atomicStore(&region->writeActive, uint32_t{0}, __ATOMIC_RELEASE);

    const uint64_t writeSequence = atomicLoad(&region->writeSequence, __ATOMIC_ACQUIRE);
    atomicStore(&region->generationStartSequence, writeSequence, __ATOMIC_RELEASE);
    atomicStore(&region->controlGate,
                packControlGate(currentGeneration + 1U, kConnectedFlag),
                __ATOMIC_RELEASE);
    atomicStore(&region->controlVersion,
                (currentVersion & 1U) != 0U ? currentVersion + 1U : currentVersion + 2U,
                __ATOMIC_RELEASE);

    const uint64_t nextEpoch = previousEpoch + 1U;
    atomicStore(&region->ownerToken, ownerToken, __ATOMIC_RELEASE);
    atomicStore(&region->ownerEpoch, nextEpoch, __ATOMIC_RELEASE);
    atomicStore(&region->ownerActive, uint32_t{1}, __ATOMIC_RELEASE);
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

struct WriteActiveGuard {
    VMSharedRegion *region = nullptr;
    bool acquired = false;

    explicit WriteActiveGuard(VMSharedRegion *targetRegion) : region(targetRegion) {
        if (region == nullptr) {
            return;
        }
        uint32_t expected = 0U;
        acquired = atomicCompareExchange(&region->writeActive,
                                         &expected,
                                         uint32_t{1},
                                         __ATOMIC_ACQ_REL,
                                         __ATOMIC_ACQUIRE);
    }

    ~WriteActiveGuard() {
        if (acquired && region != nullptr) {
            atomicStore(&region->writeActive, uint32_t{0}, __ATOMIC_RELEASE);
        }
    }

    WriteActiveGuard(const WriteActiveGuard &) = delete;
    WriteActiveGuard &operator=(const WriteActiveGuard &) = delete;
};

VMStatus applyControlTransition(VMSharedRegion *region,
                                uint32_t mask,
                                uint32_t desiredBits,
                                uint64_t *counter) {
    if (region == nullptr) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    for (uint32_t attempt = 0; attempt < kMaxControlTransitionAttempts; ++attempt) {
        const uint64_t version = atomicLoad(&region->controlVersion, __ATOMIC_ACQUIRE);
        if ((version & 1U) != 0U) {
            return VM_STATUS_BUSY;
        }
        if (version > UINT64_MAX - 2U) {
            return VM_STATUS_SYSTEM_ERROR;
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

        if (atomicLoad(&region->writeActive, __ATOMIC_ACQUIRE) != 0U) {
            atomicStore(&region->controlVersion, version + 2U, __ATOMIC_RELEASE);
            return VM_STATUS_BUSY;
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

    return VM_STATUS_BUSY;
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
    int fd = createSharedMemoryObjectWithExactMode(shmName);
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

    const VMStatus status = created
                                ? normalizeCreatedSharedMemoryPermissions(fd)
                                : validateExistingSharedMemoryPermissions(fd);
    if (status != VM_STATUS_OK) {
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return status;
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
        unregisterLocalOwnerToken(producer->ownerToken);
        munmap(producer->region, producer->mappedBytes);
    }

    closeFdIfNeeded(producer->fd);
    closeFdIfNeeded(producer->lockFd);
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

    VMStatus status = ensureAtForkRegistered();
    if (status != VM_STATUS_OK) {
        return status;
    }

    const size_t expectedBytes = regionSizeForCapacity(capacityFrames);
    if (expectedBytes == 0U) {
        return VM_STATUS_INVALID_ARGUMENT;
    }

    int fd = -1;
    VMSharedRegion *region = nullptr;
    size_t mappedBytes = 0U;
    bool created = false;
    int lockFd = -1;
    status = createOrOpenProducerRegion(shmName,
                                        expectedBytes,
                                        &fd,
                                        &region,
                                        &mappedBytes,
                                        &created);
    if (status != VM_STATUS_OK) {
        return status;
    }

    status = acquireProducerLease(shmName, fd, &lockFd);
    if (status != VM_STATUS_OK) {
        munmap(region, mappedBytes);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return status;
    }

    if (created) {
        initializeRegion(region, mappedBytes, expectedBytes, capacityFrames);
    }

    status = validateRegion(region, mappedBytes);
    if (status != VM_STATUS_OK || region->capacityFrames != capacityFrames) {
        munmap(region, mappedBytes);
        closeFdIfNeeded(lockFd);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return (status == VM_STATUS_OK) ? VM_STATUS_INVALID_ARGUMENT : status;
    }

    if (atomicLoad(&region->ownerActive, __ATOMIC_ACQUIRE) == 1U &&
        localOwnerTokenExists(atomicLoad(&region->ownerToken, __ATOMIC_ACQUIRE))) {
        munmap(region, mappedBytes);
        closeFdIfNeeded(lockFd);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return VM_STATUS_BUSY;
    }

    const uint64_t ownerToken = makeOwnerToken();
    VMProducerHandle *producer = new (std::nothrow) VMProducerHandle{
        fd,
        lockFd,
        mappedBytes,
        region,
        ownerToken,
        0U,
        currentProcessGeneration()};
    if (producer == nullptr) {
        munmap(region, mappedBytes);
        closeFdIfNeeded(lockFd);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return VM_STATUS_SYSTEM_ERROR;
    }

    status = recoverAndAcquireProducerOwnership(region, ownerToken, &producer->ownerEpoch);
    if (status != VM_STATUS_OK) {
        delete producer;
        munmap(region, mappedBytes);
        closeFdIfNeeded(lockFd);
        close(fd);
        if (created) {
            shm_unlink(shmName);
        }
        return status;
    }
    if (!registerLocalOwnerToken(ownerToken)) {
        releaseProducerOwnership(producer);
        delete producer;
        munmap(region, mappedBytes);
        closeFdIfNeeded(lockFd);
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

    WriteActiveGuard writeGuard(producer->region);
    if (!writeGuard.acquired) {
        return VM_STATUS_BUSY;
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
#ifdef VM_BRIDGE_TESTING
    runWriteAfterSnapshotHook();
#endif
    if (!producerOwnsRegion(producer)) {
        return VM_STATUS_BUSY;
    }

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
    uint64_t localCursor = consumer->readCursor;
    uint32_t localGeneration = consumer->generation;
    uint64_t localOverrun = consumer->overrunCount;
    uint64_t localUnderrun = consumer->underrunCount;

    if (generationBefore != localGeneration) {
        localCursor = std::max(localCursor, startBefore);
        localGeneration = generationBefore;
    }

    const uint64_t writeSequence = atomicLoad(&region->writeSequence, __ATOMIC_ACQUIRE);
    const uint64_t oldestSequence = (writeSequence > region->capacityFrames)
        ? (writeSequence - region->capacityFrames)
        : 0U;
    if (localCursor < oldestSequence) {
        localOverrun += oldestSequence - localCursor;
        localCursor = oldestSequence;
    }

    const uint64_t availableFrames = (writeSequence > localCursor)
        ? (writeSequence - localCursor)
        : 0U;
    const uint32_t readableFrames = static_cast<uint32_t>(std::min<uint64_t>(availableFrames, frameCount));
    uint32_t consumedFrames = 0U;
    for (; consumedFrames < readableFrames; ++consumedFrames) {
        const uint64_t sequence = localCursor + consumedFrames;
        const VMSlot *slot = slotForSequence(region, sequence);
        float sample = 0.0F;
        if (!tryReadSlotSample(slot, sequence, localGeneration, &sample)) {
            break;
        }
        outFrames[consumedFrames] = sample;
    }

    const uint64_t newCursor = localCursor + consumedFrames;
    uint64_t gateAfter = 0U;
    uint64_t startAfter = 0U;
#ifdef VM_BRIDGE_TESTING
    const bool forceFinalReadSnapshotFailure = gForceFinalReadSnapshotFailure.load(std::memory_order_acquire);
#else
    constexpr bool forceFinalReadSnapshotFailure = false;
#endif
    if (forceFinalReadSnapshotFailure ||
        !tryReadControlSnapshot(region, &gateAfter, &startAfter, kMaxStableReadAttempts)) {
        std::fill_n(outFrames, frameCount, 0.0F);
        *framesRead = frameCount;
        return VM_STATUS_OK;
    }

    if (gateAfter != gateBefore) {
        std::fill_n(outFrames, frameCount, 0.0F);
        consumer->readCursor = std::max(newCursor, startAfter);
        consumer->generation = unpackGeneration(gateAfter);
        *framesRead = frameCount;
        return VM_STATUS_OK;
    }

    consumer->readCursor = newCursor;
    consumer->generation = localGeneration;
    consumer->overrunCount = localOverrun;
    if (frameCount > consumedFrames) {
        localUnderrun += static_cast<uint64_t>(frameCount - consumedFrames);
    }
    consumer->underrunCount = localUnderrun;

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

#ifdef VM_BRIDGE_TESTING
void VMBridgeTestSetHook(uint32_t hookId, VMBridgeTestHook hook, void *context) {
    if (hookId == kTestHookWriteAfterSnapshot) {
        gWriteAfterSnapshotContext.store(context, std::memory_order_release);
        gWriteAfterSnapshotHook.store(hook, std::memory_order_release);
    }
}

void VMBridgeTestSetForceFinalReadSnapshotFailure(bool enabled) {
    gForceFinalReadSnapshotFailure.store(enabled, std::memory_order_release);
}
#endif

} // extern "C"
