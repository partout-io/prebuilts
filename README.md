# Prebuilts

This repository builds binary dependencies used by Passepartout and Partout.

## Workflows

- `Partout Vendors` builds Partout vendors from a pinned `partout-io/partout` checkout, as one workflow job per target:
  - OpenSSL
  - Mbed TLS
  - wg-go
- `Windows wxWidgets` builds static wxWidgets libraries with MSVC.
- `Release Prebuilts` downloads artifacts from successful build workflow runs and uploads them to a GitHub Release.

All workflows are manual (`workflow_dispatch`) while the packaging format is still settling. Build workflows only upload GitHub Actions artifacts. The release workflow takes a required `release_tag`, optional build run IDs, and publishes the downloaded artifacts as release assets.

The current Android target is `arm64-v8a` only. Partout owns the vendor build logic through its CMake project: the workflow enables bundled vendors, disables the Swift library, installs vendors to a temporary CMake output directory, then packages the installed vendor directories as release artifacts. Each target job still emits one archive per vendor, so Partout's prebuilt fetcher can keep using the existing asset names.

## Version Pins

The workflow files are the source of truth for pinned dependency and toolchain versions. The pinned Partout checkout is the source of truth for vendor build logic. Build packages include a `manifest.json` with the exact source refs, library versions, target, and toolchain metadata used for that artifact.

`wg-go` is tracked directly in Partout rather than as a submodule, so its source revision is the pinned Partout commit. Its upstream WireGuard Go version is pinned in Partout's `vendors/wg-go/go.mod`.

Tooling otherwise comes from the selected GitHub-hosted runner images, using their stable CMake, Ninja, MSVC, PowerShell, tar/gzip, and Go toolchain cache.
