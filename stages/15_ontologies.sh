#!/usr/bin/env bash
# 15_ontologies — build GO, PO, TO (from OBO) and domains (from InterPro XML).
#   * GO/PO/TO via populate.js -> mongoimport --drop (idempotent).
#   * domains via parseInterpro.js which is insert-only, so we DROP it first.
#   * ancestor indexes via index.js.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 15_ontologies

ONT="${MONGODB_REPO}/ontologies"
cd "${ONT}"
mkdir -p tmp

# ---- InterPro domains ----
log "downloading InterPro ParentChildTreeFile + interpro.xml.gz"
curl -fsSL "https://ftp.ebi.ac.uk/pub/databases/interpro/current_release/ParentChildTreeFile.txt" -o tmp/ParentChildTreeFile.txt
curl -fsSL "https://ftp.ebi.ac.uk/pub/databases/interpro/current_release/interpro.xml.gz"          -o tmp/interpro.xml.gz
assert_nonempty_file tmp/ParentChildTreeFile.txt
assert_nonempty_file tmp/interpro.xml.gz

mongo_drop domains      # parseInterpro is insert-only; clear for a clean rebuild
log "parsing InterPro into ${MONGO_DB}.domains"
gzip -cd tmp/interpro.xml.gz | "${NODE_BIN}" ${BIG_HEAP} parseInterpro.js tmp/ParentChildTreeFile.txt /dev/fd/0

# ---- GO / PO / TO ----
# populate.js downloads each OBO, runs obo2json.pl, mongoimports with --drop.
log "building GO/PO/TO collections"
"${NODE_BIN}" populate.js -t tmp

# ---- ancestor-lookup indexes ----
log "creating ancestor indexes"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" index.js

assert_mongo_min GO 30000
assert_mongo_min PO 1000
assert_mongo_min TO 3000
assert_mongo_min domains 30000
stage_end
