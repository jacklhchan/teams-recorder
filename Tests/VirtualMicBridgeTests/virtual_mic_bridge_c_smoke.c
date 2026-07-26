#include "VirtualMicBridge.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

int vm_c_header_smoke(void) {
    static unsigned int counter = 0;
    char shm_name[64];
    VMProducerHandle *producer = 0;
    VMConsumerHandle *consumer = 0;
    VMBridgeStats stats = {0};
    float input[4] = {1.0f, 2.0f, 3.0f, 4.0f};
    float output[4] = {0};
    unsigned int transferred = 0;
    (void)snprintf(shm_name, sizeof(shm_name), "/vm-c-smoke-%llu-%u",
                   (unsigned long long)getpid(), counter++);
    if (VMSharedMemoryUnlink(shm_name) != VM_STATUS_OK) {
        return -1;
    }
    if (VMProducerCreate(shm_name, 64U, VM_SAMPLE_RATE, &producer) != VM_STATUS_OK) {
        return -2;
    }
    if (VMProducerGetStats(producer, &stats) != VM_STATUS_OK) {
        return -3;
    }
    if (VMConsumerCreate(shm_name, VM_SAMPLE_RATE, &consumer) != VM_STATUS_OK) {
        return -4;
    }
    if (VMConsumerGetStats(consumer, &stats) != VM_STATUS_OK) {
        return -5;
    }
    if (VMProducerWriteFrames(producer, input, 4U, VM_SAMPLE_RATE, &transferred) != VM_STATUS_OK) {
        return -6;
    }
    if (transferred != 4U) {
        return -7;
    }
    if (VMConsumerReadFrames(consumer, output, 4U, VM_SAMPLE_RATE, &transferred) != VM_STATUS_OK) {
        return -8;
    }
    if (transferred != 4U) {
        return -9;
    }
    if (memcmp(input, output, sizeof(input)) != 0) {
        return -10;
    }
    VMConsumerDestroy(consumer);
    VMProducerDestroy(producer);
    if (VMSharedMemoryUnlink(shm_name) != VM_STATUS_OK) {
        return -11;
    }
    return (int)stats.capacityFrames;
}
