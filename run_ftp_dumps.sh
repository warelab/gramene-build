#!/usr/bin/env bash
# run_ftp_dumps.sh — FASTA / GFF3 / BLAST dumps for every release70 core, in parallel shards.
#
#   ./run_ftp_dumps.sh OUT_DIR [NSHARDS=8] [extra ensure_ftp_dumps.pl args, e.g. --dry]
#
# Splits reg.cores.pm (node make_reg_pm.js --cores-only) into NSHARDS registry files, balanced
# by toplevel bp + protein-coding genes (largest-first greedy), and runs one
# ensure_ftp_dumps.pl per shard in the background. Logs: RUN_DIR/logs/shard.<i>.log
# Re-running is safe: ensure_ftp_dumps.pl skips any file that already exists and is non-empty.
#
# Shard i runs its genomes ascending by size if i is odd and descending if i is even, so the
# multi-Gb wheat chromosomes (big in-memory strings) are not all being masked at once.
set -euo pipefail

OUT_DIR="${1:?usage: $0 OUT_DIR [NSHARDS] [extra args]}"; shift
NSHARDS="${1:-8}"; [ $# -gt 0 ] && shift
EXTRA=("$@")
RUN_DIR="${RUN_DIR:-${OUT_DIR}/ftp_dump_run.r70}"   # shard registries, sizes, logs, pids

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REG="${BUILD_DIR}/reg.cores.pm"
DUMP_DIR="/usr/local/gramene/gramene-ensembl/scripts/dump-scripts"   # script does `use lib '.'`
ENSROOT="${ENSROOT:-/usr/local/ensembl-115}"
export PERL5LIB="${ENSROOT}/bioperl-live:${ENSROOT}/ensembl/modules:${ENSROOT}/ensembl-io/modules"

mkdir -p "${RUN_DIR}/logs" "${RUN_DIR}/shards"
node "${BUILD_DIR}/make_reg_pm.js" --cores-only > "${REG}"

# --- genome sizes from the cores themselves ---------------------------------
SIZES="${RUN_DIR}/shards/sizes.tsv"
read -r MHOST MUSER MPASS < <(node -e 'const i=require(process.argv[1]);const c=i.cores[0];console.log(c.host,c.user,c.password||"")' "${BUILD_DIR}/../gramene-mongodb/ensembl_db_info.json")
if [ ! -s "${SIZES}" ]; then
  grep -o 'dbname  => "[^"]*"' "${REG}" | cut -d'"' -f2 | while read -r db; do
    mysql -h "$MHOST" -u "$MUSER" -p"$MPASS" -N -B "$db" -e "
      select '$db',
        (select ifnull(sum(sr.length),0) from seq_region sr join seq_region_attrib a using(seq_region_id)
           join attrib_type t using(attrib_type_id) where t.code='toplevel'),
        (select count(*) from gene where biotype='protein_coding')" 2>/dev/null
  done > "${SIZES}.tmp"
  mv "${SIZES}.tmp" "${SIZES}"
fi
[ "$(wc -l < "${SIZES}")" -eq "$(grep -c "group   => 'core'" "${REG}")" ] || { echo "FATAL: sizes.tsv incomplete" >&2; exit 1; }

# cost ~ 1 unit per 30 kb of sequence + 1 unit per gene (measured ~30 ms/gene)
awk -F'\t' -v n="${NSHARDS}" '{print $1"\t"($2/30000+$3)}' "${SIZES}" | sort -t$'\t' -k2,2gr |
awk -F'\t' -v n="${NSHARDS}" -v d="${RUN_DIR}/shards" '
  { b=0; for(i=1;i<n;i++) if(load[i]<load[b]) b=i; load[b]+=$2; print $1"\t"$2 > (d"/shard."b".list") }
  END { for(i=0;i<n;i++) printf "shard %d cost %.0f\n", i, load[i] > "/dev/stderr" }'

# --- one registry file per shard ---------------------------------------------
for ((i=0; i<NSHARDS; i++)); do
  list="${RUN_DIR}/shards/shard.${i}.list"
  if (( i % 2 )); then order=(-k2,2g); else order=(-k2,2gr); fi
  sort -t$'\t' "${order[@]}" "$list" | cut -f1 > "${list}.ordered"
  awk -v L="${list}.ordered" '
    BEGIN { while ((getline l < L) > 0) { ord[++n]=l } }
    /^Bio::EnsEMBL::DBSQL::DBAdaptor->new\(/ { buf=$0; inb=1; next }
    inb { buf=buf"\n"$0; if ($0 ~ /^\);/) { inb=0; match(buf, /dbname  => "[^"]*"/); db=substr(buf,RSTART+12,RLENGTH-13); st[db]=buf } next }
    /^# ----/ || /^1;$/ { next }
    { print }
    END { for (k=1;k<=n;k++) { if (!(ord[k] in st)) { print "MISSING " ord[k] > "/dev/stderr"; exit 1 } print st[ord[k]]"\n" } print "1;" }
  ' "${REG}" > "${RUN_DIR}/shards/reg.shard.${i}.pm"
  perl -c "${RUN_DIR}/shards/reg.shard.${i}.pm" 2>/dev/null || { echo "FATAL: bad shard registry $i" >&2; exit 1; }
done
total=$(cat "${RUN_DIR}"/shards/shard.*.list.ordered | sort -u | wc -l)
echo "sharded ${total} cores into ${NSHARDS} registries under ${RUN_DIR}/shards"

# --- launch -------------------------------------------------------------------
cd "${DUMP_DIR}"
pids=()
for ((i=0; i<NSHARDS; i++)); do
  # setsid: each shard is its own process group, so the watchdog can pause it together with
  # its bgzip / makeblastdb children.
  setsid perl ensure_ftp_dumps.pl -r "${RUN_DIR}/shards/reg.shard.${i}.pm" --out_dir "${OUT_DIR}" --verbose "${EXTRA[@]}" \
    > "${RUN_DIR}/logs/shard.${i}.log" 2>&1 &
  pids+=($!)
done
printf '%s\n' "${pids[@]}" > "${RUN_DIR}/logs/shard.pids"
echo "started ${NSHARDS} shards: ${pids[*]}"

# --- disk watchdog: OUT_DIR is on a filesystem shared with live services. Below MIN_FREE_GB
# every shard is SIGSTOPped (not killed) and stays paused; free space, then resume with
#   kill -CONT -- -<pid>   for each pid in logs/shard.pids
MIN_FREE_GB="${MIN_FREE_GB:-100}"
(
  while sleep 60; do
    alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" -eq 1 ] || exit 0
    free_gb=$(df -BG --output=avail "${OUT_DIR}" | tail -1 | tr -dc 0-9)
    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
      for p in "${pids[@]}"; do kill -STOP -- "-$p" 2>/dev/null || true; done
      echo "$(date -Is) PAUSED all shards: ${free_gb} GB free < ${MIN_FREE_GB} GB" | tee -a "${RUN_DIR}/logs/watchdog.log"
      exit 0
    fi
  done
) &
rc=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then echo "shard $i ok"; else echo "shard $i FAILED (see logs/shard.$i.log)"; rc=1; fi
done
exit $rc
