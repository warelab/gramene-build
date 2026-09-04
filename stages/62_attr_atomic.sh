#!/usr/bin/env bash
# 62_attr_atomic <attr> — patch ONE post-dump attribute layer into the genes core via
# Solr ATOMIC updates (no drop / no downtime), then PARTIALLY rebuild any suggestion
# category that layer feeds. Generic over the attribute type:
#
#   attr ∈ { maker | vep | rsid | grassius | expression }
#
# All four are add_attributes.pl tables (id + capabilities + *_attr_[sif]s? columns),
# so the same converter (attr_table_to_atomic.js) + loader (solr_atomic_attr.js) apply.
# This is the lightweight alternative to `make refresh-attributes`, which regenerates
# the merged solr_genes.attribs.json and RELOADS all 5.2M docs (dropping the core).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
ATTR="${1:-}"
# --preflight: run ONLY the schema safety check and exit with its status, so a caller can find out
# whether an atomic update is possible before doing expensive work. No logging, no stamp.
PREFLIGHT=0
[ "${ATTR}" = "--preflight" ] && { PREFLIGHT=1; ATTR="expression"; }
case "${ATTR}" in maker|vep|rsid|grassius|grassius_homolog|expression|expression_attributes) : ;;
  *) die "usage: 62_attr_atomic.sh <maker|vep|rsid|grassius|expression> | --preflight";; esac
[ "${PREFLIGHT}" = "1" ] || stage_begin "62_attr_atomic_${ATTR}"

# ── SAFETY: atomic updates DESTROY indexed-but-not-stored fields ─────────────
# Solr implements an atomic update by reconstructing the document from its STORED fields and
# reindexing it. Any field that is indexed but neither stored nor docValues, and is not a
# copyField destination, cannot be reconstructed and is silently lost for every doc touched.
#
# This is not hypothetical: `_terms` (indexed, stored=false, docValues=false, no copyField, written
# directly by genes/mongo2solr.js) was wiped from 247,323 docs by an expression run, which broke
# free-text gene search for them -- and would have propagated into the suggestions core, since
# suggestions/genes.js facets on _terms. It applies to EVERY attr type, not just expression.
#
# Refuse rather than damage the core. The real fix is stored=true on the offending field plus a
# reindex; until then use `make refresh-attributes` (full reload), not this stage.
log "checking the genes core schema for fields atomic updates cannot preserve"
UNSAFE="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/schema?wt=json" | "${NODE_BIN}" -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{
    const sc=JSON.parse(s).schema;
    const dests=new Set((sc.copyFields||[]).map(c=>c.dest));
    const bad=(sc.fields||[]).filter(f=>f.indexed && !f.stored && !f.docValues && !dests.has(f.name)).map(f=>f.name);
    console.log(bad.join(" "));
  }catch(e){console.log("__SCHEMA_UNREADABLE__")}
})')"
if [ "${UNSAFE}" = "__SCHEMA_UNREADABLE__" ]; then
  die "could not read the ${SOLR_GENES_CORE} schema — refusing to apply atomic updates blind"
elif [ -n "${UNSAFE}" ]; then
  die "REFUSING to apply atomic updates: ${SOLR_GENES_CORE} has indexed field(s) that are neither stored nor docValues nor copyField destinations, and an atomic update would silently erase them from every doc it touches: ${UNSAFE}. Use 'make refresh-attributes' (full reload) instead, or make those fields stored and reindex. See docs/04-troubleshooting.md."
fi
ok "schema is safe for atomic updates (no unreconstructable fields)"
[ "${PREFLIGHT}" = "1" ] && exit 0

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
  rsid)
    # GENOME=<system_name> patches ONE genome from its per-genome extractor output, without
    # rebuilding or merging a pan-genome table. rsID attributes are strictly per-genome -- a gene
    # belongs to exactly one genome -- so nothing is lost by doing them one at a time, and a single
    # re-projected genome costs ~2 min instead of a full 102-genome rebuild.
    #
    # The remove pass MUST be scoped to that genome. Unscoped, it queries capabilities:rsid across
    # the whole core and clears every gene not in this input -- 4.1M of them. REMOVE_SCOPE limits it,
    # and solr_atomic_attr.js additionally refuses any run that would clear >50% of the token.
    if [ -n "${GENOME:-}" ]; then
      src="${RSID_WORK_DIR}/${GENOME}.tsv"
      [ -s "${src}" ] || die "no per-genome rsID output for ${GENOME}: ${src} — run rsid_pipeline/build_rsid_table.sh ${GENOME}"
      "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval \
        'db.maps.countDocuments({system_name:"'"${GENOME}"'"})>0?quit(0):quit(1)' >/dev/null 2>&1 \
        || die "${GENOME} is not a maps.system_name in ${MONGO_DB}"
      # per-genome files are headerless; attr_table_to_atomic.js needs the header
      { printf 'id\tcapabilities\trsid__attr_ss\trsid_PTV__attr_ss\trsid_PAV__attr_ss\n'
        cat "${src}"; } > "${TABLE}"
      export REMOVE_SCOPE="system_name:${GENOME}"
      log "per-genome rsID update: ${GENOME} (remove pass scoped to system_name:${GENOME})"
    else
      [ -s "${RSID_TABLE}" ] || die "rsID table missing: ${RSID_TABLE} — build it with gramene-solr/rsid_pipeline/build_rsid_table.sh"
      cp -f "${RSID_TABLE}" "${TABLE}"
    fi ;;
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
# Both halves stream. solr_atomic_attr.js used to slurp the whole NDJSON into one array, which is
# fine for the ~250k-row layers (MAKER/VEP/expression) but not for rsid: 4.1M docs carrying 459M
# rsID strings is ~25-40 GB of JS heap on a box whose mongod already holds ~98 GB. It now reads the
# file twice -- once for ids, once to post -- so peak memory is the id list (~300 MB) plus one
# batch. The headroom below is generous, not required.
ATOMIC_HEAP="${ATOMIC_HEAP:---max-old-space-size=8192}"
"${NODE_BIN}" "${BUILD_DIR}/attr_table_to_atomic.js" < "${TABLE}" > "attr_${ATTR}.ndjson"
ndj=$(wc -l < "attr_${ATTR}.ndjson")
[ "${ndj}" -gt 0 ] || die "no atomic docs produced from ${TABLE}"
log "applying ${ATTR} atomic updates to ${SOLR_GENES_CORE} (${ndj} docs; existence-filtered, set + removals, single commit)"
"${NODE_BIN}" ${ATOMIC_HEAP} "${BUILD_DIR}/solr_atomic_attr.js" "${GENES_URL}" "attr_${ATTR}.ndjson"

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
