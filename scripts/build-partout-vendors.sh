#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: build-partout-vendors.sh <target> <vendor>}"
vendor="${2:?usage: build-partout-vendors.sh <target> <vendor>}"
partout_dir="${PARTOUT_DIR:-${PWD}/.build/partout}"
work_dir="${PWD}/.build/${target}-${vendor}"
package_root="${work_dir}/package"
artifacts_dir="${PWD}/artifacts"

case "${vendor}" in
    openssl | mbedtls | wg-go)
        ;;
    *)
        echo "Unknown vendor: ${vendor}" >&2
        exit 1
        ;;
esac

case "${target}" in
    android-arm64-v8a)
        os="android"
        arch="arm64-v8a"
        openssl_target="android-arm64"
        android_abi="arm64-v8a"
        android_goarch="arm64"
        android_clang_triple="aarch64-linux-android"
        ;;
    windows-x64)
        os="windows"
        arch="x64"
        mingw_triple="x86_64-w64-mingw32"
        openssl_target="mingw64"
        cmake_processor="x86_64"
        goarch="amd64"
        dlltool_machine="i386:x86-64"
        ;;
    windows-arm64)
        os="windows"
        arch="arm64"
        mingw_triple="aarch64-w64-mingw32"
        openssl_target="mingwarm64"
        cmake_processor="aarch64"
        goarch="arm64"
        dlltool_machine="arm64"
        ;;
    *)
        echo "Unknown target: ${target}" >&2
        exit 1
        ;;
esac

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
mkdir -p "${package_root}" "${artifacts_dir}"

build_openssl() {
    local source_dir="${partout_dir}/vendors/openssl"
    local build_dir="${work_dir}/openssl-src"
    local install_dir="${package_root}/openssl"
    local flags=(
        no-apps
        no-docs
        no-dsa
        no-engine
        no-gost
        no-legacy
        shared
        no-ssl
        no-tests
        no-zlib
    )

    cp -a "${source_dir}" "${build_dir}"
    pushd "${build_dir}"

    if [[ "${os}" == "android" ]]; then
        local ndk_root="${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT is required}"
        export PATH="${ndk_root}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}"
        export ANDROID_NDK_ROOT="${ndk_root}"
        perl Configure "${openssl_target}" -D__ANDROID_API__="${ANDROID_API:?ANDROID_API is required}" \
            --prefix="${install_dir}" --openssldir="${install_dir}" --libdir=lib "${flags[@]}"
    else
        local llvm_root="${LLVM_MINGW_ROOT:?LLVM_MINGW_ROOT is required}"
        export PATH="${llvm_root}/bin:${PATH}"
        CROSS_COMPILE="${mingw_triple}-" perl Configure "${openssl_target}" \
            --prefix="${install_dir}" --openssldir="${install_dir}" --libdir=lib "${flags[@]}"
    fi

    make "-j$(nproc)"
    make install_sw
    popd

    if [[ "${os}" == "windows" ]]; then
        if [[ -f "${install_dir}/lib/libssl.dll.a" ]]; then
            cp "${install_dir}/lib/libssl.dll.a" "${install_dir}/lib/libssl.lib"
        fi
        if [[ -f "${install_dir}/lib/libcrypto.dll.a" ]]; then
            cp "${install_dir}/lib/libcrypto.dll.a" "${install_dir}/lib/libcrypto.lib"
        fi
    fi
}

build_mbedtls() {
    local source_dir="${partout_dir}/vendors/mbedtls"
    local build_dir="${work_dir}/mbedtls-build"
    local install_dir="${package_root}/mbedtls"
    local cmake_args=(
        -S "${source_dir}"
        -B "${build_dir}"
        -G Ninja
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="${install_dir}"
        -DENABLE_TESTING=OFF
        -DENABLE_PROGRAMS=OFF
    )

    if [[ "${os}" == "android" ]]; then
        cmake_args+=(
            -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT is required}/build/cmake/android.toolchain.cmake"
            -DANDROID_ABI="${android_abi}"
            -DANDROID_PLATFORM="android-${ANDROID_API:?ANDROID_API is required}"
        )
    else
        local toolchain_file="${work_dir}/llvm-mingw-${arch}.cmake"
        cat > "${toolchain_file}" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR ${cmake_processor})
