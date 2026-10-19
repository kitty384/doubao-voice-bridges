// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DoubaoVoiceBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DoubaoVoiceBridge", targets: ["DoubaoVoiceBridge"])
    ],
    targets: [
        .executableTarget(
            name: "DoubaoVoiceBridge",
            path: "Sources/DoubaoVoiceBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
