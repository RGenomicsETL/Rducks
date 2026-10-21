#!/bin/sh
# Install the reviewed duckdb-r guard patch into a separate R library.
set -eu

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 2 ]; then
  printf 'Usage: %s OUTPUT_LIBRARY EMPTY_BUILD_DIRECTORY\n' "$0" >&2
  exit 2
fi

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] ||
  fail 'This pinned binary recipe supports Linux amd64 only.'
for command in R Rscript curl unzip tar xz git sha256sum strings make; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing build dependency: $command"
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
patch_file="$script_dir/duckdb-r-off-main-guards-v1.5.6.patch"
mkdir -p -- "$1" "$2"
output_library=$(CDPATH= cd -- "$1" && pwd)
build_dir=$(CDPATH= cd -- "$2" && pwd)
case "$output_library$build_dir" in
  *[[:space:]]*) fail 'Use library and build paths without whitespace (upstream linker flags require this).' ;;
esac
[ "$output_library" != "$build_dir" ] || fail 'Library and build directories must differ.'
[ ! -e "$output_library/duckdb" ] && [ ! -L "$output_library/duckdb" ] ||
  fail 'The output library already contains duckdb; choose a separate library.'
[ ! -e "$output_library/00LOCK-duckdb" ] || fail 'The output library has a duckdb install lock.'
[ -z "$(ls -A -- "$build_dir")" ] || fail 'The build directory must be empty.'
Rscript --vanilla -e 'stopifnot(getRversion() >= "4.2.0", requireNamespace("DBI", quietly = TRUE))'

source_sha=92a9b45b2994568d8d3f0173ecc3a085698f1241177719b79d7e3b4bcca5b0c9
library_sha=b845005f5132a7d8180057c35e14a7626632258782f871a90861b19c1c03841b
patch_sha=2169fc562d0b48bf24f9c4da11c68288599da26319f9d6324d52552cfa9e6df9
printf '%s  %s\n' "$patch_sha" "$patch_file" | sha256sum --check --status ||
  fail 'Companion patch checksum does not match this installer.'

source_archive="$build_dir/duckdb_1.5.6.tar.gz"
library_archive="$build_dir/libduckdb-linux-amd64.zip"
printf '%s\n' 'Downloading pinned duckdb 1.5.6 source and official libduckdb.'
if ! curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
  https://cran.r-project.org/src/contrib/duckdb_1.5.6.tar.gz \
  --output "$source_archive"; then
  curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
    https://cran.r-project.org/src/contrib/Archive/duckdb/duckdb_1.5.6.tar.gz \
    --output "$source_archive"
fi
curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
  https://github.com/duckdb/duckdb/releases/download/v1.5.6/libduckdb-linux-amd64.zip \
  --output "$library_archive"
printf '%s  %s\n' "$source_sha" "$source_archive" "$library_sha" "$library_archive" |
  sha256sum --check || fail 'Downloaded archive checksum mismatch.'

tar --no-same-owner -xzf "$source_archive" -C "$build_dir"
mkdir -- "$build_dir/libduckdb"
unzip -q "$library_archive" libduckdb.so -d "$build_dir/libduckdb"
(
  cd -- "$build_dir/duckdb"
  # Do not discover an enclosing Rducks checkout when build_dir is inside it.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  export GIT_CEILING_DIRECTORIES="$build_dir"
  git apply --check "$patch_file"
  git apply "$patch_file"
)

printf 'Building patched R glue; log: %s/install.log\n' "$build_dir"
# The upstream configure script verifies the exact core commit before using
# the official library. Do not bypass that check or substitute other headers.
if ! (
  cd -- "$build_dir/duckdb"
  TAR_OPTIONS=--no-same-owner \
    DUCKDB_R_USE_SYSTEM_LIB=1 \
    DUCKDB_R_LIB_DIR="$build_dir/libduckdb" \
    MAKEFLAGS="${MAKEFLAGS:--j2}" \
    R CMD INSTALL --library="$output_library" --no-byte-compile .
) > "$build_dir/install.log" 2>&1; then
  cat "$build_dir/install.log" >&2
  fail 'Patched duckdb installation failed; source and log were retained.'
fi

# Verify the actual C-callable contract, rather than inferring capability from
# the package version. A database startup registers the capability.
cat > "$build_dir/guard_probe.c" <<'C'
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <stdint.h>
SEXP rducks_guard_probe_version(void) {
    typedef uint32_t (*version_fn)(void);
    version_fn version = (version_fn) R_GetCCallable("duckdb", "duckdb_r_off_main_guard_version");
    return Rf_ScalarInteger((int) version());
}
SEXP rducks_guard_probe_lease(void) {
    typedef uint64_t (*reserve_fn)(void);
    typedef int (*lease_fn)(uint64_t);
    reserve_fn reserve = (reserve_fn) R_GetCCallable("duckdb", "duckdb_r_managed_stream_guard_reserve");
    lease_fn validate = (lease_fn) R_GetCCallable("duckdb", "duckdb_r_managed_stream_guard_validate");
    lease_fn release = (lease_fn) R_GetCCallable("duckdb", "duckdb_r_managed_stream_guard_release");
    uint64_t id = reserve();
    int ok = id != 0 && validate(id) == 0;
    if (id) ok = release(id) == 1 && validate(id) == 0 && ok;
    return Rf_ScalarLogical(ok);
}
C
if ! R CMD SHLIB -o "$build_dir/guard_probe.so" "$build_dir/guard_probe.c" \
  > "$build_dir/guard-probe.log" 2>&1; then
  cat "$build_dir/guard-probe.log" >&2
  fail 'Capability probe compilation failed.'
fi
Rscript --vanilla - "$output_library" "$build_dir" <<'R'
args <- commandArgs(trailingOnly = TRUE)
.libPaths(c(args[[1L]], .libPaths()))
stopifnot(normalizePath(find.package("duckdb")) == normalizePath(file.path(args[[1L]], "duckdb")))
local({
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  stopifnot(DBI::dbGetQuery(con, "SELECT version() AS version")$version == "v1.5.6")
  stopifnot(DBI::dbGetQuery(con, "SELECT 42::INTEGER AS answer")$answer == 42L)
  dyn.load(file.path(args[[2L]], "guard_probe.so"))
  stopifnot(.Call("rducks_guard_probe_version") == 2L)
  stopifnot(.Call("rducks_guard_probe_lease"))
})
R
printf 'Guarded duckdb installed in %s\n' "$output_library"
printf 'Keep %s/libduckdb: the installed R package links to that directory.\n' "$build_dir"
printf '%s\n' 'Use a fresh R process with this library first; the ordinary duckdb installation was not changed.'
