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
ok "gene-tree leaf domains updated"
stage_end
