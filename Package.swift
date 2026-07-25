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
        .executableTarget(
            name: "RecorderApp",
            resources: [
                .process("Resources/release-manifest.json")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Security"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "RecorderAppTests",
            dependencies: ["RecorderApp"]
        )
    ]
)
