#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: build-openssl.sh <destination> <work-directory> <configure-target> [configure-argument ...]}"
work_dir="${2:?usage: build-openssl.sh <destination> <work-directory> <configure-target> [configure-argument ...]}"
configure_target="${3:?usage: build-openssl.sh <destination> <work-directory> <configure-target> [configure-argument ...]}"
shift 3

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
source_dir="${repository_dir}/vendors/openssl"
build_source_dir="${work_dir}/source"
jobs="${BUILD_JOBS:-4}"
linkage="${OPENSSL_LINKAGE:-shared}"

if [[ ! -f "${source_dir}/Configure" ]]; then
    echo "OpenSSL is not initialized." >&2
    exit 1
fi
if [[ "${linkage}" != static && "${linkage}" != shared ]]; then
    echo "OPENSSL_LINKAGE must be static or shared, got ${linkage}." >&2
    exit 1
fi

rm -rf "${work_dir}" "${destination}"
mkdir -p "${work_dir}" "${destination}"
rsync -a --delete --exclude .git "${source_dir}/" "${build_source_dir}/"

configure_args=(
    "${configure_target}"
    "--prefix=${destination}"
    "--openssldir=${destination}"
    --libdir=lib
    no-apps
    no-docs
    no-dsa
    no-engine
    no-gost
    no-legacy
    no-ssl
    no-tests
    no-zlib
)
if [[ "${linkage}" == static ]]; then
    configure_args+=(no-shared)
else
    configure_args+=(shared)
fi
configure_args+=("$@")

(
    cd "${build_source_dir}"
    perl Configure "${configure_args[@]}"
    make -j"${jobs}"
    make install_sw
)
