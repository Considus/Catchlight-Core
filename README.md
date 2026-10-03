# Catchlight Core

This is the part of Catchlight that has to behave exactly the same on every device: the encryption, the format your Takes are saved in, and the sync engine that moves them between your iPhone and your Mac. The apps live in their own repos, [Catchlight-iOS](https://github.com/Considus/Catchlight-iOS) and [Catchlight-MacOS](https://github.com/Considus/Catchlight-MacOS), and both build against this package.

It's public so you can check it. Catchlight rests on one promise, that you hold the key to your Takes and nobody else does, me included, and a promise like that is only worth something if you can read the code that keeps it.

## What's in it

The encryption, in `Crypto/`, all through Apple CryptoKit. Your Privacy phrase is 12 BIP-39 words, and HKDF turns them into a master key. From that comes a key for each job, and Core seals each Take with AES-256-GCM. The sync manifest carries an HMAC-SHA-256, so Core catches a tampered file before it reads a word of it. There's also an X25519 handshake for passing the key from one of your devices to another, which, for now, no app uses.

The Take itself, in `Model/`: its lines and checklist items, time and place reminders, the Obie, manual ordering, and the 5 Takes a new account starts with.

Sync, in `Sync/`. It reads and writes encrypted files in a folder you choose, then keeps a manifest of what's there, with tombstones so a deletion travels as well as an edit. It also settles conflicts, and holds a lock so two devices never write at once.

Then the smaller pieces: Markdown export and import, link detection, the JSON codec every client shares, and a diagnostics log that never records what you wrote.

Nothing in here touches the Keychain, a database or the disk directly. Each app brings its own and hands it in through a protocol, which is why the same code builds for iOS and macOS, and why a version with swift-crypto standing in for CryptoKit can follow for Windows and Linux.

## Building it

If your copy sits in a synced folder, keep the build output somewhere else, or the sync spends its day uploading compiler leftovers.

With only the Command Line Tools installed, you can build Core and run its checks:

```bash
BUILD_DIR="$HOME/CatchlightBuild"
swift build --scratch-path "$BUILD_DIR/spm"
swift run   --scratch-path "$BUILD_DIR/spm" coreverify
```

`coreverify` runs the same scenarios as the test suite in a small harness of its own, because the Command Line Tools don't include XCTest. It prints its own count when it finishes, which is why this page doesn't.

With full Xcode installed, run the whole suite as well:

```bash
swift test --scratch-path "$BUILD_DIR/spm"
```

## Using it in an app

Add it as a Swift package and pin an exact version:

```swift
.package(url: "https://github.com/Considus/Catchlight-Core", exact: "1.0.1")
```

A new version can change what gets written to disk, so an app should take one on purpose, with its own tests run against it, and never pick one up by accident.

There's a second product, `CatchlightCoreTestSupport`, for an app's test target and never the app itself. It carries the contract every Take store has to meet, as a test class you subclass with your own store, so the iPhone's database and the Mac's are held to the same tests rather than to two copies that drift apart.

## The non-negotiables

The domain-separation strings and derivation parameters in `Sources/CatchlightCore/Crypto/` are fixed. Every Catchlight app, on every device, has to agree on them, so changing one doesn't tidy anything up, it locks people out of their own Takes.

Beyond that:

- Nothing leaves the device. No backend, no analytics, no network calls from Core at all.
- Encryption is always on. It's never optional, and there's no switch for it.
- Everything works offline. Sync is something extra, and running with no cloud folder at all is a proper way to use Catchlight.
- The cloud folder holds encrypted JSON files and one plain-text metadata file, and nothing else.

## Licence

Apache 2.0, in [`LICENSE`](LICENSE), with the notice in [`NOTICE`](NOTICE). If you've found a way past the encryption, please tell me privately, as [`SECURITY.md`](SECURITY.md) describes, rather than in an issue.
