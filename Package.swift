// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalMeetingRecorder",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "LocalMeetingRecorder", targets: ["RecorderApp"])
    ],
    targets: [
        .target(
            name: "VirtualMicBridge",
            path: "Sources/VirtualMicBridge"
        ),
        .executableTarget(
            name: "RecorderApp",
            dependencies: ["VirtualMicBridge"],
            resources: [
                .process("Resources/release-manifest.json")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Security"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .testTarget(
            name: "RecorderAppTests",
            dependencies: ["RecorderApp"]
        )
    ],
    cxxLanguageStandard: .cxx17
)
