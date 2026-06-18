#!/usr/bin/env bash
# 20_variation — build the qtls collection from the ensembl variation db.
# dump_qtls.js is insert-only (no drop), so we DROP qtls first for idempotency.
# Requires the maps collection (system_name -> map._id join) -> run after 10_maps.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 20_variation

assert_mongo_min maps 100   # dump_qtls joins QTLs to maps by system_name

mongo_drop qtls
cd "${MONGODB_REPO}/variation"
run "${NODE_BIN}" dump_qtls.js

assert_mongo_min qtls 100
# guard against an accidental double-load (duplicate _id)
dupes="$(mongo_eval "db.qtls.aggregate([{\$group:{_id:'\$_id',c:{\$sum:1}}},{\$match:{c:{\$gt:1}}}]).toArray().length")"
[ "${dupes}" = "0" ] && ok "no duplicate qtls" || die "found duplicate qtl docs (${dupes}) — collection was not dropped"
stage_end
