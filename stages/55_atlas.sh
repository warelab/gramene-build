#!/usr/bin/env bash
# 55_atlas — EBI Expression Atlas: experiments, assays, expression collections.
# Enrichment stage (genes get an 'expression' capability in solr if present).
# All three atlas scripts are insert-only, so we DROP the 3 collections first.
# Requires taxonomy(subset:'gramene') to decide which experiments to keep.
#
# This stage does a lot of network IO (per-experiment TSVs). It is OPTIONAL for a
# first gene index; run it before 60_solr_genes to get expression into the index,
# or run it later and re-run 60_solr_genes.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 55_atlas

assert_mongo_min taxonomy 100   # getAtlasData filters on subset:'gramene'

A="${MONGODB_REPO}/atlas"
WORK="${A}/tmp"
mkdir -p "${WORK}"
cd "${WORK}"
GXA=https://ftp.ebi.ac.uk/pub/databases/microarray/data/atlas/experiments

# clean slate (all three are insert-only)
mongo_drop experiments; mongo_drop assays; mongo_drop expression

log "downloading assaygroup + contrast detail tables"
curl -fsSL "${GXA}/assaygroupsdetails.tsv" -o assaygroupsdetails.tsv
curl -fsSL "${GXA}/contrastdetails.tsv"    -o contrastdetails.tsv
assert_nonempty_file assaygroupsdetails.tsv

# getAtlasData emits curl commands for the per-experiment files AND inserts
# experiments+assays metadata. We rewrite each "curl -O URL" so already-downloaded
# non-empty files are skipped (resumable), then run them.
skip_existing='s#^curl -O (.*/([^/]+))$#[ -s "\2" ] || curl -fsS -O "\1"#'
log "fetching baseline experiment data + loading experiments/assays metadata"
"${NODE_BIN}" ${BIG_HEAP} "${A}/getAtlasData.js" assaygroupsdetails.tsv | sed -E "${skip_existing}" | bash
log "fetching differential experiment data"
"${NODE_BIN}" ${BIG_HEAP} "${A}/getAtlasData.js" contrastdetails.tsv | sed -E "${skip_existing}" | bash

ntsv="$(ls E-*.tsv 2>/dev/null | wc -l)"
log "downloaded ${ntsv} expression TSV files"
[ "${ntsv}" -gt 0 ] || { warn "no expression TSVs downloaded (no Atlas experiments for these species?) — skipping expression load"; stage_end; exit 0; }

# load expression data. parseData.js holds all experiments' expression in memory
# before insertMany, so it needs a big heap (8G OOMs on the full sorghum set).
ATLAS_HEAP="${ATLAS_HEAP:---max-old-space-size=49152}"
log "parsing expression TSVs into ${MONGO_DB}.expression (heap ${ATLAS_HEAP})"
"${NODE_BIN}" ${ATLAS_HEAP} "${A}/parseData.js" E-*.tsv

# project expression across genome-annotation versions: Atlas keys some species'
# expression by an OLD assembly's gene IDs (e.g. poplar POPTR_*v3, grapevine VIT_,
# barley HORVU1Hr1) while this build's genes use the NEW IDs (Potri.*, Vitvi*,
# HORVU.MOREX.r3). new_old.lut.txt maps old->new; this clones each matching
# expression doc onto the new gene IDs so it attaches in mongo2solr. Insert-only,
# so it must run exactly once per (freshly loaded) expression collection.
if [ -s "${A}/new_old.lut.txt" ]; then
  log "projecting expression onto re-versioned gene IDs (new_old.lut.txt)"
  "${NODE_BIN}" ${ATLAS_HEAP} "${A}/project_expression_via_lut.js" "${A}/new_old.lut.txt"
fi

# best-effort: merge baseline landingPageDisplayName as experiment 'name'.
# NB: use grep -H (always print the filename), NOT -h — the sed below extracts the
# experiment accession FROM the filename. With -h the lines have no filename, so the
# sed can't match and the lut comes out with whitespace keys + a 'landingPageDisplayName>'
# value prefix (which is exactly how `name` got lost).
if ls E-*-factors.xml >/dev/null 2>&1; then
  grep -H landingPageDisplayName E-*-factors.xml 2>/dev/null \
    | sed 's/-factors.*<landingPageDisplayName>/</' \
    | awk -F "<" 'NR==1{print "{"}NR>1{print ","}NR>0{print "\""$1"\":{\"name\":\""$2"\"}"}END{print "}"}' \
    > baseline_name_lut.json || true
  if [ -s baseline_name_lut.json ]; then
    mongoexport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c experiments 2>/dev/null \
      | "${NODE_BIN}" "${MONGODB_REPO}/search/merge_into_mongo_docs.js" -l "${WORK}/baseline_name_lut.json" \
      | mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c experiments --upsert 2>/dev/null || warn "experiment name merge failed (non-fatal)"
  fi
fi

assert_mongo_min experiments 1
assert_mongo_min expression 1000
stage_end
