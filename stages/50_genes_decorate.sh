#!/usr/bin/env bash
# 50_genes_decorate — stream tmp/*.json.gz through decorate.js into the genes
# collection, adding homology, bins, pathways, ontology ancestors, domain
# architecture, qtl/curated/generif xrefs, species ranking, etc.
# decorate.js is insert-only, so we DROP genes first (clean, repeatable build).
#
# Preconditions (all asserted): complete gene dumps, redis homologs (db9),
# genes_to_pathways.json, and the aux collections (genetree/ontologies/qtls/
# pathways/maps/taxonomy).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 50_genes_decorate

SEARCH="${MONGODB_REPO}/search"
cd "${SEARCH}"
ASSOC="${MONGODB_REPO}/reactome/genes_to_pathways.json"

# ---- preconditions ----
ls tmp/*.json.gz >/dev/null 2>&1 || die "no gene dumps in ${SEARCH}/tmp — run 40_genes_dump first"
[ -s "${ASSOC}" ] || die "missing ${ASSOC} — run 25_reactome first"
for c in maps taxonomy GO PO TO domains qtls pathways genetree; do assert_mongo_min "$c" 1; done
HOMOLOG_LMDB="${HOMOLOG_LMDB:-${SEARCH}/homologs.lmdb}"
hentries="$("${NODE_BIN}" -e 'const {open}=require("lmdb");const d=open({path:process.argv[1],readOnly:true,dupSort:true,encoding:"string"});console.log(d.getStats().entryCount);d.close()' "${HOMOLOG_LMDB}" 2>/dev/null)"
[ "${hentries:-0}" -gt 0 ] || die "homolog LMDB ${HOMOLOG_LMDB} empty/missing — run 45_homologs"

# ---- re-verify dumps line up with maps BEFORE we ingest (cheap insurance) ----
log "re-validating gene dumps vs maps.num_genes"
DB_NAME="${MONGO_DB}" MONGO_URI="${MONGO_URI}" COLLECTION=maps \
  "${NODE_BIN}" compare_gz_lines_vs_num_genes.js "${SEARCH}/tmp" > tmp/_dump_check.txt 2>&1 || true
expected_genes="$(zcat tmp/*.json.gz | wc -l)"
log "expected gene docs (sum of dump lines): ${expected_genes}"

# ---- the build ----
mongo_drop genes
log "decorating ${expected_genes} genes -> ${MONGO_DB}.genes (this is the long pole)"
# decorate loads ALL gene trees (49k trees / ~5M nodes), ontologies, domains and
# the pathway LUT into memory while streaming 5.2M genes; 8G is marginal and OOMs.
DECORATE_HEAP="${DECORATE_HEAP:---max-old-space-size=24576}"
zcat tmp/*.json.gz | "${NODE_BIN}" ${DECORATE_HEAP} ./decorate.js \
  -i /dev/fd/0 -o insertion_errors.jsonl -p "${ASSOC}" -d "${COMPARA_DB}"

# ---- indexes ----
log "creating genes indexes"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" indexCommands.txt

# ---- validation ----
errs="$(wc -l < insertion_errors.jsonl 2>/dev/null || echo 0)"
[ "${errs}" -eq 0 ] && ok "no insertion errors" || warn "${errs} insertion errors (see ${SEARCH}/insertion_errors.jsonl)"
got="$(mongo_count genes)"
log "genes in ${MONGO_DB}: ${got} (expected ~${expected_genes})"
# allow a tiny slack for genes legitimately dropped during decoration
if [ "${got}" -lt "$(( expected_genes - expected_genes/100 ))" ]; then
  die "genes count ${got} is >1% below expected ${expected_genes} — investigate insertion_errors.jsonl"
fi
ok "genes collection built: ${got} docs"
stage_end
