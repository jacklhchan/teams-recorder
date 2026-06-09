// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalMeetingRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalMeetingRecorder", targets: ["RecorderApp"])
    ],
    targets: [
        .executableTarget(
            name: "RecorderApp",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
