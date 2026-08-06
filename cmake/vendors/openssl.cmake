set(OPENSSL_DIR "${PPV_OUTPUT}/openssl")
set(OPENSSL_TARGET "" CACHE STRING "Override the OpenSSL Configure target")
set(OPENSSL_PLATFORM_ARGS "" CACHE STRING "Additional OpenSSL Configure arguments")

if(NOT OPENSSL_TARGET)
    if(WIN32)
        if(PPV_ARCH MATCHES "^(arm64|aarch64)$")
            set(OPENSSL_TARGET VC-WIN64-ARM)
        else()
            set(OPENSSL_TARGET VC-WIN64A)
        endif()
    elseif(ANDROID)
        set(OPENSSL_TARGET android-arm64)
    elseif(APPLE)
        if(NOT CMAKE_OSX_SYSROOT OR NOT CMAKE_C_COMPILER_TARGET)
            message(FATAL_ERROR
                "Apple OpenSSL builds require CMAKE_OSX_SYSROOT and CMAKE_C_COMPILER_TARGET")
        endif()
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            if(CMAKE_C_COMPILER_TARGET MATCHES "-simulator$")
                set(OPENSSL_TARGET "iossimulator-${PPV_ARCH}-xcrun")
            elseif(PPV_ARCH MATCHES "^(arm64|aarch64)$")
                set(OPENSSL_TARGET ios64-xcrun)
            else()
                message(FATAL_ERROR "Unsupported OpenSSL iOS device architecture: ${PPV_ARCH}")
            endif()
        elseif(CMAKE_SYSTEM_NAME MATCHES "^(Darwin|tvOS)$")
            set(OPENSSL_TARGET "darwin64-${PPV_ARCH}")
        else()
            message(FATAL_ERROR "Unsupported OpenSSL Apple system: ${CMAKE_SYSTEM_NAME}")
        endif()
    endif()
endif()

set(OPENSSL_ENV ${VENDOR_ENV})
if(ANDROID)
    list(APPEND OPENSSL_ENV "ANDROID_NDK_ROOT=${CMAKE_ANDROID_NDK}")
elseif(APPLE)
    set(OPENSSL_ENV
        "${CMAKE_COMMAND}" -E env
        "CFLAGS=-isysroot ${CMAKE_OSX_SYSROOT} -target ${CMAKE_C_COMPILER_TARGET}"
        "LDFLAGS=-isysroot ${CMAKE_OSX_SYSROOT} -target ${CMAKE_C_COMPILER_TARGET}"
    )
endif()

set(OPENSSL_CONFIGURE_ARGS
    ${OPENSSL_TARGET}
    ${OPENSSL_PLATFORM_ARGS}
    "--prefix=${OPENSSL_DIR}"
    "--openssldir=${OPENSSL_DIR}"
    --libdir=lib
    no-apps
    no-docs
    no-dsa
    no-engine
    no-gost
    no-legacy
    no-ssl
    no-tests
    no-zlib
)
if(APPLE)
    list(APPEND OPENSSL_CONFIGURE_ARGS no-shared)
    if(CMAKE_SYSTEM_NAME STREQUAL "tvOS")
        list(APPEND OPENSSL_CONFIGURE_ARGS -DHAVE_FORK=0 no-async)
    endif()
else()
    list(APPEND OPENSSL_CONFIGURE_ARGS shared)
endif()

set(OPENSSL_BUILD_COMMAND ${OPENSSL_ENV} ${PPV_MAKE})
if(NOT WIN32)
    include(ProcessorCount)
    ProcessorCount(OPENSSL_BUILD_JOBS)
    if(OPENSSL_BUILD_JOBS)
        list(APPEND OPENSSL_BUILD_COMMAND "-j${OPENSSL_BUILD_JOBS}")
    endif()
endif()

set(OPENSSL_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendors/openssl")
set(OPENSSL_BUILD_SOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/vendors/openssl-src")
ExternalProject_Add(OpenSSLProject
    SOURCE_DIR "${OPENSSL_BUILD_SOURCE_DIR}"
    DOWNLOAD_COMMAND
        "${CMAKE_COMMAND}" -E rm -rf "${OPENSSL_BUILD_SOURCE_DIR}"
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${OPENSSL_SOURCE_DIR}" "${OPENSSL_BUILD_SOURCE_DIR}"
    CONFIGURE_COMMAND ${OPENSSL_ENV} perl "${OPENSSL_BUILD_SOURCE_DIR}/Configure" ${OPENSSL_CONFIGURE_ARGS}
    BUILD_COMMAND ${OPENSSL_BUILD_COMMAND}
    INSTALL_COMMAND ${OPENSSL_ENV} ${PPV_MAKE} install_sw
    BUILD_IN_SOURCE 1
)
