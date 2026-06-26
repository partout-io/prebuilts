# Passepartout Prebuilts

This repository builds binary dependencies used by Passepartout.

## Workflows

- `Linux Vendors` builds Partout vendors from a pinned `partout-io/partout` checkout:
  - OpenSSL
  - Mbed TLS
  - wg-go
- `Windows wxWidgets` builds static wxWidgets libraries with MSVC.

Both workflows are manual (`workflow_dispatch`) while the packaging format is still settling.

## Current Pins

| Component | Version / ref |
| --- | --- |
| Partout | `2400fe52e036f0d10b5f1c105e044f77e296a54e` |
| OpenSSL | `openssl-3.6.3` |
| Mbed TLS | `v4.1.0` |
| wg-go WireGuard module | `v0.0.0-20250521234502-f333402bd9cb` |
| wxWidgets | `3.3.2` |
| Go | `1.24.0` |
| Android API | `24` |
| Android NDK | `28.2.13676358` |
| llvm-mingw | `20260616` |

`wg-go` is tracked directly in Partout rather than as a submodule, so its source revision is the pinned Partout commit. Its upstream WireGuard Go version is pinned in `vendors/wg-go/go.mod`.

