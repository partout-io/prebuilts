#!/usr/bin/env bash
set -euo pipefail

target="${1:-all}"
vendor="${2:-all}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
work_dir="${repository_dir}/.build/apple-xcframeworks"
artifacts_dir="${repository_dir}/artifacts"
modulemaps_dir="${script_dir}/apple/modulemaps"

ios_deployment_target="${IOS_DEPLOYMENT_TARGET:-16.0}"
macos_deployment_target="${MACOS_DEPLOYMENT_TARGET:-13.0}"
tvos_deployment_target="${TVOS_DEPLOYMENT_TARGET:-17.0}"

jobs="$(sysctl -n hw.ncpu 2>/dev/null || true)"
if [[ -z "${jobs}" ]]; then
    jobs=4
fi

case "${target}" in
    all)
        groups=(ios ios-simulator macos tvos tvos-simulator)
        ;;
    ios)
        groups=(ios ios-simulator)
        ;;
    macos)
        groups=(macos)
        ;;
    tvos)
        groups=(tvos tvos-simulator)
        ;;
    *)
        echo "Unknown Apple target: ${target}. Expected all, ios, macos, or tvos." >&2
        exit 1
        ;;
esac

build_openssl=OFF
build_mbedtls=OFF
build_wg_go=OFF
case "${vendor}" in
    all)
        build_openssl=ON
        build_mbedtls=ON
        build_wg_go=ON
        ;;
    openssl)
        build_openssl=ON
        ;;
    mbedtls)
        build_mbedtls=ON
        ;;
    wg-go)
        build_wg_go=ON
        ;;
    *)
        echo "Unknown Apple vendor: ${vendor}. Expected all, openssl, mbedtls, or wg-go." >&2
        exit 1
        ;;
esac

required_commands=(ditto git grep lipo make patch perl plutil python3 rsync shasum swift xcodebuild xcrun)
if [[ "${build_wg_go}" == ON ]]; then
    required_commands+=(go)
fi
for command_name in "${required_commands[@]}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command not found: ${command_name}" >&2
        exit 1
    fi
done

if [[ "${build_openssl}" == ON && ! -f "${repository_dir}/vendors/openssl/Configure" ]]; then
    echo "OpenSSL is not initialized in prebuilts." >&2
    exit 1
fi
if [[ "${build_mbedtls}" == ON && ! -f "${repository_dir}/vendors/mbedtls/tf-psa-crypto/scripts/basic.requirements.txt" ]]; then
    echo "Mbed TLS submodules are not initialized in prebuilts." >&2
    exit 1
fi

rm -rf "${work_dir}" "${artifacts_dir}"
mkdir -p "${work_dir}/slices" "${work_dir}/groups" "${artifacts_dir}"

mbedtls_python=""
if [[ "${build_mbedtls}" == ON ]]; then
    mbedtls_python="$(${script_dir}/prepare-mbedtls-python.sh "${work_dir}/mbedtls-python")"
fi

set_slice_metadata() {
    local slice="${1}"

    case "${slice}" in
        ios-arm64)
            slice_sdk="iphoneos"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-ios${ios_deployment_target}"
            slice_deployment_target="${ios_deployment_target}"
            slice_openssl_target="ios64-xcrun"
            slice_goos="ios"
            ;;
        ios-simulator-arm64)
            slice_sdk="iphonesimulator"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-ios${ios_deployment_target}-simulator"
            slice_deployment_target="${ios_deployment_target}"
            slice_openssl_target="iossimulator-arm64-xcrun"
            slice_goos="ios"
            ;;
        ios-simulator-x86_64)
            slice_sdk="iphonesimulator"
            slice_arch="x86_64"
            slice_clang_target="x86_64-apple-ios${ios_deployment_target}-simulator"
            slice_deployment_target="${ios_deployment_target}"
            slice_openssl_target="iossimulator-x86_64-xcrun"
            slice_goos="ios"
            ;;
        macos-arm64)
            slice_sdk="macosx"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-macos${macos_deployment_target}"
            slice_deployment_target="${macos_deployment_target}"
            slice_openssl_target="darwin64-arm64"
            slice_goos="darwin"
            ;;
        macos-x86_64)
            slice_sdk="macosx"
            slice_arch="x86_64"
            slice_clang_target="x86_64-apple-macos${macos_deployment_target}"
            slice_deployment_target="${macos_deployment_target}"
            slice_openssl_target="darwin64-x86_64"
            slice_goos="darwin"
            ;;
        tvos-arm64)
            slice_sdk="appletvos"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-tvos${tvos_deployment_target}"
            slice_deployment_target="${tvos_deployment_target}"
            slice_openssl_target="darwin64-arm64"
            slice_goos="ios"
            ;;
        tvos-simulator-arm64)
            slice_sdk="appletvsimulator"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-tvos${tvos_deployment_target}-simulator"
            slice_deployment_target="${tvos_deployment_target}"
            slice_openssl_target="darwin64-arm64"
            slice_goos="ios"
            ;;
        tvos-simulator-x86_64)
            slice_sdk="appletvsimulator"
            slice_arch="x86_64"
            slice_clang_target="x86_64-apple-tvos${tvos_deployment_target}-simulator"
            slice_deployment_target="${tvos_deployment_target}"
            slice_openssl_target="darwin64-x86_64"
            slice_goos="ios"
            ;;
        *)
            echo "Unknown Apple slice: ${slice}" >&2
            exit 1
            ;;
    esac

    slice_sdkroot="$(xcrun --sdk "${slice_sdk}" --show-sdk-path)"
    slice_clang="$(xcrun --sdk "${slice_sdk}" --find clang)"
}

