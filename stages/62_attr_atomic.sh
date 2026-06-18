#!/usr/bin/env bash
# 62_attr_atomic <attr> — patch ONE post-dump attribute layer into the genes core via
# Solr ATOMIC updates (no drop / no downtime), then PARTIALLY rebuild any suggestion
# category that layer feeds. Generic over the attribute type:
#
#   attr ∈ { maker | vep | grassius | expression }
#
# All four are add_attributes.pl tables (id + capabilities + *_attr_[sif]s? columns),
# so the same converter (attr_table_to_atomic.js) + loader (solr_atomic_attr.js) apply.
# This is the lightweight alternative to `make refresh-attributes`, which regenerates
# the merged solr_genes.attribs.json and RELOADS all 5.2M docs (dropping the core).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
ATTR="${1:-}"
case "${ATTR}" in maker|vep|grassius|grassius_homolog|expression|expression_attributes) : ;;
  *) die "usage: 62_attr_atomic.sh <maker|vep|grassius|expression>";; esac
stage_begin "62_attr_atomic_${ATTR}"

# atomic updates only patch EXISTING docs — the genes core must be fully loaded.
gdocs="$(solr_numdocs "${SOLR_GENES_CORE}")"; want="$(mongo_count genes)"
[ "${gdocs:-0}" = "${want}" ] || die "${SOLR_GENES_CORE} has ${gdocs}/${want} docs — load the genes core fully (make 60_solr_genes) before an atomic attribute update"

GENES="${SOLR_REPO}/genes"; cd "${GENES}"
GENES_URL="${SOLR_URL}/${SOLR_GENES_CORE}"
TABLE="attr_${ATTR}.tsv"
SUGG_CAT=""; SUGG_DELQ=""; SUGG_FILE=""

# ── produce the attribute table (static file or freshly generated) ────────────
case "${ATTR}" in
  maker)
    [ -s "${MAKER_TABLE}" ] || die "MAKER table missing: ${MAKER_TABLE}"
    cp -f "${MAKER_TABLE}" "${TABLE}" ;;
  vep)
    [ -s "${VEP_TABLE}" ] || die "VEP table missing: ${VEP_TABLE}"
    cp -f "${VEP_TABLE}" "${TABLE}" ;;
  grassius|grassius_homolog)
    log "generating grassius_homolog table from gene trees"
    "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" "${BUILD_DIR}/grassius_homolog_table.js" > "${TABLE}"
    SUGG_CAT="tf"; SUGG_DELQ='id:GrassiusTF*'; SUGG_FILE="TF.json" ;;
  expression|expression_attributes)
    "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval 'db.expression_attributes.countDocuments({})>0?quit(0):quit(1)' >/dev/null 2>&1 \
      || die "no expression_attributes collection in ${MONGO_DB}"
    log "generating expression-attribute table from ${MONGO_DB}.expression_attributes"
    "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" "${BUILD_DIR}/expression_attributes_table.js" > "${TABLE}"
    SUGG_CAT="expr"; SUGG_DELQ='id:expr_*'; SUGG_FILE="expr.json" ;;
esac
rows=$(( $(wc -l < "${TABLE}") - 1 ))
[ "${rows}" -gt 0 ] || die "attribute table ${TABLE} has no data rows"
ok "${ATTR} table rows: ${rows}"

# ── genes core: table -> atomic NDJSON -> apply in place ──────────────────────
"${NODE_BIN}" "${BUILD_DIR}/attr_table_to_atomic.js" < "${TABLE}" > "attr_${ATTR}.ndjson"
ndj=$(wc -l < "attr_${ATTR}.ndjson")
[ "${ndj}" -gt 0 ] || die "no atomic docs produced from ${TABLE}"
log "applying ${ATTR} atomic updates to ${SOLR_GENES_CORE} (${ndj} docs; existence-filtered, set + removals, single commit)"
"${NODE_BIN}" "${BUILD_DIR}/solr_atomic_attr.js" "${GENES_URL}" "attr_${ATTR}.ndjson"

# ── suggestions: PARTIAL rebuild of the category this layer feeds (if any) ────
if [ -n "${SUGG_CAT}" ]; then
  SUGG="${SOLR_REPO}/suggestions"; cd "${SUGG}"
  before="$(curl -s "${SOLR_URL}/${SOLR_SUGG_CORE}/select?q=${SUGG_DELQ}&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | sed 's/.*://')"
  log "partial suggestions: deleting ${before:-0} old ${SUGG_CAT} docs (${SUGG_DELQ}); regenerating from the updated genes core"
  curl -s "${SOLR_URL}/${SOLR_SUGG_CORE}/update" -H 'Content-type:application/json' \
    --data-binary "{\"delete\":{\"query\":\"${SUGG_DELQ}\"}}" | grep -q '"status":0' || die "delete of old ${SUGG_CAT} suggestions failed"
  "${NODE_BIN}" ${BIG_HEAP} aux.js "${GENES_URL}" "${SUGG_CAT}"
  [ -s "${SUGG_FILE}" ] && "${NODE_BIN}" -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "${SUGG_FILE}" 2>/dev/null \
    || die "${SUGG_FILE} missing/invalid after aux.js"
  solr_load_json "${SOLR_SUGG_CORE}" "${SUGG_FILE}"   # commits
  after="$(curl -s "${SOLR_URL}/${SOLR_SUGG_CORE}/select?q=${SUGG_DELQ}&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | sed 's/.*://')"
  log "${SUGG_CAT} suggestion docs: ${after:-0} (was ${before:-0})"
fi

ok "${ATTR} atomic update complete (genes core NOT dropped; ${rows} table rows applied)"
stage_end
