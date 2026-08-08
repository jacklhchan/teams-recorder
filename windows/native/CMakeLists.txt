cmake_minimum_required(VERSION 3.21)

project(RecorderNativeBridge VERSION 0.8.0 LANGUAGES C CXX)

option(RECORDER_NATIVE_BUILD_TESTS "Build native bridge contract tests" ON)

function(recorder_enable_strict_warnings target)
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX /permissive-)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
endfunction()

add_library(Recorder.NativeBridge SHARED src/recorder_native_bridge.cpp)

add_library(Recorder.NativeBridge::Recorder.NativeBridge ALIAS Recorder.NativeBridge)

target_compile_features(Recorder.NativeBridge PUBLIC cxx_std_17)
target_include_directories(Recorder.NativeBridge
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
)
target_compile_definitions(Recorder.NativeBridge PRIVATE RECORDER_NATIVE_BRIDGE_BUILDING=1)
recorder_enable_strict_warnings(Recorder.NativeBridge)

add_library(Recorder.Wav STATIC
    wav/src/wav_writer.cpp
)
target_compile_features(Recorder.Wav PUBLIC cxx_std_17)
target_include_directories(Recorder.Wav PUBLIC wav/include)
recorder_enable_strict_warnings(Recorder.Wav)

if(WIN32)
    add_compile_definitions(NOMINMAX)

    add_library(Recorder.Format STATIC
        format/mix_format_decoder.cpp
    )
    target_compile_features(Recorder.Format PUBLIC cxx_std_17)
    target_include_directories(Recorder.Format PUBLIC format)
    target_link_libraries(Recorder.Format PUBLIC uuid)
    recorder_enable_strict_warnings(Recorder.Format)

    add_library(Recorder.Downmix STATIC
        downmix/src/stereo_downmix.cpp
    )
    target_compile_features(Recorder.Downmix PUBLIC cxx_std_17)
    target_include_directories(Recorder.Downmix PUBLIC downmix/include)
    recorder_enable_strict_warnings(Recorder.Downmix)

    add_library(Recorder.Resample STATIC
        resample/src/linear_resampler.cpp
    )
    target_compile_features(Recorder.Resample PUBLIC cxx_std_17)
    target_include_directories(Recorder.Resample PUBLIC resample/include downmix/include)
    target_link_libraries(Recorder.Resample PUBLIC Recorder.Downmix)
    recorder_enable_strict_warnings(Recorder.Resample)

    add_library(Recorder.Timeline STATIC
        timeline/canonical_timeline.cpp
        timeline/video_pts_mapper.cpp
    )
    target_compile_features(Recorder.Timeline PUBLIC cxx_std_17)
    target_include_directories(Recorder.Timeline PUBLIC timeline)
    recorder_enable_strict_warnings(Recorder.Timeline)

    add_library(Recorder.WasapiCapture STATIC
        audio/wasapi_capture.cpp
    )
    target_compile_features(Recorder.WasapiCapture PUBLIC cxx_std_17)
    target_include_directories(Recorder.WasapiCapture PUBLIC audio)
