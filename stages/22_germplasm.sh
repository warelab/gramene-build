#!/usr/bin/env bash
# 22_germplasm — populate the germplasm collection (Germplasm-tab data: accession
# -> seed-repository metadata). This is externally CURATED data with no build
# script in any of the 5 repos, so by default we carry it forward from the
# previous release (the accessions don't change release-to-release).
#
# To load a freshly curated germplasm set instead, point GERMPLASM_SRC at a JSON
# file (mongoexport format) or set GERMPLASM_SRC_DB to a different source db.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 22_germplasm

mongo_drop germplasm
if [ -n "${GERMPLASM_SRC:-}" ]; then
  log "loading germplasm from file ${GERMPLASM_SRC}"
  mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c germplasm < "${GERMPLASM_SRC}"
else
  SRCDB="${GERMPLASM_SRC_DB:-${PREV_DB}}"
  log "carrying germplasm forward from ${SRCDB}"
  mongoexport --quiet -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${SRCDB}" -c germplasm 2>/dev/null \
    | mongoimport --quiet -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c germplasm 2>/dev/null
fi

assert_mongo_min germplasm 1
log "germplasm docs: $(mongo_count germplasm)"
stage_end
