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
need_dump=()
for name in "${!CMD[@]}"; do
  f="tmp/${name}.json.gz"
  want="${NUM[$name]:-0}"
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
stage_end
