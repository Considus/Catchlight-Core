# Agent notes

For a coding agent working in this repo. `README.md` and `CONTRIBUTING.md` are the human documents; read the rules in the README first.

Every task moves through four beats: isolate on a branch, build, prove with evidence, ship a PR carrying that evidence.

## What this repo is

`CatchlightCore`, the platform-agnostic Swift package every Catchlight app builds against: the Take model, the platform-agnostic JSON file format, the crypto chain, the sync engine, export and import, link detection. It moved here from `Considus/Catchlight-iOS` on 2026-10-03 ([[D-344]]), with its history.

Consumers pin an exact version (`exactVersion` in each app's `project.yml`). A release here reaches an app only through an update PR in that app, which runs the app's own tests ([[D-344]]). Never assume a change here is live anywhere until those PRs merge.

## Isolate

```bash
git fetch origin
gh pr list -R Considus/Catchlight-Core
git checkout -b <type>/<short-name> origin/main
```

Stage by explicit path. Never `git add -A` or `git commit -a`. A fresh clone needs the committed hooks wired up once:

```bash
git config core.hooksPath hooks
```

`hooks/pre-commit` refuses commits on `main`; `hooks/commit-msg` refuses Claude attribution footers.

## Build

🚨 **`Sources/CatchlightCore/Crypto/` holds frozen contract bytes.** The domain-separation strings and derivation parameters had specialist sign-off on 2026-06-05, revised to v1.1 on 2026-06-10, and every client on every platform has to agree on them. Changing one is not a refactor, it breaks existing data. Do not propose it.

🚨 **The on-disk format is shared with every app and every device.** A change to what is written (a Take field, the manifest, an envelope) needs a reader for the old shape, and the apps have to agree it before it ships. Additive optional fields are the safe shape; see `ManifestEntry.kind` (D-315) for the precedent.

`Sources/CatchlightCoreTestSupport/` is the second library product, for test targets only: the `TakeStoreContractTests` base class every app subclasses with its own store, and the shared fixtures (`TestFixtures.richTake`, `Take.primaryText`). Its tests also run here against `InMemoryTakeStore`. A change to the contract reaches each store through its pin bump, so treat it like an API change.

🚨 **Only a test target that is not hosted in an app can link it.** A hosted test bundle (Catchlight-iOS's) gets a second copy of CatchlightCore from this product, beside the app's (`objc: Class _TtC14CatchlightCore… is implemented in both`), and every cast across the two copies fails: the app's store throws its copy's `StorageError` and the contract's `guard case StorageError.notFound` sees another type. Measured on Catchlight-iOS#309, which reverted it. The Mac app's tests (they compile the app's sources) and Catchlight-AppleStorage's package tests use it; iOS keeps its copy of the contract, identical to this one at the pinned tag. The XCTest file sits inside `#if canImport(XCTest)` so `swift build` still works with only the Command Line Tools.

Core has no platform dependencies: Keychain, storage, file protection and the cloud folder are injected through protocols and implemented in each app. Keep it that way. No network code, ever (there is none today).

No third-party dependencies without the owner agreeing it first. The only one is `swift-crypto` (owner-agreed 2026-10-05), linked on Linux and Windows only (`linuxCrypto`, named before Windows joined, in `Package.swift`). Every file that needs crypto imports it as:

```swift
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
```

so Apple builds link CryptoKit and never swift-crypto. Under `import Crypto`, swift-crypto's `CryptoError` clashes with Core's own, so code outside the `CatchlightCore` module (tests, `coreverify`) writes `CatchlightCore.CryptoError`.

## Prove

```bash
BUILD_DIR="$HOME/CatchlightBuild"
swift build --scratch-path "$BUILD_DIR/spm"
swift run   --scratch-path "$BUILD_DIR/spm" coreverify   # must pass before any PR
swift test  --scratch-path "$BUILD_DIR/spm"
```

Read the test count, never the word "passed". CI also runs the suite on the iOS simulator (`xcodebuild test -scheme CatchlightCore-Package`), oldest and newest runtimes, on Linux in the official Swift image (`linux-tests`) and on Windows with the swift.org toolchain (`windows-tests`), where the same known-answer vectors run against swift-crypto. The macOS and Linux `Executed N tests` lines differ only by Apple-only suites: Linux skips the two LinkDetector suites (they pin `NSDataDetector`) and compiles out 15 Spotlight tests (`CoreSpotlight`). Linux also never runs the 31 `TakeStoreContractTests`: they live in the `CatchlightCoreTestSupport` library, and Linux test discovery sees only methods declared in the test target (a subclass there inherits none it can find). Expect Linux to report 46 fewer tests than macOS (the 15 Spotlight and 31 contract tests), and 26 of the tests it does report (the LinkDetector suites) to be skipped. Windows has no `NSDataDetector` or `CoreSpotlight` either, so its count should match Linux's; a difference means a suite was dropped or compiled out, and is worth reading before merging.

To exercise the swift-crypto (BoringSSL) path on a Mac without Linux, copy the package to a scratch folder, point it at a local swift-crypto checkout with `let development = true` in that checkout's `Package.swift`, drop the platform condition from `linuxCrypto`, and replace the guarded imports with `import Crypto`. Never commit that setup.

`Fuzz/` is a separate SwiftPM package of libFuzzer targets over Core's untrusted-input parsers (import, manifest, blob, recovery phrase). The root build never sees it, and it runs on Linux only; `Fuzz/README.md` has the commands. Every crash it finds is pinned in `FuzzRegressionTests`, and lands in the same PR as its fix, because a trap kills the whole test run.

**An expected value comes from outside the code under test**: a known-good literal, a worked example, the spec, or a captured fixture. Tests live at public seams, not internals.

`Scripts/generate_tld_list.py` regenerates `Sources/CatchlightCore/Text/TLDList.swift` from IANA. The nightly audit checks the list for drift (`Catchlight-Ops/check_tld_list.py`). The Mac prototype's `ui/tlds.js` is a copy of the same list and is refreshed with it.

## Ship

Run `/code-review` locally before opening the PR. Every PR gets one automatic Claude review (`.github/workflows/claude-review.yml`); after a push, add the `re-review` label so the review covers the new head (remove it first if it is on). Closing and reopening also works but re-runs Greptile, which spends a credit. A release is a tag (`X.Y.Z`) on `main` after the PR merges; each app then takes it through its own update PR.
