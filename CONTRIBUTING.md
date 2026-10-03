# Contributing to Catchlight Core

Thanks for taking a look. Catchlight holds people's private notes, and it holds them under a key the user controls and nobody else has, so the constraints below aren't house style. They are the reason the app is worth having.

## Before you write anything

Read the non-negotiables in `README.md`, the zero-knowledge and encryption-always-on ones in particular. A contribution that weakens either of them won't be accepted, however good the rest of it is.

The encryption architecture had specialist sign-off on 2026-06-05 and was revised to v1.1 on 2026-06-10. The domain-separation strings and derivation parameters in `Sources/CatchlightCore/Crypto/` are frozen cross-platform contract bytes, so please don't propose changes to them. They are the bytes every future client has to agree on.

## Development setup

The Command Line Tools are enough to build Core and run its checks, and the full test suite needs Xcode. Keep build output outside the source tree, as described in `README.md`.

```bash
BUILD_DIR="$HOME/CatchlightBuild"
swift build  --scratch-path "$BUILD_DIR/spm"
swift run    --scratch-path "$BUILD_DIR/spm" coreverify   # the runtime checks, and they must pass before any PR
swift test   --scratch-path "$BUILD_DIR/spm"
```

## Pull requests

- Every PR has to pass `swift test` with no regressions.
- No analytics, no telemetry, nothing transmitted off the device. Ever.
- No change to the format Takes are saved in unless the apps have agreed a way to read the old one, because people's existing Takes are written in it.
- Follow the code style that is already there.
- No third-party dependencies without talking about it first.

## Security issues

Please don't open a public issue for a security vulnerability. [`SECURITY.md`](SECURITY.md) says how to report one privately.
