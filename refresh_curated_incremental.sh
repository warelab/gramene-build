#!/usr/bin/env bash
# refresh_curated_incremental.sh — pick up new rows from the curation sheet and land them in the
# live index without a full rebuild.
#
# The sheet gains rows every month. A full 50 -> 60 -> 65 chain costs ~15h, which is the reason the
# feed sat frozen for two years, so this is the path that makes a monthly refresh routine:
#
#   1. regenerate cshl_curated_genes.json from the sheet (DOIs standardized to PMIDs)
#   2. diff it against the committed artifact, and stop if nothing changed
#   3. replay decorate.js's isGramene chain over the stage-40 dumps for the affected species and
#      write name / synonyms / curated literature into mongo for the changed genes only
#   4. recompute those genes' solr docs from the updated mongo and apply them as atomic updates
#   5. repair terms.tsv for the affected terms and rebuild the suggestions core
#
# Ontology-term changes are NOT applied by this path and are reported as a deferred remainder --
# ancestor_adder.js expands them during decorate and nothing here can reproduce that. They stay in
# the artifact and land at the next full rebuild. See curated_patch.js for the long version.
#
# Dry run by default. Nothing is written without --apply.
#
# usage: bash refresh_curated_incremental.sh [--apply] [--no-ncbi]
set -o pipefail
cd /usr/local/gramene/release70/build || exit 2

APPLY=""; NO_NCBI=""
for a in "$@"; do
  case "$a" in
    --apply)   APPLY="--apply" ;;
    --no-ncbi) NO_NCBI="--no-ncbi" ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

: "${MONGO_DB:=search70}"
: "${GENES_CORE:=http://localhost:8983/solr/genes70}"
export MONGO_DB

SEARCH=../gramene-mongodb/search
ARTIFACT="${SEARCH}/cshl_curated_genes.json"
SOLRDIR=../gramene-solr/genes
WORK="${CURATED_WORK:-/tmp/curated_refresh.$$}"
mkdir -p "$WORK" || exit 2
CHAIN=logs/chain.curated.log

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] REFRESH: $*" | tee -a "$CHAIN"; }
die(){ log "FATAL $*"; exit 1; }

log "================================================================"
log "incremental curated refresh  (${APPLY:-dry run})  work=${WORK}"

# --- 1. regenerate -----------------------------------------------------------------------------
log "---- regenerating the artifact from the sheet"
node fetch_cshl_curation.js $NO_NCBI > "${WORK}/new.json" 2> "${WORK}/fetch.err"
rc=$?
cat "${WORK}/fetch.err" | tee -a "$CHAIN"
[ $rc -eq 0 ] || die "fetch_cshl_curation.js exited ${rc} -- artifact NOT replaced"
# A truncated or empty artifact must never reach the build: curated_source.js would read it as "no
# curation" and a patch would then remove every curated reference in the index.
NEW_LOCI=$(node -e 'console.error(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length)' "${WORK}/new.json" 2>&1)
OLD_LOCI=$(node -e 'console.error(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length)' "$ARTIFACT" 2>&1)
log "artifact loci: ${OLD_LOCI} committed -> ${NEW_LOCI} regenerated"
case "$NEW_LOCI" in ''|*[!0-9]*) die "regenerated artifact is not a JSON array of entries" ;; esac
[ "$NEW_LOCI" -ge 500 ] || die "regenerated artifact has only ${NEW_LOCI} loci -- refusing (sheet fetch truncated?)"

# --- 2. diff and classify ----------------------------------------------------------------------
log "---- classifying the change"
node curated_diff.js "$ARTIFACT" "${WORK}/new.json" --json "${WORK}/delta.json" 2>&1 | tee -a "$CHAIN"
[ -s "${WORK}/delta.json" ] || die "curated_diff.js wrote no delta"

CHANGED=$(node -e 'console.error(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).counts.changed)' "${WORK}/delta.json" 2>&1)
if [ "$CHANGED" = "0" ]; then
  log "nothing changed -- the sheet holds no new curation. Done."
  exit 0
fi
log "${CHANGED} loci differ"

# Which species own the changed loci? Derived, not assumed: a curator can submit for any genome and
# hardcoding the four curated ones would silently skip a fifth.
node -e '
const fs=require("fs"), path=require("path");
const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const {MongoClient}=require(path.resolve("../gramene-mongodb/node_modules/mongodb"));
(async()=>{
  const c=new MongoClient("mongodb://localhost:27017",{useNewUrlParser:true,useUnifiedTopology:true});
  await c.connect();
  const rows=await c.db(process.env.MONGO_DB).collection("genes")
    .find({_id:{$in:d.loci}},{projection:{system_name:1}}).toArray();
  const sp=Array.from(new Set(rows.map(r=>r.system_name))).sort();
  fs.writeFileSync(process.argv[2], sp.join("\n")+"\n");
  fs.writeFileSync(process.argv[3], d.loci.join("\n")+"\n");
  console.error("species touched: "+sp.join(", "));
  console.error("loci resolved in the collection: "+rows.length+" of "+d.loci.length);
  await c.close();
})().catch(e=>{console.error("ERR "+e);process.exit(1);});
' "${WORK}/delta.json" "${WORK}/species.txt" "${WORK}/loci.txt" 2>&1 | tee -a "$CHAIN"
[ -s "${WORK}/species.txt" ] || die "could not determine which species changed"
SPECIES=$(tr '\n' ' ' < "${WORK}/species.txt")
log "species: ${SPECIES}"

