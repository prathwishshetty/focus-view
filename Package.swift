// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Focus",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Focus", targets: ["Focus"]),
        .library(name: "FocusCore", targets: ["FocusCore"]),
    ],
    targets: [
        // Pure, platform-independent logic: the split tree and address parsing.
        .target(name: "FocusCore"),
        // The macOS app: SwiftUI + AppKit + WKWebView.
        .executableTarget(
            name: "Focus",
            dependencies: ["FocusCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"]),
    ]
)
