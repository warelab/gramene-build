#!/usr/bin/env bash
# 66_rsid_suggestions — rebuild ONLY the "Variants: rsID" layer of the suggestions core, in place.
#
# Stage 65 recreates the whole core; this patches one category without touching the other 7.5M
# docs, for when the rsID inputs changed but nothing else did. Both paths share one generator
# (gramene-solr/suggestions/build_rsid_suggestions.sh), so they cannot drift.
#
# NOT cheap, despite being "partial": deleting 10M docs by query and re-adding 10M is a full
# rewrite of the layer (40-70 min) and leaves 10M deleted docs pending merge, transiently up to
# ~2x the layer's disk. This is why 62_attr_atomic.sh does NOT call it by default.
#
# usage: bash 66_rsid_suggestions.sh          (regenerates the jsonl, then reloads)
#        REGEN_RSID=0 bash 66_rsid_suggestions.sh   (reuse an existing jsonl)
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 66_rsid_suggestions

SUGG="${SOLR_REPO}/suggestions"
RSID_JSON="${RSID_SUGG_JSON:-/scratch/olson/rsid_projection/rsid_suggestions.jsonl}"
solr_core_exists "${SOLR_SUGG_CORE}" || die "${SOLR_SUGG_CORE} does not exist — run 65_solr_suggestions first"

if [ "${REGEN_RSID:-1}" = "1" ]; then
  log "generating rsID suggestions (file-based; see build_rsid_suggestions.sh for why not faceted)"
  bash "${SUGG}/build_rsid_suggestions.sh" "${RSID_JSON}"
else
  log "REGEN_RSID=0 — reusing ${RSID_JSON}"
fi
[ -s "${RSID_JSON}" ] || die "rsID suggestion file missing/empty: ${RSID_JSON}"
want=$(wc -l < "${RSID_JSON}")
log "rsID suggestion docs to load: ${want}"

sugg_count() {   # $1 = query
  curl -s -G "${SOLR_URL}/${SOLR_SUGG_CORE}/select" \
    --data-urlencode "q=$1" --data-urlencode rows=0 --data-urlencode wt=json \
    | grep -o '"numFound":[0-9]*' | head -1 | cut -d: -f2
}

before="$(sugg_count 'id:rsid_*')"
log "deleting ${before:-0} existing rsID suggestion docs (id:rsid_*)"
curl -s "${SOLR_URL}/${SOLR_SUGG_CORE}/update" -H 'Content-type:application/json' \
  --data-binary '{"delete":{"query":"id:rsid_*"}}' | grep -q '"status":0' \
  || die "delete of old rsID suggestions failed"
solr_commit "${SOLR_SUGG_CORE}"

# SKIP_DOCS is explicit and MUST be: solr_chunk_load.js derives its resume point from the WHOLE
# core's numFound, which is only correct for the first file into an empty core. Here the core
# already holds ~7.5M other docs, so auto-detection would skip that many lines of this file and
# load a fraction of it — silently, exit code 0. We just deleted the layer, so 0 is right.
# batch 5000 (not 10000): rsID docs are ~800 B vs ~240 B for gene docs, keeping the request body
# comparable. COMMIT_EVERY 100 => ~20 commits rather than 2000 searcher reopens.
SKIP_DOCS=0 SOLR_COMMIT_EVERY=100 solr_load_json_chunked "${SOLR_SUGG_CORE}" "${RSID_JSON}" 5000

after="$(sugg_count 'id:rsid_*')"
[ "${after:-0}" = "${want}" ] || die "rsID layer: ${after} docs after load, expected ${want}"
ok "rsID suggestion layer rebuilt: ${after} docs (was ${before:-0})"
stage_end
