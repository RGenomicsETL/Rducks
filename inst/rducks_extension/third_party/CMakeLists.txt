cmake_minimum_required(VERSION 3.16)
project(rducks_third_party_nng C)

# Build NNG as a static, position-independent implementation detail of the
# Rducks DuckDB extension. Mbed TLS sources are vendored next to NNG for the
# planned TLS transport, but TLS stays outside the default worker endpoint set
# until certificate/client-config policy is explicit.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

set(RDUCKS_VENDOR_ROOT "${CMAKE_CURRENT_LIST_DIR}")

set(NNG_DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
set(NNG_TESTS OFF CACHE BOOL "" FORCE)
set(NNG_TOOLS OFF CACHE BOOL "" FORCE)
set(NNG_ENABLE_DOC OFF CACHE BOOL "" FORCE)
set(NNG_ENABLE_COVERAGE OFF CACHE BOOL "" FORCE)
set(NNG_ENABLE_HTTP ON CACHE BOOL "" FORCE)
set(NNG_ENABLE_TLS OFF CACHE BOOL "" FORCE)

# Enable every non-TLS NNG URL transport usable by the native worker provider.
# inproc/pair0 are used by the native self-test; req/rep is the chunk execution
# path; push/pull and pub/sub are reserved for broker/control paths.
set(NNG_TRANSPORT_INPROC ON CACHE BOOL "" FORCE)
set(NNG_TRANSPORT_IPC ON CACHE BOOL "" FORCE)
set(NNG_TRANSPORT_TCP ON CACHE BOOL "" FORCE)
set(NNG_TRANSPORT_TLS OFF CACHE BOOL "" FORCE)
set(NNG_TRANSPORT_WS ON CACHE BOOL "" FORCE)
set(NNG_TRANSPORT_WSS OFF CACHE BOOL "" FORCE)

set(NNG_PROTO_REQ0 ON CACHE BOOL "" FORCE)
set(NNG_PROTO_REP0 ON CACHE BOOL "" FORCE)
set(NNG_PROTO_PAIR0 ON CACHE BOOL "" FORCE)
set(NNG_PROTO_PAIR1 OFF CACHE BOOL "" FORCE)
set(NNG_PROTO_PUSH0 ON CACHE BOOL "" FORCE)
set(NNG_PROTO_PULL0 ON CACHE BOOL "" FORCE)
set(NNG_PROTO_PUB0 ON CACHE BOOL "" FORCE)
set(NNG_PROTO_SUB0 ON CACHE BOOL "" FORCE)
set(NNG_PROTO_BUS0 OFF CACHE BOOL "" FORCE)
set(NNG_PROTO_RESPONDENT0 OFF CACHE BOOL "" FORCE)
set(NNG_PROTO_SURVEYOR0 OFF CACHE BOOL "" FORCE)

add_subdirectory("${RDUCKS_VENDOR_ROOT}/nng" nng EXCLUDE_FROM_ALL)
