#!/usr/bin/env bash
# 28_grassius_source — refresh the decorate-stage grassius.tsv from the GRASSIUS
# source (grassius.org), mapped to THIS build's gene IDs via synonyms.
#
# IMPORTANT, by design:
#   * This does NOT run in `make all`. Direct Grassius is already applied from the
#     committed grassius.tsv, and the grassius.org download currently has LESS
#     sorghum coverage than the curated file — so we MERGE (curated wins, source
#     only adds genes the curated file lacks), we never replace/regress.
#   * It only regenerates the input file. To take effect you must re-decorate and
#     rebuild solr:  make refresh-grassius
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 28_grassius_source

assert_mongo_min genes 1000
SEARCH="${MONGODB_REPO}/search"
GT="${SEARCH}/grassius.tsv"

log "fetching Grassius source families and mapping to ${MONGO_DB} gene IDs"
MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" \
  "${NODE_BIN}" "${BUILD_DIR}/fetch_grassius.js" ${GRASSIUS_SPECIES:-} > "${SEARCH}/grassius.fromsource.tsv"
src_rows=$(wc -l < "${SEARCH}/grassius.fromsource.tsv")
[ "${src_rows}" -gt 0 ] || die "fetch_grassius produced no rows"
ok "grassius source rows mapped: ${src_rows}"

# merge: keep every curated row; append source rows for gene IDs not already present
if [ -s "${GT}" ]; then
  before=$(wc -l < "${GT}")
  cp -p "${GT}" "${GT}.curated.bak"                 # back up curated file
  # print all curated rows, then source rows whose gene id (col 1) isn't already present
  awk -F'\t' 'FNR==NR{seen[$1]=1; print; next} !($1 in seen)' \
      "${GT}.curated.bak" "${SEARCH}/grassius.fromsource.tsv" > "${GT}.merged"
  after=$(wc -l < "${GT}.merged")
  mv "${GT}.merged" "${GT}"
  ok "grassius.tsv merged: ${before} curated -> ${after} rows (+$((after-before)) from source)"
else
  cp "${SEARCH}/grassius.fromsource.tsv" "${GT}"
  warn "no curated grassius.tsv existed — using source-only (${src_rows} rows)"
fi
log "grassius.tsv refreshed. Run 'make refresh-grassius' to re-decorate + rebuild solr so it takes effect."
stage_end
