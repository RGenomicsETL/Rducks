#!/usr/bin/env bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PORT=${PORT:-8000}
HOST=${HOST:-127.0.0.1}
WEBR_IMAGE=${WEBR_IMAGE:-ghcr.io/r-wasm/webr:main}
ARTIFACT_ROOT=${ARTIFACT_ROOT:-${ROOT_DIR}/.webr-local-artifacts}

mkdir -p "${ARTIFACT_ROOT}"

echo "Building Rducks webR artifact with ${WEBR_IMAGE}..."
docker run --rm -v "${ROOT_DIR}:/work/Rducks" -w /work/Rducks "${WEBR_IMAGE}" bash -lc '
set -eu
rm -rf Rducks.Rcheck ..Rcheck README.html inst/rducks_extension/build
R CMD build --no-build-vignettes .
Rscript -e "if (!requireNamespace(\"pak\", quietly = TRUE)) install.packages(\"pak\", repos = \"https://repo.r-wasm.org/\")"
Rscript -e "pak::pak(\"r-wasm/rwasm\", ask = FALSE)"
Rscript -e "version <- read.dcf(\"DESCRIPTION\")[1, \"Version\"]; rwasm::build(sprintf(\"./Rducks_%s.tar.gz\", version))"
'

VERSION=$(Rscript -e 'cat(read.dcf("DESCRIPTION")[1, "Version"])')
TGZ_SOURCE="${ROOT_DIR}/Rducks_${VERSION}.tgz"
TGZ_PATH="${ARTIFACT_ROOT}/Rducks_${VERSION}.tgz"
REPO_ROOT="${ARTIFACT_ROOT}/repo"
SITE_ROOT="${ARTIFACT_ROOT}/site"
WEBR_R_SERIES=$(
  docker run --rm "${WEBR_IMAGE}" bash -lc \
    "Rscript -e 'cat(paste(R.version\$major, sub(\"\\\\..*$\", \"\", R.version\$minor), sep = \".\"))'"
)
LOCAL_REPO_DIR="${REPO_ROOT}/src/contrib"
BINARY_REPO_DIR="${REPO_ROOT}/bin/emscripten/contrib/${WEBR_R_SERIES}"

if [ ! -f "${TGZ_SOURCE}" ]; then
  echo "Expected wasm package artifact not found: ${TGZ_SOURCE}" >&2
  exit 1
fi

rm -rf "${REPO_ROOT}" "${SITE_ROOT}"
mkdir -p "${LOCAL_REPO_DIR}" "${BINARY_REPO_DIR}" "${SITE_ROOT}/r/Rducks" "${SITE_ROOT}/scripts"
cp -f "${TGZ_SOURCE}" "${TGZ_PATH}"
cp -f "${TGZ_PATH}" "${LOCAL_REPO_DIR}/"
cp -f "${TGZ_PATH}" "${BINARY_REPO_DIR}/"
cp -f "${ROOT_DIR}/DESCRIPTION" "${SITE_ROOT}/r/Rducks/DESCRIPTION"
cp -f "${ROOT_DIR}/scripts/webr-local-test.html" "${SITE_ROOT}/scripts/webr-local-test.html"

RDUCKS_VERSION="${VERSION}" RDUCKS_REPO_ROOT="${REPO_ROOT}" RDUCKS_WEBR_R_SERIES="${WEBR_R_SERIES}" Rscript - <<'RS'
desc <- read.dcf('DESCRIPTION')
fields <- as.list(desc[1, , drop = TRUE])
fields$File <- sprintf('Rducks_%s.tgz', Sys.getenv('RDUCKS_VERSION'))
db <- as.data.frame(fields, stringsAsFactors = FALSE, check.names = FALSE)
mat <- as.matrix(db)
rownames(mat) <- mat[, 'Package']
write_index <- function(repo) {
  dir.create(repo, recursive = TRUE, showWarnings = FALSE)
  write.dcf(db, file = file.path(repo, 'PACKAGES'))
  con <- gzfile(file.path(repo, 'PACKAGES.gz'), 'wb')
  writeLines(readLines(file.path(repo, 'PACKAGES')), con)
  close(con)
  saveRDS(mat, file.path(repo, 'PACKAGES.rds'))
}
root <- Sys.getenv('RDUCKS_REPO_ROOT')
series <- Sys.getenv('RDUCKS_WEBR_R_SERIES')
write_index(file.path(root, 'src/contrib'))
write_index(file.path(root, 'bin/emscripten/contrib', series))
RS

cp -a "${REPO_ROOT}" "${SITE_ROOT}/r/Rducks/webr-repo"

cat <<EOF
Built: ${TGZ_PATH}
Open:  http://${HOST}:${PORT}/scripts/webr-local-test.html
Repo:  /r/Rducks/webr-repo
EOF

cd "${SITE_ROOT}"
exec python3 -m http.server "${PORT}" --bind "${HOST}"
