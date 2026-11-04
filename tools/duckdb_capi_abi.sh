# Select the DuckDB C extension ABI that configure and configure.win build for
# one exact DuckDB engine release. Sourced by both scripts; POSIX sh only.
#
# DuckDB 1.x engines: the exact-version unstable V1 struct. The footer records
# C_STRUCT_UNSTABLE and the engine version; the entrypoint is rducks_init_c_api.
#
# DuckDB 2.x and later engines: C_STRUCT_UNSTABLE now selects the separate V2 C
# API (duckdb_extension_v2.h, entrypoint rducks_init_c_api_v2). Rducks calls
# the V1 API, and every V1 entry outside the v1.2.0 surface that it calls was
# stabilized in C API v1.5.6. It therefore builds the stable V1 struct pinned to
# that version: the footer records C_STRUCT and v1.5.6, and the entrypoint
# stays rducks_init_c_api. The header compiles out entries newer than the pin,
# so calling one is a compile error rather than a load-time failure. Upstream
# rule: UsesCAPIV2() in DuckDB v2.0.0 src/main/extension/extension_load.cpp.
RDUCKS_V1_STABLE_CAPI_MAJOR=1
RDUCKS_V1_STABLE_CAPI_MINOR=5
RDUCKS_V1_STABLE_CAPI_PATCH=6

# Sets RDUCKS_CAPI_ABI_TYPE, RDUCKS_CAPI_FOOTER_VERSION and RDUCKS_CAPI_CPPFLAGS
# for the engine release given as vMAJOR.MINOR.PATCH.
rducks_select_duckdb_capi() {
  rducks_engine_version="$1"
  rducks_engine_major=`printf '%s\n' "${rducks_engine_version}" | sed -e 's/^v//' -e 's/\..*$//'`
  case "${rducks_engine_major}" in
    ''|*[!0-9]*)
      echo "ERROR: cannot read the major version of DuckDB '${rducks_engine_version}'"
      exit 1
      ;;
  esac
  if [ "${rducks_engine_major}" -lt 2 ]; then
    RDUCKS_CAPI_ABI_TYPE=C_STRUCT_UNSTABLE
    RDUCKS_CAPI_FOOTER_VERSION="${rducks_engine_version}"
    RDUCKS_CAPI_CPPFLAGS="-DDUCKDB_EXTENSION_API_VERSION_UNSTABLE=${rducks_engine_version} -DDUCKDB_EXTENSION_API_UNSTABLE_VERSION=\"${rducks_engine_version}\""
  else
    RDUCKS_CAPI_ABI_TYPE=C_STRUCT
    RDUCKS_CAPI_FOOTER_VERSION="v${RDUCKS_V1_STABLE_CAPI_MAJOR}.${RDUCKS_V1_STABLE_CAPI_MINOR}.${RDUCKS_V1_STABLE_CAPI_PATCH}"
    RDUCKS_CAPI_CPPFLAGS="-DDUCKDB_EXTENSION_API_VERSION_MAJOR=${RDUCKS_V1_STABLE_CAPI_MAJOR} -DDUCKDB_EXTENSION_API_VERSION_MINOR=${RDUCKS_V1_STABLE_CAPI_MINOR} -DDUCKDB_EXTENSION_API_VERSION_PATCH=${RDUCKS_V1_STABLE_CAPI_PATCH}"
  fi
}
