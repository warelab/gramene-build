#!/usr/bin/env bash
# 65_solr_suggestions — build the autocomplete suggestions core from the loaded
# genes core (facets) + mongo term metadata.
#   * recreates ${SOLR_SUGG_CORE} fresh (the old recipe never purged it, so dropped
#     terms / unstable _term_N ids accumulated across releases).
#   * loads the COMPLETE set of suggestion files (the old README curl loop omitted
#     TO.json, QTL_TO.json, qtls.json -> missing Trait-ontology & QTL suggestions).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 65_solr_suggestions

# genes core must be loaded (suggestions are faceted from it)
gdocs="$(solr_numdocs "${SOLR_GENES_CORE}")"
[ "${gdocs:-0}" -gt 0 ] || die "${SOLR_GENES_CORE} is empty — run 60_solr_genes first"

SUGG="${SOLR_REPO}/suggestions"
cd "${SUGG}"
GENES_URL="${SOLR_URL}/${SOLR_GENES_CORE}"

# fresh core — prefer the REPO conf (now synced to the live sorghum_suggestions11 conf:
# Solr 8.2 managed-schema); fall back to the previous release's deployed core conf.
CONF="${SUGG}/conf"; [ -d "${CONF}" ] || CONF="${SOLR_DATA_DIR}/${PREV_SUGG_CORE}/conf"
log "using suggestions conf: ${CONF}"
solr_recreate_core "${SOLR_SUGG_CORE}" "${CONF}"

# generate suggestion json. The two layers regenerate INDEPENDENTLY:
#
#  * aux.js writes the per-category files (GO/PO/TO/QTL_TO/qtls/taxonomy/domains/
#    pathways + TF + expr). These are FACETED from the genes core, so they go stale
#    whenever the genes core changes (new expression/TF/ontology terms). They're
#    cheap to rebuild. Regenerate when forced (REGEN_AUX=1 or REGEN_SUGGEST=1) or
#    when any aux file is missing — this is what `make refresh-attributes` uses to
#    pick up new expression_attributes / grassius_homolog data without re-running
#    the expensive gene-level pass.
#  * genes.js -> genes.json is the gene-level (id/name/synonym) layer. It depends
#    ONLY on the gene set, not on expression/attributes, and re-reads all ~5.2M gene
#    stubs (~1.6GB output, slow). Reuse it unless missing/truncated or REGEN_SUGGEST=1.
# Both layers are DERIVED FROM the genes core, so anything written before the core was last
# rebuilt is stale and must not be reused. Reusing a stale genes.json once shipped 169,944
# suggestions for genes that no longer existed (dropped duplicate assemblies), plus taxon_ids
# that had since been reassigned to other genomes — invisible to the "is the file complete?"
# checks below, because the file was perfectly well-formed, just built from a different gene set.
GENES_STAMP="${BUILD_DIR}/.state/60_solr_genes.done"
stale_vs_genes() {   # $1 = file; true when the genes core is newer than it
  [ -f "${GENES_STAMP}" ] && [ -f "$1" ] && [ "${GENES_STAMP}" -nt "$1" ]
}
if stale_vs_genes genes.json || stale_vs_genes GO.json; then
  log "genes core is newer than the suggestion json — forcing a regenerate"
  REGEN_AUX=1; REGEN_SUGGEST=1
fi

if [ "${REGEN_AUX:-0}" != "1" ] && [ "${REGEN_SUGGEST:-0}" != "1" ] \
   && [ -s GO.json ] && [ -s pathways.json ] && [ -s TF.json ] && [ -s expr.json ]; then
  log "reusing existing aux suggestion json (set REGEN_AUX=1 to rebuild from the genes core)"
else
  log "generating ontology/structured/TF/expression suggestions (aux.js, faceted from ${GENES_URL})"
  "${NODE_BIN}" ${BIG_HEAP} aux.js "${GENES_URL}"
fi

if [ "${REGEN_SUGGEST:-0}" != "1" ] && [ -s genes.json ] && tail -c 3 genes.json | grep -q ']'; then
  log "reusing existing gene-level genes.json (set REGEN_SUGGEST=1 to regenerate)"
else
  log "generating gene-level suggestions (genes.js)"
  "${NODE_BIN}" ${BIG_HEAP} genes.js "${GENES_URL}" > genes.json
fi

# Load gene-level suggestions FIRST, while the core is empty, via the streaming
# chunk loader: genes.json is ~1.6GB (millions of docs) — too big for a single
# curl update AND too big to JSON.parse in one string (V8 ~536MB string cap, which
# is what silently skipped it before). Validate it cheaply (must close with ']').
[ -s genes.json ] && tail -c 3 genes.json | grep -q ']' || die "genes.json missing/truncated (no closing ']')"
solr_load_json_chunked "${SOLR_SUGG_CORE}" genes.json

# Load the small ontology/structured files (curl is fine; each is < ~50MB).
loaded=0
for f in GO PO TO QTL_TO qtls taxonomy domains pathways TF expr; do
  if [ -s "${f}.json" ] && "${NODE_BIN}" -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "${f}.json" 2>/dev/null; then
    solr_load_json "${SOLR_SUGG_CORE}" "${f}.json"; loaded=$((loaded+1))
  else
    warn "${f}.json missing/empty/invalid — skipped"
  fi
done

# Completeness gate: gene-level suggestions dominate (prior release had ~7M docs),
# so a tiny count means genes.json didn't load. Floor at the gene count.
sdocs="$(solr_numdocs "${SOLR_SUGG_CORE}")"
floor="$(mongo_count genes)"
log "${SOLR_SUGG_CORE} numDocs=${sdocs} (genes.json + ${loaded} ontology files; prior release ~7.2M)"
[ "${sdocs:-0}" -ge "${floor:-1000000}" ] || die "suggestions core has only ${sdocs} docs (< ${floor}) — gene-level suggestions did not load"
ok "suggestions core built: ${sdocs} docs"

# ---- gate: the 'Genes: primary id' layer must agree with the genes core ----
# A well-formed but stale genes.json produces suggestions for genes that no longer exist; the
# doc-count check above cannot see that. Compare the primary-id count to the genes core.
gsug="$(curl -s "${SOLR_URL}/${SOLR_SUGG_CORE}/select?q=category:%22Genes%3A+primary+id%22&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | head -1 | cut -d: -f2)"
gcore="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/select?q=*:*&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | head -1 | cut -d: -f2)"
if [ "${gsug:-0}" = "${gcore:-1}" ]; then
  ok "primary-id suggestions match the genes core (${gsug})"
else
  die "primary-id suggestions=${gsug} but genes core=${gcore} — suggestions were built from a different gene set; rerun with REGEN_SUGGEST=1 REGEN_AUX=1"
fi
stage_end
