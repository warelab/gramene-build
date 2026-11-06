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

# 2+3) merge-join -> pairs flatfile -> sort by gene_id (LC_ALL=C byte order, so the load is
# sequential). Resumable on the same terms as the dumps above: the sorted flatfile is the ONLY
# input phase 4 needs, and re-earning it costs a ~60 min merge-join over 1.06B homologies plus an
# external sort of ~964M lines. gzip -t is the completeness test -- a run killed mid-write leaves
# a truncated stream, which fails it and falls through to a rebuild.
SORTED="${TMP}/homolog_pairs.sorted.tsv.gz"
if [ -s "${SORTED}" ] && gzip -t "${SORTED}" 2>/dev/null; then
  ok "sorted homolog pairs already complete ($(du -h "${SORTED}" | cut -f1)) — skipping merge-join + sort"
else
  log "emitting homolog pairs flatfile"
  run bash -c "'${NODE_BIN}' --max-old-space-size=32768 build_homologs.js '${TMP}' | ${Z} > '${TMP}/homolog_pairs.tsv.gz'"

  log "sorting homolog pairs by gene_id"
  mkdir -p "${TMP}/sorttmp"
  run bash -c "${UZ} '${TMP}/homolog_pairs.tsv.gz' | LC_ALL=C sort -S 20G --parallel=16 -T '${TMP}/sorttmp' | ${Z} > '${SORTED}'"
  rm -f "${TMP}/homolog_pairs.tsv.gz"
  # `|| true` matters: sorttmp is typically a SYMLINK onto a filesystem big enough for the sort
  # (/usr/local is not), and rmdir on a symlink exits ENOTDIR. Being the last command on its line
  # under `set -e`, that aborted the stage immediately AFTER a successful 10-minute sort, with
  # 2>/dev/null hiding the reason and make reporting a bare "Error 1".
  rmdir "${TMP}/sorttmp" 2>/dev/null || true
fi

# 4) load into mongo, one doc per gene (drop-based, so re-running is idempotent).
#    Was an LMDB bulk-load; moved to mongo because decorate reads this store once per gene while
#    streaming 5.4M genes, and LMDB's memory map grew without bound inside decorate's own RSS
#    (~1GB per 175k genes). mongod owns that cache now, so decorate's footprint stays flat.
log "loading homologs into ${MONGO_DB}.homologs"
run bash -c "${UZ} '${SORTED}' | '${NODE_BIN}' --max-old-space-size=8192 load_homolog_mongo.js"

# 5) assert the store is non-empty
docs="$(mongo_count homologs)"
[ "${docs:-0}" -gt 0 ] && ok "homologs collection has ${docs} gene docs" \
  || die "${MONGO_DB}.homologs is empty after load"

# 6) assert CROSS-SPECIES orthology is actually present.
#
# "Non-empty" is not a correctness test. On 2026-10-14 this stage shipped a collection of
# 9,083,100 docs and 964,496,164 values that contained essentially ONLY within-species paralogs:
# homology_member.tsv.gz held 965,185,582 of the table's 2,114,930,328 rows while passing gzip -t,
# so for 550 million consecutive homologies build_homologs.js found no members and silently kept
# nothing. Os01g0517500 came out with 42 homologs against release 69's 239; AT1G78400 had 50, all
# arabidopsis. The dumps are row-count verified now, but this asserts the OUTCOME rather than the
# input, because that is the property we actually care about and the one nobody was checking.
log "asserting cross-species orthology is present"
hom_check="$(mongo --quiet "${MONGO_DB}" --eval '
  var want = ["ortholog_one2one","ortholog_one2many","ortholog_many2many","within_species_paralog"];
  var seen = {}, probed = 0, crossSpecies = 0;
  // A small deterministic probe. All three verified present in grapevine4 (and so expected in
  // grapevine5, same cores): VIT_01s0010g03900 = vitis_vinifera, the VIT_-keyed 12X reference, so
  // the gate actually covers the species this site is about; AT1G78400 and Os01g0517500 are the
  // arabidopsis and rice outgroups. The main-release Zm00001eb000010 probe is dropped -- maize
  // is present here as zea_maysb73, but a grape probe is the one worth having.
  // NB this block is inside a single-quoted shell string: no apostrophes in these comments.
  var probes = ["VIT_01s0010g03900","AT1G78400","Os01g0517500"];
  probes.forEach(function (id) {
    var d = db.homologs.findOne({_id: id});
    if (!d || !d.homologous_genes) { return; }
    probed++;
    var pfx = id.replace(/[0-9._].*$/, "");
    Object.keys(d.homologous_genes).forEach(function (k) {
      seen[k] = true;
      (d.homologous_genes[k] || []).forEach(function (o) {
        if (String(o).indexOf(pfx) !== 0) { crossSpecies++; }
      });
    });
  });
  var missing = want.filter(function (k) { return !seen[k]; });
  print(probed + "|" + crossSpecies + "|" + missing.join(","));
' 2>/dev/null | tail -1)"
hc_probed="${hom_check%%|*}"; hc_rest="${hom_check#*|}"
hc_cross="${hc_rest%%|*}"; hc_missing="${hc_rest#*|}"
log "  probe genes found: ${hc_probed:-0}; cross-species homolog values: ${hc_cross:-0}"
[ "${hc_probed:-0}" -ge 2 ] \
  || die "only ${hc_probed:-0} of 3 probe genes have homologs -- the store is far too sparse"
[ "${hc_cross:-0}" -ge 100 ] \
  || die "only ${hc_cross:-0} cross-species homolog values across the probe genes (expect hundreds).\
 This is the 2026-10-14 failure: check tmp_homologs/*.rows against the compara tables."
[ -z "${hc_missing}" ] \
  || die "homology kinds missing entirely: ${hc_missing} -- orthology did not survive the build"
ok "cross-species orthology present (${hc_cross} values, all expected kinds)"
stage_end
