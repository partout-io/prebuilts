#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: build-partout-vendors.sh <target>}"
partout_dir="${PARTOUT_DIR:-${PWD}/.build/partout}"
work_dir="${PWD}/.build/${target}"
package_root="${work_dir}/package"
artifacts_dir="${PWD}/artifacts"

case "${target}" in
    android-arm64-v8a)
        os="android"
        arch="arm64-v8a"
        openssl_target="android-arm64"
        android_abi="arm64-v8a"
        android_goarch="arm64"
        android_clang_triple="aarch64-linux-android"
        ;;
    android-x86_64)
        os="android"
        arch="x86_64"
        openssl_target="android-x86_64"
        android_abi="x86_64"
        android_goarch="amd64"
        android_clang_triple="x86_64-linux-android"
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
    cat > "${manifest}" <<EOF
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
    "go": "${GO_VERSION}",
    "androidApi": "${ANDROID_API:-}",
    "androidNdk": "${ANDROID_NDK_VERSION:-}",
    "llvmMingw": "${LLVM_MINGW_VERSION:-}"
  }
}
EOF
}

package_target() {
    local package_name="partout-vendors-${target}.tar.zst"
    tar --zstd -cf "${artifacts_dir}/${package_name}" -C "${package_root}" .
    shasum -a 256 "${artifacts_dir}/${package_name}" > "${artifacts_dir}/${package_name}.sha256"
}

build_openssl
build_mbedtls
build_wg_go
write_manifest
package_target

