#!/usr/bin/env bash
# 40_genes_dump — dump per-genome gene docs from the ensembl cores into
# search/tmp/<system_name>.json.gz, one file per genome listed in maps.
#
# Robustness vs the old recipe:
#   * RESUMABLE: a genome whose gz already exists, is a valid gzip, and whose
#     line count already equals maps.num_genes is SKIPPED — so a re-run only
#     re-dumps what's missing/short (the old recipe re-dumped everything).
#   * THROTTLED: runs DUMP_PARALLELISM dumps at once instead of all 125.
#   * GATED: ends with compare_gz_lines_vs_num_genes.js (DB_NAME pinned to the
#     target db, which the script otherwise defaults to the PREVIOUS release) so
#     a truncated dump (OOM / dropped mysql conn) is caught HERE, not 3 stages
#     later as missing genes.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 40_genes_dump

SEARCH="${MONGODB_REPO}/search"
cd "${SEARCH}"
mkdir -p tmp

# name -> num_genes (the sanity target set during the maps stage)
log "loading per-genome gene counts from ${MONGO_DB}.maps"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval \
  'db.maps.find({type:"genome"},{system_name:1,num_genes:1}).forEach(g=>print(g.system_name+"\t"+(g.num_genes||0)))' \
  > tmp/_num_genes.tsv
declare -A NUM
while IFS=$'\t' read -r name n; do NUM["$name"]="$n"; done < tmp/_num_genes.tsv
log "genomes to dump: ${#NUM[@]}"

