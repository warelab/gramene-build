#!/usr/bin/env bash
# 60_solr_genes — convert mongo genes -> flat solr docs and load the genes core.
#   * recreates the ${SOLR_GENES_CORE} core fresh from the repo conf (no stale docs)
#   * mongo2solr.js streams every gene; it process.exit(2)s if any gene lacks a
#     canonical transcript, so a non-zero exit here means a data problem, not a
#     partial load — we refuse to load a truncated solr_genes.json.
#   * merges gene-level attribute tables into the solr docs (add_attributes.pl):
#     MAKER (AED/QI), VEP (germplasm/PTV), and grassius_homolog (TF families
#     projected onto homologs). MAKER/VEP reuse the prior release's tables.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 60_solr_genes

assert_mongo_min genes 1000

GENES="${SOLR_REPO}/genes"
cd "${GENES}"

# 1) core. Prefer the REPO conf (gramene-solr/genes/conf) — it is now the authoritative,
# complete schema: synced from the deployed prev-release conf (atlas_id, closest_rep_identity,
# model_rep_identity) plus the alt_id field, and it matches mongo2solr's output. Fall back to
# the previous release's deployed core conf only if the repo conf is missing.
# Recreate fresh only when the core is empty/absent (or REBUILD_CORE=1); if it
# already holds docs from an interrupted load, KEEP them and let the chunk loader
# resume (it skips the already-committed docs).
CONF="${GENES}/conf"
[ -d "${CONF}" ] || CONF="${SOLR_DATA_DIR}/${PREV_GENES_CORE}/conf"
existing="$(solr_numdocs "${SOLR_GENES_CORE}" 2>/dev/null || echo 0)"
if [ "${existing:-0}" -eq 0 ] || [ "${REBUILD_CORE:-0}" = "1" ]; then
  log "using genes conf: ${CONF}"
  solr_recreate_core "${SOLR_GENES_CORE}" "${CONF}"
else
  log "resuming load into existing ${SOLR_GENES_CORE} (${existing} docs already committed)"
fi

# 2) mongo -> solr docs (must reach ']' or it exited 2 on a bad gene).
# Uses mongo2solr.join.js (the newer implementation; the original recipe pinned the
# older mongo2solr.js by mistake). It joins the expression collection server-side via
# a $lookup aggregation (allowDiskUse) and streams each gene, so it does NOT load the
# whole expression collection into Node memory the way mongo2solr.js did (which OOMed
# at 8G). It also emits expressed_in_gxa_attr_ss (GXA experiments a gene is expressed
# in), region-padded compara_idx, canonical_transcript__attr_s, supertree, and pan-gene
# capabilities. The heap below is now precautionary, not required.
# Resumable: if a complete solr_genes.json already exists (ends with ']' and has
# 2*genes+1 lines — '[ '+doc for the first gene, ','+doc for each other, ']'),
# reuse it instead of re-running the ~20min conversion.
SOLR_HEAP="${SOLR_HEAP:---max-old-space-size=16384}"
want_lines=$(( $(mongo_count genes) * 2 + 1 ))
if [ -s solr_genes.json ] && tail -c 3 solr_genes.json | grep -q ']' \
   && [ "$(wc -l < solr_genes.json)" = "${want_lines}" ]; then
  log "reusing existing complete solr_genes.json ($(wc -c <solr_genes.json) bytes, ${want_lines} lines)"
else
  log "converting mongo genes -> solr docs via mongo2solr.join.js (heap ${SOLR_HEAP})"
  "${NODE_BIN}" ${SOLR_HEAP} ./mongo2solr.join.js > solr_genes.json
  tail -c 3 solr_genes.json | grep -q ']' || die "mongo2solr.join.js did not finish (no closing ']') — check for genes lacking a canonical transcript"
fi
assert_nonempty_file solr_genes.json

LOAD_FILE="solr_genes.json"

# 3) merge gene-level attribute tables into the solr docs via add_attributes.pl:
#    - MAKER  : per-genome gene-model AED/QI scores       (${MAKER_TABLE})
#    - VEP    : germplasm/PTV alleles from the variation DB (${VEP_TABLE})
#    - grassius_homolog : Grassius TF families projected onto homologs (this build)
# MAKER/VEP reuse the prior release's tables by default (same variation DB + gene IDs);
# grassius_homolog is generated fresh from the decorated genes collection.
attr_tables=()
if [ -s "${MAKER_TABLE}" ]; then attr_tables+=("${MAKER_TABLE}"); ok "MAKER table: ${MAKER_TABLE}"; else warn "MAKER table missing (${MAKER_TABLE}) — skipping"; fi
if [ -s "${VEP_TABLE}" ];   then attr_tables+=("${VEP_TABLE}");   ok "VEP table: ${VEP_TABLE}";   else warn "VEP table missing (${VEP_TABLE}) — skipping"; fi

