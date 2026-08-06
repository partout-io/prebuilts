# Prebuilts

This repository is the source of truth for third-party binary dependencies used by Passepartout and Partout. It owns the upstream source pins, patches, cross-platform build recipes, packaging, and release metadata.

## Vendor Superbuild

The root CMake project builds OpenSSL, Mbed TLS, wg-go, and Wintun without building Partout. One CMake configure represents one target ABI; toolchain files carry the cross-compilation environment into the vendor adapters under `cmake/vendors`.

The build can select vendors independently:

```sh
cmake -S . -B .build/vendors -G Ninja \
    -DPPV_BUILD_OPENSSL=ON \
    -DPPV_BUILD_MBEDTLS=ON \
    -DPPV_BUILD_WG_GO=ON
cmake --build .build/vendors --target vendors
```

Initialize the OpenSSL and Mbed TLS sources before building:

```sh
scripts/checkout-vendors.sh
```

Partout contains no vendor sources or vendor build recipes. It consumes system libraries, a local artifact root through `PP_BUILD_VENDOR_ROOT`, or published archives through `PP_BUILD_VENDOR_PREBUILT_URL`.

## Workflows

- `Vendor Prebuilts` builds the vendor distribution matrix.
- `Windows wxWidgets` builds static wxWidgets libraries with MSVC.
- `Release Prebuilts` downloads successful workflow artifacts and uploads them to a GitHub Release.

All workflows are manual (`workflow_dispatch`) while the packaging format is settling. Build workflows upload GitHub Actions artifacts; the release workflow publishes those artifacts as release assets.

### Apple XCFrameworks

The Apple matrix builds OpenSSL, Mbed TLS, and wg-go in separate parallel jobs. Each job produces one static XCFramework containing slices for:

- iOS device (`arm64`) and simulator (`arm64`, `x86_64`)
- macOS (`arm64`, `x86_64`)
- tvOS device (`arm64`) and simulator (`arm64`, `x86_64`)

OpenSSL's `libssl.a` and `libcrypto.a` are consolidated into one archive per slice. Mbed TLS's `libmbedtls.a`, `libmbedx509.a`, and `libmbedcrypto.a` are consolidated similarly. wg-go uses Go's `c-archive` mode. No dynamic library is included in an Apple XCFramework.

Each job emits a zipped SwiftPM-compatible XCFramework, `.checksum` and `.sha256` sidecars, and a vendor-specific manifest. Build all Apple vendors locally with:

```sh
scripts/build-partout-apple-xcframeworks.sh all
```

Pass a vendor as the second argument to reproduce one CI job, for example:

```sh
scripts/build-partout-apple-xcframeworks.sh all openssl
```

The current non-Apple targets are Android `arm64-v8a` and Windows `x64`/`arm64`.

## Version Pins

The `vendors/openssl` and `vendors/mbedtls` submodules pin their upstream revisions. wg-go and its Go module lock files are tracked directly in this repository. Wintun and toolchain versions are pinned by the CMake and workflow files.

Every package includes a manifest containing its exact source revisions, target, linkage, and toolchain metadata.
