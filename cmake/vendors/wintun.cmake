set(WINTUN_VERSION 0.14.1)
set(WINTUN_DIR "${PPV_OUTPUT}/wintun")

FetchContent_Declare(wintun
    URL "https://www.wintun.net/builds/wintun-${WINTUN_VERSION}.zip"
)
FetchContent_MakeAvailable(wintun)
file(COPY
    "${wintun_SOURCE_DIR}/include/wintun.h"
    "${wintun_SOURCE_DIR}/bin/${PPV_ARCH}/wintun.dll"
    DESTINATION "${WINTUN_DIR}"
)
add_custom_target(WintunProject DEPENDS
    "${WINTUN_DIR}/wintun.h"
    "${WINTUN_DIR}/wintun.dll"
)
