#!/usr/bin/env bash
# 25_reactome — Plant Reactome: build the pathways collection, stamp reactomePrefix
# onto taxonomy, and emit genes_to_pathways.json (the -p associations file that
# decorate.js requires). get_pathways.js is drop-based on pathways (safe rerun).
# Requires maps (is_anchor) + taxonomy collections -> run after 10_maps.
#
# NOTE: the old recipe also hand-munged Ensembl2PlantReactomeReactions.txt to add
# Oryza japonica UniProt->gene mappings (see merged_lut.txt). That enhancement is
# OPTIONAL and rice-japonica-specific; it is intentionally skipped here. To apply
# it, see build/README.md "Reactome japonica enhancement".
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 25_reactome

assert_mongo_min maps 100
assert_mongo_min taxonomy 100

R="${MONGODB_REPO}/reactome"
cd "${R}"
PR=https://plantreactome.gramene.org/download/current

log "downloading Plant Reactome mapping files"
curl -fsSL "${PR}/UniProt2PlantReactomeReactions.txt"        -o UniProt2PlantReactomeReactions.txt
curl -fsSL "${PR}/gene_ids_by_pathway_and_species.tab"       -o gene_ids_by_pathway_and_species.tab
curl -fsSL "${PR}/Ensembl2PlantReactomeReactions.txt"        -o Ensembl2PlantReactomeReactions.txt
assert_nonempty_file Ensembl2PlantReactomeReactions.txt
assert_nonempty_file gene_ids_by_pathway_and_species.tab

# 1) reactome species prefixes from the anchor genomes
log "deriving reactome species prefixes"
"${NODE_BIN}" get_species_prefixes.js > merge_into_taxonomy.json
assert_valid_json merge_into_taxonomy.json

# 2) merge reactomePrefix onto taxonomy docs (upsert: leaves other docs intact)
log "merging reactomePrefix into ${MONGO_DB}.taxonomy"
mongoexport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c taxonomy 2>/dev/null \
  | "${NODE_BIN}" "${MONGODB_REPO}/search/merge_into_mongo_docs.js" -l "${R}/merge_into_taxonomy.json" \
  | mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c taxonomy --upsert 2>/dev/null
pfx="$(mongo_eval "db.taxonomy.countDocuments({reactomePrefix:{\$exists:true}})")"
[ "${pfx:-0}" -gt 0 ] && ok "taxonomy docs with reactomePrefix: ${pfx}" || warn "no taxonomy docs got a reactomePrefix"

# 3) build pathways collection + the gene->pathway associations json
log "building pathways collection + genes_to_pathways.json"
"${NODE_BIN}" ${BIG_HEAP} get_pathways.js \
  --gtr Ensembl2PlantReactomeReactions.txt \
  --gtp gene_ids_by_pathway_and_species.tab \
  --api https://plantreactome.gramene.org/ContentService \
  > genes_to_pathways.raw.json

assert_valid_json genes_to_pathways.raw.json
assert_mongo_min pathways 100

# 4) grape v4->v3 key rewrite (vitis is an anchor); fall back if it breaks json
if "${MONGODB_REPO}/reactome/update_vv.pl" < genes_to_pathways.raw.json > genes_to_pathways.json 2>/dev/null \
   && "${NODE_BIN}" -e 'JSON.parse(require("fs").readFileSync("genes_to_pathways.json"))' 2>/dev/null; then
  ok "applied grape v4->v3 key rewrite"
else
  warn "update_vv.pl produced invalid json — using raw associations"
  cp genes_to_pathways.raw.json genes_to_pathways.json
fi
assert_valid_json genes_to_pathways.json
ln -sf "${R}/genes_to_pathways.json" "${MONGODB_REPO}/search/genes_to_pathways.json"
stage_end
