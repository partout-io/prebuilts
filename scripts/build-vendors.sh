#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: build-vendors.sh <target> <vendor>}"
vendor="${2:?usage: build-vendors.sh <target> <vendor>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
work_dir="${repository_dir}/.build/${target}/${vendor}"
install_dir="${work_dir}/install"
vendor_dir="${install_dir}/${vendor}"
artifacts_dir="${repository_dir}/artifacts"
host_arch="$(uname -m)"

if [[ "$(uname -s)" != Linux ]]; then
    echo "build-vendors.sh must run on Linux." >&2
    exit 1
fi

case "${target}" in
    android-arm64-v8a)
        os=android
        arch=arm64-v8a
        ;;
    linux-x64)
        os=linux
        arch=x64
        [[ "${host_arch}" == x86_64 || "${host_arch}" == amd64 ]] || {
            echo "linux-x64 must be built on an x64 host, got ${host_arch}." >&2
            exit 1
        }
        ;;
    linux-arm64)
        os=linux
        arch=arm64
        [[ "${host_arch}" == aarch64 || "${host_arch}" == arm64 ]] || {
            echo "linux-arm64 must be built on an arm64 host, got ${host_arch}." >&2
            exit 1
        }
        ;;
    *)
        echo "Unknown Linux-hosted target: ${target}" >&2
        exit 1
        ;;
esac

case "${vendor}" in
    openssl|mbedtls|wg-go)
        ;;
    *)
        echo "Unknown vendor: ${vendor}. Expected openssl, mbedtls, or wg-go." >&2
        exit 1
        ;;
esac
required_commands=(git make rsync shasum)
case "${vendor}" in
    openssl)
        required_commands+=(perl)
        ;;
    mbedtls)
        required_commands+=(ar cc python3 ranlib)
        ;;
    wg-go)
        required_commands+=(go)
        ;;
esac
for command_name in "${required_commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "Required command not found: ${command_name}" >&2
        exit 1
    }
done

