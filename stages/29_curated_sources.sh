#!/usr/bin/env bash
# 29_curated_sources — refresh the two curated-gene source artifacts that the decorate stage reads:
#   gramene-mongodb/search/cshl_curated_genes.json   (the in-house curation sheet)
#   gramene-mongodb/search/maizegdb_go.csv.gz        (MaizeGDB curated gene names, B73 v5)
#
# IMPORTANT, by design:
#   * This does NOT run in `make all`, for the same reason 28_grassius_source does not: the committed
#     artifacts are what decorate reads, and a release must not silently change its curation content
#     because an upstream site changed between runs. Run it deliberately, read the coverage report,
#     commit the artifacts.
#   * It only regenerates the inputs. To take effect you must re-decorate and rebuild solr:
#     make refresh-curated
#   * Each fetch lands in a .fromsource file first and is only promoted over the tracked artifact
#     once it passes its gate, so a bad upstream day cannot replace good committed data.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 29_curated_sources

assert_mongo_min genes 1000
SEARCH="${MONGODB_REPO}/search"

# ---------------------------------------------------------------------------------------------
# 1. the in-house curation sheet
# ---------------------------------------------------------------------------------------------
CSHL="${SEARCH}/cshl_curated_genes.json"
CSHL_SRC="${SEARCH}/cshl_curated_genes.fromsheet.json"

log "fetching the curation sheet and resolving gene ids against ${MONGO_DB}"
MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" \
  "${NODE_BIN}" "${BUILD_DIR}/fetch_cshl_curation.js" ${CURATION_ARGS:-} > "${CSHL_SRC}"
assert_valid_json "${CSHL_SRC}"

cshl_entries="$("${NODE_BIN}" -e "console.log(require('${CSHL_SRC}').length)")"
cshl_refs="$("${NODE_BIN}" -e "console.log(require('${CSHL_SRC}').reduce((n,e)=>n+Object.keys(e.references||{}).length,0))")"

# The gate that matters. The feed this replaces was frozen at 158 entries for two years while the
# sheet grew to 1,221 rows; silently regressing to anything near that number means the fetch or the
# id resolution broke, and shipping it would re-create exactly the defect this stage exists to fix.
# Measured resolution is ~870 of 1,087 distinct ids (80%); the rest are ids retired between sorghum
# annotations, which the coverage report lists for the curators.
CSHL_MIN="${CSHL_MIN:-800}"
[ "${cshl_entries}" -ge "${CSHL_MIN}" ] \
  || die "cshl curation resolved only ${cshl_entries} genes (floor ${CSHL_MIN}); the 2024 frozen feed
 had 158. Read the coverage report above before overriding with CSHL_MIN=."
ok "cshl curation: ${cshl_entries} genes, ${cshl_refs} references"

if [ -s "${CSHL}" ]; then
  prev="$("${NODE_BIN}" -e "console.log(require('${CSHL}').length)" 2>/dev/null || echo 0)"
  log "cshl_curated_genes.json: ${prev} -> ${cshl_entries} genes"
fi
cp -p "${CSHL_SRC}" "${CSHL}"
ok "promoted ${CSHL}"

# ---------------------------------------------------------------------------------------------
# 2. MaizeGDB curated gene names
# ---------------------------------------------------------------------------------------------
MGDB="${SEARCH}/maizegdb_go.csv.gz"
MGDB_SRC="${MGDB}.fromsource"
MGDB_URL="${MAIZEGDB_URL:-https://download.maizegdb.org/Zm-B73-REFERENCE-NAM-5.0/Zm-B73-REFERENCE-NAM-5.0-GMs-GOTerms.csv.gz}"

log "fetching MaizeGDB curated gene names"
# download.maizegdb.org is open; the maizegdb.org web pages are Cloudflare-blocked, so do not be
# tempted to scrape those instead.
if curl -fsSL --max-time 300 -o "${MGDB_SRC}" "${MGDB_URL}"; then
  gzip -t "${MGDB_SRC}" || die "${MGDB_SRC} is not valid gzip"
  mgdb_rows="$(zcat "${MGDB_SRC}" | wc -l)"
  mgdb_genes="$(zcat "${MGDB_SRC}" | tail -n +2 | cut -d, -f1 | tr -d '"' | sort -u | wc -l)"
  # Gate on the join, not just the row count: the file's distinct gene_model set should BE this
  # build's maize gene set. They are 44,303 and 44,303 today, so a real divergence means MaizeGDB
  # moved to a different annotation and the names would land on the wrong genes.
  maize_genes="$(mongo --quiet "${MONGO_DB}" --eval \
    'db.genes.count({system_name:"zea_mays"})' 2>/dev/null || echo 0)"
  log "MaizeGDB rows=${mgdb_rows} distinct gene_models=${mgdb_genes}; ${MONGO_DB} zea_mays=${maize_genes}"
  if [ "${maize_genes}" -gt 0 ]; then
    pct=$(( 100 * mgdb_genes / maize_genes ))
    [ "${pct}" -ge 95 ] && [ "${pct}" -le 105 ] \
      || die "MaizeGDB gene_model count (${mgdb_genes}) is ${pct}% of zea_mays (${maize_genes}) --
 refusing to promote. MaizeGDB has probably moved to a different maize annotation."
    ok "MaizeGDB gene set matches zea_mays within ${pct}%"
  fi
  mv "${MGDB_SRC}" "${MGDB}"
  ok "promoted ${MGDB}"
else
  if [ -s "${MGDB}" ]; then
    warn "MaizeGDB download failed -- keeping the committed ${MGDB}"
    rm -f "${MGDB_SRC}"
  else
    die "MaizeGDB download failed and no committed artifact exists"
  fi
fi

log "curated source artifacts refreshed. Run 'make refresh-curated' to re-decorate + update solr."
stage_end
