#!/usr/bin/env bash
# 56_project_maize_v4v5 — fold orphaned maize v4 (Zm00001d) differential expression onto the
# corresponding v5 (Zm00001eb) genes via the MaizeGDB id-history, so 58_expression_attributes
# scores it (activated_by/repressed_by). The genes collection's maize models are all v5, so the
# v4-keyed differential docs never join genes ⋈ expression and would otherwise be lost.
#
# Idempotent (only projects experiments not already on the v5 doc). Skips cleanly when there is no
# maize / no id-history table, so it's a harmless no-op for non-maize builds.
# Depends on: 55_atlas (expression collection loaded). Must run BEFORE 58_expression_attributes.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 56_project_maize_v4v5

LUT_DIR="${MONGODB_REPO}/search"
LUT="${LUT_DIR}/geneIDhistory.maizeV5"
if [ ! -s "${LUT}" ]; then
  log "no maize id-history (${LUT}) — skipping v4->v5 projection"
  stage_end; exit 0
fi
expr_docs="$(mongo_count expression)"
if [ "${expr_docs:-0}" -lt 1000 ]; then
  warn "expression collection has only ${expr_docs:-0} docs (run 55_atlas first?) — skipping v4->v5 projection"
  stage_end; exit 0
fi

# run from the id-history dir so the script reads geneIDhistory.maizeV5 relative to cwd
log "projecting maize v4 differential -> v5 genes via $(basename "${LUT}")"
( cd "${LUT_DIR}" && "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" "${BUILD_DIR}/project_maize_v4_to_v5.js" )

ok "maize v4->v5 differential projection complete"
stage_end
