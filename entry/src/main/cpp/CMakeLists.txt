# minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(hish)
set(PROJECT_LANGUAGE C)
if(DEFINED CMAKE_CXX_COMPILER)
  set(CMAKE_CXX_STANDARD 17)
  list(APPEND PROJECT_LANGUAGES CXX)
endif(DEFINED CMAKE_CXX_COMPILER)

project(HiSH VERSION 1.0.0 LANGUAGES ${PROJECT_LANGUAGES})
include(CheckFunctionExists)
include(CheckSymbolExists)
include(CheckIncludeFile)
include(CheckTypeSize)
include(TestBigEndian)
include(CheckCSourceCompiles)
include(CheckCSourceRuns)
include(GNUInstallDirs)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# Local AI runtime: embed only llama.cpp's portable CPU backend.  The app's
# native entry remains a shared library; llama/ggml are linked into it as
# position-independent static libraries.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build native dependencies statically" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_UI OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU ON CACHE BOOL "" FORCE)
set(GGML_CPU_REPACK OFF CACHE BOOL "" FORCE)
set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_HIP OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_RPC OFF CACHE BOOL "" FORCE)
set(GGML_SYCL OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

add_subdirectory(
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp
    ${CMAKE_CURRENT_BINARY_DIR}/llama.cpp
    EXCLUDE_FROM_ALL
)

# DevEco's HarmonyOS Ninja pipeline does not emit a usable PCH dependency when
# llama's forced Unity build is enabled. Disable these compile-time-only
# optimizations on this target; no llama.cpp source or runtime behavior changes.
set_target_properties(llama PROPERTIES
    UNITY_BUILD OFF
    DISABLE_PRECOMPILE_HEADERS ON
)

# DevEco debug builds add -O0 globally. That makes ggml's quantized CPU kernels
# unusably slow on-device even though the ARM64/NEON backend is selected. Keep
# app debug symbols, but compile the pinned inference engine with optimized
# machine code in every configuration. These options are intentionally scoped
# to llama.cpp/ggml and do not change the rest of HiSH.
foreach(LOCAL_AI_OPTIMIZED_TARGET llama ggml ggml-base ggml-cpu)
    if(TARGET ${LOCAL_AI_OPTIMIZED_TARGET})
        target_compile_options(${LOCAL_AI_OPTIMIZED_TARGET} PRIVATE -O3)
    endif()
endforeach()

# The OHOS clang target defines __linux__, while the HarmonyOS musl NDK does
# not expose glibc's cpu_set_t / pthread_setaffinity_np API. Make only the C
# thread-pool source select ggml's existing portable no-affinity branch.
if(OHOS OR CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    set_property(
        SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c
        TARGET_DIRECTORY ggml-cpu
        APPEND PROPERTY COMPILE_OPTIONS -U__linux__
    )
endif()

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

# libvncclient paths
set(COMMON_DIR ${CMAKE_CURRENT_SOURCE_DIR}/libvncserver/src/common)
set(LIBVNCCLIENT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/libvncserver/src/libvncclient)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CMAKE_CURRENT_SOURCE_DIR}/libvncserver/cmake/Modules/")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Headers needed for check_type_size()
check_include_file("vfork.h"       LIBVNCSERVER_HAVE_VFORK_H)
check_include_file("ws2tcpip.h"    LIBVNCSERVER_HAVE_WS2TCPIP_H)
check_include_file("arpa/inet.h"   HAVE_ARPA_INET_H)
check_include_file("stdint.h"      HAVE_STDINT_H)
check_include_file("stddef.h"      HAVE_STDDEF_H)
check_include_file("sys/types.h"   HAVE_SYS_TYPES_H)
check_include_file("sys/time.h"    LIBVNCSERVER_HAVE_SYS_TIME_H)
check_include_file("sys/socket.h"  LIBVNCSERVER_HAVE_SYS_SOCKET_H)
check_include_file("netinet/in.h"  LIBVNCSERVER_HAVE_NETINET_IN_H)

if(HAVE_ARPA_INET_H)
  list(APPEND CMAKE_EXTRA_INCLUDE_FILES "arpa/inet.h")
endif()

check_function_exists(vfork           LIBVNCSERVER_HAVE_VFORK)

# Crypto - use builtin only (simplest for HarmonyOS)
set(CRYPTO_SOURCES ${COMMON_DIR}/crypto_included.c ${COMMON_DIR}/sha1.c ${COMMON_DIR}/d3des.c)

# zlib - required for zlib/tight/zrle encodings
find_package(ZLIB)
if(ZLIB_FOUND)
    message(STATUS "zlib found: ${ZLIB_LIBRARIES}")
    set(LIBVNCSERVER_HAVE_LIBZ 1)
else()
    message(WARNING "zlib not found — zlib/tight/zrle encodings will be unavailable")
endif()

check_type_size(pid_t     LIBVNCSERVER_PID_T)
check_type_size(size_t    LIBVNCSERVER_SIZE_T)
check_type_size(socklen_t LIBVNCSERVER_SOCKLEN_T)
check_type_size(in_addr_t LIBVNCSERVER_IN_ADDR_T)

# Generate rfbconfig.h
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/libvncserver/include/rfb/rfbconfig.h.cmakein
               ${CMAKE_CURRENT_BINARY_DIR}/include/rfb/rfbconfig.h)

# Configure libvncclient
set(LIBVNCCLIENT_SOURCES
    ${LIBVNCCLIENT_DIR}/cursor.c
    ${LIBVNCCLIENT_DIR}/listen.c
    ${LIBVNCCLIENT_DIR}/rfbclient.c
    ${LIBVNCCLIENT_DIR}/sockets.c
    ${LIBVNCCLIENT_DIR}/vncviewer.c
    ${COMMON_DIR}/sockets.c
    ${CRYPTO_SOURCES}
)

# Use TLS_none (no TLS support for simplicity)
set(LIBVNCCLIENT_SOURCES
    ${LIBVNCCLIENT_SOURCES}
    ${LIBVNCCLIENT_DIR}/tls_none.c
)

# Use minilzo (no LZO dependency)
set(LIBVNCCLIENT_SOURCES
    ${LIBVNCCLIENT_SOURCES}
    ${COMMON_DIR}/minilzo.c
)

# Include directories
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
    ${NATIVERENDER_ROOT_PATH}/libvncserver/include
    ${NATIVERENDER_ROOT_PATH}/libvncserver/src/common
    ${NATIVERENDER_ROOT_PATH}/third_party/llama.cpp/vendor/hash/sha256
    ${NATIVERENDER_ROOT_PATH}/third_party/llama.cpp/vendor/hash
    ${LIBVNCCLIENT_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}/include
)

# HiSH sources
add_library(entry SHARED
    napi_init.cpp
    napi_local_inference.cpp
    napi_vnc.cpp
    local_inference_runtime.cpp
    local_model_installer.cpp
    third_party/llama.cpp/vendor/hash/sha256/sha256.c
    vnc_client.cpp
    vnc_renderer.cpp
    utils.cpp
    ${LIBVNCCLIENT_SOURCES}
)

target_link_libraries(entry PUBLIC
    llama
    libace_napi.z.so
    librawfile.z.so
    libhilog_ndk.z.so
    libEGL.so
    libGLESv3.so
    libnative_window.so
    ${ZLIB_LIBRARIES}
)

# Add zlib include if found
if(ZLIB_FOUND)
    include_directories(${ZLIB_INCLUDE_DIRS})
    target_compile_definitions(entry PRIVATE LIBVNCSERVER_HAVE_LIBZ)
endif()
