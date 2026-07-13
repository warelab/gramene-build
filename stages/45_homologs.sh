#!/usr/bin/env bash
# 45_homologs — build the cross-species homolog store consumed by decorate (homolog_adder).
#
# The full Ensembl-Plants compara (homology 1.06B / homology_member 965M rows) is too large to join on
# colden's 4GB-buffer-pool MySQL (random-access join ~100 rows/s / days). Instead, done LOCALLY in 4 phases:
#   1. dump the needed columns via fast SEQUENTIAL scans, sorting homology/homology_member by homology_id;
#   2. merge-join them -> emit gene_id/other/kind pairs (both directions) to a flatfile;
#   3. SORT the pairs by gene_id (so the LMDB inserts are append-sequential — random live inserts into a
#      30GB+ dupSort B-tree on this memory-tight box collapse to ~2.5K/s);
#   4. bulk-load the on-disk LMDB (dupSort) sequentially. decorate.js's homolog_adder reads it.
# All clustersets with homologies are included (default + pan-genome cultivar clustersets).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 45_homologs

SEARCH="${MONGODB_REPO}/search"
TMP="${SEARCH}/tmp_homologs"
HOMOLOG_LMDB="${SEARCH}/homologs.lmdb"
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

# 4) bulk-load the LMDB sequentially
log "bulk-loading homolog LMDB ${HOMOLOG_LMDB}"
rm -f "${HOMOLOG_LMDB}" "${HOMOLOG_LMDB}-lock"
run bash -c "${UZ} '${TMP}/homolog_pairs.sorted.tsv.gz' | '${NODE_BIN}' --max-old-space-size=8192 load_homolog_lmdb.js '${HOMOLOG_LMDB}'"

# 5) assert the store is non-empty
entries="$("${NODE_BIN}" -e 'const {open}=require("lmdb");const d=open({path:process.argv[1],readOnly:true,dupSort:true,encoding:"string"});console.log(d.getStats().entryCount);d.close()' "${HOMOLOG_LMDB}" 2>/dev/null)"
[ "${entries:-0}" -gt 0 ] && ok "homolog LMDB has ${entries} entries" \
  || die "homolog LMDB ${HOMOLOG_LMDB} is empty after load"
stage_end
