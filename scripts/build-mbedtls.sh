#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: build-mbedtls.sh <destination> <work-directory>}"
work_dir="${2:?usage: build-mbedtls.sh <destination> <work-directory>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
source_dir="${repository_dir}/vendors/mbedtls"
build_source_dir="${work_dir}/source"
build_dir="${work_dir}/build"
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
mkdir -p "${work_dir}" "${destination}"
rsync -a --delete --exclude .git "${source_dir}/" "${build_source_dir}/"

cmake_args=(
    -S "${build_source_dir}"
    -B "${build_dir}"
    -DCMAKE_BUILD_TYPE=Release
    "-DCMAKE_INSTALL_PREFIX=${destination}"
    -DCMAKE_INSTALL_LIBDIR=lib
    "-DCMAKE_C_COMPILER=${CC}"
    "-DCMAKE_AR=${AR}"
    "-DCMAKE_RANLIB=${RANLIB}"
    "-DCMAKE_C_FLAGS=${CFLAGS:--O2}"
    "-DPython3_EXECUTABLE=${MBEDTLS_PYTHON}"
    -DGEN_FILES=ON
    -DENABLE_PROGRAMS=OFF
    -DENABLE_TESTING=OFF
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON
)
if [[ -n "${MBEDTLS_CMAKE_TOOLCHAIN_FILE:-}" ]]; then
    cmake_args+=("-DCMAKE_TOOLCHAIN_FILE=${MBEDTLS_CMAKE_TOOLCHAIN_FILE}")
fi
if [[ -n "${MBEDTLS_CMAKE_ANDROID_ABI:-}" ]]; then
    cmake_args+=("-DANDROID_ABI=${MBEDTLS_CMAKE_ANDROID_ABI}")
fi
if [[ -n "${MBEDTLS_CMAKE_ANDROID_PLATFORM:-}" ]]; then
    cmake_args+=("-DANDROID_PLATFORM=${MBEDTLS_CMAKE_ANDROID_PLATFORM}")
fi
if [[ -n "${MBEDTLS_CMAKE_SYSTEM_NAME:-}" ]]; then
    cmake_args+=("-DCMAKE_SYSTEM_NAME=${MBEDTLS_CMAKE_SYSTEM_NAME}")
fi
if [[ -n "${MBEDTLS_CMAKE_OSX_SYSROOT:-}" ]]; then
    cmake_args+=("-DCMAKE_OSX_SYSROOT=${MBEDTLS_CMAKE_OSX_SYSROOT}")
fi
if [[ -n "${MBEDTLS_CMAKE_OSX_ARCHITECTURES:-}" ]]; then
    cmake_args+=("-DCMAKE_OSX_ARCHITECTURES=${MBEDTLS_CMAKE_OSX_ARCHITECTURES}")
fi
if [[ -n "${MBEDTLS_CMAKE_OSX_DEPLOYMENT_TARGET:-}" ]]; then
    cmake_args+=("-DCMAKE_OSX_DEPLOYMENT_TARGET=${MBEDTLS_CMAKE_OSX_DEPLOYMENT_TARGET}")
fi

cmake "${cmake_args[@]}"
cmake --build "${build_dir}" --parallel "${jobs}"
cmake --install "${build_dir}"
