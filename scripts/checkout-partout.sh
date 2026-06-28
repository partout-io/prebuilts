#!/usr/bin/env bash
set -euo pipefail

partout_dir="${PARTOUT_DIR:-${PWD}/partout}"

git submodule update --init --checkout partout
git -C "${partout_dir}" submodule update --init vendors/openssl vendors/mbedtls
git -C "${partout_dir}/vendors/mbedtls" submodule update --init --recursive

echo "PARTOUT_DIR=${partout_dir}" >> "${GITHUB_ENV:-/dev/null}"
