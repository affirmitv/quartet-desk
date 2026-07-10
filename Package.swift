// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuartetDeskKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuartetEngine", targets: ["QuartetEngine"]),
        .library(name: "QuartetProviders", targets: ["QuartetProviders"]),
        .library(name: "QuartetExport", targets: ["QuartetExport"]),
        .library(name: "QuartetUI", targets: ["QuartetUI"]),
    ],
    targets: [
        // UI-free, network-free core: seat config, prompt assembly, SSE parsing,
        // dissent parsing, price math, orchestration. Fully unit-testable.
        .target(name: "QuartetEngine"),

        // Network clients (Anthropic Messages API + OpenAI-chat-compatible),
        // Keychain storage, live key testing.
        .target(name: "QuartetProviders", dependencies: ["QuartetEngine"]),

        // Markdown export + on-disk run history.
        .target(name: "QuartetExport", dependencies: ["QuartetEngine"]),

        // SwiftUI views + app model. The App/ folder (xcodegen target) is a thin
        // @main shell over this module.
        .target(name: "QuartetUI", dependencies: ["QuartetEngine", "QuartetProviders", "QuartetExport"]),

        .testTarget(name: "QuartetEngineTests", dependencies: ["QuartetEngine"]),
    ]
)