log "projecting Grassius TF families onto homologs"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" "${BUILD_DIR}/grassius_homolog_table.js" > grassius_homolog_attrib_table.txt
gh_rows=$(( $(wc -l < grassius_homolog_attrib_table.txt) - 1 ))
if [ "${gh_rows}" -gt 0 ]; then ok "grassius_homolog rows: ${gh_rows}"; attr_tables+=("${GENES}/grassius_homolog_attrib_table.txt"); else warn "no grassius_homolog rows"; fi

# expression summary attributes (tissue specificity / breadth / stress / per-organ
# level), generated fresh from the expression_attributes collection.
if "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval 'db.expression_attributes.countDocuments({})>0?quit(0):quit(1)' >/dev/null 2>&1; then
  log "generating expression-attribute table from ${MONGO_DB}.expression_attributes"
  "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" "${BUILD_DIR}/expression_attributes_table.js" > expression_attributes_table.txt
  ea_rows=$(( $(wc -l < expression_attributes_table.txt) - 1 ))
  if [ "${ea_rows}" -gt 0 ]; then ok "expression_attributes rows: ${ea_rows}"; attr_tables+=("${GENES}/expression_attributes_table.txt"); else warn "no expression_attributes rows"; fi
else
  warn "no expression_attributes collection — skipping expression attributes"
fi

if [ "${#attr_tables[@]}" -gt 0 ]; then
  # Reuse a complete attribs file across kill-resumes — but ONLY if it is newer than every input.
  # "Complete" (closing ']' + matching line count) says nothing about whether the merged VALUES are
  # current: several of these tables are regenerated from mongo on every run, so a rebuilt
  # expression_attributes collection produced a fresh expression_attributes_table.txt while this
  # file was reused untouched, and the index kept serving the previous release's values.
  attribs_stale=0
  if [ -s solr_genes.attribs.json ]; then
    for t in "${attr_tables[@]}" solr_genes.json; do
      if [ -e "$t" ] && [ "$t" -nt solr_genes.attribs.json ]; then
        log "attribute input newer than solr_genes.attribs.json: $(basename "$t") — will re-merge"
        attribs_stale=1
      fi
    done
  fi
  if [ "${attribs_stale}" -eq 0 ] && [ -s solr_genes.attribs.json ] && tail -c 3 solr_genes.attribs.json | grep -q ']' \
     && [ "$(wc -l < solr_genes.attribs.json)" = "$(wc -l < solr_genes.json)" ]; then
    log "reusing existing complete solr_genes.attribs.json"
  else
    log "merging ${#attr_tables[@]} attribute tables into solr docs"
    pipe="cat solr_genes.json"
    for t in "${attr_tables[@]}"; do pipe="${pipe} | '${GENES}/add_attributes.pl' '${t}'"; done
    eval "${pipe}" > solr_genes.attribs.json
    tail -c 3 solr_genes.attribs.json | grep -q ']' || die "attribute merge produced a truncated solr_genes.attribs.json"
    [ "$(wc -l < solr_genes.attribs.json)" = "$(wc -l < solr_genes.json)" ] || die "solr_genes.attribs.json line count != solr_genes.json (merge dropped docs)"
  fi
  LOAD_FILE="solr_genes.attribs.json"
fi

# 4) load + commit. The genes file is multi-GB, so stream it in batches rather
# than handing Solr one giant update request.
solr_load_json_chunked "${SOLR_GENES_CORE}" "${LOAD_FILE}"

# 5) validate count + attribute coverage
want="$(mongo_count genes)"
got="$(solr_numdocs "${SOLR_GENES_CORE}")"
log "solr ${SOLR_GENES_CORE} numDocs=${got} ; mongo genes=${want}"
[ "${got}" = "${want}" ] && ok "solr genes count matches mongo" || warn "solr genes (${got}) != mongo genes (${want})"
# report how many genes carry each merged capability
for cap in MAKER VEP expression_attributes; do
  n="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/select?q=capabilities:${cap}&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | sed 's/.*://')"
  log "  genes with ${cap} capability: ${n:-0}"
done
ghn="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/select?q=grassius_homolog__attr_ss:*&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | sed 's/.*://')"
log "  genes with grassius_homolog: ${ghn:-0}"
stage_end
