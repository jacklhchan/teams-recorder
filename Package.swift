// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalMeetingRecorder",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "RecorderControl", targets: ["RecorderControl"]),
        .executable(name: "recorderctl", targets: ["RecorderControlCLI"]),
        .executable(name: "LocalMeetingRecorder", targets: ["RecorderApp"])
    ],
    targets: [
        .target(name: "RecorderControl"),
        .executableTarget(
            name: "RecorderControlCLI",
            dependencies: ["RecorderControl"]
        ),
        .target(
            name: "VirtualMicBridge",
            path: "Sources/VirtualMicBridge"
        ),
        .executableTarget(
            name: "RecorderApp",
            dependencies: ["VirtualMicBridge", "RecorderControl"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVKit"),
                .linkedFramework("ApplicationServices"),
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
            dependencies: ["RecorderApp", "RecorderControl"]
        ),
        .testTarget(
            name: "RecorderControlTests",
            dependencies: ["RecorderControl"]
        ),
        .testTarget(
            name: "RecorderControlCLITests",
            dependencies: ["RecorderControlCLI", "RecorderControl"]
        )
    ],
    cxxLanguageStandard: .cxx17
)
