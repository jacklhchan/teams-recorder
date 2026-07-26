#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "VirtualMicBridge.h"

void *LocalRecorderVirtualMic_Create(
    CFAllocatorRef allocator,
    CFUUIDRef requestedTypeUUID
);

static int gFailures = 0;
static AudioServerPlugInDriverRef gDriver = NULL;

#define REQUIRE(condition)                                                       \
    do {                                                                         \
        if (!(condition)) {                                                      \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
            ++gFailures;                                                         \
        }                                                                        \
    } while (0)

static OSStatus hostPropertiesChanged(
    AudioServerPlugInHostRef host,
    AudioObjectID objectID,
    UInt32 addressCount,
    const AudioObjectPropertyAddress *addresses
) {
    (void)host;
    (void)objectID;
    (void)addressCount;
    (void)addresses;
    return noErr;
}

static OSStatus hostCopyFromStorage(
    AudioServerPlugInHostRef host,
    CFStringRef key,
    CFPropertyListRef *outData
) {
    (void)host;
    (void)key;
    *outData = NULL;
    return noErr;
}

static OSStatus hostWriteToStorage(
    AudioServerPlugInHostRef host,
    CFStringRef key,
    CFPropertyListRef data
) {
    (void)host;
    (void)key;
    (void)data;
    return noErr;
}

static OSStatus hostDeleteFromStorage(
    AudioServerPlugInHostRef host,
    CFStringRef key
) {
    (void)host;
    (void)key;
    return noErr;
}

static OSStatus hostRequestDeviceConfigurationChange(
    AudioServerPlugInHostRef host,
    AudioObjectID deviceID,
    UInt64 action,
    void *changeInfo
) {
    (void)host;
    (void)deviceID;
    (void)action;
    (void)changeInfo;
    return kAudioHardwareUnsupportedOperationError;
}

static const AudioServerPlugInHostInterface gHost = {
    .PropertiesChanged = hostPropertiesChanged,
    .CopyFromStorage = hostCopyFromStorage,
    .WriteToStorage = hostWriteToStorage,
    .DeleteFromStorage = hostDeleteFromStorage,
    .RequestDeviceConfigurationChange = hostRequestDeviceConfigurationChange,
};

