#!/usr/bin/env bash
# 35_genetrees — build the genetree collection from compara.
# genetree.js is insert-only (insertOne) so we DROP genetree first.
# Needs: curated/curated.json (representative scoring) + taxonomy subset:'compara'.
# (add_domains_to_tree runs AFTER decorate — see 52_tree_domains.sh.)
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 35_genetrees

[ -s "${MONGODB_REPO}/curated/curated.json" ] || die "curated/curated.json missing — run 30_curated first"
cmp_taxa="$(mongo_eval "db.taxonomy.countDocuments({subset:'compara'})")"
[ "${cmp_taxa:-0}" -gt 0 ] || die "no taxonomy subset:'compara' docs — run 10_maps first"

# ---- the tree sets -------------------------------------------------------------------------
# genetree.js builds ONE set per run (see its header), so it is invoked once per set here. Each
# becomes genes.homology.<tree_set> in the decorate, so a consumer reads the homology object's keys
# to learn which trees a gene is in.
#
# EVERY tree of each clusterset is taken. 'default' has a published stable_id on all 170,253, but
# the cultivar clustersets carry 162,111 trees with no stable_id beside 54,034 published ones.
# Those unnamed trees used to be excluded as "fragments"; they are included now because excluding
# them left 3,821,574 genes holding homologous_genes with no tree at all, and because the fragment
# assumption fails in the tail (1,615 unnamed trees have 250+ leaves, averaging 1,056).
#
# The crop ids are rewritten from the clusterset prefix compara ships
# (barley_cultivars_PTHR10000_SF7) to a Gramene one (EplBarleyGT_PTHR10000_SF7), keeping the
# PANTHER/TreeFam family part so an id stays traceable upstream. 'default' keeps its EPlGT* ids,
# which are already meaningful. An unnamed tree gets <prefix>root<root_id>, which does NOT survive
# a compara release the way a family-based id does -- see genetree.js for that caveat.
#
# The set -> clusterset -> prefix mapping is NOT repeated here. It comes from
# gramene-mongodb/trees/tree_sets.js, which search/supertrees.js also requires, so the stage and
# the supertree map cannot drift. (decorate.js and redecorate.js once carried private copies of a
# species-rank map that silently disagreed; this table was heading the same way.)
# NOT YET SHARED: genetree.js still builds its own copy of the id-rewrite SQL. It is equivalent
# for every case that fires -- the substring offsets match clusterset.length+2 either way -- and it
# has just been validated by a full run, so it is left alone rather than changed without a re-run.
# tree_sets.js exports idSql() ready for it whenever stage 35 is next exercised.
# Only the expected counts stay here -- those are facts about THIS release's compara, not about
# the sets, and they are ALL trees of the clusterset (tree_type='tree'), not just the named ones.
declare -A EXPECT_TREES=(
  [gene_tree]=34196
)
mapfile -t TREE_SETS < <("${NODE_BIN}" -e \
  'require(process.argv[1]).TREE_SETS.forEach(function (t) { console.log([t.set, t.clusterset, t.prefix].join("|")); })' \
  "${MONGODB_REPO}/trees/tree_sets.js")
[ "${#TREE_SETS[@]}" -eq "${#EXPECT_TREES[@]}" ] \
  || die "tree_sets.js yielded ${#TREE_SETS[@]} sets but ${#EXPECT_TREES[@]} expected counts are defined here —
 add or remove a count in EXPECT_TREES above to match trees/tree_sets.js"
ok "tree sets from trees/tree_sets.js: $(printf '%s ' "${TREE_SETS[@]%%|*}")"

mongo_drop genetree
cd "${MONGODB_REPO}/trees"

