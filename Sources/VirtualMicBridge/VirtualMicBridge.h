#ifndef VIRTUAL_MIC_BRIDGE_H
#define VIRTUAL_MIC_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    VM_SAMPLE_RATE = 48000,
    VM_CHANNELS = 1
};

typedef struct VMProducerHandle VMProducerHandle;
typedef struct VMConsumerHandle VMConsumerHandle;

typedef enum VMStatus {
    VM_STATUS_OK = 0,
    VM_STATUS_INVALID_ARGUMENT = 1,
    VM_STATUS_INVALID_SAMPLE_RATE = 2,
    VM_STATUS_SYSTEM_ERROR = 3,
    VM_STATUS_BUSY = 4,
    VM_STATUS_ABI_MISMATCH = 5,
    VM_STATUS_PERMISSION_ERROR = 6
} VMStatus;

typedef struct VMBridgeStats {
    uint64_t writeSequence;
    uint64_t generation;
    uint64_t publishedFrames;
    uint64_t silentFrames;
    uint64_t overrunCount;
    uint64_t underrunCount;
    uint64_t disconnectCount;
    uint64_t muteCount;
    uint32_t capacityFrames;
    uint32_t availableFrames;
    uint32_t isMuted;
    uint32_t isConnected;
} VMBridgeStats;

VMStatus VMProducerCreate(const char *shmName,
                          uint32_t capacityFrames,
                          uint32_t sampleRate,
                          VMProducerHandle **outProducer);
VMStatus VMSharedMemoryUnlink(const char *shmName);
void VMProducerDestroy(VMProducerHandle *producer);
VMStatus VMProducerSetMuted(VMProducerHandle *producer, bool muted);
VMStatus VMProducerDisconnect(VMProducerHandle *producer);
VMStatus VMProducerWriteFrames(VMProducerHandle *producer,
                               const float *frames,
                               uint32_t frameCount,
                               uint32_t sampleRate,
                               uint32_t *framesWritten);
VMStatus VMProducerGetStats(const VMProducerHandle *producer, VMBridgeStats *outStats);

VMStatus VMConsumerCreate(const char *shmName,
                          uint32_t sampleRate,
                          VMConsumerHandle **outConsumer);
void VMConsumerDestroy(VMConsumerHandle *consumer);
VMStatus VMConsumerReadFrames(VMConsumerHandle *consumer,
                              float *outFrames,
                              uint32_t frameCount,
                              uint32_t sampleRate,
                              uint32_t *framesRead);
VMStatus VMConsumerGetStats(const VMConsumerHandle *consumer, VMBridgeStats *outStats);

#ifdef __cplusplus
}
#endif

#endif
