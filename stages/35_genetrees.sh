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

mongo_drop genetree
cd "${MONGODB_REPO}/trees"
run "${NODE_BIN}" ${BIG_HEAP} genetree.js

# index so downstream can pull just this release's trees
mongo_eval "db.genetree.createIndex({compara_db:1})" >/dev/null
ok "compara_db index created"

assert_mongo_min genetree 1000
total="$(mongo_count genetree)"
tagged="$(mongo_eval "db.genetree.countDocuments({compara_db:'${COMPARA_DB}'})")"
[ "${total}" = "${tagged}" ] && ok "all ${total} trees tagged compara_db=${COMPARA_DB}" \
  || warn "only ${tagged}/${total} trees tagged with this compara_db"
stage_end
