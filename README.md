# Passepartout Prebuilts

This repository builds binary dependencies used by Passepartout.

## Workflows

- `Partout Vendors` builds Partout vendors from a pinned `partout-io/partout` checkout, as one workflow job per vendor and target:
  - OpenSSL
  - Mbed TLS
  - wg-go
- `Windows wxWidgets` builds static wxWidgets libraries with MSVC.
- `Release Prebuilts` downloads artifacts from successful build workflow runs and uploads them to a GitHub Release.

All workflows are manual (`workflow_dispatch`) while the packaging format is still settling. Build workflows only upload GitHub Actions artifacts. The release workflow takes a required `release_tag`, optional build run IDs, and publishes the downloaded artifacts as release assets.

The current Android target is `arm64-v8a` only.

## Current Pins

| Component | Version / ref |
| --- | --- |
| Partout | `2400fe52e036f0d10b5f1c105e044f77e296a54e` |
| OpenSSL | `openssl-3.6.3` |
| Mbed TLS | `v4.1.0` |
| wg-go WireGuard module | `v0.0.0-20250521234502-f333402bd9cb` |
| wxWidgets | `3.3.2` |
| Android API | `28` |
| Android NDK | `30.0.14904198` |
| llvm-mingw | `20260616` |

`wg-go` is tracked directly in Partout rather than as a submodule, so its source revision is the pinned Partout commit. Its upstream WireGuard Go version is pinned in `vendors/wg-go/go.mod`.

Tooling otherwise comes from the selected GitHub-hosted runner images, using their stable CMake, Ninja, MSVC, PowerShell, tar/gzip, and Go toolchain cache.
