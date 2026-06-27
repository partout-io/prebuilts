#!/usr/bin/env bash
set -euo pipefail

repo="${PARTOUT_REPOSITORY:?PARTOUT_REPOSITORY is required}"
ref="${PARTOUT_REF:?PARTOUT_REF is required}"
partout_dir="${PARTOUT_DIR:-${PWD}/.build/partout}"

mkdir -p "$(dirname "${partout_dir}")"
rm -rf "${partout_dir}"

git clone --filter=blob:none "${repo}" "${partout_dir}"
git -C "${partout_dir}" checkout --detach "${ref}"
git -C "${partout_dir}" submodule update --init vendors/openssl vendors/mbedtls
git -C "${partout_dir}/vendors/mbedtls" submodule update --init --recursive

actual_ref="$(git -C "${partout_dir}" rev-parse HEAD)"
if [[ "${actual_ref}" != "${ref}" ]]; then
    echo "Expected Partout ${ref}, got ${actual_ref}" >&2
    exit 1
fi

actual_openssl="$(git -C "${partout_dir}/vendors/openssl" describe --tags --always)"
if [[ "${actual_openssl}" != "${OPENSSL_VERSION:?OPENSSL_VERSION is required}" ]]; then
    echo "Expected OpenSSL ${OPENSSL_VERSION}, got ${actual_openssl}" >&2
    exit 1
fi

actual_mbedtls="$(git -C "${partout_dir}/vendors/mbedtls" describe --tags --always)"
if [[ "${actual_mbedtls}" != "${MBEDTLS_VERSION:?MBEDTLS_VERSION is required}" ]]; then
    echo "Expected Mbed TLS ${MBEDTLS_VERSION}, got ${actual_mbedtls}" >&2
    exit 1
fi

if ! grep -Fq "golang.zx2c4.com/wireguard ${WIREGUARD_GO_VERSION:?WIREGUARD_GO_VERSION is required}" "${partout_dir}/vendors/wg-go/go.mod"; then
    echo "Expected wg-go to pin golang.zx2c4.com/wireguard ${WIREGUARD_GO_VERSION}" >&2
    exit 1
fi

echo "PARTOUT_DIR=${partout_dir}" >> "${GITHUB_ENV:-/dev/null}"