target_link_libraries(Recorder.WasapiCapture PUBLIC ole32 uuid mf mfplat mfreadwrite mfuuid)
    recorder_enable_strict_warnings(Recorder.WasapiCapture)

    add_library(Recorder.ProcessLoopback STATIC
        process_loopback/process_loopback.cpp
    )
    target_compile_features(Recorder.ProcessLoopback PUBLIC cxx_std_17)
    target_include_directories(Recorder.ProcessLoopback PUBLIC process_loopback)
    target_compile_definitions(Recorder.ProcessLoopback
        PUBLIC
            _WIN32_WINNT=0x0A00
            NTDDI_VERSION=0x0A00000A
    )
    target_link_libraries(Recorder.ProcessLoopback PUBLIC ole32 mmdevapi)
    recorder_enable_strict_warnings(Recorder.ProcessLoopback)

    target_sources(Recorder.NativeBridge PRIVATE
        src/capture_session.cpp
        src/mixed_capture_session.cpp
        src/m4a_writer.cpp
        src/mp4_decode_validator.cpp
        src/mp4_mux_writer.cpp
    )
    target_include_directories(Recorder.NativeBridge PRIVATE src)
    target_link_libraries(Recorder.NativeBridge
        PRIVATE
            Recorder.Format
            Recorder.ProcessLoopback
            Recorder.Resample
            Recorder.Timeline
            Recorder.WasapiCapture
            Recorder.WgcWindowCaptureSession
            Recorder.Wav
            mfplat
            mfreadwrite
            mfuuid
            ole32
    )

    add_executable(Recorder.AudioProbe tools/audio_probe_main.cpp)
    target_compile_features(Recorder.AudioProbe PRIVATE cxx_std_17)
    target_link_libraries(Recorder.AudioProbe PRIVATE Recorder.WasapiCapture Recorder.Wav)
    recorder_enable_strict_warnings(Recorder.AudioProbe)

    add_executable(Recorder.BridgeProbe tools/bridge_probe_main.cpp)
    target_compile_features(Recorder.BridgeProbe PRIVATE cxx_std_17)
    target_link_libraries(Recorder.BridgeProbe PRIVATE Recorder.NativeBridge)
    recorder_enable_strict_warnings(Recorder.BridgeProbe)

    add_executable(Recorder.TonePlayer tools/tone_player_main.cpp)
    target_compile_features(Recorder.TonePlayer PRIVATE cxx_std_17)
    target_link_libraries(Recorder.TonePlayer PRIVATE winmm)
    recorder_enable_strict_warnings(Recorder.TonePlayer)

    add_library(Recorder.WgcCaptureProbe STATIC
        video/wgc_capture_probe.cpp
        video/bgra_to_nv12.cpp
    )
    target_compile_features(Recorder.WgcCaptureProbe PUBLIC cxx_std_17)
    target_include_directories(Recorder.WgcCaptureProbe PUBLIC video)
    target_link_libraries(Recorder.WgcCaptureProbe PUBLIC d3d11 dxgi dwmapi windowsapp)
    recorder_enable_strict_warnings(Recorder.WgcCaptureProbe)

    add_library(Recorder.WgcWindowCaptureSession STATIC
        video/wgc_window_capture_session.cpp
    )
    target_compile_features(Recorder.WgcWindowCaptureSession PUBLIC cxx_std_17)
    target_include_directories(Recorder.WgcWindowCaptureSession PUBLIC video)
    target_link_libraries(Recorder.WgcWindowCaptureSession PUBLIC Recorder.WgcCaptureProbe)
    recorder_enable_strict_warnings(Recorder.WgcWindowCaptureSession)

    add_executable(Recorder.WgcCaptureProbe.Tool tools/wgc_capture_probe_main.cpp)
    target_compile_features(Recorder.WgcCaptureProbe.Tool PRIVATE cxx_std_17)
    target_link_libraries(Recorder.WgcCaptureProbe.Tool PRIVATE Recorder.WgcCaptureProbe)
    recorder_enable_strict_warnings(Recorder.WgcCaptureProbe.Tool)

    add_executable(Recorder.ProcessLoopbackProbe
        process_loopback/process_loopback_probe.cpp
    )
    target_compile_features(Recorder.ProcessLoopbackProbe PRIVATE cxx_std_17)
    target_link_libraries(Recorder.ProcessLoopbackProbe PRIVATE Recorder.ProcessLoopback)
    recorder_enable_strict_warnings(Recorder.ProcessLoopbackProbe)
endif()

