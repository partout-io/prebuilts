#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: build-partout-vendors.sh <target>}"
partout_dir="${PARTOUT_DIR:-${PWD}/.build/partout}"
work_dir="${PWD}/.build/${target}"
build_dir="${work_dir}/cmake-build"
vendor_output_dir="${work_dir}/vendor-output"
install_dir="${work_dir}/install"
artifacts_dir="${PWD}/artifacts"
vendors=(openssl mbedtls wg-go)

case "${target}" in
    android-arm64-v8a)
        os="android"
        arch="arm64-v8a"
        android_abi="arm64-v8a"
        android_swift_arch="aarch64"
        ;;
    *)
        echo "Unknown Linux-hosted target: ${target}" >&2
        exit 1
        ;;
esac

if [[ ! -d "${partout_dir}" ]]; then
    echo "Partout checkout not found: ${partout_dir}" >&2
    exit 1
fi

go_version=""
if command -v go >/dev/null 2>&1; then
    go_version="$(go env GOVERSION 2>/dev/null || go version)"
fi
cmake_version="$(cmake --version | sed -n '1s/^cmake version //p')"
ninja_version="$(ninja --version 2>/dev/null || true)"
android_ndk_version=""

if [[ "${os}" == "android" ]]; then
    if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "${ANDROID_NDK_ROOT}" ]]; then
        :
    elif [[ -n "${ANDROID_NDK_VERSION:-}" && -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}" ]]; then
        export ANDROID_NDK_ROOT="${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}"
    elif [[ -n "${ANDROID_NDK_LATEST_HOME:-}" && -d "${ANDROID_NDK_LATEST_HOME}" ]]; then
        export ANDROID_NDK_ROOT="${ANDROID_NDK_LATEST_HOME}"
    else
        echo "Unable to resolve Android NDK. Set ANDROID_NDK_ROOT or ANDROID_NDK_LATEST_HOME." >&2
        exit 1
    fi
    android_ndk_version="$(basename "${ANDROID_NDK_ROOT}")"
fi

rm -rf "${work_dir}" "${artifacts_dir}"
mkdir -p "${build_dir}" "${vendor_output_dir}" "${install_dir}" "${artifacts_dir}"

cmake_args=(
    -S "${partout_dir}"
    -B "${build_dir}"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${install_dir}"
    -DPP_BUILD_OUTPUT="${vendor_output_dir}"
    -DPP_BUILD_LIBRARY=OFF
    -DPP_BUILD_VENDOR_SOURCE=bundled
    -DPP_BUILD_USE_OPENSSL=ON
    -DPP_BUILD_USE_MBEDTLS=ON
    -DPP_BUILD_USE_WIREGUARD=ON
)

if [[ "${os}" == "android" ]]; then
    cmake_args+=(
        -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_ROOT}/build/cmake/android.toolchain.cmake"
        -DANDROID_ABI="${android_abi}"
        -DANDROID_PLATFORM="android-${ANDROID_API:?ANDROID_API is required}"
        -DANDROID_STL=c++_shared
        -DANDROID_NATIVE_API_LEVEL="${ANDROID_API}"
        -DSWIFT_ANDROID_ARCH="${android_swift_arch}"
    )
fi

cmake "${cmake_args[@]}"
cmake --build "${build_dir}" --parallel
cmake --install "${build_dir}"

assert_vendor_package() {
    local vendor="${1}"
    local root="${install_dir}/${vendor}"

    case "${vendor}" in
        openssl)
            [[ -d "${root}/include" ]] || { echo "Missing OpenSSL headers in ${root}" >&2; exit 1; }
            [[ -d "${root}/lib" ]] || { echo "Missing OpenSSL libraries in ${root}" >&2; exit 1; }
            ;;
        mbedtls)
            [[ -d "${root}/include" ]] || { echo "Missing Mbed TLS headers in ${root}" >&2; exit 1; }
            [[ -f "${root}/lib/libmbedtls.a" ]] || { echo "Missing Mbed TLS library in ${root}" >&2; exit 1; }
            [[ -f "${root}/lib/libmbedx509.a" ]] || { echo "Missing Mbed X509 library in ${root}" >&2; exit 1; }
            [[ -f "${root}/lib/libmbedcrypto.a" ]] || { echo "Missing Mbed Crypto library in ${root}" >&2; exit 1; }
            ;;
        wg-go)
            [[ -d "${root}/include" ]] || { echo "Missing wg-go headers in ${root}" >&2; exit 1; }
            [[ -f "${root}/lib/libwg-go.so" ]] || { echo "Missing wg-go library in ${root}" >&2; exit 1; }
            ;;
        *)
            echo "Unknown vendor: ${vendor}" >&2
            exit 1
            ;;
    esac
}

for vendor in "${vendors[@]}"; do
    assert_vendor_package "${vendor}"
done

cat > "${install_dir}/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "target": "${target}",
  "os": "${os}",
  "arch": "${arch}",
  "partout": {
    "repository": "${PARTOUT_REPOSITORY}",
    "ref": "${PARTOUT_REF}"
  },
  "libraries": {
    "openssl": {
      "version": "${OPENSSL_VERSION}",
      "linkage": "shared"
    },
    "mbedtls": {
      "version": "${MBEDTLS_VERSION}",
      "linkage": "static"
    },
    "wg-go": {
      "partoutRef": "${PARTOUT_REF}",
      "wireguardGoVersion": "${WIREGUARD_GO_VERSION}",
      "linkage": "shared"
    }
  },
  "toolchains": {
    "go": "${go_version}",
    "cmake": "${cmake_version}",
    "ninja": "${ninja_version}",
    "androidApi": "${ANDROID_API:-}",
    "androidNdk": "${android_ndk_version}"
  }
}
EOF

package_name="partout-vendors-${target}.tar.gz"
tar -czf "${artifacts_dir}/${package_name}" -C "${install_dir}" .