slice_architecture() {
    set_slice_metadata "${1}"
    printf '%s\n' "${slice_arch}"
}

group_slices() {
    case "${1}" in
        ios)
            printf '%s\n' ios-arm64
            ;;
        ios-simulator)
            printf '%s\n' ios-simulator-arm64 ios-simulator-x86_64
            ;;
        macos)
            printf '%s\n' macos-arm64 macos-x86_64
            ;;
        tvos)
            printf '%s\n' tvos-arm64
            ;;
        tvos-simulator)
            printf '%s\n' tvos-simulator-arm64 tvos-simulator-x86_64
            ;;
        *)
            echo "Unknown Apple group: ${1}" >&2
            exit 1
            ;;
    esac
}

build_slice() {
    local slice="${1}"
    local slice_dir="${work_dir}/slices/${slice}"
    local build_dir="${slice_dir}/build"
    local vendor_dir="${slice_dir}/vendors"
    local build_log="${slice_dir}/build.log"
    local apple_cflags
    local slice_ar
    local slice_ranlib
    local slice_goarch
    local openssl_extra=()

    set_slice_metadata "${slice}"
    mkdir -p "${slice_dir}"
    apple_cflags="-O2 -isysroot ${slice_sdkroot} -target ${slice_clang_target}"
    slice_ar="$(xcrun --sdk "${slice_sdk}" --find ar)"
    slice_ranlib="$(xcrun --sdk "${slice_sdk}" --find ranlib)"
    if [[ "${slice_arch}" == arm64 ]]; then
        slice_goarch=arm64
    else
        slice_goarch=amd64
    fi
    if [[ "${slice}" == tvos-* ]]; then
        openssl_extra=(-DHAVE_FORK=0 no-async)
    fi

    echo "Building ${vendor} for ${slice}"
    if ! {
        if [[ "${build_openssl}" == ON ]]; then
            if [[ "${#openssl_extra[@]}" -gt 0 ]]; then
                CFLAGS="${apple_cflags}" \
                LDFLAGS="-isysroot ${slice_sdkroot} -target ${slice_clang_target}" \
                OPENSSL_LINKAGE=static \
                BUILD_JOBS="${jobs}" \
                    "${script_dir}/build-openssl.sh" \
                    "${vendor_dir}/openssl" "${build_dir}/openssl" \
                    "${slice_openssl_target}" "${openssl_extra[@]}"
            else
                CFLAGS="${apple_cflags}" \
                LDFLAGS="-isysroot ${slice_sdkroot} -target ${slice_clang_target}" \
                OPENSSL_LINKAGE=static \
                BUILD_JOBS="${jobs}" \
                    "${script_dir}/build-openssl.sh" \
                    "${vendor_dir}/openssl" "${build_dir}/openssl" \
                    "${slice_openssl_target}"
            fi
        fi
        if [[ "${build_mbedtls}" == ON ]]; then
            CC="${slice_clang}" \
            AR="${slice_ar}" \
            RANLIB="${slice_ranlib}" \
            CFLAGS="${apple_cflags}" \
            MBEDTLS_PYTHON="${mbedtls_python}" \
            BUILD_JOBS="${jobs}" \
                "${script_dir}/build-mbedtls.sh" \
                "${vendor_dir}/mbedtls" "${build_dir}/mbedtls"
        fi
        if [[ "${build_wg_go}" == ON ]]; then
            make -C "${repository_dir}/vendors/wg-go" install \
                "BUILDDIR=${build_dir}/wg-go" \
                "DESTDIR=${vendor_dir}/wg-go" \
                "TMPROOTDIR=${build_dir}/wg-go-goroot" \
                APPLE=1 "GOARCH=${slice_goarch}" "GOOS=${slice_goos}" \
                "SDKROOT=${slice_sdkroot}" "TARGET=${slice_clang_target}"
        fi
    } > "${build_log}" 2>&1; then
        tail -n 300 "${build_log}" >&2
        exit 1
    fi

    if [[ "${build_openssl}" == ON ]]; then
        [[ -f "${vendor_dir}/openssl/lib/libssl.a" ]] || { echo "Missing libssl.a for ${slice}" >&2; exit 1; }
        [[ -f "${vendor_dir}/openssl/lib/libcrypto.a" ]] || { echo "Missing libcrypto.a for ${slice}" >&2; exit 1; }
        /usr/bin/libtool -static -o "${slice_dir}/libopenssl.a" \
            "${vendor_dir}/openssl/lib/libssl.a" \
            "${vendor_dir}/openssl/lib/libcrypto.a"
    fi
    if [[ "${build_mbedtls}" == ON ]]; then
        [[ -f "${vendor_dir}/mbedtls/lib/libmbedtls.a" ]] || { echo "Missing libmbedtls.a for ${slice}" >&2; exit 1; }
        [[ -f "${vendor_dir}/mbedtls/lib/libmbedx509.a" ]] || { echo "Missing libmbedx509.a for ${slice}" >&2; exit 1; }
        [[ -f "${vendor_dir}/mbedtls/lib/libmbedcrypto.a" ]] || { echo "Missing libmbedcrypto.a for ${slice}" >&2; exit 1; }
        /usr/bin/libtool -static -o "${slice_dir}/libmbedtls.a" \
            "${vendor_dir}/mbedtls/lib/libmbedtls.a" \
            "${vendor_dir}/mbedtls/lib/libmbedx509.a" \
            "${vendor_dir}/mbedtls/lib/libmbedcrypto.a"
    fi
    if [[ "${build_wg_go}" == ON ]]; then
        [[ -f "${vendor_dir}/wg-go/lib/libwg-go.a" ]] || { echo "Missing libwg-go.a for ${slice}" >&2; exit 1; }
        cp "${vendor_dir}/wg-go/lib/libwg-go.a" "${slice_dir}/libwg-go.a"
    fi
}

