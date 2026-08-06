# Prebuilts

This repository builds binary dependencies used by Passepartout and Partout.

## Workflows

- `Partout Vendors` builds Partout vendors from the pinned `partout` submodule, as one workflow job per target:
  - OpenSSL
  - Mbed TLS
  - wg-go
- `Windows wxWidgets` builds static wxWidgets libraries with MSVC.
- `Release Prebuilts` downloads artifacts from successful build workflow runs and uploads them to a GitHub Release.

All workflows are manual (`workflow_dispatch`) while the packaging format is still settling. Build workflows only upload GitHub Actions artifacts. The release workflow takes a required `release_tag`, optional build run IDs, and publishes the downloaded artifacts as release assets.

Partout owns the vendor build logic through its CMake project. The build jobs enable bundled vendors, set `PP_BUILD_LIBRARY=OFF`, and build the OpenSSL, Mbed TLS, and wg-go vendor targets without building Partout itself.

The Apple job produces static `openssl.xcframework`, `mbedtls.xcframework`, and `wg-go.xcframework` archives for:

- iOS device (`arm64`) and simulator (`arm64`, `x86_64`)
- macOS (`arm64`, `x86_64`)
- tvOS device (`arm64`) and simulator (`arm64`, `x86_64`)

OpenSSL's `libssl.a` and `libcrypto.a` are consolidated into one archive per slice. Mbed TLS's `libmbedtls.a`, `libmbedx509.a`, and `libmbedcrypto.a` are consolidated in the same way. wg-go is built with Go's `c-archive` mode. The final XCFrameworks contain only `.a` libraries and headers; generated dylibs are not packaged.

Each Apple XCFramework is zipped as an independent SwiftPM-compatible release asset with `.checksum` and `.sha256` sidecars. The job also emits `partout-vendors-apple-manifest.json` with source revisions, deployment targets, and toolchain versions. Build all Apple slices locally with:

```sh
scripts/checkout-partout.sh
scripts/build-partout-apple-xcframeworks.sh all
```

The current Android target is `arm64-v8a` only. Windows `wg-go` is built on Windows with Go and llvm-mingw clang for cgo. Non-Apple target jobs emit one target archive plus a `.sha256` sidecar: `.tar.gz` for Android and `.zip` for Windows.

## Version Pins

The workflow files are the source of truth for pinned toolchain versions. The `partout` submodule is the source of truth for vendor build logic and bundled vendor pins. Build packages include a root `manifest.json` with the exact source refs, library versions, target, and toolchain metadata used for that artifact.

`wg-go` is tracked directly in Partout rather than as a submodule, so its source revision is the pinned Partout commit. Its upstream WireGuard Go dependency is pinned by Partout's `vendors/wg-go/go.mod` and `go.sum`.

Tooling otherwise comes from the selected GitHub-hosted runner images, using their stable CMake, Ninja, MSVC, PowerShell, tar/gzip, and Go toolchain cache.
