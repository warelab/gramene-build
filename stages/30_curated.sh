#!/usr/bin/env bash
# 30_curated — produce curated/curated.json (locus -> {sources}) used by genetree.js
# to bias representative-member selection toward curated genes.
# Sources: thalemine (Araport), rapdb mirror, and GeneRIFs in redis db ${REDIS_GENERIF_DB}.
# Output is a stdout redirect (fully idempotent overwrite).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 30_curated

gsz="$(redis_dbsize "${REDIS_GENERIF_DB}")"
if [ "${gsz:-0}" -eq 0 ]; then
  warn "redis db ${REDIS_GENERIF_DB} (GeneRIFs) is EMPTY — curated.json will have no generif sources."
  warn "load GeneRIFs first (see build/README.md 'GeneRIFs') if you want generif-backed curation."
else
  ok "redis db ${REDIS_GENERIF_DB} has ${gsz} GeneRIF keys"
fi

cd "${MONGODB_REPO}/curated"
run "${NODE_BIN}" get_curated.js > curated.json
assert_valid_json curated.json
loci="$("${NODE_BIN}" -e 'console.log(Object.keys(require("./curated.json")).length)')"
[ "${loci}" -ge 100 ] && ok "curated loci: ${loci}" || warn "curated.json has only ${loci} loci"
stage_end