if(RECORDER_NATIVE_BUILD_TESTS)
    enable_testing()
    add_executable(Recorder.NativeBridge.ContractTests tests/contract_tests.cpp)
    target_link_libraries(Recorder.NativeBridge.ContractTests PRIVATE Recorder.NativeBridge)
    recorder_enable_strict_warnings(Recorder.NativeBridge.ContractTests)
    add_test(NAME Recorder.NativeBridge.ContractTests COMMAND Recorder.NativeBridge.ContractTests)

    # Compile this source as C (not C++) to prevent accidental C++ ABI leakage.
    add_executable(Recorder.NativeBridge.CAbiSmokeTests tests/c_abi_smoke_test.c)
    set_target_properties(Recorder.NativeBridge.CAbiSmokeTests PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
    target_link_libraries(Recorder.NativeBridge.CAbiSmokeTests PRIVATE Recorder.NativeBridge)
    recorder_enable_strict_warnings(Recorder.NativeBridge.CAbiSmokeTests)
    add_test(NAME Recorder.NativeBridge.CAbiSmokeTests COMMAND Recorder.NativeBridge.CAbiSmokeTests)

    add_executable(Recorder.Wav.Tests wav/tests/wav_writer_tests.cpp)
    target_compile_features(Recorder.Wav.Tests PRIVATE cxx_std_17)
    target_link_libraries(Recorder.Wav.Tests PRIVATE Recorder.Wav)
    recorder_enable_strict_warnings(Recorder.Wav.Tests)
    add_test(NAME Recorder.Wav.Tests COMMAND Recorder.Wav.Tests)

    # Keep the Media Foundation sink lifecycle independently exercised; the
    # ABI-only contract tests cannot cover repeated AAC sink finalization.
    add_executable(Recorder.M4aWriter.Tests
        tests/m4a_writer_tests.cpp
        src/m4a_writer.cpp
    )
    target_compile_features(Recorder.M4aWriter.Tests PRIVATE cxx_std_17)
    target_include_directories(Recorder.M4aWriter.Tests PRIVATE src)
    target_link_libraries(Recorder.M4aWriter.Tests PRIVATE mfplat mfreadwrite mfuuid)
    recorder_enable_strict_warnings(Recorder.M4aWriter.Tests)
    add_test(NAME Recorder.M4aWriter.Container COMMAND Recorder.M4aWriter.Tests container --frames 960)
    # AAC encoders commonly consume 1024 sample access units. These tests make
    # the writer prove that its final partial block is padded safely, rather
    # than relying on one canonical capture block size.
    add_test(NAME Recorder.M4aWriter.TailOneFrame COMMAND Recorder.M4aWriter.Tests tail --frames 1)
    add_test(NAME Recorder.M4aWriter.Tail960Frames COMMAND Recorder.M4aWriter.Tests tail --frames 960)
    add_test(NAME Recorder.M4aWriter.Tail1024Frames COMMAND Recorder.M4aWriter.Tests tail --frames 1024)
    add_test(NAME Recorder.M4aWriter.AudibleSignalRoundTrip COMMAND Recorder.M4aWriter.Tests signal)
    # One deterministic in-process exercise. For teardown isolation, repeat
    # this CTest test from the command line so every repetition is a fresh EXE.
    add_test(NAME Recorder.M4aWriter.Stress COMMAND Recorder.M4aWriter.Tests stress --iterations 16 --frames 960)
    add_test(NAME Recorder.M4aWriter.Duration COMMAND Recorder.M4aWriter.Tests duration)
    add_test(NAME Recorder.M4aWriter.Abort COMMAND Recorder.M4aWriter.Tests abort)
    add_test(NAME Recorder.M4aWriter.AbortAfterOneFrame
        COMMAND Recorder.M4aWriter.Tests abort-after-write --frames 1)
    add_test(NAME Recorder.M4aWriter.AbortAfter960Frames
        COMMAND Recorder.M4aWriter.Tests abort-after-write --frames 960)

    add_executable(Recorder.Mp4MuxWriter.Tests
        tests/mp4_mux_writer_tests.cpp
        src/mp4_mux_writer.cpp
    )
    target_compile_features(Recorder.Mp4MuxWriter.Tests PRIVATE cxx_std_17)
    target_include_directories(Recorder.Mp4MuxWriter.Tests PRIVATE src)
    target_link_libraries(Recorder.Mp4MuxWriter.Tests PRIVATE Recorder.NativeBridge mfplat mfreadwrite mfuuid)
    recorder_enable_strict_warnings(Recorder.Mp4MuxWriter.Tests)
    add_test(NAME Recorder.Mp4MuxWriter.Container COMMAND Recorder.Mp4MuxWriter.Tests)

    # AT-03/AT-05 deterministic media evidence. The CTest default is short so
    # the regular verifier remains bounded; release acceptance runs the same
    # executable with --duration-seconds 300 (and three 600-second runs).
    add_executable(Recorder.AvMarkerAcceptance.Tests
        tests/av_marker_acceptance_tests.cpp
        src/mp4_mux_writer.cpp
    )
    target_compile_features(Recorder.AvMarkerAcceptance.Tests PRIVATE cxx_std_17)
    target_include_directories(Recorder.AvMarkerAcceptance.Tests PRIVATE src)
    target_link_libraries(Recorder.AvMarkerAcceptance.Tests PRIVATE mfplat mfreadwrite mfuuid ole32)
    recorder_enable_strict_warnings(Recorder.AvMarkerAcceptance.Tests)
    add_test(NAME Recorder.AvMarkerAcceptance.Short COMMAND Recorder.AvMarkerAcceptance.Tests)
    set_tests_properties(Recorder.AvMarkerAcceptance.Short PROPERTIES LABELS "av;media-foundation" RUN_SERIAL TRUE TIMEOUT 180)

    add_executable(Recorder.BgraToNv12.Tests tests/bgra_to_nv12_tests.cpp)
    target_compile_features(Recorder.BgraToNv12.Tests PRIVATE cxx_std_17)
    target_link_libraries(Recorder.BgraToNv12.Tests PRIVATE Recorder.WgcCaptureProbe)
    recorder_enable_strict_warnings(Recorder.BgraToNv12.Tests)
    add_test(NAME Recorder.BgraToNv12.Tests COMMAND Recorder.BgraToNv12.Tests)
    add_test(NAME Recorder.M4aWriter.AbortAfter1024Frames
        COMMAND Recorder.M4aWriter.Tests abort-after-write --frames 1024)
    add_test(NAME Recorder.M4aWriter.SplitOnePlus1023
        COMMAND Recorder.M4aWriter.Tests split --frames 1)
    add_test(NAME Recorder.M4aWriter.Split960Plus64
        COMMAND Recorder.M4aWriter.Tests split --frames 960)
    add_test(NAME Recorder.M4aWriter.AbortState
        COMMAND Recorder.M4aWriter.Tests abort-state)
    add_test(NAME Recorder.M4aWriter.PublishFailureRetention
        COMMAND Recorder.M4aWriter.Tests publish-failure)
    add_test(NAME Recorder.M4aWriter.FaultAfterOneBlockRecovery
        COMMAND Recorder.M4aWriter.Tests fault-after --iterations 1)
    add_test(NAME Recorder.M4aWriter.FaultAfterSevenBlocksRecovery
        COMMAND Recorder.M4aWriter.Tests fault-after --iterations 7)
    set_tests_properties(
        Recorder.M4aWriter.Container
        Recorder.M4aWriter.TailOneFrame
        Recorder.M4aWriter.Tail960Frames
        Recorder.M4aWriter.Tail1024Frames
        Recorder.M4aWriter.AudibleSignalRoundTrip
        Recorder.M4aWriter.Stress
        Recorder.M4aWriter.Duration
        Recorder.M4aWriter.Abort
        Recorder.M4aWriter.AbortAfterOneFrame
        Recorder.M4aWriter.AbortAfter960Frames
        Recorder.M4aWriter.AbortAfter1024Frames
        Recorder.M4aWriter.SplitOnePlus1023
        Recorder.M4aWriter.Split960Plus64
        Recorder.M4aWriter.AbortState
        Recorder.M4aWriter.PublishFailureRetention
        Recorder.M4aWriter.FaultAfterOneBlockRecovery
        Recorder.M4aWriter.FaultAfterSevenBlocksRecovery
        PROPERTIES
            LABELS "m4a;media-foundation"
            RUN_SERIAL TRUE
            TIMEOUT 90
    )

    if(WIN32)
        add_executable(Recorder.WasapiCapture.EndpointProbe
            audio/tests/wasapi_capture_probe.cpp
        )
        target_compile_features(Recorder.WasapiCapture.EndpointProbe PRIVATE cxx_std_17)
        target_link_libraries(Recorder.WasapiCapture.EndpointProbe PRIVATE Recorder.WasapiCapture)
        recorder_enable_strict_warnings(Recorder.WasapiCapture.EndpointProbe)
        add_test(NAME Recorder.WasapiCapture.EndpointProbe COMMAND Recorder.WasapiCapture.EndpointProbe)

        add_executable(Recorder.ProcessLoopback.Tests
            process_loopback/process_loopback_tests.cpp
        )
        target_compile_features(Recorder.ProcessLoopback.Tests PRIVATE cxx_std_17)
        target_link_libraries(Recorder.ProcessLoopback.Tests PRIVATE Recorder.ProcessLoopback)
        recorder_enable_strict_warnings(Recorder.ProcessLoopback.Tests)
        add_test(NAME Recorder.ProcessLoopback.Tests COMMAND Recorder.ProcessLoopback.Tests)

        add_executable(Recorder.Format.Tests
            format/tests/mix_format_decoder_tests.cpp
        )
        target_compile_features(Recorder.Format.Tests PRIVATE cxx_std_17)
        target_link_libraries(Recorder.Format.Tests PRIVATE Recorder.Format)
        recorder_enable_strict_warnings(Recorder.Format.Tests)
        add_test(NAME Recorder.Format.Tests COMMAND Recorder.Format.Tests)

        add_executable(Recorder.Resample.Tests
            resample/tests/linear_resampler_tests.cpp
        )
        target_compile_features(Recorder.Resample.Tests PRIVATE cxx_std_17)
        target_link_libraries(Recorder.Resample.Tests PRIVATE Recorder.Resample)
        recorder_enable_strict_warnings(Recorder.Resample.Tests)
        add_test(NAME Recorder.Resample.Tests COMMAND Recorder.Resample.Tests)

        add_executable(Recorder.Downmix.Tests
            downmix/tests/stereo_downmix_tests.cpp
        )
        target_compile_features(Recorder.Downmix.Tests PRIVATE cxx_std_17)
        target_link_libraries(Recorder.Downmix.Tests PRIVATE Recorder.Downmix)
        recorder_enable_strict_warnings(Recorder.Downmix.Tests)
        add_test(NAME Recorder.Downmix.Tests COMMAND Recorder.Downmix.Tests)

        add_executable(Recorder.Timeline.Tests
            timeline/tests/canonical_timeline_tests.cpp
        )
        target_compile_features(Recorder.Timeline.Tests PRIVATE cxx_std_17)
        target_link_libraries(Recorder.Timeline.Tests PRIVATE Recorder.Timeline)
        recorder_enable_strict_warnings(Recorder.Timeline.Tests)
        add_test(NAME Recorder.Timeline.Tests COMMAND Recorder.Timeline.Tests)

        add_executable(Recorder.WgcWindowCaptureSession.Tests
            video/wgc_window_capture_session_tests.cpp
        )
        target_compile_features(Recorder.WgcWindowCaptureSession.Tests PRIVATE cxx_std_17)
        target_link_libraries(Recorder.WgcWindowCaptureSession.Tests
            PRIVATE Recorder.WgcWindowCaptureSession)
        recorder_enable_strict_warnings(Recorder.WgcWindowCaptureSession.Tests)
        add_test(NAME Recorder.WgcWindowCaptureSession.Tests
            COMMAND Recorder.WgcWindowCaptureSession.Tests)

        add_executable(Recorder.SelectedAudioSessionFacade.Tests
            tests/selected_audio_session_facade_tests.cpp
        )
        target_compile_features(Recorder.SelectedAudioSessionFacade.Tests PRIVATE cxx_std_17)
        target_include_directories(Recorder.SelectedAudioSessionFacade.Tests PRIVATE src)
        recorder_enable_strict_warnings(Recorder.SelectedAudioSessionFacade.Tests)
        add_test(NAME Recorder.SelectedAudioSessionFacade.Tests
            COMMAND Recorder.SelectedAudioSessionFacade.Tests)

    endif()
endif()
