#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: build-partout-vendors.sh <target>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
work_dir="${repository_dir}/.build/${target}"
build_dir="${work_dir}/cmake-build"
vendor_output_dir="${work_dir}/vendor-output"
install_dir="${work_dir}/install"
artifacts_dir="${repository_dir}/artifacts"
vendors=(openssl mbedtls wg-go)

case "${target}" in
    android-arm64-v8a)
        os="android"
        arch="arm64-v8a"
        android_abi="arm64-v8a"
        ;;
    *)
        echo "Unknown Linux-hosted target: ${target}" >&2
        exit 1
        ;;
esac

openssl_dir="${repository_dir}/vendors/openssl"
mbedtls_dir="${repository_dir}/vendors/mbedtls"
wg_go_dir="${repository_dir}/vendors/wg-go"
[[ -f "${openssl_dir}/Configure" ]] || { echo "OpenSSL is not initialized." >&2; exit 1; }
[[ -f "${mbedtls_dir}/tf-psa-crypto/CMakeLists.txt" ]] || { echo "Mbed TLS submodules are not initialized." >&2; exit 1; }

prebuilts_remote="$(git -C "${repository_dir}" remote | sed -n '1p')"
prebuilts_repository=""
if [[ -n "${prebuilts_remote}" ]]; then
    prebuilts_repository="$(git -C "${repository_dir}" remote get-url "${prebuilts_remote}")"
fi
prebuilts_ref="$(git -C "${repository_dir}" rev-parse HEAD)"
openssl_ref="$(git -C "${openssl_dir}" rev-parse HEAD)"
mbedtls_ref="$(git -C "${mbedtls_dir}" rev-parse HEAD)"
openssl_version="$(git -C "${openssl_dir}" describe --tags --always --dirty)"
mbedtls_version="$(git -C "${mbedtls_dir}" describe --tags --always --dirty)"
wireguard_go_version="$(awk '$1 == "golang.zx2c4.com/wireguard" && $2 !~ /\/go\.mod$/ { print $2; exit }' "${wg_go_dir}/go.sum")"
if [[ -z "${wireguard_go_version}" ]]; then
    echo "Unable to resolve golang.zx2c4.com/wireguard from ${wg_go_dir}/go.sum" >&2
    exit 1
fi

go_version=""
if command -v go >/dev/null 2>&1; then
    go_version="$(go env GOVERSION 2>/dev/null || go version)"
fi
cmake_version="$(cmake --version | sed -n '1s/^cmake version //p')"
ninja_version="$(ninja --version 2>/dev/null || true)"

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

rm -rf "${work_dir}" "${artifacts_dir}"
mkdir -p "${build_dir}" "${vendor_output_dir}" "${install_dir}" "${artifacts_dir}"

cmake_args=(
    -S "${repository_dir}"
    -B "${build_dir}"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${install_dir}"
    -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_ROOT}/build/cmake/android.toolchain.cmake"
    -DANDROID_ABI="${android_abi}"
    -DANDROID_PLATFORM="android-${ANDROID_API:?ANDROID_API is required}"
    -DANDROID_STL=c++_shared
    -DANDROID_NATIVE_API_LEVEL="${ANDROID_API}"
    -DPPV_BUILD_MBEDTLS=ON
    -DPPV_BUILD_OPENSSL=ON
    -DPPV_BUILD_WG_GO=ON
    -DPPV_OUTPUT="${vendor_output_dir}"
)

cmake "${cmake_args[@]}"
cmake --build "${build_dir}" --target vendors --parallel
cmake --install "${build_dir}"

for vendor in "${vendors[@]}"; do
    [[ -d "${install_dir}/${vendor}/include" ]] || {
        echo "Missing ${vendor} headers in ${install_dir}/${vendor}" >&2
        exit 1
    }
done
[[ -d "${install_dir}/openssl/lib" ]] || { echo "Missing OpenSSL libraries" >&2; exit 1; }
[[ -f "${install_dir}/mbedtls/lib/libmbedtls.a" ]] || { echo "Missing libmbedtls.a" >&2; exit 1; }
[[ -f "${install_dir}/mbedtls/lib/libmbedx509.a" ]] || { echo "Missing libmbedx509.a" >&2; exit 1; }
[[ -f "${install_dir}/mbedtls/lib/libmbedcrypto.a" ]] || { echo "Missing libmbedcrypto.a" >&2; exit 1; }
[[ -f "${install_dir}/wg-go/lib/libwg-go.so" ]] || { echo "Missing libwg-go.so" >&2; exit 1; }

cat > "${install_dir}/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "target": "${target}",
  "os": "${os}",
  "arch": "${arch}",
  "prebuilts": { "repository": "${prebuilts_repository}", "ref": "${prebuilts_ref}" },
  "libraries": {
    "openssl": { "version": "${openssl_version}", "ref": "${openssl_ref}", "linkage": "shared" },
    "mbedtls": { "version": "${mbedtls_version}", "ref": "${mbedtls_ref}", "linkage": "static" },
    "wg-go": { "sourceRef": "${prebuilts_ref}", "wireguardGoVersion": "${wireguard_go_version}", "linkage": "shared" }
  },
  "toolchains": {
    "go": "${go_version}",
    "cmake": "${cmake_version}",
    "ninja": "${ninja_version}",
    "androidApi": "${ANDROID_API}",
    "androidNdk": "${android_ndk_version}"
  }
}
EOF

package_name="partout-vendors-${target}.tar.gz"
package_path="${artifacts_dir}/${package_name}"
tar -czf "${package_path}" -C "${install_dir}" .
sha256="$(shasum -a 256 "${package_path}" | awk '{print $1}')"
printf '%s  %s\n' "${sha256}" "${package_name}" > "${package_path}.sha256"