for spec in "${TREE_SETS[@]}"; do
  IFS='|' read -r ts cs pfx <<< "${spec}"
  want="${EXPECT_TREES[${ts}]:-}"
  [ -n "${want}" ] || die "no expected tree count for set '${ts}' — add it to EXPECT_TREES above"
  before="$(mongo_count genetree)"
  log "tree set '${ts}': clusterset=${cs} prefix=${pfx:-<as published>} (expect ~${want})"
  TREE_SET="${ts}" CLUSTERSET="${cs}" TREE_ID_PREFIX="${pfx}" \
    run "${NODE_BIN}" ${BIG_HEAP} genetree.js
  # Check the exit status EXPLICITLY. These stages do not run under `set -e` and lib.sh's run()
  # is `log "+ $*"; "$@"` -- it does not test the status either -- so a failing genetree.js was
  # simply ignored. It is now non-zero when any insert fails, which is how 147 trees vanished
  # from release 70 unnoticed.
  rc=$?
  [ "${rc}" -eq 0 ] || die "genetree.js exited ${rc} for tree set '${ts}' — some trees were not
 stored. Its per-set log says which and why: ${MONGODB_REPO}/trees/inserts.genetree.${ts}.jsonl"
  # Independent of the exit status, count failures in the log it just wrote, so a crash before the
  # summary cannot hide them either.
  ilog="${MONGODB_REPO}/trees/inserts.genetree.${ts}.jsonl"
  if [ -s "${ilog}" ]; then
    # `|| true`, not `|| echo 0`: grep -c already PRINTS 0 when nothing matches, it just exits 1,
    # so `|| echo 0` emitted "0\n0" and the integer test below errored on every clean run.
    ierr="$(grep -c '"err":"' "${ilog}" 2>/dev/null || true)"
    [ "${ierr:-0}" -eq 0 ] \
      && ok "tree set '${ts}': no insert errors" \
      || die "tree set '${ts}': ${ierr} insert failures in ${ilog}
 First few:
$(grep '"err":"' "${ilog}" | head -3 | sed 's/^/   /')"
  else
    warn "tree set '${ts}': no insert log at ${ilog} — cannot confirm every tree stored"
  fi
  after="$(mongo_count genetree)"
  got=$(( after - before ))
  # Bounded on BOTH sides. Too few means the clusterset name moved upstream, or a stable_id
  # filter crept back in and dropped the unnamed trees again. Too many means the per-set env did
  # not reach genetree.js and it rebuilt 'default' again -- which a lower bound alone cannot see.
  # That upper guard still works now that the crop sets are larger: 'default' (170,253) is above
  # every crop set's hi bound, the largest being barley at 87,626 * 3/2 = 131,439.
  lo=$(( want * 9 / 10 )); hi=$(( want * 3 / 2 ))
  if [ "${got}" -lt "${lo}" ]; then
    die "tree set '${ts}': only ${got} trees loaded, expected ~${want} — check clusterset_id upstream"
  elif [ "${got}" -gt "${hi}" ]; then
    die "tree set '${ts}': ${got} trees loaded, expected ~${want} — the set selection did not take (did TREE_SET/CLUSTERSET reach genetree.js?)"
  fi
  ok "tree set '${ts}': ${got} trees loaded"

  # Trees are STORED FLAT now, and /genetrees rebuilds them with the same conversion. A rebuild
  # that was subtly not an inverse would corrupt every tree response while every count here still
  # looked right -- the same shape of failure as the 147 trees that went missing unnoticed. So
  # check the stored documents actually are flat and do round trip exactly.
  run "${NODE_BIN}" verify_tree_shape.js "${ts}" 50
  [ $? -eq 0 ] || die "tree set '${ts}': stored trees failed the shape check (see above)"
done

# indexes: compara_db for backward compatibility, tree_set for the per-set LUT the adder builds,
# and max_depth so "which trees would the old nested shape have refused?" stays answerable without
# scanning 386k documents averaging ~100 KB each.
mongo_eval "db.genetree.createIndex({compara_db:1})" >/dev/null
mongo_eval "db.genetree.createIndex({tree_set:1})" >/dev/null
mongo_eval "db.genetree.createIndex({max_depth:1})" >/dev/null
ok "compara_db + tree_set + max_depth indexes created"

assert_mongo_min genetree 1000
log "trees per set:"
mongo_eval "db.genetree.aggregate([{\$group:{_id:'\$tree_set',n:{\$sum:1}}},{\$sort:{n:-1}}]).forEach(d=>print('    '+d._id+'  '+d.n))"
untagged="$(mongo_eval "db.genetree.countDocuments({tree_set:{\$exists:false}})")"
[ "${untagged:-0}" -eq 0 ] && ok "every tree carries a tree_set" \
  || die "${untagged} trees have no tree_set — genetree.js did not tag them"

# The point of the flat shape: trees the nested one could not store at all. Release 70 lost 147 of
# them (barley 105, wheat 22, oat 16, default 4, rice 0) and ~120,014 genes' tree membership with
# them. Reported per set and asserted only in total, because rice legitimately has none.
log "trees too deep for the old nested shape:"
cd "${MONGODB_REPO}/trees"
run "${NODE_BIN}" verify_tree_shape.js --deep-report
[ $? -eq 0 ] || die "no tree is deeper than the old nested limit — the deep trees are being dropped
 again, or max_depth is not being written. Release 70 had 147 of them."
stage_end
