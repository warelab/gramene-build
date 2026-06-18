#!/usr/bin/env bash
# 10_maps — build the maps + taxonomy collections from the ensembl cores/compara.
# load.js is drop-based (deleteMany+insertMany) so this is naturally idempotent.
# maps.num_genes (COUNT of is_current genes per core) becomes the per-genome
# sanity-check target used by the gene-dump stage.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 10_maps

cd "${MONGODB_REPO}/maps"
run "${NODE_BIN}" load.js

assert_mongo_min maps 100        # 125 cores; cores with 0 genes/no taxon are skipped
assert_mongo_min taxonomy 100

# QC: every genome's system_name must resolve in the ensembl REST registry
log "QC: checking maps against ensembl REST registry"
MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" BASE_URL="${ENSEMBL_REST}" \
  "${NODE_BIN}" check_maps_in_ensembl_rest.js || warn "check_maps_in_ensembl_rest reported issues (see above)"

# report what we built
log "genome maps: $(mongo_eval "db.maps.countDocuments({type:'genome'})")"
log "anchor genomes: $(mongo_eval "db.maps.countDocuments({is_anchor:true})")"
stage_end