for group in "${groups[@]}"; do
    while IFS= read -r slice; do
        build_slice "${slice}"
    done < <(group_slices "${group}")
done

merge_group_library() {
    local group="${1}"
    local library="${2}"
    local group_dir="${work_dir}/groups/${group}"
    local inputs=()
    local slice

    while IFS= read -r slice; do
        inputs+=("${work_dir}/slices/${slice}/${library}.a")
    done < <(group_slices "${group}")

    mkdir -p "${group_dir}"
    if [[ "${#inputs[@]}" -eq 1 ]]; then
        cp "${inputs[0]}" "${group_dir}/${library}.a"
    else
        lipo -create "${inputs[@]}" -output "${group_dir}/${library}.a"
    fi
}

assert_common_headers() {
    local vendor="${1}"
    local group="${2}"
    local first_slice=""
    local slice

    while IFS= read -r slice; do
        if [[ -z "${first_slice}" ]]; then
            first_slice="${slice}"
            continue
        fi
        if ! diff -qr \
            "${work_dir}/slices/${first_slice}/vendors/${vendor}/include" \
            "${work_dir}/slices/${slice}/vendors/${vendor}/include" >/dev/null; then
            echo "${vendor} headers differ between ${first_slice} and ${slice}" >&2
            exit 1
        fi
    done < <(group_slices "${group}")
}

prepare_openssl_headers() {
    local group="${1}"
    local headers_dir="${work_dir}/groups/${group}/headers/openssl/openssl"
    local first_slice=""
    local slice
    local arch
    local configuration_header
    local configuration_headers=()

    while IFS= read -r slice; do
        if [[ -z "${first_slice}" ]]; then
            first_slice="${slice}"
            mkdir -p "${headers_dir}"
            rsync -a "${work_dir}/slices/${slice}/vendors/openssl/include/openssl/" "${headers_dir}/"
        fi

        arch="$(slice_architecture "${slice}")"
        configuration_header="${headers_dir}/configuration-${arch}.h"
        cp "${work_dir}/slices/${slice}/vendors/openssl/include/openssl/configuration.h" \
            "${configuration_header}"
        configuration_headers+=("${configuration_header}")
    done < <(group_slices "${group}")

    if [[ "${#configuration_headers[@]}" -gt 1 ]]; then
        {
            printf '#pragma once\n\n'
            printf '#if defined(__arm64__) || defined(__aarch64__)\n'
            printf '#include "configuration-arm64.h"\n'
            printf '#elif defined(__x86_64__)\n'
            printf '#include "configuration-x86_64.h"\n'
            printf '#else\n'
            printf '#error Unsupported architecture\n'
            printf '#endif\n'
        } > "${headers_dir}/configuration.h"
    fi

    cp "${modulemaps_dir}/openssl.modulemap" "${headers_dir}/module.modulemap"
}

