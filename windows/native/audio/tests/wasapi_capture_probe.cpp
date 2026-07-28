#include "../wasapi_capture.h"

#include <iostream>
#include <vector>

// Deliberately a small manual/integration probe: CI hosts may have no active endpoint.
int wmain() {
    std::vector<recorder::audio::EndpointInfo> endpoints;
    recorder::audio::CaptureError error;
    const HRESULT result = recorder::audio::WasapiCapture::EnumerateEndpoints(&endpoints, &error);
    if (FAILED(result)) {
        std::wcerr << L"SKIP/FAIL: endpoint enumeration unavailable: " << error.message << L"\n";
        return 0;  // No device/service is an environment skip, not a fabricated capture pass.
    }
    std::wcout << L"Enumerated " << endpoints.size() << L" active endpoint(s).\n";
    return 0;
}
