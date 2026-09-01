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

# ── mode ────────────────────────────────────────────────────────────────────────────
# ATLAS_ADD="E-MTAB-8969,E-MTAB-10280" switches this stage to an INCREMENTAL add: fetch and load
# only those experiments, leaving everything already loaded in place. Unset = the full rebuild.
# The stage never guesses which mode is wanted; incremental validates its preconditions and dies
# naming the full target if they do not hold.
ADD_LIST="$(csv_to_words "${ATLAS_ADD:-}")"
if [ -n "${ADD_LIST}" ]; then
  INCREMENTAL=1
  log "INCREMENTAL add of: ${ADD_LIST}"
  require_populated expression  1000 "make refresh-expression"
  require_populated experiments 1    "make refresh-expression"
else
  INCREMENTAL=0
fi

assert_mongo_min taxonomy 100   # getAtlasData filters on subset:'gramene'

A="${MONGODB_REPO}/atlas"
WORK="${A}/tmp"
mkdir -p "${WORK}"
cd "${WORK}"
GXA=https://ftp.ebi.ac.uk/pub/databases/microarray/data/atlas/experiments

# Clean slate for a FULL rebuild. The loaders are upsert-based now, so this is no longer required
# for correctness -- it just guarantees no stale experiment survives a full run.
if [ "${INCREMENTAL}" = "0" ]; then
  mongo_drop experiments; mongo_drop assays; mongo_drop expression
else
  log "incremental: keeping existing experiments/assays/expression"
fi

# build the descendant->genome taxon remap (from compara ncbi_taxa_node) so getAtlasData keeps
# experiments tagged with a subspecies/cultivar taxon below a genome (remapping them to the genome
# taxon). Non-fatal: getAtlasData falls back to its static map if this file is absent.
log "building descendant->genome taxon remap from ${COMPARA_DB}"
"${NODE_BIN}" "${A}/build_taxon_remap.js" || warn "taxon remap build failed (non-fatal; getAtlasData uses static map)"

log "downloading assaygroup + contrast detail tables"
curl -fsSL "${GXA}/assaygroupsdetails.tsv" -o assaygroupsdetails.tsv
curl -fsSL "${GXA}/contrastdetails.tsv"    -o contrastdetails.tsv
assert_nonempty_file assaygroupsdetails.tsv

# getAtlasData emits curl commands for the per-experiment files AND inserts
# experiments+assays metadata. We rewrite each "curl -O URL" so already-downloaded
# non-empty files are skipped (resumable), then run them.
skip_existing='s#^curl -O (.*/([^/]+))$#[ -s "\2" ] || curl -fsS -O "\1"#'
ONLY_ENV=""
[ "${INCREMENTAL}" = "1" ] && ONLY_ENV="$(echo "${ADD_LIST}" | tr ' ' ',')"
log "fetching baseline experiment data + loading experiments/assays metadata"
ONLY="${ONLY_ENV}" "${NODE_BIN}" ${BIG_HEAP} "${A}/getAtlasData.js" assaygroupsdetails.tsv | sed -E "${skip_existing}" | bash
log "fetching differential experiment data"
ONLY="${ONLY_ENV}" "${NODE_BIN}" ${BIG_HEAP} "${A}/getAtlasData.js" contrastdetails.tsv | sed -E "${skip_existing}" | bash

# Which TSVs to load: everything for a full run, only the added accessions incrementally.
TSV_LIST=()
if [ "${INCREMENTAL}" = "1" ]; then
  for acc in ${ADD_LIST}; do
    for f in "${acc}-tpms.tsv" "${acc}-analytics.tsv"; do
      [ -s "${f}" ] && TSV_LIST+=("${f}")
    done
  done
  [ "${#TSV_LIST[@]}" -gt 0 ] || die "no expression TSV downloaded for: ${ADD_LIST} — are those accessions RNA-Seq experiments for a hosted genome? (check with atlas/check_new_atlas_experiments.js)"
else
  shopt -s nullglob; TSV_LIST=( E-*.tsv ); shopt -u nullglob
fi
ntsv="${#TSV_LIST[@]}"
log "expression TSV files to load: ${ntsv}"
[ "${ntsv}" -gt 0 ] || { warn "no expression TSVs downloaded (no Atlas experiments for these species?) — skipping expression load"; stage_end; exit 0; }

# load expression data. parseData.js holds all experiments' expression in memory
# before insertMany, so it needs a big heap (8G OOMs on the full sorghum set).
ATLAS_HEAP="${ATLAS_HEAP:---max-old-space-size=49152}"
log "parsing expression TSVs into ${MONGO_DB}.expression (heap ${ATLAS_HEAP})"
"${NODE_BIN}" ${ATLAS_HEAP} "${A}/parseData.js" "${TSV_LIST[@]}"

# project expression across genome-annotation versions: Atlas keys some species'
# expression by an OLD assembly's gene IDs (e.g. poplar POPTR_*v3, grapevine VIT_,
# barley HORVU1Hr1) while this build's genes use the NEW IDs (Potri.*, Vitvi*,
# HORVU.MOREX.r3). new_old.lut.txt maps old->new; this clones each matching
# expression doc onto the new gene IDs so it attaches in mongo2solr. Insert-only,
# so it must run exactly once per (freshly loaded) expression collection.
if [ -s "${A}/new_old.lut.txt" ]; then
  log "projecting expression onto re-versioned gene IDs (new_old.lut.txt)"
  if [ "${INCREMENTAL}" = "1" ]; then
    "${NODE_BIN}" ${ATLAS_HEAP} "${A}/project_expression_via_lut.js" --only "${ONLY_ENV}" "${A}/new_old.lut.txt"
  else
    "${NODE_BIN}" ${ATLAS_HEAP} "${A}/project_expression_via_lut.js" "${A}/new_old.lut.txt"
  fi
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

# Incremental post-condition: every requested accession must now be present. The doc COUNT of
# `expression` is a poor signal here -- adding a study mostly widens existing gene documents rather
# than creating new ones -- so assert on the experiment records themselves.
if [ "${INCREMENTAL}" = "1" ]; then
  for acc in ${ADD_LIST}; do
    n="$(mongo_eval "db.experiments.countDocuments({_id:'${acc}'})")"
    [ "${n:-0}" -ge 1 ] || die "incremental add did not land ${acc} in experiments — it may not be an RNA-Seq experiment for a hosted genome"
    tx="$(mongo_eval "db.experiments.findOne({_id:'${acc}'}).taxon_id")"
    ok "added ${acc} (taxon ${tx})"
    ledger_add atlas_studies "${acc}" "${tx}"
  done
fi
stage_end