static AudioObjectPropertyAddress address(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope
) {
    return (AudioObjectPropertyAddress){
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
}

static UInt32 propertySize(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope
) {
    AudioObjectPropertyAddress propertyAddress = address(selector, scope);
    UInt32 size = UINT32_MAX;
    OSStatus status = (*gDriver)->GetPropertyDataSize(
        gDriver,
        objectID,
        0,
        &propertyAddress,
        0,
        NULL,
        &size
    );
    REQUIRE(status == noErr);
    return size;
}

static OSStatus propertyData(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    UInt32 capacity,
    UInt32 *outSize,
    void *outData
) {
    AudioObjectPropertyAddress propertyAddress = address(selector, scope);
    return (*gDriver)->GetPropertyData(
        gDriver,
        objectID,
        0,
        &propertyAddress,
        0,
        NULL,
        capacity,
        outSize,
        outData
    );
}

static void requireStringProperty(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    const char *expected
) {
    CFStringRef value = NULL;
    UInt32 outSize = 0;
    OSStatus status = propertyData(
        objectID,
        selector,
        kAudioObjectPropertyScopeGlobal,
        sizeof(value),
        &outSize,
        &value
    );
    REQUIRE(status == noErr);
    REQUIRE(outSize == sizeof(value));
    REQUIRE(value != NULL);

    char buffer[256] = {0};
    if (value != NULL) {
        REQUIRE(CFStringGetCString(
            value,
            buffer,
            sizeof(buffer),
            kCFStringEncodingUTF8
        ));
        REQUIRE(strcmp(buffer, expected) == 0);
    }
}

static AudioObjectID publishedDevice(void) {
    UInt32 size = propertySize(
        kAudioObjectPlugInObject,
        kAudioPlugInPropertyDeviceList,
        kAudioObjectPropertyScopeGlobal
    );
    REQUIRE(size == sizeof(AudioObjectID));

    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 outSize = 0;
    OSStatus status = propertyData(
        kAudioObjectPlugInObject,
        kAudioPlugInPropertyDeviceList,
        kAudioObjectPropertyScopeGlobal,
        sizeof(deviceID),
        &outSize,
        &deviceID
    );
    REQUIRE(status == noErr);
    REQUIRE(outSize == sizeof(deviceID));
    REQUIRE(deviceID != kAudioObjectUnknown);
    return deviceID;
}

static void testPluginPublishesOnlyDevice(void) {
    AudioObjectID deviceID = publishedDevice();
    UInt32 ownedSize = propertySize(
        kAudioObjectPlugInObject,
        kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeGlobal
    );
    REQUIRE(ownedSize == sizeof(AudioObjectID));

    AudioObjectID ownedObject = kAudioObjectUnknown;
    UInt32 outSize = 0;
    REQUIRE(propertyData(
        kAudioObjectPlugInObject,
        kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeGlobal,
        sizeof(ownedObject),
        &outSize,
        &ownedObject
    ) == noErr);
    REQUIRE(outSize == sizeof(ownedObject));
    REQUIRE(ownedObject == deviceID);

    REQUIRE(propertySize(
        kAudioObjectPlugInObject,
        kAudioPlugInPropertyBoxList,
        kAudioObjectPropertyScopeGlobal
    ) == 0);
    REQUIRE(propertySize(
        kAudioObjectPlugInObject,
        kAudioPlugInPropertyResourceBundle,
        kAudioObjectPropertyScopeGlobal
    ) == sizeof(CFStringRef));

    AudioObjectPropertyAddress iconAddress = address(
        kAudioDevicePropertyIcon,
        kAudioObjectPropertyScopeGlobal
    );
    REQUIRE(!(*gDriver)->HasProperty(
        gDriver,
        deviceID,
        0,
        &iconAddress
    ));

    AudioObjectPropertyAddress customInfoAddress = address(
        kAudioObjectPropertyCustomPropertyInfoList,
        kAudioObjectPropertyScopeGlobal
    );
    REQUIRE(!(*gDriver)->HasProperty(
        gDriver,
        kAudioObjectPlugInObject,
        0,
        &customInfoAddress
    ));
}

static AudioObjectID publishedInputStream(AudioObjectID deviceID) {
    REQUIRE(propertySize(
        deviceID,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeGlobal
    ) == sizeof(AudioObjectID));
    REQUIRE(propertySize(
        deviceID,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput
    ) == sizeof(AudioObjectID));
    REQUIRE(propertySize(
        deviceID,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput
    ) == 0);

    AudioObjectID streamID = kAudioObjectUnknown;
    UInt32 outSize = 0;
    OSStatus status = propertyData(
        deviceID,
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        sizeof(streamID),
        &outSize,
        &streamID
    );
    REQUIRE(status == noErr);
    REQUIRE(outSize == sizeof(streamID));
    REQUIRE(streamID != kAudioObjectUnknown);
    return streamID;
}

static void testFactoryAndIdentity(void) {
    gDriver = (AudioServerPlugInDriverRef)LocalRecorderVirtualMic_Create(
        kCFAllocatorDefault,
        kAudioServerPlugInTypeUUID
    );
    REQUIRE(gDriver != NULL);
    if (gDriver == NULL) {
        return;
    }

    REQUIRE((*gDriver)->Initialize(gDriver, &gHost) == noErr);

    AudioObjectID deviceID = publishedDevice();
    requireStringProperty(
        deviceID,
        kAudioObjectPropertyName,
        "Local Recorder Virtual Mic"
    );
    requireStringProperty(
        deviceID,
        kAudioObjectPropertyManufacturer,
        "Local Meeting Recorder"
    );
    requireStringProperty(
        deviceID,
        kAudioDevicePropertyDeviceUID,
        "local.meeting.recorder.virtual-mic.v1"
    );
    requireStringProperty(
        deviceID,
        kAudioDevicePropertyModelUID,
        "local.meeting.recorder.virtual-mic.model.v1"
    );

    UInt32 transport = 0;
    UInt32 outSize = 0;
    REQUIRE(propertyData(
        deviceID,
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        sizeof(transport),
        &outSize,
        &transport
    ) == noErr);
    REQUIRE(transport == kAudioDeviceTransportTypeVirtual);
}

static void testInputOnlyDeviceContract(void) {
    AudioObjectID deviceID = publishedDevice();
    AudioObjectID streamID = publishedInputStream(deviceID);

    Float64 rate = 0;
    UInt32 outSize = 0;
    REQUIRE(propertyData(
        deviceID,
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        sizeof(rate),
        &outSize,
        &rate
    ) == noErr);
    REQUIRE(rate == 48000.0);

    REQUIRE(propertySize(
        deviceID,
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal
    ) == sizeof(AudioValueRange));
    AudioValueRange availableRate = {0};
    REQUIRE(propertyData(
        deviceID,
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal,
        sizeof(availableRate),
        &outSize,
        &availableRate
    ) == noErr);
    REQUIRE(availableRate.mMinimum == 48000.0);
    REQUIRE(availableRate.mMaximum == 48000.0);

    AudioStreamBasicDescription format = {0};
    REQUIRE(propertyData(
        streamID,
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        sizeof(format),
        &outSize,
        &format
    ) == noErr);
    REQUIRE(format.mSampleRate == 48000.0);
    REQUIRE(format.mFormatID == kAudioFormatLinearPCM);
    REQUIRE((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0);
    REQUIRE((format.mFormatFlags & kAudioFormatFlagIsPacked) != 0);
    REQUIRE(format.mBytesPerPacket == sizeof(Float32));
    REQUIRE(format.mFramesPerPacket == 1);
    REQUIRE(format.mBytesPerFrame == sizeof(Float32));
    REQUIRE(format.mChannelsPerFrame == 1);
    REQUIRE(format.mBitsPerChannel == 32);

    UInt32 direction = 0;
    REQUIRE(propertyData(
        streamID,
        kAudioStreamPropertyDirection,
        kAudioObjectPropertyScopeGlobal,
        sizeof(direction),
        &outSize,
        &direction
    ) == noErr);
    REQUIRE(direction == 1);

    UInt32 terminal = 0;
    REQUIRE(propertyData(
        streamID,
        kAudioStreamPropertyTerminalType,
        kAudioObjectPropertyScopeGlobal,
        sizeof(terminal),
        &outSize,
        &terminal
    ) == noErr);
    REQUIRE(terminal == kAudioStreamTerminalTypeMicrophone);

    UInt32 canBeDefaultInput = 0;
    REQUIRE(propertyData(
        deviceID,
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioObjectPropertyScopeInput,
        sizeof(canBeDefaultInput),
        &outSize,
        &canBeDefaultInput
    ) == noErr);
    REQUIRE(canBeDefaultInput == 1);

    AudioObjectPropertyAddress outputDefaultAddress = address(
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioObjectPropertyScopeOutput
    );
    REQUIRE(!(*gDriver)->HasProperty(
        gDriver,
        deviceID,
        0,
        &outputDefaultAddress
    ));
    UInt32 canBeDefaultOutput = 1;
    REQUIRE(propertyData(
        deviceID,
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioObjectPropertyScopeOutput,
        sizeof(canBeDefaultOutput),
        &outSize,
        &canBeDefaultOutput
    ) == kAudioHardwareUnknownPropertyError);

    AudioObjectPropertyAddress systemDefaultAddress = address(
        kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
        kAudioObjectPropertyScopeInput
    );
    REQUIRE(!(*gDriver)->HasProperty(
        gDriver,
        deviceID,
        0,
        &systemDefaultAddress
    ));
}

static void testReadInputProducesFreshSilence(void) {
    AudioObjectID deviceID = publishedDevice();
    AudioObjectID streamID = publishedInputStream(deviceID);

    Boolean willDo = false;
    Boolean inPlace = false;
    REQUIRE((*gDriver)->WillDoIOOperation(
        gDriver,
        deviceID,
        1,
        kAudioServerPlugInIOOperationReadInput,
        &willDo,
        &inPlace
    ) == noErr);
    REQUIRE(willDo);
    REQUIRE(inPlace);

    willDo = true;
    REQUIRE((*gDriver)->WillDoIOOperation(
        gDriver,
        deviceID,
        1,
        kAudioServerPlugInIOOperationWriteMix,
        &willDo,
        &inPlace
    ) == noErr);
    REQUIRE(!willDo);

    REQUIRE((*gDriver)->StartIO(gDriver, deviceID, 1) == noErr);

    Float32 frames[128];
    for (size_t index = 0; index < 128; ++index) {
        frames[index] = NAN;
    }
    AudioServerPlugInIOCycleInfo cycle = {0};
    REQUIRE((*gDriver)->DoIOOperation(
        gDriver,
        deviceID,
        streamID,
        1,
        kAudioServerPlugInIOOperationReadInput,
        128,
        &cycle,
        frames,
        NULL
    ) == noErr);
    for (size_t index = 0; index < 128; ++index) {
        REQUIRE(frames[index] == 0.0f);
    }

    Float64 firstSampleTime = 0;
    Float64 secondSampleTime = 0;
    UInt64 firstHostTime = 0;
    UInt64 secondHostTime = 0;
    UInt64 firstSeed = 0;
    UInt64 secondSeed = 0;
    REQUIRE((*gDriver)->GetZeroTimeStamp(
        gDriver,
        deviceID,
        1,
        &firstSampleTime,
        &firstHostTime,
        &firstSeed
    ) == noErr);
    usleep(2000);
    REQUIRE((*gDriver)->GetZeroTimeStamp(
        gDriver,
        deviceID,
        1,
        &secondSampleTime,
        &secondHostTime,
        &secondSeed
    ) == noErr);
    REQUIRE(secondSampleTime >= firstSampleTime);
    REQUIRE(secondHostTime >= firstHostTime);
    REQUIRE(firstSeed == secondSeed);

    REQUIRE((*gDriver)->StopIO(gDriver, deviceID, 1) == noErr);
}

static void testEachHALClientReadsTheSamePublishedMicrophoneFrames(void) {
    REQUIRE(VMSharedMemoryUnlink(VM_DEFAULT_SHARED_MEMORY_NAME) == VM_STATUS_OK);

    VMProducerHandle *producer = NULL;
    REQUIRE(VMProducerCreate(
        VM_DEFAULT_SHARED_MEMORY_NAME,
        64,
        VM_SAMPLE_RATE,
        &producer
    ) == VM_STATUS_OK);
    if (producer == NULL) {
        return;
    }

    AudioObjectID deviceID = publishedDevice();
    AudioObjectID streamID = publishedInputStream(deviceID);
    REQUIRE((*gDriver)->StartIO(gDriver, deviceID, 101) == noErr);
    REQUIRE((*gDriver)->StartIO(gDriver, deviceID, 202) == noErr);

    const Float32 speech[] = {0.125F, -0.25F, 0.5F, -0.75F};
    UInt32 framesWritten = 0;
    REQUIRE(VMProducerWriteFrames(
        producer,
        speech,
        4,
        VM_SAMPLE_RATE,
        &framesWritten
    ) == VM_STATUS_OK);
    REQUIRE(framesWritten == 4);

    Float32 firstClient[4] = {9, 9, 9, 9};
    Float32 secondClient[4] = {8, 8, 8, 8};
    AudioServerPlugInIOCycleInfo cycleInfo = {0};
    REQUIRE((*gDriver)->DoIOOperation(
        gDriver,
        deviceID,
        streamID,
        101,
        kAudioServerPlugInIOOperationReadInput,
        4,
        &cycleInfo,
        firstClient,
        NULL
    ) == noErr);
    REQUIRE((*gDriver)->DoIOOperation(
        gDriver,
        deviceID,
        streamID,
        202,
        kAudioServerPlugInIOOperationReadInput,
        4,
        &cycleInfo,
        secondClient,
        NULL
    ) == noErr);
    REQUIRE(memcmp(firstClient, speech, sizeof(speech)) == 0);
    REQUIRE(memcmp(secondClient, speech, sizeof(speech)) == 0);

    REQUIRE(VMProducerSetMuted(producer, true) == VM_STATUS_OK);
    const Float32 shouldBeMuted[] = {0.9F, 0.8F, 0.7F, 0.6F};
    REQUIRE(VMProducerWriteFrames(
        producer,
        shouldBeMuted,
        4,
        VM_SAMPLE_RATE,
        &framesWritten
    ) == VM_STATUS_OK);
    Float32 mutedFrames[4] = {7, 7, 7, 7};
    REQUIRE((*gDriver)->DoIOOperation(
        gDriver,
        deviceID,
        streamID,
        101,
        kAudioServerPlugInIOOperationReadInput,
        4,
        &cycleInfo,
        mutedFrames,
        NULL
    ) == noErr);
    for (size_t index = 0; index < 4; ++index) {
        REQUIRE(mutedFrames[index] == 0.0F);
    }

    REQUIRE(VMProducerSetMuted(producer, false) == VM_STATUS_OK);
    const Float32 freshSpeech[] = {-0.1F, -0.2F, 0.3F, 0.4F};
    REQUIRE(VMProducerWriteFrames(
        producer,
        freshSpeech,
        4,
        VM_SAMPLE_RATE,
        &framesWritten
    ) == VM_STATUS_OK);
    Float32 unmutedFrames[4] = {6, 6, 6, 6};
    REQUIRE((*gDriver)->DoIOOperation(
        gDriver,
        deviceID,
        streamID,
        101,
        kAudioServerPlugInIOOperationReadInput,
        4,
        &cycleInfo,
        unmutedFrames,
        NULL
    ) == noErr);
    REQUIRE(memcmp(unmutedFrames, freshSpeech, sizeof(freshSpeech)) == 0);

    REQUIRE((*gDriver)->StopIO(gDriver, deviceID, 202) == noErr);
    REQUIRE((*gDriver)->StopIO(gDriver, deviceID, 101) == noErr);
    VMProducerDestroy(producer);
    REQUIRE(VMSharedMemoryUnlink(VM_DEFAULT_SHARED_MEMORY_NAME) == VM_STATUS_OK);
}

static void testFixedFormatRejectsMutation(void) {
    AudioObjectID deviceID = publishedDevice();
    AudioObjectID streamID = publishedInputStream(deviceID);
    AudioObjectPropertyAddress nominalRateAddress = address(
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal
    );
    Boolean settable = true;
    REQUIRE((*gDriver)->IsPropertySettable(
        gDriver,
        deviceID,
        0,
        &nominalRateAddress,
        &settable
    ) == noErr);
    REQUIRE(!settable);

    Float64 unsupportedRate = 44100.0;
    REQUIRE((*gDriver)->SetPropertyData(
        gDriver,
        deviceID,
        0,
        &nominalRateAddress,
        0,
        NULL,
        sizeof(unsupportedRate),
        &unsupportedRate
    ) == kAudioHardwareUnsupportedOperationError);
    REQUIRE((*gDriver)->PerformDeviceConfigurationChange(
        gDriver,
        deviceID,
        (UInt64)unsupportedRate,
        NULL
    ) == kAudioHardwareUnsupportedOperationError);

    AudioObjectPropertyAddress formatAddress = address(
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal
    );
    settable = true;
    REQUIRE((*gDriver)->IsPropertySettable(
        gDriver,
        streamID,
        0,
        &formatAddress,
        &settable
    ) == noErr);
    REQUIRE(!settable);

    AudioStreamBasicDescription unsupportedFormat = {
        .mSampleRate = 44100.0,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = (
            kAudioFormatFlagIsFloat |
            kAudioFormatFlagsNativeEndian |
            kAudioFormatFlagIsPacked
        ),
        .mBytesPerPacket = sizeof(Float32),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(Float32),
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = 32,
    };
    REQUIRE((*gDriver)->SetPropertyData(
        gDriver,
        streamID,
        0,
        &formatAddress,
        0,
        NULL,
        sizeof(unsupportedFormat),
        &unsupportedFormat
    ) == kAudioHardwareUnsupportedOperationError);
}

static void testClockCatchesUpWithoutResetForExtraClient(void) {
    AudioObjectID deviceID = publishedDevice();
    UInt32 period = 0;
    UInt32 outSize = 0;
    REQUIRE(propertyData(
        deviceID,
        kAudioDevicePropertyZeroTimeStampPeriod,
        kAudioObjectPropertyScopeGlobal,
        sizeof(period),
        &outSize,
        &period
    ) == noErr);
    REQUIRE(period > 0);

    REQUIRE((*gDriver)->StartIO(gDriver, deviceID, 10) == noErr);
    Float64 firstSampleTime = 0;
    UInt64 firstHostTime = 0;
    UInt64 seed = 0;
    REQUIRE((*gDriver)->GetZeroTimeStamp(
        gDriver,
        deviceID,
        10,
        &firstSampleTime,
        &firstHostTime,
        &seed
    ) == noErr);

    usleep(720000);
    Float64 caughtUpSampleTime = 0;
    UInt64 caughtUpHostTime = 0;
    REQUIRE((*gDriver)->GetZeroTimeStamp(
        gDriver,
        deviceID,
        10,
        &caughtUpSampleTime,
        &caughtUpHostTime,
        &seed
    ) == noErr);
    REQUIRE(caughtUpSampleTime >= firstSampleTime + (2.0 * period));
    REQUIRE(caughtUpHostTime > firstHostTime);

    REQUIRE((*gDriver)->StartIO(gDriver, deviceID, 11) == noErr);
    Float64 extraClientSampleTime = 0;
    UInt64 extraClientHostTime = 0;
    REQUIRE((*gDriver)->GetZeroTimeStamp(
        gDriver,
        deviceID,
        11,
        &extraClientSampleTime,
        &extraClientHostTime,
        &seed
    ) == noErr);
    REQUIRE(extraClientSampleTime >= caughtUpSampleTime);
    REQUIRE(extraClientHostTime >= caughtUpHostTime);

    REQUIRE((*gDriver)->StopIO(gDriver, deviceID, 11) == noErr);
    REQUIRE((*gDriver)->StopIO(gDriver, deviceID, 10) == noErr);
}

int main(void) {
    testFactoryAndIdentity();
    if (gDriver != NULL) {
        testPluginPublishesOnlyDevice();
        testInputOnlyDeviceContract();
        testReadInputProducesFreshSilence();
        testEachHALClientReadsTheSamePublishedMicrophoneFrames();
        testFixedFormatRejectsMutation();
        testClockCatchesUpWithoutResetForExtraClient();
    }

    if (gFailures == 0) {
        printf("Virtual mic driver contract tests passed\n");
        return EXIT_SUCCESS;
    }

    fprintf(stderr, "%d virtual mic driver contract assertion(s) failed\n", gFailures);
    return EXIT_FAILURE;
}