set(CMAKE_C_COMPILER "${LLVM_MINGW_ROOT:?LLVM_MINGW_ROOT is required}/bin/${mingw_triple}-clang")
set(CMAKE_CXX_COMPILER "${LLVM_MINGW_ROOT}/bin/${mingw_triple}-clang++")
set(CMAKE_RC_COMPILER "${LLVM_MINGW_ROOT}/bin/${mingw_triple}-windres")
set(CMAKE_AR "${LLVM_MINGW_ROOT}/bin/llvm-ar")
set(CMAKE_RANLIB "${LLVM_MINGW_ROOT}/bin/llvm-ranlib")
EOF
        cmake_args+=(-DCMAKE_TOOLCHAIN_FILE="${toolchain_file}")
    fi

    cmake "${cmake_args[@]}"
    cmake --build "${build_dir}" --target install
}

build_wg_go() {
    local source_dir="${partout_dir}/vendors/wg-go"
    local install_dir="${package_root}/wg-go"
    local build_dir="${work_dir}/wg-go-build"

    mkdir -p "${install_dir}/include" "${install_dir}/lib" "${build_dir}"
    cp -R "${source_dir}/include/." "${install_dir}/include"

    if [[ "${os}" == "android" ]]; then
        local cc="${ANDROID_NDK_ROOT:?ANDROID_NDK_ROOT is required}/toolchains/llvm/prebuilt/linux-x86_64/bin/${android_clang_triple}${ANDROID_API:?ANDROID_API is required}-clang"
        CGO_ENABLED=1 GOOS=android GOARCH="${android_goarch}" CC="${cc}" \
            go build -C "${source_dir}/src" -ldflags=-w -trimpath -v \
            -o "${install_dir}/lib/libwg-go.so" -buildmode=c-shared
    else
        local cc="${LLVM_MINGW_ROOT:?LLVM_MINGW_ROOT is required}/bin/${mingw_triple}-clang"
        CGO_ENABLED=1 GOOS=windows GOARCH="${goarch}" CC="${cc}" \
            CGO_CFLAGS="--target=${mingw_triple}" CGO_CXXFLAGS="--target=${mingw_triple}" \
            go build -C "${source_dir}/src" -ldflags=-w -trimpath -v \
            -o "${install_dir}/lib/wg-go.dll" -buildmode=c-shared
        cat > "${build_dir}/wg-go.def" <<EOF
LIBRARY wg-go.dll
EXPORTS
wgSetLogger
wgTurnOn
wgGetSocketV4
wgGetSocketV6
wgTurnOff
wgSetConfig
wgGetConfig
wgBumpSockets
wgBumpSocketsAndWait
wgDisableSomeRoamingForBrokenMobileSemantics
wgVersion
EOF
        "${LLVM_MINGW_ROOT}/bin/llvm-dlltool" -m "${dlltool_machine}" -d "${build_dir}/wg-go.def" -l "${install_dir}/lib/wg-go.lib"
    fi
}

write_manifest() {
    local manifest="${package_root}/manifest.json"
    local libraries_json

    case "${vendor}" in
        openssl)
            libraries_json="$(cat <<EOF
    "openssl": {
      "version": "${OPENSSL_VERSION}",
      "linkage": "shared"
    }
EOF
)"
            ;;
        mbedtls)
            libraries_json="$(cat <<EOF
    "mbedtls": {
      "version": "${MBEDTLS_VERSION}",
      "linkage": "static"
    }
EOF
)"
            ;;
        wg-go)
            libraries_json="$(cat <<EOF
    "wg-go": {
      "partoutRef": "${PARTOUT_REF}",
      "wireguardGoVersion": "${WIREGUARD_GO_VERSION}",
      "linkage": "shared"
    }
EOF
)"
            ;;
    esac

    cat > "${manifest}" <<EOF
{
  "schemaVersion": 1,
  "target": "${target}",
  "vendor": "${vendor}",
  "os": "${os}",
  "arch": "${arch}",
  "partout": {
    "repository": "${PARTOUT_REPOSITORY}",
    "ref": "${PARTOUT_REF}"
  },
  "libraries": {
${libraries_json}
  },
  "toolchains": {
    "go": "${go_version}",
    "cmake": "${cmake_version}",
    "ninja": "${ninja_version}",
    "androidApi": "${ANDROID_API:-}",
    "androidNdk": "${android_ndk_version}",
    "llvmMingw": "${LLVM_MINGW_VERSION:-}"
  }
}
EOF
}

package_target() {
    local package_name="partout-vendors-${vendor}-${target}.tar.gz"
    tar -czf "${artifacts_dir}/${package_name}" -C "${package_root}" .
    shasum -a 256 "${artifacts_dir}/${package_name}" > "${artifacts_dir}/${package_name}.sha256"
}

case "${vendor}" in
    openssl)
        build_openssl
        ;;
    mbedtls)
        build_mbedtls
        ;;
    wg-go)
        build_wg_go
        ;;
esac
write_manifest
package_target
