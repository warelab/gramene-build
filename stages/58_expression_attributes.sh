#!/usr/bin/env bash
# 58_expression_attributes — build the per-gene expression_attributes collection DIRECTLY
# from the mongo expression/assays/experiments/genes collections, using the mongo-native
# pipeline in gramene-solr/expression_pipeline/, then load mongo.expression_attributes.
#
# This collection feeds the solr-gene expr_* fields + Expression suggestion categories
# (stage 60_solr_genes / `make refresh-expression-attrs`). Genome coverage is auto-discovered
# from mongo (every genome that actually has data in the `expression` collection), so it
# tracks the build rather than a hand-maintained list.
#
# Depends on: 55_atlas (expression/assays/experiments) + 50_genes_decorate (genes).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 58_expression_attributes

# ── mode ────────────────────────────────────────────────────────────────────────────
# EXPR_ONLY="3702 4577" rebuilds ONLY those genomes' expression attributes, leaving every other
# genome's artifacts and collection documents untouched. Unset = rebuild everything.
#
# Genome-level (not gene-level) is the correct granularity: adding a study changes that genome's
# reference quantile distributions (ref_<taxon>.json), which changes scores for EVERY gene of that
# genome, not only the genes in the new study.
RUN_START="$(date +%s)"
ONLY_TAXA="$(csv_to_words "${EXPR_ONLY:-}")"
if [ -n "${ONLY_TAXA}" ]; then
  INCREMENTAL=1
  log "INCREMENTAL rebuild, taxa: ${ONLY_TAXA}"
  require_populated expression_attributes 1000 "make refresh-expression"
else
  INCREMENTAL=0
fi

assert_mongo_min genes 1000               # from 50_genes_decorate

# expression is optional (atlas may have found nothing for these species) — skip cleanly.
expr_docs="$(mongo_count expression)"
if [ "${expr_docs:-0}" -lt 1000 ]; then
  warn "expression collection has only ${expr_docs:-0} docs (run 55_atlas first?) — skipping expression_attributes"
  stage_end; exit 0
fi

PIPE="${SOLR_REPO}/expression_pipeline"
[ -d "${PIPE}" ] || die "expression_pipeline not found at ${PIPE}"
cd "${PIPE}"
command -v python3 >/dev/null || die "python3 required for the expression pipeline"

# Clear previous run artifacts so the build reflects CURRENT mongo data. Incrementally, clear ONLY
# the target taxa's caches/refs — this is what keeps the shared expression_panel.json complete.
# assemble_config.py rediscovers every genome from mongo and reads whatever ref_<taxon>.json are on
# disk, so leaving the other genomes' references in place is exactly what makes --only safe.
if [ "${INCREMENTAL}" = "1" ]; then
  # The OUTPUTS must go too, not just the caches. batch.py is resumable: it counts the lines
  # already in <short>_attributes.jsonl and appends from there (batch.py:49,53), so a complete
  # file from a previous run means it writes nothing at all -- the stage then "succeeds" and
  # imports stale attributes. Resolve taxon -> short from the CURRENT panel before removing it.
  SHORTS="$(ONLY_TAXA="${ONLY_TAXA}" python3 - <<'PY'
import json, os
only = [int(t) for t in os.environ["ONLY_TAXA"].split()]
out = []
try:
    sp = json.load(open("expression_panel.json"))["species"]
    m = {int(t): v["short"] for t, v in sp.items()}
except Exception:
    m = {}
if not m:
    import mongo_source
    g = mongo_source.discover_genomes(json.load(open("manifest.json")).get("genomes"))
    m = {x["taxon"]: x["short"] for x in g}
for t in only:
    if t in m: out.append(m[t])
print(" ".join(out))
PY
)"
  [ -n "${SHORTS}" ] || die "could not resolve a short name for taxa '${ONLY_TAXA}' — cannot clear their outputs safely"
  for t in ${ONLY_TAXA}; do
    log "  clearing cached artifacts for taxon ${t}"
    rm -f "./${t}.assays_cache.json" "./ref_${t}.json" "./inv_${t}.json" "./prog_${t}.json" 2>/dev/null || true
  done
  for sh in ${SHORTS}; do
    log "  clearing previous outputs for ${sh} (batch.py appends, so a stale JSONL would be reused)"
    rm -f "./${sh}_attributes.jsonl" "./${sh}_attributes.tsv" "./${sh}_attributes.json" 2>/dev/null || true
  done
  rm -f ./expression_panel.json 2>/dev/null || true   # reassembled from ALL surviving ref_*.json
  ONLY_ARG=(--only ${ONLY_TAXA})
