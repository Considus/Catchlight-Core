# CatchlightCore fuzz targets

libFuzzer targets over Core's parsers of untrusted input. This is its own SwiftPM package (it depends on Core by path), so the root `swift build` and `swift test` never build it. Linux only: libFuzzer ships with the Linux toolchains, not with Xcode's.

| Target | Input | What it reaches |
|---|---|---|
| `fuzz-import` | a Markdown or text file the user imports | `TakeImporter.parseDocument` and `parse`, the `<!-- catchlight:data` block through `TakeTransfer.decoder()` |
| `fuzz-manifest` | first byte = mode, then `catchlight-manifest.json` (mode 0, no key), a v3 body sealed and signed with a fixed key (1), or a v1/v2 manifest re-signed (2) | `ManifestEnvelope`/`Manifest` decoding, `ManifestSigner.verify`, `Manifest.opening`, then a full `pullInbound` + `pushOutbound` (`readVerifiedManifest`) |
| `fuzz-blob` | first byte = mode, then a `.clk` file (0, no key), a Take's JSON plaintext sealed under its item key (1), or a `.clk` listed with its correct HMAC (2) | `CloudBlob.parse`, `CryptoService.decrypt`, `TakeCrypto.open`, then pull + push |
| `fuzz-phrase` | first byte = mode, then a typed or pasted phrase (0) or 16 bytes of entropy (1) | `PhraseRecovery.recoverMasterKey`, `BIP39.validate` and `mnemonic(fromEntropy:)` |

The fixed key, store and folder are in `Sources/FuzzSupport`. Core ships no BIP-39 wordlist, so `fuzz-phrase` uses the unit tests' synthetic one (`w0` … `w2047`); `phrase.dict` holds its words.

## Run

In the official Swift image (CI's `linux-tests` pins the same one by digest), from the repository root:

```bash
docker run --rm -it -v "$PWD":/src -w /src/Fuzz swift:6.2.4-noble bash
```

Then, inside the container:

```bash
# Build the four targets (by product: fuzz-seeds cannot link under the fuzzer sanitizer).
for p in fuzz-import fuzz-manifest fuzz-blob fuzz-phrase; do
  swift build -c debug --product $p -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library
done

# Write the starting corpora from Core's own fixtures (an ordinary build, no sanitizer).
swift build -c debug --scratch-path .build-seeds --product fuzz-seeds
.build-seeds/debug/fuzz-seeds seeds

# Run one target: 20 minutes or 5 million executions, whichever comes first.
# T is import, manifest, blob or phrase. `-dict` applies to import and phrase only.
export TZ=UTC SWIFT_BACKTRACE=enable=no ASAN_OPTIONS=detect_leaks=0
mkdir -p corpus/$T artifacts/$T
.build/debug/fuzz-$T corpus/$T seeds/$T -dict=$T.dict \
  -max_total_time=1200 -runs=5000000 -timeout=10 -rss_limit_mb=4096 -max_len=16384 \
  -print_final_stats=1 -artifact_prefix=artifacts/$T/

# Replay one input:
.build/debug/fuzz-$T artifacts/$T/crash-…
```

`SWIFT_BACKTRACE=enable=no` matters: Swift's own crash backtracer reads the stack in a way AddressSanitizer reports as a `dynamic-stack-buffer-overflow`, which buries the real trap. `TZ=UTC` because legacy-heading import reads dates in local time.

To keep going past a known crash, add `-fork=1 -ignore_crashes=1 -ignore_timeouts=1 -ignore_ooms=1`.

Every crash found is pinned as a test in `Tests/CatchlightCoreTests/FuzzRegressionTests.swift`.

Tools version 5.4 in `Package.swift` is deliberate: from 5.5 SwiftPM renames each executable's entry point to `<module>_main`, which libFuzzer's `main` does not provide.
