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
# Only trees with a published stable_id are taken. That is every tree for 'default', but the crop
# cultivar clustersets also hold ~162k smaller unnamed fragments which are deliberately excluded.
#
# The crop ids are rewritten from the clusterset prefix compara ships
# (barley_cultivars_PTHR10000_SF7) to a Gramene one (EplBarleyGT_PTHR10000_SF7), keeping the
# PANTHER/TreeFam family part so an id stays traceable upstream. 'default' keeps its EPlGT* ids,
# which are already meaningful.
#
#        tree_set | clusterset       | id prefix     | expected trees
TREE_SETS=(
  "gene_tree|default||170253"
  "barley|barley_cultivars|EplBarleyGT_|12167"
  "oat|oat_cultivars|EplOatGT_|12846"
  "wheat|wheat_cultivars|EplWheatGT_|12772"
  "rice|rice_cultivars|EplRiceGT_|16249"
)

mongo_drop genetree
cd "${MONGODB_REPO}/trees"

for spec in "${TREE_SETS[@]}"; do
  IFS='|' read -r ts cs pfx want <<< "${spec}"
  before="$(mongo_count genetree)"
  log "tree set '${ts}': clusterset=${cs} prefix=${pfx:-<as published>} (expect ~${want})"
  TREE_SET="${ts}" CLUSTERSET="${cs}" TREE_ID_PREFIX="${pfx}" \
    run "${NODE_BIN}" ${BIG_HEAP} genetree.js
  after="$(mongo_count genetree)"
  got=$(( after - before ))
  # A set landing far under its expected count means the clusterset name or the stable_id filter
  # moved upstream; that is worth stopping for rather than quietly shipping a thin tree set.
  [ "${got}" -ge $(( want * 9 / 10 )) ] \
    && ok "tree set '${ts}': ${got} trees loaded" \
    || die "tree set '${ts}': only ${got} trees loaded, expected ~${want} — check clusterset_id upstream"
done

# indexes: compara_db for backward compatibility, tree_set for the per-set LUT the adder builds
mongo_eval "db.genetree.createIndex({compara_db:1})" >/dev/null
mongo_eval "db.genetree.createIndex({tree_set:1})" >/dev/null
ok "compara_db + tree_set indexes created"

assert_mongo_min genetree 1000
log "trees per set:"
mongo_eval "db.genetree.aggregate([{\$group:{_id:'\$tree_set',n:{\$sum:1}}},{\$sort:{n:-1}}]).forEach(d=>print('    '+d._id+'  '+d.n))"
untagged="$(mongo_eval "db.genetree.countDocuments({tree_set:{\$exists:false}})")"
[ "${untagged:-0}" -eq 0 ] && ok "every tree carries a tree_set" \
  || die "${untagged} trees have no tree_set — genetree.js did not tag them"
stage_end