prepare_common_headers() {
    local vendor="${1}"
    local group="${2}"
    local module="${3}"
    local modulemap="${4}"
    local first_slice
    local headers_dir="${work_dir}/groups/${group}/headers/${vendor}"

    first_slice="$(group_slices "${group}" | sed -n '1p')"
    assert_common_headers "${vendor}" "${group}"
    mkdir -p "${headers_dir}"
    rsync -a "${work_dir}/slices/${first_slice}/vendors/${vendor}/include/" "${headers_dir}/"
    if [[ -n "${modulemap}" ]]; then
        cp "${modulemap}" "${headers_dir}/${module}/module.modulemap"
    fi
}

prepare_wg_go_headers() {
    local group="${1}"
    local first_slice
    local headers_dir="${work_dir}/groups/${group}/headers/wg-go/wg_go"

    first_slice="$(group_slices "${group}" | sed -n '1p')"
    assert_common_headers wg-go "${group}"
    mkdir -p "${headers_dir}"
    rsync -a \
        "${work_dir}/slices/${first_slice}/vendors/wg-go/include/wg_go/" \
        "${headers_dir}/"
    cp "${modulemaps_dir}/wg-go.modulemap" "${headers_dir}/module.modulemap"
}

for group in "${groups[@]}"; do
    if [[ "${build_openssl}" == ON ]]; then
        merge_group_library "${group}" libopenssl
        prepare_openssl_headers "${group}"
    fi
    if [[ "${build_mbedtls}" == ON ]]; then
        merge_group_library "${group}" libmbedtls
        prepare_common_headers mbedtls "${group}" mbedtls "${modulemaps_dir}/mbedtls.modulemap"
    fi
    if [[ "${build_wg_go}" == ON ]]; then
        merge_group_library "${group}" libwg-go
        prepare_wg_go_headers "${group}"
    fi
done

create_xcframework() {
    local name="${1}"
    local library="${2}"
    local headers="${3}"
    local module="${4}"
    local output="${work_dir}/${name}.xcframework"
    local arguments=(-create-xcframework)
    local group

    for group in "${groups[@]}"; do
        arguments+=(
            -library "${work_dir}/groups/${group}/${library}.a"
            -headers "${work_dir}/groups/${group}/headers/${headers}"
        )
    done
    arguments+=(-output "${output}")

    xcodebuild "${arguments[@]}"
    plutil -lint "${output}/Info.plist"

    if find "${output}" -type f \( -name '*.dylib' -o -name '*.so' \) -print | grep -q .; then
        echo "Dynamic library found in ${output}" >&2
        exit 1
    fi
    if [[ "$(find "${output}" -type f -name '*.a' | wc -l | tr -d ' ')" -ne "${#groups[@]}" ]]; then
        echo "Unexpected static library count in ${output}" >&2
        exit 1
    fi
    if [[ "$(find "${output}" -type f -path "*/Headers/${module}/module.modulemap" | wc -l | tr -d ' ')" -ne "${#groups[@]}" ]]; then
        echo "Unexpected module map layout in ${output}: expected Headers/${module}/module.modulemap" >&2
        exit 1
    fi
    if find "${output}" -type f -path '*/Headers/module.modulemap' -print | grep -q .; then
        echo "Flattened module map found in ${output}" >&2
        exit 1
    fi

    local archive_name="${name}.xcframework.zip"
    local archive_path="${artifacts_dir}/${archive_name}"
    local sha256
    ditto -c -k --sequesterRsrc --keepParent "${output}" "${archive_path}"
    sha256="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
    printf '%s  %s\n' "${sha256}" "${archive_name}" > "${archive_path}.sha256"
    swift package compute-checksum "${archive_path}" > "${archive_path}.checksum"
}

if [[ "${build_openssl}" == ON ]]; then
    create_xcframework openssl libopenssl openssl openssl