# --- 3. install the artifact, then patch mongo -------------------------------------------------
# The artifact has to be on disk BEFORE the chain replay either way: curated.js reads it from the
# filesystem, and the replay is what computes "what a rebuild would produce". A dry run that left
# the old file in place would replay the old sheet and report no changes -- a dry run that always
# says "nothing to do" is worse than none.
#
# So it is installed in both modes, and a trap puts the committed file back unless we got all the
# way through an --apply. That ordering matters: an artifact newer than the index is exactly the
# drift this whole path exists to prevent, so an interrupted run must not leave one behind.
cp -p "$ARTIFACT" "${WORK}/committed.backup.json" || die "cannot back up the committed artifact"
RESTORE=1
restore_artifact(){
  if [ "$RESTORE" = "1" ] && [ -s "${WORK}/committed.backup.json" ]; then
    cp "${WORK}/committed.backup.json" "$ARTIFACT" \
      && log "restored the committed artifact (this run did not complete an --apply)"
  fi
}
trap restore_artifact EXIT
cp "${WORK}/new.json" "$ARTIFACT" || die "cannot install the new artifact"
log "installed the regenerated artifact for the replay (previous kept at ${WORK}/committed.backup.json)"

log "---- patching mongo (name, synonyms, curated literature)"
PATCH_OUT="${WORK}/patch.json" DEFERRED_OUT="${WORK}/deferred_ontology.json" \
  node curated_patch.js $SPECIES $APPLY 2>&1 | tee -a "$CHAIN"
rc=${PIPESTATUS[0]}
[ $rc -eq 0 ] || die "curated_patch.js exited ${rc} (2 = a field outside its scope changed; that needs a full decorate)"

if [ -z "$APPLY" ]; then
  log "dry run complete -- nothing was written. Re-run with --apply to write mongo, the core"
  log "and the suggestions. The committed artifact is about to be restored by the exit trap."
  exit 0
fi
# Past this point the index is being changed to match the new artifact, so the artifact must stay.
RESTORE=0

# --- 4. recompute the affected solr docs from the updated mongo --------------------------------
log "---- recomputing solr docs for ${CHANGED} genes"
# SOLR_TERMS_TSV is deliberately NOT set: mongo2solr.join.js only writes terms.tsv when it is, and
# a subset run would otherwise overwrite the real 1.1GB file with these few genes' terms.
( cd "$SOLRDIR" && SOLR_ID_FILTER="${WORK}/loci.txt" \
    node --max-old-space-size=4096 ./mongo2solr.join.js > "${WORK}/recomputed.json" ) 2>&1 | tee -a "$CHAIN"
[ -s "${WORK}/recomputed.json" ] || die "mongo2solr.join.js produced no output"

log "---- applying atomic updates to ${GENES_CORE}"
TERMS_DELTA="${WORK}/terms_delta.json" \
  node curated_patch_solr.js "$GENES_CORE" "${WORK}/recomputed.json" --apply 2>&1 | tee -a "$CHAIN"
rc=${PIPESTATUS[0]}
[ $rc -eq 0 ] || die "curated_patch_solr.js exited ${rc}"

# --- 5. terms.tsv + suggestions ----------------------------------------------------------------
log "---- repairing terms.tsv for the affected terms"
node curated_patch_terms.js "$GENES_CORE" "${SOLRDIR}/terms.tsv" "${WORK}/terms_delta.json" --apply 2>&1 | tee -a "$CHAIN"
rc=${PIPESTATUS[0]}
[ $rc -eq 0 ] || die "curated_patch_terms.js exited ${rc}"

log "---- rebuilding the suggestions core"
mt(){ [ -f ".state/$1.done" ] && stat -c %Y ".state/$1.done" || echo 0; }
B=$(mt 65_solr_suggestions)
rm -f .state/65_solr_suggestions.done
REGEN_AUX=1 REGEN_SUGGEST=1 make 65_solr_suggestions >> "$CHAIN" 2>&1
rc=$?
A=$(mt 65_solr_suggestions)
# make reads only mtimes, so a stage can "succeed" having done nothing. Assert it actually ran.
if [ "$A" -gt "$B" ]; then log "65 stamp advanced ${B} -> ${A}"; else die "65 stamp did not advance"; fi
[ $rc -eq 0 ] || die "65_solr_suggestions exited ${rc}"

DEF=0
[ -s "${WORK}/deferred_ontology.json" ] && DEF=$(node -e 'try{const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.error(d.genes.reduce((n,g)=>n+g.terms.length,0))}catch(e){console.error(0)}' "${WORK}/deferred_ontology.json" 2>&1)
log "DONE rc=0 -- ${CHANGED} loci refreshed; ${DEF} ontology terms deferred to the next full decorate"
log "  commit ${ARTIFACT} and ${SEARCH}/curation_pmid_map.tsv to record this refresh"
exit 0
