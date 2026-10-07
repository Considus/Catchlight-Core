// swift-tools-version:5.4
//
// Catchlight — CatchlightCore fuzz targets
//
// A separate package so the root `swift build` and `swift test` never see it. Each
// executable is a libFuzzer target over one of Core's parsers of untrusted input. They
// define `LLVMFuzzerTestOneInput` and no `main`, so they link only under the fuzzer
// sanitizer, on Linux, from this folder:
//
//     swift build -c debug -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library
//
// Tools version 5.4 on purpose: from 5.5 SwiftPM renames each executable's entry point to
// `<module>_main`, which libFuzzer's own `main` does not provide, so the link fails.
//
// `fuzz-seeds` is an ordinary executable that writes each target's starting corpus from
// Core's own fixtures. README.md has the commands.
//
import PackageDescription

let package = Package(
    name: "CatchlightCoreFuzz",
    platforms: [.macOS("13.0")],
    dependencies: [
        .package(name: "CatchlightCore", path: "..")
    ],
    targets: [
        .target(
            name: "FuzzSupport",
            dependencies: [.product(name: "CatchlightCore", package: "CatchlightCore")]
        ),
        .executableTarget(name: "fuzz-import", dependencies: ["FuzzSupport"], path: "Sources/FuzzImport"),
        .executableTarget(name: "fuzz-manifest", dependencies: ["FuzzSupport"], path: "Sources/FuzzManifest"),
        .executableTarget(name: "fuzz-blob", dependencies: ["FuzzSupport"], path: "Sources/FuzzBlob"),
        .executableTarget(name: "fuzz-phrase", dependencies: ["FuzzSupport"], path: "Sources/FuzzPhrase"),
        .executableTarget(name: "fuzz-capture-inbox", dependencies: ["FuzzSupport"], path: "Sources/FuzzCaptureInbox"),
        .executableTarget(
            name: "fuzz-seeds",
            dependencies: [
                "FuzzSupport",
                .product(name: "CatchlightCoreTestSupport", package: "CatchlightCore")
            ],
            path: "Sources/FuzzSeeds"
        )
    ]
)
