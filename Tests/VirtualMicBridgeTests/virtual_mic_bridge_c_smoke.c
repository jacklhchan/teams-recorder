#include "VirtualMicBridge.h"

#include <stdio.h>
#include <unistd.h>

int vm_c_header_smoke(void) {
    static unsigned int counter = 0;
    char shm_name[64];
    VMProducerHandle *producer = 0;
    VMConsumerHandle *consumer = 0;
    VMBridgeStats stats = {0};
    (void)snprintf(shm_name, sizeof(shm_name), "/vm-c-smoke-%llu-%u",
                   (unsigned long long)getpid(), counter++);
    (void)VMSharedMemoryUnlink(shm_name);
    (void)VMProducerCreate(shm_name, 64U, VM_SAMPLE_RATE, &producer);
    (void)VMProducerGetStats(producer, &stats);
    (void)VMConsumerCreate(shm_name, VM_SAMPLE_RATE, &consumer);
    (void)VMConsumerGetStats(consumer, &stats);
    VMConsumerDestroy(consumer);
    VMProducerDestroy(producer);
    (void)VMSharedMemoryUnlink(shm_name);
    return (int)stats.capacityFrames;
}
