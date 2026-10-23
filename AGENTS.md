# Agent notes

For a coding agent working in this repo. People start with [`README.md`](README.md) (its non-negotiables first) and [`CONTRIBUTING.md`](CONTRIBUTING.md); this file does not repeat them.

## Build

- **Leave the frozen contract bytes in `Sources/CatchlightCore/Crypto/` as they are:** changing one breaks existing data.
- **Give every change to what is written (a Take field, the manifest, an envelope) a reader for the old shape,** agreed with the apps. Additive optional fields are safe: see `ManifestEntry.kind`, and `Take.kind` / `Take.pageMode`, written only when set so a Take's bytes never change (`TakeKindTests` pins them against a golden).
- **Ask `holds(_:)` whether this device may read an entry.** `SyncEngine(holdsScripts:)` is off on the phone and on for the desktop; the Script rules are in `SyncEngine.swift`'s doc comments, pinned by `SyncScriptEntryTests` and `SyncScriptsHeldTests`. A deletion record carries no kind, so with the option off, a Script deleted from the device's own store (the desktop before its Scripts sync) is the app's to keep local (Catchlight-MacOS does, in `App/Sources/Vault/Library.swift`).
- **Treat `CatchlightCoreTestSupport` (the store contract and shared fixtures) like an API.** Link it only from a test target not hosted in an app: a hosted bundle gets a second CatchlightCore and casts across the copies fail (Catchlight-iOS#309), so iOS keeps its own copy of the contract, matching the pinned tag. Keep its XCTest file inside `#if canImport(XCTest)` so `swift build` works with only the Command Line Tools.
- **`swift-crypto` is the one dependency,** for Linux and Windows only (`linuxCrypto`). Import crypto as below so Apple builds never link it, and outside the module write `CatchlightCore.CryptoError`, which clashes with swift-crypto's.

```swift
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
```

A release here is live in an app only once that app's pin-bump PR merges.

## Test

```bash
BUILD_DIR="$HOME/CatchlightBuild"
swift build --scratch-path "$BUILD_DIR/spm"
swift run   --scratch-path "$BUILD_DIR/spm" coreverify   # must pass before any PR
swift test  --scratch-path "$BUILD_DIR/spm"
```

Read the test **count**, not the word "passed". On CI (`.github/workflows/ci.yml`), Linux reports 46 fewer tests than macOS (15 Spotlight tests compiled out, 31 contract tests its discovery can't see) and skips 26 LinkDetector tests. Windows should match Linux; any other gap means a suite was dropped.

To try swift-crypto on a Mac, in a scratch copy: point at a local swift-crypto checkout (`let development = true` in its `Package.swift`), drop `linuxCrypto`'s platform condition, import `Crypto` directly. Never commit that.

`Fuzz/` is a separate, Linux-only libFuzzer package (`Fuzz/README.md`). Pin each crash in `FuzzRegressionTests`, in the same PR as its fix, because a trap kills the whole test run.

Take expected values from outside the code under test (a known-good literal, worked example, spec or captured fixture), and test at public seams.

`Scripts/generate_tld_list.py` regenerates `TLDList.swift` from IANA; refresh Catchlight-MacOS `ui/tlds.js`, a copy, with it.

## Ship

1. Install the committed hooks once per clone, copied from `origin/main` into git's own hooks folder. `hooks/pre-commit` refuses a commit on `main`, and `hooks/commit-msg` refuses a Claude attribution footer or an em or en dash.

   ```bash
   git fetch origin
   git config --unset core.hooksPath || true
   d="$(git rev-parse --git-common-dir)/hooks"; mkdir -p "$d"
   for h in pre-commit commit-msg; do git show "origin/main:hooks/$h" > "$d/$h" && chmod 755 "$d/$h"; done
   ```

   Never set `core.hooksPath` to `hooks`. Git would then run the hook files of whichever branch is checked out, so checking out an outsider's PR would run their code on your machine. The unset line removes that setting from a clone that followed the old instruction. While it is set, git ignores its own hooks folder. If `git config --show-origin --get core.hooksPath` still prints a value afterwards, it was set globally: remove it with `git config --global --unset core.hooksPath`. Copy again after a reviewed change to `hooks/` lands on `main`.
2. Check nobody is on the work; branch from `origin/main`:

   ```bash
   git fetch origin
   gh pr list -R Considus/Catchlight-Core
   git checkout -b <type>/<short-name> origin/main
   ```

3. Stage by explicit path, never `git add -A` or `git commit -a`.
4. Open the PR against `main` with [`.github/pull_request_template.md`](.github/pull_request_template.md) filled in.