android_ndk_version=""
android_clang=""
if [[ "${os}" == android ]]; then
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
    android_prebuilt_root="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt"
    android_toolchain=""
    for candidate in "${android_prebuilt_root}"/*; do
        if [[ -d "${candidate}/bin" ]]; then
            android_toolchain="${candidate}"
            break
        fi
    done
    if [[ -z "${android_toolchain}" ]]; then
        echo "Unable to resolve the Android NDK LLVM toolchain." >&2
        exit 1
    fi
    android_clang="${android_toolchain}/bin/aarch64-linux-android${ANDROID_API:?ANDROID_API is required}-clang"
    [[ -x "${android_clang}" ]] || { echo "Missing Android clang: ${android_clang}" >&2; exit 1; }
fi

rm -rf "${work_dir}"
mkdir -p "${install_dir}" "${artifacts_dir}"

case "${vendor}" in
    openssl)
        if [[ "${os}" == android ]]; then
            openssl_target=android-arm64
            openssl_path="${android_toolchain}/bin:${PATH}"
        elif [[ "${arch}" == x64 ]]; then
            openssl_target=linux-x86_64
            openssl_path="${PATH}"
        else
            openssl_target=linux-aarch64
            openssl_path="${PATH}"
        fi
        PATH="${openssl_path}" \
            ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-}" \
            OPENSSL_LINKAGE=shared \
            BUILD_JOBS="$(nproc)" \
                "${script_dir}/build-openssl.sh" \
                "${vendor_dir}" "${work_dir}/openssl" "${openssl_target}"
        ;;
    mbedtls)
        mbedtls_python="$(${script_dir}/prepare-mbedtls-python.sh "${work_dir}/mbedtls-python")"
        if [[ "${os}" == android ]]; then
            mbedtls_path="${android_toolchain}/bin:${PATH}"
            mbedtls_cc="${android_clang}"
            mbedtls_ar="${android_toolchain}/bin/llvm-ar"
            mbedtls_ranlib="${android_toolchain}/bin/llvm-ranlib"
        else
            mbedtls_path="${PATH}"
            mbedtls_cc="$(command -v cc)"
            mbedtls_ar="$(command -v ar)"
            mbedtls_ranlib="$(command -v ranlib)"
        fi
        PATH="${mbedtls_path}" \
        CC="${mbedtls_cc}" \
        AR="${mbedtls_ar}" \
        RANLIB="${mbedtls_ranlib}" \
        CFLAGS="-O2 -fPIC" \
        MBEDTLS_PYTHON="${mbedtls_python}" \
        BUILD_JOBS="$(nproc)" \
            "${script_dir}/build-mbedtls.sh" \
            "${vendor_dir}" "${work_dir}/mbedtls"
        ;;
    wg-go)
        make_args=(
            -C "${repository_dir}/vendors/wg-go" install
            "BUILDDIR=${work_dir}/wg-go-build"
            "DESTDIR=${vendor_dir}"
            "TMPROOTDIR=${work_dir}/wg-go-goroot"
        )
        if [[ "${os}" == android ]]; then
            make_args+=(ANDROID=1 "CC=${android_clang}")
        fi
        make "${make_args[@]}"
        ;;
esac

[[ -d "${vendor_dir}/include" ]] || { echo "Missing ${vendor} headers" >&2; exit 1; }
case "${vendor}" in
    openssl)
        [[ -f "${vendor_dir}/lib/libssl.so" ]] || { echo "Missing libssl.so" >&2; exit 1; }
        [[ -f "${vendor_dir}/lib/libcrypto.so" ]] || { echo "Missing libcrypto.so" >&2; exit 1; }
        ;;
    mbedtls)
        for library in libmbedtls.a libmbedx509.a libmbedcrypto.a; do
            [[ -f "${vendor_dir}/lib/${library}" ]] || { echo "Missing ${library}" >&2; exit 1; }
        done
        ;;
    wg-go)
        [[ -f "${vendor_dir}/lib/libwg-go.so" ]] || { echo "Missing libwg-go.so" >&2; exit 1; }
        ;;
esac

prebuilts_remote="$(git -C "${repository_dir}" remote | sed -n '1p')"
prebuilts_repository=""
if [[ -n "${prebuilts_remote}" ]]; then
    prebuilts_repository="$(git -C "${repository_dir}" remote get-url "${prebuilts_remote}")"
fi
prebuilts_ref="$(git -C "${repository_dir}" rev-parse HEAD)"
go_version=""
case "${vendor}" in
    openssl)
        source_dir="${repository_dir}/vendors/openssl"
        source_ref="$(git -C "${source_dir}" rev-parse HEAD)"
        source_version="$(git -C "${source_dir}" describe --tags --always --dirty)"
        libraries_json="    \"openssl\": { \"version\": \"${source_version}\", \"ref\": \"${source_ref}\", \"linkage\": \"shared\" }"
        ;;
    mbedtls)
        source_dir="${repository_dir}/vendors/mbedtls"
        source_ref="$(git -C "${source_dir}" rev-parse HEAD)"
        source_version="$(git -C "${source_dir}" describe --tags --always --dirty)"
        libraries_json="    \"mbedtls\": { \"version\": \"${source_version}\", \"ref\": \"${source_ref}\", \"linkage\": \"static\" }"
        ;;
    wg-go)
        wireguard_go_version="$(awk '$1 == "golang.zx2c4.com/wireguard" && $2 !~ /\/go\.mod$/ { print $2; exit }' "${repository_dir}/vendors/wg-go/go.sum")"
        [[ -n "${wireguard_go_version}" ]] || { echo "Unable to resolve wireguard-go version" >&2; exit 1; }
        go_version="$(go env GOVERSION 2>/dev/null || go version)"
        libraries_json="    \"wg-go\": { \"sourceRef\": \"${prebuilts_ref}\", \"wireguardGoVersion\": \"${wireguard_go_version}\", \"linkage\": \"shared\" }"
        ;;
esac

platform_toolchains=""
if [[ "${os}" == android ]]; then
    clang_version="$(${android_clang} --version | sed -n '1p')"
    platform_toolchains="$(printf ',\n    \"androidApi\": \"%s\",\n    \"androidNdk\": \"%s\",\n    \"clang\": \"%s\"' \
        "${ANDROID_API}" "${android_ndk_version}" "${clang_version}")"
else
    platform_toolchains="$(printf ',\n    \"hostArchitecture\": \"%s\"' "${host_arch}")"
fi
make_version="$(make --version | sed -n '1p')"

cat > "${vendor_dir}/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "target": "${target}",
  "vendor": "${vendor}",
  "os": "${os}",
  "arch": "${arch}",
  "prebuilts": { "repository": "${prebuilts_repository}", "ref": "${prebuilts_ref}" },
  "libraries": {
${libraries_json}
  },
  "toolchains": {
    "go": "${go_version}",
    "make": "${make_version}"${platform_toolchains}
  }
}
EOF

package_name="${vendor}-${target}.tar.gz"
package_path="${artifacts_dir}/${package_name}"
tar -czf "${package_path}" -C "${vendor_dir}" .
sha256="$(shasum -a 256 "${package_path}" | awk '{print $1}')"
printf '%s  %s\n' "${sha256}" "${package_name}" > "${package_path}.sha256"
