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

# clean previous run artifacts so the build reflects CURRENT mongo data (caches/refs/outputs)
rm -f ./*.assays_cache.json ./ref_*.json ./inv_*.json ./prog_*.json \
      ./expression_panel.json ./*_attributes.jsonl ./*_attributes.tsv 2>/dev/null || true

log "building expression attributes from mongo (${MONGO_DB}) via expression_pipeline/build.py"
MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" python3 build.py

# fresh-load every per-genome JSONL into the expression_attributes collection (keyed on _id)
shopt -s nullglob
files=( *_attributes.jsonl )
[ "${#files[@]}" -gt 0 ] || die "pipeline produced no *_attributes.jsonl"
mongo_drop expression_attributes
lines=0
for f in "${files[@]}"; do
  [ -s "$f" ] || continue
  c="$(wc -l < "$f")"; lines=$((lines + c))
  log "  importing ${f} (${c} docs)"
  mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" \
    -c expression_attributes --file "$f" >/dev/null 2>&1 || die "mongoimport of ${f} failed"
done

got="$(mongo_count expression_attributes)"
log "expression_attributes loaded: ${got} docs (from ${lines} jsonl lines across ${#files[@]} genomes)"
[ "${got:-0}" -gt 1000 ] || die "expression_attributes has only ${got} docs after import"
ok "expression_attributes built from mongo (${#files[@]} genomes) + loaded"
stage_end
