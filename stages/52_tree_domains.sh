#!/usr/bin/env bash
# 52_tree_domains — push protein-domain architecture, taxa, transcript counts and
# exon junctions from the (now-built) genes collection onto gene-tree leaf nodes.
# Must run AFTER 50_genes_decorate (needs genes) and after 15_ontologies (domains).
# updateOne-based -> idempotent.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 52_tree_domains

assert_mongo_min genes 1000
assert_mongo_min genetree 1000
assert_mongo_min domains 1000

cd "${MONGODB_REPO}/trees"
run "${NODE_BIN}" ${BIG_HEAP} add_domains_to_tree.js

# Assert the decoration actually LANDED, per tree set -- not that the script ran.
#
# On 2026-10-16 this stage reported "updated 224000 trees" and exited 0 while doing nothing at all
# to 54,948 of them. add_domains_to_tree.js looked genes up by a hardcoded homology.gene_tree.id,
# but genetree_adder writes membership to homology.<set>.id, so every cultivar tree matched zero
# genes. Because each write is guarded by hasOwnProperty, the trees were simply re-saved unchanged:
# no domains, nTranscripts or exon_junctions on any cultivar leaf. Nothing in the stage noticed,
# and the bug was found only because someone asked whether cultivar trees got domains.
#
# So the check is per tree set, discovered from the data rather than hardcoded, and it samples
# randomly ($sample, not .limit(), which takes the biggest trees first and flatters the result).
#
# Thresholds against measured coverage (random 20 trees per set, 2026-10-16):
#   nTranscripts  100% in every set          -> floor 50%
#   domains       77-98% depending on set    -> floor 20% (genuinely varies: non-coding genes and
#                                               genes with no InterPro hit have no architecture)
# The failure mode being guarded is 0%, so both floors have wide margin and will not false-alarm.
log "asserting leaf decoration landed in every tree set"
dec="$(mongo --quiet "${MONGO_DB}" --eval '
  var out = [];
  db.genetree.distinct("tree_set").forEach(function (set) {
    if (!set) { return; }
    var leaves = 0, dom = 0, ntx = 0;
    db.genetree.aggregate([{$match: {tree_set: set}}, {$sample: {size: 20}}],
                          {allowDiskUse: true}).forEach(function (t) {
      (function walk(n) {
        if (!n.children || !n.children.length) {
          leaves++;
          if (n.domains) { dom++; }
          if (n.nTranscripts !== undefined) { ntx++; }
        } else { n.children.forEach(walk); }
      })(t);
    });
    out.push(set + ":" + leaves + ":" + dom + ":" + ntx);
  });
  print(out.sort().join(" "));
' 2>/dev/null | tail -1)"

[ -n "${dec}" ] || die "leaf-decoration probe returned nothing -- is ${MONGO_DB}.genetree populated?"
nsets=0
for entry in ${dec}; do
  set_name="${entry%%:*}"; rest="${entry#*:}"
  leaves="${rest%%:*}"; rest="${rest#*:}"
  dom="${rest%%:*}"; ntx="${rest##*:}"
  nsets=$(( nsets + 1 ))
  [ "${leaves:-0}" -gt 0 ] \
    || die "tree set '${set_name}': sampled 20 trees and found no leaves at all"
  ntx_pct=$(( 100 * ntx / leaves ))
  dom_pct=$(( 100 * dom / leaves ))
  log "  ${set_name}: leaves=${leaves} nTranscripts=${ntx} (${ntx_pct}%) domains=${dom} (${dom_pct}%)"
  [ "${ntx_pct}" -ge 50 ] \
    || die "tree set '${set_name}': only ${ntx_pct}% of leaves have nTranscripts (expect ~100%).\
 add_domains_to_tree.js looks genes up by homology.<tree_set>.id -- check that key exists on genes\
 and that indexCommands.txt has an index for it."
  [ "${dom_pct}" -ge 20 ] \
    || die "tree set '${set_name}': only ${dom_pct}% of leaves have domains (expect 77-98%)"
done
[ "${nsets}" -ge 1 ] || die "no tree sets found in ${MONGO_DB}.genetree"
ok "leaf decoration present in all ${nsets} tree sets"
stage_end
