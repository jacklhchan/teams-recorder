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
    VMStatus status = VMSharedMemoryUnlink(shm_name);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMSharedMemoryUnlink initial status %d\n", (int)status);
        return -1;
    }
    status = VMProducerCreate(shm_name, 64U, VM_SAMPLE_RATE, &producer);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMProducerCreate status %d\n", (int)status);
        return -2;
    }
    status = VMProducerGetStats(producer, &stats);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMProducerGetStats status %d\n", (int)status);
        return -3;
    }
    status = VMConsumerCreate(shm_name, VM_SAMPLE_RATE, &consumer);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMConsumerCreate status %d\n", (int)status);
        return -4;
    }
    status = VMConsumerGetStats(consumer, &stats);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMConsumerGetStats status %d\n", (int)status);
        return -5;
    }
    status = VMProducerWriteFrames(producer, input, 4U, VM_SAMPLE_RATE, &transferred);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMProducerWriteFrames status %d\n", (int)status);
        return -6;
    }
    if (transferred != 4U) {
        return -7;
    }
    status = VMConsumerReadFrames(consumer, output, 4U, VM_SAMPLE_RATE, &transferred);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMConsumerReadFrames status %d\n", (int)status);
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
    status = VMSharedMemoryUnlink(shm_name);
    if (status != VM_STATUS_OK) {
        fprintf(stderr, "C smoke VMSharedMemoryUnlink final status %d\n", (int)status);
        return -11;
    }
    return (int)stats.capacityFrames;
}
