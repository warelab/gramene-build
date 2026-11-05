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

assert_mongo_min taxonomy "${TAXONOMY_MIN}"   # getAtlasData filters on subset:'gramene'

A="${MONGODB_REPO}/atlas"
WORK="${A}/tmp"
mkdir -p "${WORK}"
cd "${WORK}"
GXA=https://ftp.ebi.ac.uk/pub/databases/microarray/data/atlas/experiments
GXA_FTP=ftp://ftp.ebi.ac.uk/pub/databases/microarray/data/atlas/experiments

# https://ftp.ebi.ac.uk/ intermittently refuses or hangs while plain ftp:// to the SAME host
# answers and https://www.ebi.ac.uk/ is fine -- the ftp host's TLS listener, not our network.
# 15_ontologies carries the same fallback for InterPro, for the same reason.
#
# Without it this stage half-loads SILENTLY, which is worse than failing: the experiment and
# assay metadata comes from www.ebi.ac.uk and lands fine, while every per-experiment TSV fails,
# so experiments exist with no gene data at all and the gates below (experiments >= 1,
# expression >= 1000) still pass because the OTHER experiments carry them. That happened on
# 2026-11-04: 119 failed fetches, 50 of 381 experiments loaded with zero expression values, and
# the stage reported success. E-CURD-47 went from 132,359 samples >= 0.5 TPM in v4 to nothing.
# The assert_experiments_carried gate at the end of this stage is what catches it.
# Downloads to "$2.part" and renames only on success: curl -o truncates its target before it
# knows the transfer failed, which would destroy a good copy from an earlier run.
fetch_gxa() {   # $1 = path under the experiments dir, $2 = output file
  if curl -fsSL --max-time 900 "${GXA}/$1" -o "$2.part"; then
    mv "$2.part" "$2"; return 0
  fi
  warn "  $1: https failed, trying ftp"
  if curl -fsS --max-time 900 "${GXA_FTP}/$1" -o "$2.part"; then
    mv "$2.part" "$2"; return 0
  fi
  rm -f "$2.part"
  return 1
}

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
fetch_gxa assaygroupsdetails.tsv assaygroupsdetails.tsv \
  || die "could not fetch assaygroupsdetails.tsv over https or ftp -- check both
 https://ftp.ebi.ac.uk/ and ftp://ftp.ebi.ac.uk/ by hand before re-running."
fetch_gxa contrastdetails.tsv contrastdetails.tsv \
  || die "could not fetch contrastdetails.tsv over https or ftp."
assert_nonempty_file assaygroupsdetails.tsv

# getAtlasData emits curl commands for the per-experiment files AND inserts
# experiments+assays metadata. We rewrite each "curl -O URL" so already-downloaded
# non-empty files are skipped (resumable), then run them.
# Rewrite each emitted "curl -O <url>" so an already-downloaded non-empty file is skipped
# (resumable) and so a failed https attempt falls back to ftp on the same path, per fetch_gxa
# above. These run under `| bash`, which does not inherit shell functions, hence the inline form.
skip_existing='s#^curl -O https://ftp\.ebi\.ac\.uk(/[^ ]*/([^/]+))$#[ -s "\2" ] || curl -fsS -O "https://ftp.ebi.ac.uk\1" || curl -fsS -O "ftp://ftp.ebi.ac.uk\1"#'
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

# Report baseline assay groups whose TPM column is entirely zero. A TPM column sums to ~1e6 by
# construction, so an all-zero one is not a low-expression sample -- it is a group the upstream
# file carries no data for, and it renders in the expression widget as a real measurement of
# zero. Faithfully loaded either way; this exists so such a column is known from the build log
# rather than discovered through the UI.
#
# Reported, never fatal: the data is upstream's and correct for us to carry. E-CURD-1 g13
# (E-GEOD-49090, flower) is the one in grapevine v5 -- the only all-zero column in 1,896 baseline
# assay groups across 97 studies. Its sibling E-CURD-1 g19 is NOT caught here and should not be:
# that column sums to 1,000,001 and is a genuine library that happens to be 84% chloroplast, so
# every nuclear gene rounds to zero. Few expressed genes is a judgement call about the biology;
# a zero column is arithmetically impossible, which is why only the latter is checked.
#
# Tests the raw cell text rather than parsing quantiles, and stops testing a column once any
# non-zero cell is seen -- 11s over 980 MB, against 95s for a parse-every-field version.
shopt -s nullglob; TPMS_LIST=( ); for f in "${TSV_LIST[@]}"; do case "${f}" in *-tpms.tsv) TPMS_LIST+=("${f}");; esac; done; shopt -u nullglob
if [ "${#TPMS_LIST[@]}" -gt 0 ]; then
  log "checking baseline TPM columns for all-zero assay groups (${#TPMS_LIST[@]} files)"
  zero_cols="$(awk -F'\t' '
    FNR==1 { acc=FILENAME; sub(/-tpms\.tsv$/,"",acc); ncol=NF
             for(i=3;i<=NF;i++){ name[i]=$i; live[i]=0 }
             next }
    { for(i=3;i<=ncol;i++) if(!live[i] && $i !~ /^0(\.0+)?(,0(\.0+)?)*$/) live[i]=1 }
    ENDFILE { for(i=3;i<=ncol;i++) if(!live[i]) printf "%s %s\n", acc, name[i] }
  ' "${TPMS_LIST[@]}")"
  if [ -z "${zero_cols}" ]; then
    ok "no all-zero TPM columns"
  else
    warn "$(echo "${zero_cols}" | grep -c .) baseline assay group(s) have an all-zero TPM column"
    warn "  upstream carries no data for these; they will show as a zero column in the widget:"
    echo "${zero_cols}" | while read -r acc grp; do
      [ -n "${acc}" ] && warn "    ${acc} ${grp}"
    done
  fi
