#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
vendor="${1:-all}"

case "${vendor}" in
    all)
        git -C "${repository_dir}" submodule update --init --checkout vendors/openssl vendors/mbedtls
        git -C "${repository_dir}/vendors/mbedtls" submodule update --init --recursive
        ;;
    openssl)
        git -C "${repository_dir}" submodule update --init --checkout vendors/openssl
        ;;
    mbedtls)
        git -C "${repository_dir}" submodule update --init --checkout vendors/mbedtls
        git -C "${repository_dir}/vendors/mbedtls" submodule update --init --recursive
        ;;
    wg-go|wintun)
        ;;
    *)
        echo "Unknown vendor: ${vendor}. Expected all, openssl, mbedtls, wg-go, or wintun." >&2
        exit 1
        ;;
esac
