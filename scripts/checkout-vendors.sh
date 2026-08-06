#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"

git -C "${repository_dir}" submodule update --init --checkout vendors/openssl vendors/mbedtls
git -C "${repository_dir}/vendors/mbedtls" submodule update --init --recursive
