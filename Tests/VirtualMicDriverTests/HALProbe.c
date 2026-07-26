#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *kExpectedUID = "local.meeting.recorder.virtual-mic.v1";

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
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(
            objectID,
            &propertyAddress,
            0,
            NULL,
            &size
        ) != noErr) {
        return 0;
    }
    return size;
}

static CFStringRef stringProperty(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector
) {
    AudioObjectPropertyAddress propertyAddress = address(
        selector,
        kAudioObjectPropertyScopeGlobal
    );
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            NULL,
            &size,
            &value
        ) != noErr) {
        return NULL;
    }
    return value;
}

static UInt32 channelCount(
    AudioObjectID deviceID,
    AudioObjectPropertyScope scope
) {
    UInt32 size = propertySize(
        deviceID,
        kAudioDevicePropertyStreamConfiguration,
        scope
    );
    if (size < offsetof(AudioBufferList, mBuffers)) {
        return UINT32_MAX;
    }

    AudioBufferList *configuration = calloc(1, size);
    if (configuration == NULL) {
        return UINT32_MAX;
    }

    AudioObjectPropertyAddress propertyAddress = address(
        kAudioDevicePropertyStreamConfiguration,
        scope
    );
    OSStatus status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        NULL,
        &size,
        configuration
    );
    UInt32 channels = 0;
    if (status == noErr) {
        for (UInt32 index = 0; index < configuration->mNumberBuffers; ++index) {
            channels += configuration->mBuffers[index].mNumberChannels;
        }
    } else {
        channels = UINT32_MAX;
    }

    free(configuration);
    return channels;
}

static int verifyDevice(AudioObjectID deviceID) {
    CFStringRef name = stringProperty(deviceID, kAudioObjectPropertyName);
    CFStringRef uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID);
    if (name == NULL || uid == NULL) {
        return 1;
    }

    char nameBuffer[256] = {0};
    char uidBuffer[256] = {0};
    Boolean nameOK = CFStringGetCString(
        name,
        nameBuffer,
        sizeof(nameBuffer),
        kCFStringEncodingUTF8
    );
    Boolean uidOK = CFStringGetCString(
        uid,
        uidBuffer,
        sizeof(uidBuffer),
        kCFStringEncodingUTF8
    );
    CFRelease(name);
    CFRelease(uid);

    AudioObjectPropertyAddress rateAddress = address(
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal
    );
    Float64 sampleRate = 0;
    UInt32 rateSize = sizeof(sampleRate);
    OSStatus rateStatus = AudioObjectGetPropertyData(
        deviceID,
        &rateAddress,
        0,
        NULL,
        &rateSize,
        &sampleRate
    );

    UInt32 inputChannels = channelCount(
        deviceID,
        kAudioObjectPropertyScopeInput
    );
    UInt32 outputChannels = channelCount(
        deviceID,
        kAudioObjectPropertyScopeOutput
    );

    printf(
        "name=%s\nuid=%s\nsample_rate=%.0f\ninput_channels=%u\noutput_channels=%u\n",
        nameBuffer,
        uidBuffer,
        sampleRate,
        inputChannels,
        outputChannels
    );

    if (!nameOK || !uidOK) {
        return 1;
    }
    if (strcmp(nameBuffer, "Local Recorder Virtual Mic") != 0) {
        return 1;
    }
    if (strcmp(uidBuffer, kExpectedUID) != 0) {
        return 1;
    }
    if (rateStatus != noErr || sampleRate != 48000.0) {
        return 1;
    }
    if (inputChannels != 1 || outputChannels != 0) {
        return 1;
    }
    return 0;
}

int main(void) {
    UInt32 size = propertySize(
        kAudioObjectSystemObject,
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal
    );
    if (size == 0) {
        fprintf(stderr, "Could not enumerate Core Audio devices\n");
        return 1;
    }

    AudioObjectID *devices = malloc(size);
    if (devices == NULL) {
        return 1;
    }

    AudioObjectPropertyAddress devicesAddress = address(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal
    );
    if (AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &devicesAddress,
            0,
            NULL,
            &size,
            devices
        ) != noErr) {
        free(devices);
        return 1;
    }

    UInt32 count = size / sizeof(AudioObjectID);
    for (UInt32 index = 0; index < count; ++index) {
        CFStringRef uid = stringProperty(
            devices[index],
            kAudioDevicePropertyDeviceUID
        );
        if (uid == NULL) {
            continue;
        }
        Boolean matches = CFStringCompare(
            uid,
            CFSTR("local.meeting.recorder.virtual-mic.v1"),
            0
        ) == kCFCompareEqualTo;
        CFRelease(uid);
        if (matches) {
            int result = verifyDevice(devices[index]);
            free(devices);
            return result;
        }
    }

    free(devices);
    fprintf(stderr, "Local Recorder Virtual Mic is not enumerated\n");
    return 2;
}