fi
if [[ "${build_mbedtls}" == ON ]]; then
    create_xcframework mbedtls libmbedtls mbedtls mbedtls
fi
if [[ "${build_wg_go}" == ON ]]; then
    create_xcframework wg-go libwg-go wg-go wg_go
fi

prebuilts_remote="$(git -C "${repository_dir}" remote | sed -n '1p')"
prebuilts_repository=""
if [[ -n "${prebuilts_remote}" ]]; then
    prebuilts_repository="$(git -C "${repository_dir}" remote get-url "${prebuilts_remote}")"
fi
prebuilts_ref="$(git -C "${repository_dir}" rev-parse HEAD)"
if [[ "${build_openssl}" == ON ]]; then
    openssl_dir="${repository_dir}/vendors/openssl"
    openssl_ref="$(git -C "${openssl_dir}" rev-parse HEAD)"
    openssl_version="$(git -C "${openssl_dir}" describe --tags --always --dirty)"
fi
if [[ "${build_mbedtls}" == ON ]]; then
    mbedtls_dir="${repository_dir}/vendors/mbedtls"
    mbedtls_ref="$(git -C "${mbedtls_dir}" rev-parse HEAD)"
    mbedtls_version="$(git -C "${mbedtls_dir}" describe --tags --always --dirty)"
fi
if [[ "${build_wg_go}" == ON ]]; then
    wg_go_dir="${repository_dir}/vendors/wg-go"
    wireguard_go_version="$(awk '$1 == "golang.zx2c4.com/wireguard" && $2 !~ /\/go\.mod$/ { print $2; exit }' "${wg_go_dir}/go.sum")"
fi
xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
go_version=""
if [[ "${build_wg_go}" == ON ]] && command -v go >/dev/null 2>&1; then
    go_version="$(go env GOVERSION 2>/dev/null || go version)"
fi
make_version="$(make --version | sed -n '1p')"
python_version="$(python3 --version 2>&1)"

manifest_scope="apple"
if [[ "${vendor}" != all ]]; then
    manifest_scope="${vendor}-apple"
fi
manifest_path="${artifacts_dir}/${manifest_scope}-manifest.json"
{
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "target": "%s",\n' "${target}"
    printf '  "vendor": "%s",\n' "${vendor}"
    printf '  "linkage": "static",\n'
    printf '  "prebuilts": { "repository": "%s", "ref": "%s" },\n' "${prebuilts_repository}" "${prebuilts_ref}"
    printf '  "libraries": {\n'
    library_separator=""
    if [[ "${build_openssl}" == ON ]]; then
        printf '%s    "openssl": { "version": "%s", "ref": "%s", "artifact": "openssl.xcframework.zip" }' \
            "${library_separator}" "${openssl_version}" "${openssl_ref}"
        library_separator=$',\n'
    fi
    if [[ "${build_mbedtls}" == ON ]]; then
        printf '%s    "mbedtls": { "version": "%s", "ref": "%s", "artifact": "mbedtls.xcframework.zip" }' \
            "${library_separator}" "${mbedtls_version}" "${mbedtls_ref}"
        library_separator=$',\n'
    fi
    if [[ "${build_wg_go}" == ON ]]; then
        printf '%s    "wg-go": { "sourceRef": "%s", "wireguardGoVersion": "%s", "artifact": "wg-go.xcframework.zip" }' \
            "${library_separator}" "${prebuilts_ref}" "${wireguard_go_version}"
    fi
    printf '\n'
    printf '  },\n'
    printf '  "deploymentTargets": { "iOS": "%s", "macOS": "%s", "tvOS": "%s" },\n' "${ios_deployment_target}" "${macos_deployment_target}" "${tvos_deployment_target}"
    printf '  "platforms": ['
    separator=""
    for group in "${groups[@]}"; do
        printf '%s"%s"' "${separator}" "${group}"
        separator=", "
    done
    printf '],\n'
    printf '  "toolchains": { "xcode": "%s", "go": "%s", "make": "%s", "python": "%s" }\n' \
        "${xcode_version}" "${go_version}" "${make_version}" "${python_version}"
    printf '}\n'
} > "${manifest_path}"

manifest_name="$(basename "${manifest_path}")"
manifest_sha256="$(shasum -a 256 "${manifest_path}" | awk '{print $1}')"
printf '%s  %s\n' "${manifest_sha256}" "${manifest_name}" > "${manifest_path}.sha256"

echo "Created static Apple XCFramework artifacts in ${artifacts_dir}:"
find "${artifacts_dir}" -maxdepth 1 -type f -print | sort
