set(MBEDTLS_DIR "${PPV_OUTPUT}/mbedtls")
set(MBEDTLS_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls")
set(MBEDTLS_PYTHON_VENV "${PPV_OUTPUT}/mbedtls-python")
if(WIN32)
    set(MBEDTLS_PYTHON "${MBEDTLS_PYTHON_VENV}/Scripts/python.exe")
else()
    set(MBEDTLS_PYTHON "${MBEDTLS_PYTHON_VENV}/bin/python")
endif()

set(MBEDTLS_REQUIREMENTS
    "${MBEDTLS_SOURCE_DIR}/scripts/basic.requirements.txt"
    "${MBEDTLS_SOURCE_DIR}/tf-psa-crypto/scripts/basic.requirements.txt"
)
set(MBEDTLS_REQUIREMENTS_DEPENDS
    ${MBEDTLS_REQUIREMENTS}
    "${MBEDTLS_SOURCE_DIR}/scripts/driver.requirements.txt"
    "${MBEDTLS_SOURCE_DIR}/tf-psa-crypto/scripts/driver.requirements.txt"
)
set(MBEDTLS_PYTHON_STAMP "${MBEDTLS_PYTHON_VENV}/.requirements.stamp")

find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_custom_command(
    OUTPUT "${MBEDTLS_PYTHON_STAMP}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${PPV_OUTPUT}"
    COMMAND "${Python3_EXECUTABLE}" -m venv "${MBEDTLS_PYTHON_VENV}"
    COMMAND "${MBEDTLS_PYTHON}" -m pip install --disable-pip-version-check
        -r "${MBEDTLS_SOURCE_DIR}/scripts/basic.requirements.txt"
        -r "${MBEDTLS_SOURCE_DIR}/tf-psa-crypto/scripts/basic.requirements.txt"
    COMMAND "${CMAKE_COMMAND}" -E touch "${MBEDTLS_PYTHON_STAMP}"
    DEPENDS ${MBEDTLS_REQUIREMENTS_DEPENDS}
    VERBATIM
)
add_custom_target(MbedTLSPython DEPENDS "${MBEDTLS_PYTHON_STAMP}")

set(MBEDTLS_CMAKE_ARGS
    "-DCMAKE_INSTALL_PREFIX=${MBEDTLS_DIR}"
    "-DPython3_EXECUTABLE=${MBEDTLS_PYTHON}"
    -DGEN_FILES=ON
    -DENABLE_PROGRAMS=OFF
    -DENABLE_TESTING=OFF
)
if(CMAKE_BUILD_TYPE)
    list(APPEND MBEDTLS_CMAKE_ARGS "-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}")
endif()
if(CMAKE_TOOLCHAIN_FILE)
    list(APPEND MBEDTLS_CMAKE_ARGS "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}")
endif()
if(WIN32 OR APPLE)
    list(APPEND MBEDTLS_CMAKE_ARGS
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
        -DUSE_STATIC_MBEDTLS_LIBRARY=ON
    )
endif()

if(WIN32)
    list(APPEND MBEDTLS_CMAKE_ARGS
        -DCMAKE_POLICY_DEFAULT_CMP0091=NEW
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=${CMAKE_MSVC_RUNTIME_LIBRARY}"
    )
    set(MBEDTLS_NORMALIZE_CRYPTO_LIBRARY_SCRIPT
        "${CMAKE_CURRENT_BINARY_DIR}/vendors/mbedtls-normalize-crypto.cmake")
    file(WRITE "${MBEDTLS_NORMALIZE_CRYPTO_LIBRARY_SCRIPT}" [=[
set(mbedcrypto_lib "${MBEDTLS_DIR}/lib/mbedcrypto.lib")
set(mbedcrypto_archive "${MBEDTLS_DIR}/lib/libmbedcrypto.a")
if(NOT EXISTS "${mbedcrypto_lib}" AND EXISTS "${mbedcrypto_archive}")
    file(COPY_FILE "${mbedcrypto_archive}" "${mbedcrypto_lib}" ONLY_IF_DIFFERENT)
endif()
]=])
    set(MBEDTLS_INSTALL_COMMAND
        INSTALL_COMMAND "${CMAKE_COMMAND}" --build <BINARY_DIR> --target install ${PPV_CONFIG_ARGS}
        COMMAND "${CMAKE_COMMAND}" "-DMBEDTLS_DIR=${MBEDTLS_DIR}"
            -P "${MBEDTLS_NORMALIZE_CRYPTO_LIBRARY_SCRIPT}"
    )
elseif(ANDROID)
    list(APPEND MBEDTLS_CMAKE_ARGS
        "-DCMAKE_ANDROID_NDK=${CMAKE_ANDROID_NDK}"
        "-DANDROID_ABI=${ANDROID_ABI}"
        "-DANDROID_PLATFORM=${ANDROID_PLATFORM}"
        "-DANDROID_STL=${ANDROID_STL}"
    )
endif()

ExternalProject_Add(MbedTLSProject
    SOURCE_DIR "${MBEDTLS_SOURCE_DIR}"
    DEPENDS MbedTLSPython
    CMAKE_ARGS ${MBEDTLS_CMAKE_ARGS}
    ${MBEDTLS_INSTALL_COMMAND}
)
