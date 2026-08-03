#!/usr/bin/env bash
# 45_homologs — build the cross-species homolog store consumed by decorate (homolog_adder).
#
# The full Ensembl-Plants compara (homology 1.06B / homology_member 965M rows) is too large to join on
# colden's 4GB-buffer-pool MySQL (random-access join ~100 rows/s / days). Instead, done LOCALLY in 4 phases:
#   1. dump the needed columns via fast SEQUENTIAL scans, sorting homology/homology_member by homology_id;
#   2. merge-join them -> emit gene_id/other/kind pairs (both directions) to a flatfile;
#   3. SORT the pairs by gene_id, so all rows for a gene are contiguous and the loader can group
#      them one gene at a time in O(one gene) memory;
#   4. load into mongo as one doc per gene. decorate.js's homolog_adder reads it in $in batches.
# All clustersets with homologies are included (default + pan-genome cultivar clustersets).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 45_homologs

SEARCH="${MONGODB_REPO}/search"
TMP="${SEARCH}/tmp_homologs"
cd "${SEARCH}"
command -v pigz >/dev/null && Z="pigz -p 32" && UZ="pigz -dc" || { Z="gzip"; UZ="zcat"; }

# 1) dump minimal compara columns (resumable; homology/homology_member sorted by homology_id)
log "dumping compara columns to ${TMP}"
run bash dump_compara_tables.sh "${TMP}"

# 2) merge-join -> emit pairs flatfile (gene_id \t other_id \t kind, both directions)
log "emitting homolog pairs flatfile"
run bash -c "'${NODE_BIN}' --max-old-space-size=32768 build_homologs.js '${TMP}' | ${Z} > '${TMP}/homolog_pairs.tsv.gz'"

# 3) sort pairs by gene_id (LC_ALL=C byte order == lmdb string-key order) so the load is sequential
log "sorting homolog pairs by gene_id"
mkdir -p "${TMP}/sorttmp"
run bash -c "${UZ} '${TMP}/homolog_pairs.tsv.gz' | LC_ALL=C sort -S 20G --parallel=16 -T '${TMP}/sorttmp' | ${Z} > '${TMP}/homolog_pairs.sorted.tsv.gz'"
rm -f "${TMP}/homolog_pairs.tsv.gz"; rmdir "${TMP}/sorttmp" 2>/dev/null

# 4) load into mongo, one doc per gene (drop-based, so re-running is idempotent).
#    Was an LMDB bulk-load; moved to mongo because decorate reads this store once per gene while
#    streaming 5.4M genes, and LMDB's memory map grew without bound inside decorate's own RSS
#    (~1GB per 175k genes). mongod owns that cache now, so decorate's footprint stays flat.
log "loading homologs into ${MONGO_DB}.homologs"
run bash -c "${UZ} '${TMP}/homolog_pairs.sorted.tsv.gz' | '${NODE_BIN}' --max-old-space-size=8192 load_homolog_mongo.js"

# 5) assert the store is non-empty
docs="$(mongo_count homologs)"
[ "${docs:-0}" -gt 0 ] && ok "homologs collection has ${docs} gene docs" \
  || die "${MONGO_DB}.homologs is empty after load"
stage_end