# generate the exact dump commands (createDumpCommandsfromCores now exits cleanly)
"${NODE_BIN}" createDumpCommandsfromCores.js > tmp/_dump_cmds.txt
# pair up: `echo "name"` line followed by its dump command
declare -A CMD
cur=""
while IFS= read -r line; do
  if [[ "$line" =~ ^echo\ \"(.*)\"$ ]]; then cur="${BASH_REMATCH[1]}";
  elif [[ -n "$cur" ]]; then CMD["$cur"]="$line"; cur=""; fi
done < tmp/_dump_cmds.txt

# decide which genomes still need dumping (resumable)
# NB: a dump is also stale whenever maps has been rebuilt since it was written. Each gene doc
# embeds taxon_id, and the synthetic per-genome taxon ids are REASSIGNED when the genome set
# changes (dropping 3 duplicate cores shifted 78 of 128 genomes by one). The gene COUNTS are
# unchanged in that case, so the line-count check below cannot see it -- the resulting dumps
# carry taxon ids belonging to other genomes and decorate wedges partway through. Compare
# against the maps stamp so this dependency is enforced rather than assumed.
# ${STATE_DIR}, NOT ".state": this stage has already cd'd to ${SEARCH}, where no .state
# directory exists, so the relative path made `[ -f "${MAPS_STAMP}" ]` false on every run and the
# staleness guard the comment above describes never fired once. The dumps it was meant to
# invalidate -- ones carrying another genome's reassigned taxon_id -- would have sailed through.
MAPS_STAMP="${STATE_DIR}/10_maps.done"
need_dump=()
for name in "${!CMD[@]}"; do
  f="tmp/${name}.json.gz"
  want="${NUM[$name]:-0}"
  if [ -s "$f" ] && [ -f "${MAPS_STAMP}" ] && [ "${MAPS_STAMP}" -nt "$f" ]; then
    need_dump+=("$name"); continue          # maps newer than the dump -> taxon ids may have moved
  fi
  if [ -s "$f" ] && gzip -t "$f" 2>/dev/null; then
    have="$(zcat "$f" 2>/dev/null | wc -l)"
    if [ "$have" = "$want" ] && [ "$want" -gt 0 ]; then continue; fi
  fi
  need_dump+=("$name")
done
log "already complete: $(( ${#CMD[@]} - ${#need_dump[@]} ))/${#CMD[@]}; to (re)dump: ${#need_dump[@]}"

# throttled parallel dump
P="${DUMP_PARALLELISM}"
running=0
for name in "${need_dump[@]}"; do
  log "dumping ${name} (expect ${NUM[$name]:-?} genes)"
  bash -c "${CMD[$name]}" &
  running=$((running+1))
  if [ "$running" -ge "$P" ]; then wait -n; running=$((running-1)); fi
done
wait
ok "all dump jobs finished"

# ---- the critical gate: line counts must match maps.num_genes ----
log "validating dumps against maps.num_genes (DB_NAME=${MONGO_DB})"
DB_NAME="${MONGO_DB}" MONGO_URI="${MONGO_URI}" COLLECTION=maps \
  "${NODE_BIN}" compare_gz_lines_vs_num_genes.js "${SEARCH}/tmp" | tee tmp/_dump_check.txt
if grep -qiE "MISMATCH|NO_MONGO_DOC|w/o file|[^0] (mismatch|missing)" tmp/_dump_check.txt; then
  warn "dump check reported discrepancies — inspect tmp/_dump_check.txt"
fi

# ---- second gate: the taxon_id embedded in each dump must match maps ----
# Line counts can't see a taxon reshuffle (same gene count, different synthetic taxon id), and a
# gene carrying another genome's taxon_id poisons every taxon-keyed lookup in decorate. Assert it.
log "validating dump taxon_id against maps.taxon_id"
MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" TMPDIR_GENES="${SEARCH}/tmp" \
"${NODE_BIN}" -e '
const {execSync}=require("child_process"); const fs=require("fs");
const dir=process.env.TMPDIR_GENES;
const out=execSync(`mongosh --quiet "${process.env.MONGO_URI}/${process.env.MONGO_DB}" --eval `+
  `\x27db.maps.find({},{system_name:1,taxon_id:1}).forEach(function(m){print(m.system_name+"\\t"+m.taxon_id)})\x27`,
  {maxBuffer:1e9}).toString().trim();
const maps={}; out.split("\n").forEach(l=>{const [s,t]=l.split("\t"); if(s) maps[s]=+t;});
let bad=[], checked=0;
for (const f of fs.readdirSync(dir).filter(f=>f.endsWith(".json.gz"))) {
  const sys=f.replace(/\.json\.gz$/,"");
  if (maps[sys]===undefined) continue;
  let line=""; try { line=execSync(`zcat ${dir}/${f} | head -1`,{maxBuffer:1e8}).toString(); } catch(e){ continue; }
  if (!line.trim()) continue;
  const g=JSON.parse(line); checked++;
  if (g.taxon_id !== maps[sys]) bad.push(`${sys}: dump=${g.taxon_id} maps=${maps[sys]}`);
}
console.log(`checked ${checked} dumps; ${bad.length} taxon mismatches`);
bad.slice(0,10).forEach(b=>console.log("  "+b));
process.exit(bad.length ? 1 : 0);
' || die "dump taxon_id does not match maps — the dumps are stale, delete search/tmp/*.json.gz and re-run 40_genes_dump"
ok "dump taxon_id matches maps"

# ---- third gate: no gene stable id may be claimed by two genomes ----
# <db>.genes keys on the gene stable id (and so does the Solr core), so if two genomes claim the
# same one the second write silently replaces the first and the totals still look plausible. Two
# pairs did this in v70, and one of them shipped in r69 -- reference wheat serves 17,705 of its
# 120,744 genes there because triticum_aestivum_alchemy's core used the reference's TraesCS*
# namespace. The dumps are the first place every gene id exists locally, so this is the earliest
# point the check is cheap; the alternative was finding out nine minutes into the decorate.
log "checking for gene stable id collisions across genomes"
# ${BUILD_DIR}/tmp is the sort scratch dir. It must be created here: git does not track empty
# directories, so a release root cut by CLONING (rather than cp -r from an existing one) has no
# build/tmp at all, and check_stable_id_collisions.sh then fails inside mktemp. That failure
# arrives as a non-zero exit and so was reported by the die below as "gene stable id collisions" --
# sending you to hunt for collisions that do not exist. The mkdir is the fix; the message below now
# says what else could have gone wrong.
mkdir -p "${BUILD_DIR}/tmp" || die "cannot create the sort scratch dir ${BUILD_DIR}/tmp"
SORT_TMP="${SORT_TMP:-${BUILD_DIR}/tmp}" SORT_MEM="${STABLE_ID_SORT_MEM:-4G}" \
  STABLE_ID_COLLISION_ALLOW="${STABLE_ID_COLLISION_ALLOW:-}" \
  bash "${SEARCH}/check_stable_id_collisions.sh" "${SEARCH}/tmp" \
  || die "check_stable_id_collisions.sh failed. Usually that IS a real collision -- fix the source
 core, or record the decision in STABLE_ID_COLLISION_ALLOW. But the script also exits non-zero if it
 cannot write to SORT_TMP (${SORT_TMP:-${BUILD_DIR}/tmp}) or cannot read the dumps in ${SEARCH}/tmp,
 so check the output above for a mktemp/permission error before going looking for colliding ids."
ok "no blocking gene stable id collisions"
stage_end
