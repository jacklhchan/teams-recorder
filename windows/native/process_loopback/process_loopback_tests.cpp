#include "process_loopback.h"

#include <cassert>

using teams_recorder::process_loopback::ParseProcessId;
using teams_recorder::process_loopback::ActivationCompletionDisposition;
using teams_recorder::process_loopback::ActivationCompletionDispositionFor;
using teams_recorder::process_loopback::ProcessLoopbackCapture;
using teams_recorder::process_loopback::ProcessLoopbackCaptureRequest;
using teams_recorder::process_loopback::DescribeProcessLoopbackTarget;
using teams_recorder::process_loopback::ProcessLoopbackTargetScope;
using teams_recorder::process_loopback::TargetProcessWaitDisposition;
using teams_recorder::process_loopback::TargetProcessWaitDispositionFor;

int main() {
    const auto ordinary = ParseProcessId(L"12345");
    assert(ordinary.succeeded() && ordinary.process_id == 12345);
    assert(!ParseProcessId(L"").succeeded());
    assert(!ParseProcessId(L"0").succeeded());
    assert(!ParseProcessId(L" 12").succeeded());
    assert(!ParseProcessId(L"+12").succeeded());
    assert(!ParseProcessId(L"12x").succeeded());
    assert(!ParseProcessId(L"4294967296").succeeded());
    assert(ActivationCompletionDispositionFor(false) ==
           ActivationCompletionDisposition::deliver_result);
    assert(ActivationCompletionDispositionFor(true) ==
           ActivationCompletionDisposition::release_client);

    const auto target = DescribeProcessLoopbackTarget(12345);
    assert(target.selected_root_process_id == 12345);
    assert(target.target_scope ==
           ProcessLoopbackTargetScope::include_selected_root_process_tree);
    assert(!target.system_audio_fallback_permitted);
    assert(TargetProcessWaitDispositionFor(WAIT_TIMEOUT) ==
           TargetProcessWaitDisposition::still_running);
    assert(TargetProcessWaitDispositionFor(WAIT_OBJECT_0) ==
           TargetProcessWaitDisposition::exited);
    assert(TargetProcessWaitDispositionFor(WAIT_FAILED) ==
           TargetProcessWaitDisposition::wait_failed);

    ProcessLoopbackCapture capture;
    ProcessLoopbackCaptureRequest invalid_request;
    invalid_request.target_process_id = 0;
    assert(!capture.Start(invalid_request, [](auto&&) {}));
    assert(!capture.is_running());
    assert(capture.last_error().hresult == E_INVALIDARG);
    return 0;
}
