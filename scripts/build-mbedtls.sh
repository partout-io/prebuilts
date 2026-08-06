#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: build-mbedtls.sh <destination> <work-directory>}"
work_dir="${2:?usage: build-mbedtls.sh <destination> <work-directory>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
source_dir="${repository_dir}/vendors/mbedtls"
build_source_dir="${work_dir}/source"
jobs="${BUILD_JOBS:-4}"

: "${CC:?CC is required}"
: "${AR:?AR is required}"
: "${RANLIB:?RANLIB is required}"
: "${MBEDTLS_PYTHON:?MBEDTLS_PYTHON is required}"

if [[ ! -f "${source_dir}/tf-psa-crypto/scripts/basic.requirements.txt" ]]; then
    echo "Mbed TLS submodules are not initialized." >&2
    exit 1
fi

rm -rf "${work_dir}" "${destination}"
mkdir -p "${work_dir}" "${destination}/include/mbedtls" \
    "${destination}/include/psa" "${destination}/include/tf-psa-crypto" \
    "${destination}/lib"
rsync -a --delete --exclude .git "${source_dir}/" "${build_source_dir}/"

make -C "${build_source_dir}" -f scripts/legacy.make -j"${jobs}" lib \
    "CC=${CC}" \
    "AR=${AR}" \
    "RL=${RANLIB}" \
    "PYTHON=${MBEDTLS_PYTHON}" \
    "CFLAGS=${CFLAGS:--O2}" \
    GEN_FILES=yes

rsync -a "${build_source_dir}/include/mbedtls/" "${destination}/include/mbedtls/"
rsync -a "${build_source_dir}/tf-psa-crypto/include/mbedtls/" \
    "${destination}/include/mbedtls/"
rsync -a "${build_source_dir}/tf-psa-crypto/drivers/builtin/include/mbedtls/" \
    "${destination}/include/mbedtls/"
rsync -a "${build_source_dir}/tf-psa-crypto/include/psa/" "${destination}/include/psa/"
rsync -a "${build_source_dir}/tf-psa-crypto/include/tf-psa-crypto/" \
    "${destination}/include/tf-psa-crypto/"
cp "${build_source_dir}/library/libmbedtls.a" \
    "${build_source_dir}/library/libmbedx509.a" \
    "${build_source_dir}/library/libmbedcrypto.a" \
    "${destination}/lib/"
