# Prebuilts

This repository is the source of truth for third-party binary dependencies used by Passepartout and Partout. It owns the upstream source pins, patches, cross-platform build recipes, packaging, and release metadata.

## Vendor Builds

The repository invokes each vendor's native build directly: OpenSSL `Configure`, Mbed TLS `scripts/legacy.make`, Go's build toolchain for wg-go, and `nmake` for wxWidgets. There is no repository-level meta-build system.

Build scripts select one vendor and target at a time, matching the CI matrix:

```sh
scripts/build-apple-xcframeworks.sh all openssl
scripts/build-vendors.sh android-arm64-v8a mbedtls
scripts/build-vendors.sh linux-x64 wg-go
```

Initialize the OpenSSL and Mbed TLS sources before building:

```sh
scripts/checkout-vendors.sh
```

Consumers download the published vendor/platform archives independently. Partout uses system libraries where available and otherwise resolves the relevant vendor archive URL; this repository never checks out or builds Partout.

## Workflows

- `Vendor Prebuilts` (`partout-vendors.yml`) builds the vendor distribution matrix.
- `Windows wxWidgets` builds static wxWidgets libraries with MSVC.
- `Release Prebuilts` downloads successful workflow artifacts and uploads them to a GitHub Release.

All workflows are manual (`workflow_dispatch`) while the packaging format is settling. Build workflows upload GitHub Actions artifacts; the release workflow publishes those artifacts as release assets.

The vendor workflow can build `all`, `openssl`, `mbedtls`, or `wg-go`. Selecting one vendor rebuilds it for every platform it supports. Every matrix entry emits a release-ready vendor/platform artifact; `all` only selects the complete matrix.

The release workflow defaults to the latest successful `all` run. Pass a specific vendor workflow run ID to publish or replace only that run's vendor artifacts.

### Apple XCFrameworks

The Apple matrix builds OpenSSL, Mbed TLS, and wg-go in separate parallel jobs. Each job produces one static XCFramework containing slices for:

- iOS device (`arm64`) and simulator (`arm64`, `x86_64`)
- macOS (`arm64`, `x86_64`)
- tvOS device (`arm64`) and simulator (`arm64`, `x86_64`)

OpenSSL's `libssl.a` and `libcrypto.a` are consolidated into one archive per slice. Mbed TLS's `libmbedtls.a`, `libmbedx509.a`, and `libmbedcrypto.a` are consolidated similarly. wg-go uses Go's `c-archive` mode. No dynamic library is included in an Apple XCFramework.

Each job emits a zipped SwiftPM-compatible XCFramework, a `.checksum` sidecar, and vendor metadata for release aggregation. Build all Apple vendors locally with:

```sh
scripts/build-apple-xcframeworks.sh all
```

Pass a vendor as the second argument to reproduce one CI job, for example:

```sh
scripts/build-apple-xcframeworks.sh all openssl
```

### Android, Linux, and Windows

Android `arm64-v8a` builds OpenSSL, Mbed TLS, and wg-go in three parallel jobs. Windows `x64` and `arm64` each build OpenSSL, Mbed TLS, and wg-go in three parallel jobs. Every build job configures and packages only its selected vendor, producing names such as `openssl-android-arm64-v8a.tar.gz` and `wg-go-windows-arm64.zip`.

Linux builds OpenSSL, Mbed TLS, and wg-go natively for `x64` and `arm64` in six separate jobs. Each package contains that vendor's libraries, public headers, and manifest for its architecture; OpenSSL and wg-go are shared, while Mbed TLS is static.

The local scripts take the same vendor selection as CI, for example:

```sh
scripts/build-vendors.sh android-arm64-v8a openssl
scripts/build-vendors.sh linux-x64 wg-go
scripts/build-vendors-windows.ps1 -Target windows-x64 -Vendor mbedtls
```

## Version Pins

The `vendors/openssl` and `vendors/mbedtls` submodules pin their upstream revisions. wg-go and its Go module lock files are tracked directly in this repository. Toolchain versions are pinned by the build scripts and workflow files.

Every Android, Linux, and Windows package includes a manifest containing its exact source revisions, target, linkage, and toolchain metadata. Apple builds emit equivalent vendor-specific metadata. The release workflow attaches one `manifest.json` that aggregates the metadata for every published OpenSSL, Mbed TLS, wg-go, and wxWidgets artifact; intermediate manifests are not published separately.
