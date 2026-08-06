#!/usr/bin/env bash
set -euo pipefail

target="${1:-all}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
partout_dir="${PARTOUT_DIR:-${repository_dir}/partout}"
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

required_commands=(cmake ditto git grep lipo ninja plutil rsync shasum swift xcodebuild xcrun)
for command_name in "${required_commands[@]}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command not found: ${command_name}" >&2
        exit 1
    fi
done

if [[ ! -f "${partout_dir}/CMakeLists.txt" ]]; then
    echo "Partout checkout not found: ${partout_dir}" >&2
    exit 1
fi
if [[ ! -f "${partout_dir}/vendors/openssl/Configure" ]]; then
    echo "OpenSSL is not initialized in Partout." >&2
    exit 1
fi
if [[ ! -f "${partout_dir}/vendors/mbedtls/tf-psa-crypto/CMakeLists.txt" ]]; then
    echo "Mbed TLS submodules are not initialized in Partout." >&2
    exit 1
fi

rm -rf "${work_dir}" "${artifacts_dir}"
mkdir -p "${work_dir}/slices" "${work_dir}/groups" "${artifacts_dir}"

set_slice_metadata() {
    local slice="${1}"

    case "${slice}" in
        ios-arm64)
            slice_sdk="iphoneos"
            slice_cmake_system="iOS"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-ios${ios_deployment_target}"
            slice_deployment_target="${ios_deployment_target}"
            ;;
        ios-simulator-arm64)
            slice_sdk="iphonesimulator"
            slice_cmake_system="iOS"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-ios${ios_deployment_target}-simulator"
            slice_deployment_target="${ios_deployment_target}"
            ;;
        ios-simulator-x86_64)
            slice_sdk="iphonesimulator"
            slice_cmake_system="iOS"
            slice_arch="x86_64"
            slice_clang_target="x86_64-apple-ios${ios_deployment_target}-simulator"
            slice_deployment_target="${ios_deployment_target}"
            ;;
        macos-arm64)
            slice_sdk="macosx"
            slice_cmake_system="Darwin"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-macos${macos_deployment_target}"
            slice_deployment_target="${macos_deployment_target}"
            ;;
        macos-x86_64)
            slice_sdk="macosx"
            slice_cmake_system="Darwin"
            slice_arch="x86_64"
            slice_clang_target="x86_64-apple-macos${macos_deployment_target}"
            slice_deployment_target="${macos_deployment_target}"
            ;;
        tvos-arm64)
            slice_sdk="appletvos"
            slice_cmake_system="tvOS"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-tvos${tvos_deployment_target}"
            slice_deployment_target="${tvos_deployment_target}"
            ;;
        tvos-simulator-arm64)
            slice_sdk="appletvsimulator"
            slice_cmake_system="tvOS"
            slice_arch="arm64"
            slice_clang_target="arm64-apple-tvos${tvos_deployment_target}-simulator"
            slice_deployment_target="${tvos_deployment_target}"
            ;;
        tvos-simulator-x86_64)
            slice_sdk="appletvsimulator"
            slice_cmake_system="tvOS"
            slice_arch="x86_64"
            slice_clang_target="x86_64-apple-tvos${tvos_deployment_target}-simulator"
            slice_deployment_target="${tvos_deployment_target}"
            ;;
        *)
            echo "Unknown Apple slice: ${slice}" >&2
            exit 1
            ;;
    esac

    slice_sdkroot="$(xcrun --sdk "${slice_sdk}" --show-sdk-path)"
    slice_clang="$(xcrun --sdk "${slice_sdk}" --find clang)"
    slice_openssl_args=""
    case "${slice_sdk}" in
        iphoneos)
            slice_openssl_target="ios64-xcrun"
            ;;
        iphonesimulator)
            slice_openssl_target="iossimulator-${slice_arch}-xcrun"
            ;;
        macosx)
            slice_openssl_target="darwin64-${slice_arch}"
            ;;
        appletvos|appletvsimulator)
            slice_openssl_target="darwin64-${slice_arch}"
            slice_openssl_args="-DHAVE_FORK=0;no-async"
            ;;
    esac
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
    local build_dir="${slice_dir}/cmake-build"
    local vendor_dir="${slice_dir}/vendors"
    local build_log="${slice_dir}/build.log"
    local toolchain_file="${slice_dir}/toolchain.cmake"

    set_slice_metadata "${slice}"
    mkdir -p "${slice_dir}"
    {
        printf 'set(CMAKE_SYSTEM_NAME "%s" CACHE STRING "")\n' "${slice_cmake_system}"
        printf 'set(CMAKE_SYSTEM_PROCESSOR "%s" CACHE STRING "")\n' "${slice_arch}"
        printf 'set(CMAKE_C_COMPILER "%s" CACHE FILEPATH "")\n' "${slice_clang}"
        printf 'set(CMAKE_C_COMPILER_TARGET "%s" CACHE STRING "")\n' "${slice_clang_target}"
        printf 'set(CMAKE_OSX_ARCHITECTURES "%s" CACHE STRING "")\n' "${slice_arch}"
        printf 'set(CMAKE_OSX_DEPLOYMENT_TARGET "%s" CACHE STRING "")\n' "${slice_deployment_target}"
        printf 'set(CMAKE_OSX_SYSROOT "%s" CACHE PATH "")\n' "${slice_sdkroot}"
        printf 'set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY CACHE STRING "")\n'
    } > "${toolchain_file}"

    echo "Configuring Partout vendors for ${slice}"
    cmake \
        -S "${partout_dir}" \
        -B "${build_dir}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DOPENSSL_PLATFORM_ARGS="${slice_openssl_args}" \
        -DOPENSSL_TARGET="${slice_openssl_target}" \
        -DPP_BUILD_LIBRARY=OFF \
        -DPP_BUILD_OUTPUT="${vendor_dir}" \
        -DPP_BUILD_USE_MBEDTLS=ON \
        -DPP_BUILD_USE_OPENSSL=ON \
        -DPP_BUILD_USE_WIREGUARD=ON \
        -DPP_BUILD_VENDOR_SOURCE=bundled

    echo "Building Partout vendor targets for ${slice}"
    if ! cmake --build "${build_dir}" \
        --target OpenSSLProject MbedTLSProject WireGuardGoProject \
        --parallel "${jobs}" > "${build_log}" 2>&1; then
        tail -n 300 "${build_log}" >&2
        exit 1
    fi

    [[ -f "${vendor_dir}/openssl/lib/libssl.a" ]] || { echo "Missing libssl.a for ${slice}" >&2; exit 1; }
    [[ -f "${vendor_dir}/openssl/lib/libcrypto.a" ]] || { echo "Missing libcrypto.a for ${slice}" >&2; exit 1; }
    [[ -f "${vendor_dir}/mbedtls/lib/libmbedtls.a" ]] || { echo "Missing libmbedtls.a for ${slice}" >&2; exit 1; }
    [[ -f "${vendor_dir}/mbedtls/lib/libmbedx509.a" ]] || { echo "Missing libmbedx509.a for ${slice}" >&2; exit 1; }
    [[ -f "${vendor_dir}/mbedtls/lib/libmbedcrypto.a" ]] || { echo "Missing libmbedcrypto.a for ${slice}" >&2; exit 1; }
    [[ -f "${vendor_dir}/wg-go/lib/libwg-go.a" ]] || { echo "Missing libwg-go.a for ${slice}" >&2; exit 1; }

    /usr/bin/libtool -static -o "${slice_dir}/libopenssl.a" \
        "${vendor_dir}/openssl/lib/libssl.a" \
        "${vendor_dir}/openssl/lib/libcrypto.a"
    /usr/bin/libtool -static -o "${slice_dir}/libmbedtls.a" \
        "${vendor_dir}/mbedtls/lib/libmbedtls.a" \
        "${vendor_dir}/mbedtls/lib/libmbedx509.a" \
        "${vendor_dir}/mbedtls/lib/libmbedcrypto.a"
    cp "${vendor_dir}/wg-go/lib/libwg-go.a" "${slice_dir}/libwg-go.a"
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
    local headers_dir="${work_dir}/groups/${group}/headers/openssl"
    local first_slice=""
    local slice
    local arch
    local configuration_header
    local configuration_headers=()

    while IFS= read -r slice; do
        if [[ -z "${first_slice}" ]]; then
            first_slice="${slice}"
            mkdir -p "${headers_dir}"
            rsync -a "${work_dir}/slices/${slice}/vendors/openssl/include/" "${headers_dir}/"
        fi

        arch="$(slice_architecture "${slice}")"
        configuration_header="${headers_dir}/openssl/configuration-${arch}.h"
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
        } > "${headers_dir}/openssl/configuration.h"
    fi

    cp "${modulemaps_dir}/openssl.modulemap" "${headers_dir}/module.modulemap"
}