fi

# load expression data. parseData.js holds all experiments' expression in memory
# before insertMany, so it needs a big heap (8G OOMs on the full sorghum set).
ATLAS_HEAP="${ATLAS_HEAP:---max-old-space-size=49152}"
log "parsing expression TSVs into ${MONGO_DB}.expression (heap ${ATLAS_HEAP})"
"${NODE_BIN}" ${ATLAS_HEAP} "${A}/parseData.js" "${TSV_LIST[@]}"

# project expression across genome-annotation versions: Atlas keys some species'
# expression by an OLD assembly's gene IDs (e.g. poplar POPTR_*v3, grapevine VIT_,
# barley HORVU1Hr1) while this build's genes use the NEW IDs (Potri.*, Vitvi*,
# HORVU.MOREX.r3). new_old.lut.txt maps old->new; this clones each matching
# expression doc onto the new gene IDs so it attaches in mongo2solr.
#
# IDEMPOTENT, and safe to run on its own. This comment used to say "Insert-only, so it must run
# exactly once per (freshly loaded) expression collection", which stopped being true when the
# script moved to bulkWrite updateOne/$set with upsert:true (verified at its line 71, not taken
# from its header). The distinction matters in practice: the LUT is edited independently of this
# stage -- 957 medicago mappings were added on 2026-10-14, long after this stage's stamp was
# written on 2026-10-08, so make considers the stage done and never revisits it. Re-run just the
# projection with:
#   node --max-old-space-size=8192 ../gramene-mongodb/atlas/project_expression_via_lut.js \
#        ../gramene-mongodb/atlas/new_old.lut.txt
# Medicago had in fact never been projected: 0 docs keyed MtrunA17_* against 51,519 keyed on the
# Atlas MTR_* ids. On 2026-10-16 that run created 24,024, and 400 of 400 sampled join a gene.
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

# Every experiment record must be carried by at least one gene. Doc counts cannot see this:
# a study mostly WIDENS existing gene documents rather than creating new ones, so a study whose
# TSV never downloaded leaves a complete-looking experiments/assays entry and adds nothing to
# `expression`, while the collection total stays well above any threshold. This is the gate that
# catches a transport failure (see the fetch_gxa comment at the top of this stage); without it
# the only symptom is an empty expression widget, and the API 500s on it.
# Fatal on a full build. Incremental adds assert per-accession below, so here it only warns --
# an older study that was already empty before this run is not this run's fault.
assert_experiments_carried() {
  local out
  out="$(mongo_eval '
    const exps = db.experiments.find({}, {_id:1}).toArray().map(e => e._id);
    const bad = exps.filter(id => db.expression.countDocuments({[id]: {$exists: true}}, {limit:1}) === 0);
    print(bad.length + "|" + bad.join(","));
  ' | tr -d "\r")"
  local n="${out%%|*}" list="${out#*|}"
  if [ "${n:-0}" -eq 0 ]; then
    ok "all experiments carry gene data"
    return 0
  fi
  warn "${n} experiment(s) have NO gene expression data: ${list}"
  warn "  almost always a failed per-experiment TSV download. Re-fetch just those with:"
  warn "    make 55_atlas ATLAS_ADD=\"$(echo "${list}" | cut -d, -f1-5)...\""
  return 1
}
if [ "${INCREMENTAL}" = "0" ]; then
  assert_experiments_carried || die "atlas load is incomplete -- see the warnings above. The TSVs
 live in ${WORK}; a missing one re-downloads on re-run, an empty one must be deleted first."
else
  assert_experiments_carried || true
fi

# Incremental post-condition: every requested accession must now be present. The doc COUNT of
# `expression` is a poor signal here -- adding a study mostly widens existing gene documents rather
# than creating new ones -- so assert on the experiment records themselves.
if [ "${INCREMENTAL}" = "1" ]; then
  for acc in ${ADD_LIST}; do
    n="$(mongo_eval "db.experiments.countDocuments({_id:'${acc}'})")"
    [ "${n:-0}" -ge 1 ] || die "incremental add did not land ${acc} in experiments — it may not be an RNA-Seq experiment for a hosted genome"
    tx="$(mongo_eval "db.experiments.findOne({_id:'${acc}'}).taxon_id")"
    # ... and it must actually carry gene data. The experiment record alone lands even when the
    # per-experiment TSV never downloaded, which is exactly how 50 empty studies got here.
    g="$(mongo_eval "db.expression.countDocuments({'${acc}':{\$exists:true}})")"
    [ "${g:-0}" -ge 1 ] || die "incremental add landed the ${acc} experiment record but NO gene
 data -- its TSV almost certainly failed to download. Check ${WORK}/${acc}-*.tsv exists and is
 non-empty (delete a zero-length one so it re-downloads), and that both https://ftp.ebi.ac.uk/
 and ftp://ftp.ebi.ac.uk/ are reachable."
    ok "added ${acc} (taxon ${tx}, ${g} genes)"
    ledger_add atlas_studies "${acc}" "${tx}"
  done
fi
stage_end