else
  rm -f ./*.assays_cache.json ./ref_*.json ./inv_*.json ./prog_*.json \
        ./expression_panel.json ./*_attributes.jsonl ./*_attributes.tsv 2>/dev/null || true
  ONLY_ARG=()
fi

log "building expression attributes from mongo (${MONGO_DB}) via expression_pipeline/build.py"
MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" python3 build.py "${ONLY_ARG[@]}"

# ── INVARIANT: each genome's JSONL must be COMPLETE (one line per expression-bearing gene) ──
# Guards against silent stream truncation (see mongo_source._stream): a partial JSONL would ship
# an incomplete expression_attributes collection (this is exactly how maize once shipped 17,468 of
# 44,303). Compare each <short>_attributes.jsonl line count to the discovered genes-with-expression.
# INVARIANT: the rebuilt outputs must be newer than this run. batch.py resumes by appending to an
# existing JSONL, so a stale complete file is silently reused and the completeness check below --
# which only compares line counts -- would still pass. This is the same failure shape as the stale
# gene dumps in 40_genes_dump: well-formed, right size, wrong vintage.
if [ "${INCREMENTAL}" = "1" ]; then
  for sh in ${SHORTS}; do
    f="./${sh}_attributes.jsonl"
    [ -s "${f}" ] || die "expected ${f} after build.py --only ${ONLY_TAXA}"
    m="$(stat -c %Y "${f}")"
    [ "${m}" -ge "${RUN_START}" ] || die "${f} was NOT regenerated by this run (mtime $(date -d @${m} '+%F %T') predates the run) — batch.py resumed from a stale output instead of rebuilding"
    ok "  ${f} regenerated by this run"
  done
fi

log "verifying per-genome completeness (jsonl lines == genes-with-expression)"
MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" ONLY_TAXA="${ONLY_TAXA}" python3 - <<'PY' || die "expression_attributes completeness check FAILED — a genome's JSONL is short of its genes-with-expression (stream truncation?); do NOT ship this partial collection"
import json, os, sys, mongo_source
genomes = mongo_source.discover_genomes(json.load(open("manifest.json")).get("genomes"))
short = {int(t): sp["short"] for t, sp in json.load(open("expression_panel.json"))["species"].items()}
# Incrementally, only the rebuilt genomes are verified and re-imported; the others' JSONL files are
# left over from an earlier run and must NOT be re-imported (they would be redundant at best).
only = {int(t) for t in (os.environ.get("ONLY_TAXA") or "").split()}
if only:
    genomes = [g for g in genomes if g["taxon"] in only]
    if not genomes:
        print("no genome with expression data matches ONLY_TAXA=%s" % sorted(only)); sys.exit(1)
with open(".rebuilt_jsonl", "w") as fh:
    for g in genomes:
        fh.write(short.get(g["taxon"], g["system_name"]) + "_attributes.jsonl\n")
bad = 0
for g in genomes:
    s = short.get(g["taxon"], g["system_name"])
    jp = s + "_attributes.jsonl"
    have = sum(1 for _ in open(jp)) if os.path.exists(jp) else 0
    want = g["n_genes"]
    print("  %-28s jsonl=%-7d genes_with_expr=%-7d %s" % (s, have, want, "OK" if have == want else "MISMATCH"))
    bad += (have != want)
sys.exit(1 if bad else 0)
PY
ok "all genomes complete (jsonl == genes-with-expression)"

# fresh-load every per-genome JSONL into the expression_attributes collection (keyed on _id)
shopt -s nullglob
if [ "${INCREMENTAL}" = "1" ]; then
  mapfile -t files < .rebuilt_jsonl
  log "incremental: importing only the rebuilt genomes (${#files[@]}); expression_attributes NOT dropped"
else
  files=( *_attributes.jsonl )
  mongo_drop expression_attributes
fi
[ "${#files[@]}" -gt 0 ] || die "pipeline produced no *_attributes.jsonl"
lines=0
for f in "${files[@]}"; do
  [ -s "$f" ] || continue
  c="$(wc -l < "$f")"; lines=$((lines + c))
  log "  importing ${f} (${c} docs)"
  mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" \
    -c expression_attributes --mode upsert --file "$f" >/dev/null 2>&1 || die "mongoimport of ${f} failed"
done

got="$(mongo_count expression_attributes)"
log "expression_attributes loaded: ${got} docs (from ${lines} jsonl lines across ${#files[@]} genomes)"
[ "${got:-0}" -gt 1000 ] || die "expression_attributes has only ${got} docs after import"
ok "expression_attributes built from mongo (${#files[@]} genomes) + loaded"
stage_end