prepare_common_headers() {
    local vendor="${1}"
    local group="${2}"
    local modulemap="${3}"
    local first_slice
    local headers_dir="${work_dir}/groups/${group}/headers/${vendor}"

    first_slice="$(group_slices "${group}" | sed -n '1p')"
    assert_common_headers "${vendor}" "${group}"
    mkdir -p "${headers_dir}"
    rsync -a "${work_dir}/slices/${first_slice}/vendors/${vendor}/include/" "${headers_dir}/"
    if [[ -n "${modulemap}" ]]; then
        cp "${modulemap}" "${headers_dir}/module.modulemap"
    fi
}

for group in "${groups[@]}"; do
    merge_group_library "${group}" libopenssl
    merge_group_library "${group}" libmbedtls
    merge_group_library "${group}" libwg-go
    prepare_openssl_headers "${group}"
    prepare_common_headers mbedtls "${group}" "${modulemaps_dir}/mbedtls.modulemap"
    prepare_common_headers wg-go "${group}" ""
done

create_xcframework() {
    local name="${1}"
    local library="${2}"
    local headers="${3}"
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

    local archive_name="${name}.xcframework.zip"
    local archive_path="${artifacts_dir}/${archive_name}"
    local sha256
    ditto -c -k --sequesterRsrc --keepParent "${output}" "${archive_path}"
    sha256="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
    printf '%s  %s\n' "${sha256}" "${archive_name}" > "${archive_path}.sha256"
    swift package compute-checksum "${archive_path}" > "${archive_path}.checksum"
}

