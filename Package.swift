// swift-tools-version: 5.9
//
// Catchlight — CatchlightCore
//
// The platform-agnostic heart of Catchlight. Pure Swift + Apple CryptoKit on Apple
// platforms; swift-crypto (Apple's open-source implementation of the same API) on
// Linux and Windows only, where CryptoKit does not exist. Every file that uses it imports
// CryptoKit under `#if canImport(CryptoKit)` and falls back to `Crypto`, so Apple
// builds never link swift-crypto. No UIKit, no SwiftUI, no SQLCipher —
// every platform-specific dependency (storage, cloud folder) is injected through
// a protocol (see Storage/ and Sync/). Master-key derivation is HKDF-SHA-256 via
// CryptoKit (see Crypto/MasterKeyDerivation.swift). This is what makes the
// Roadmap §4 cross-platform
// constraint real rather than aspirational: the exact same source compiles for
// iOS, macOS, and (with swift-crypto) Linux, and the file format it produces is
// readable by a future WebCrypto/WASM or Android/Tink client.
//
// It builds and its full test suite runs on macOS with the Command Line Tools
// toolchain, and on Linux (CI runs both). CryptoKit is a system framework on
// macOS, so HKDF, ChaCha20-Poly1305, HMAC-SHA-256 and X25519 are exercised for
// real there; on Linux the same tests and vectors run against swift-crypto.
//
import PackageDescription

/// swift-crypto's `Crypto` module, linked only where CryptoKit is unavailable
/// (Linux and Windows).
let linuxCrypto: Target.Dependency = .product(
    name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])
)

let package = Package(
    name: "CatchlightCore",
    platforms: [
        .macOS(.v13),     // for local test execution; iOS target is configured in the app project
        .iOS("18.0")      // D-039 — floor raised to iOS 18.0 (2026-06-14). String form
                          // because the `.v18` enum case needs swift-tools-version 6.0+
                          // (this manifest is 5.9).
    ],
    products: [
        .library(name: "CatchlightCore", targets: ["CatchlightCore"]),
        // For test targets only: the shared TakeStore contract and fixtures, so
        // each app runs the contract against its own store instead of a copy.
        .library(name: "CatchlightCoreTestSupport", targets: ["CatchlightCoreTestSupport"]),
        .executable(name: "coreverify", targets: ["coreverify"])
    ],
    dependencies: [
        // Linux and Windows only (see the target conditions below). SwiftPM still resolves it
        // on Apple platforms, but nothing there links it.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")
    ],
    targets: [
        .target(
            name: "CatchlightCore",
            dependencies: [linuxCrypto],
            path: "Sources/CatchlightCore"
        ),
        .target(
            name: "CatchlightCoreTestSupport",
            dependencies: ["CatchlightCore"],
            path: "Sources/CatchlightCoreTestSupport"
        ),
        // XCTest-based suite — the canonical Phase 5 §12 tests. Runs under a full
        // Xcode toolchain / CI (`swift test` or the Xcode test action).
        .testTarget(
            name: "CatchlightCoreTests",
            dependencies: ["CatchlightCore", "CatchlightCoreTestSupport", linuxCrypto],
            path: "Tests/CatchlightCoreTests"
        ),
        // A dependency-free executable that re-runs the same scenarios with a tiny
        // assert harness. Exists so the core can be verified GREEN on a
        // Command-Line-Tools-only machine (no Xcode, no XCTest). `swift run coreverify`.
        .executableTarget(
            name: "coreverify",
            dependencies: ["CatchlightCore", linuxCrypto],
            path: "Sources/coreverify"
        )
    ]
)