create_xcframework openssl libopenssl openssl
create_xcframework mbedtls libmbedtls mbedtls
create_xcframework wg-go libwg-go wg-go

partout_repository="$(git config --file "${repository_dir}/.gitmodules" --get submodule.partout.url || git -C "${partout_dir}" config --get remote.origin.url || true)"
partout_ref="$(git -C "${partout_dir}" rev-parse HEAD)"
openssl_dir="${partout_dir}/vendors/openssl"
mbedtls_dir="${partout_dir}/vendors/mbedtls"
wg_go_dir="${partout_dir}/vendors/wg-go"
openssl_ref="$(git -C "${openssl_dir}" rev-parse HEAD)"
mbedtls_ref="$(git -C "${mbedtls_dir}" rev-parse HEAD)"
openssl_version="$(git -C "${openssl_dir}" describe --tags --always --dirty)"
mbedtls_version="$(git -C "${mbedtls_dir}" describe --tags --always --dirty)"
wireguard_go_version="$(awk '$1 == "golang.zx2c4.com/wireguard" && $2 !~ /\/go\.mod$/ { print $2; exit }' "${wg_go_dir}/go.sum")"
xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
go_version="$(go env GOVERSION 2>/dev/null || go version)"
cmake_version="$(cmake --version | sed -n '1s/^cmake version //p')"
ninja_version="$(ninja --version)"

manifest_path="${artifacts_dir}/partout-vendors-apple-manifest.json"
{
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "target": "%s",\n' "${target}"
    printf '  "linkage": "static",\n'
    printf '  "partout": { "repository": "%s", "ref": "%s" },\n' "${partout_repository}" "${partout_ref}"
    printf '  "libraries": {\n'
    printf '    "openssl": { "version": "%s", "ref": "%s", "artifact": "openssl.xcframework.zip" },\n' "${openssl_version}" "${openssl_ref}"
    printf '    "mbedtls": { "version": "%s", "ref": "%s", "artifact": "mbedtls.xcframework.zip" },\n' "${mbedtls_version}" "${mbedtls_ref}"
    printf '    "wg-go": { "partoutRef": "%s", "wireguardGoVersion": "%s", "artifact": "wg-go.xcframework.zip" }\n' "${partout_ref}" "${wireguard_go_version}"
    printf '  },\n'
    printf '  "deploymentTargets": { "iOS": "%s", "macOS": "%s", "tvOS": "%s" },\n' "${ios_deployment_target}" "${macos_deployment_target}" "${tvos_deployment_target}"
    printf '  "platforms": ['
    separator=""
    for group in "${groups[@]}"; do
        printf '%s"%s"' "${separator}" "${group}"
        separator=", "
    done
    printf '],\n'
    printf '  "toolchains": { "xcode": "%s", "go": "%s", "cmake": "%s", "ninja": "%s" }\n' \
        "${xcode_version}" "${go_version}" "${cmake_version}" "${ninja_version}"
    printf '}\n'
} > "${manifest_path}"

manifest_name="$(basename "${manifest_path}")"
manifest_sha256="$(shasum -a 256 "${manifest_path}" | awk '{print $1}')"
printf '%s  %s\n' "${manifest_sha256}" "${manifest_name}" > "${manifest_path}.sha256"

echo "Created static Apple XCFramework artifacts in ${artifacts_dir}:"
find "${artifacts_dir}" -maxdepth 1 -type f -print | sort
