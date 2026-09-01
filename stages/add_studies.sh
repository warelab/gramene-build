#!/usr/bin/env bash
# add_studies [ACCESSION[,ACCESSION...]] — INCREMENTAL addition of Expression Atlas studies.
#
#   make add-studies                                        # auto-discover new RNA-Seq studies
#   make add-studies ACCESSIONS="E-MTAB-8969,E-MTAB-10280"   # explicit
#   FORCE=1 make add-studies ACCESSIONS="E-MTAB-8969"        # re-load one already present
#
# A new study touches ONE genome, so this rebuilds only what that genome affects instead of the
# ~3 hours a full `make refresh-expression` costs (55: 19m, 58: 50m, 60: 103m, 65: 7m):
#
#   55_atlas   ATLAS_ADD=...   fetch + upsert just those experiments
#   56_maize   (only if maize is among the affected genomes; already idempotent)
#   58_attrs   EXPR_ONLY=...   rebuild only the affected genomes' expression attributes
#   62_atomic  expression      patch the genes core IN PLACE (no drop, no downtime) + expr suggestions
#
# The full path is unchanged and remains the right tool for a first build or a wholesale reload:
#   make refresh-expression
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin add_studies

ACC_IN="${1:-${ACCESSIONS:-}}"
A="${MONGODB_REPO}/atlas"

# ── 1. which studies? ────────────────────────────────────────────────────────────────
if [ -z "${ACC_IN}" ]; then
  log "no accessions given — discovering new RNA-Seq studies for hosted genomes"
  ACC_IN="$(MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" JSON=1 \
    "${NODE_BIN}" "${A}/check_new_atlas_experiments.js" 2>/dev/null \
    | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{console.log((JSON.parse(s).newHosted||[]).map(x=>x.accession).join(","))}catch(e){console.log("")}})')"
  [ -n "${ACC_IN}" ] || { ok "no new Atlas studies for the genomes in ${MONGO_DB} — nothing to do"; stage_end; exit 0; }
  log "discovered: ${ACC_IN}"
fi
WANTED="$(csv_to_words "${ACC_IN}")"

# ── 2. drop the ones already loaded (unless FORCE) ───────────────────────────────────
TODO=""
for acc in ${WANTED}; do
  have="$(mongo_eval "db.experiments.countDocuments({_id:'${acc}'})")"
  if [ "${have:-0}" -ge 1 ] && [ "${FORCE:-0}" != "1" ]; then
    warn "${acc} already loaded — skipping (FORCE=1 to re-load)"
  else
    TODO="${TODO} ${acc}"
  fi
done
TODO="$(csv_to_words "${TODO}")"
[ -n "${TODO}" ] || { ok "every requested study is already loaded — nothing to do"; stage_end; exit 0; }
log "studies to add: ${TODO}"

# ── baselines, for the summary at the end ────────────────────────────────────────────
B_EXP="$(mongo_count experiments)"; B_ASY="$(mongo_count assays)"
B_XPR="$(mongo_count expression)";  B_ATR="$(mongo_count expression_attributes)"
B_SOLR="$(solr_numdocs "${SOLR_GENES_CORE}")"

# ── 3. atlas: fetch + upsert only these experiments ──────────────────────────────────
ATLAS_ADD="$(echo "${TODO}" | tr ' ' ',')" bash "${BUILD_DIR}/stages/55_atlas.sh"

# ── 4. which genomes did that touch? ─────────────────────────────────────────────────
TAXA="$(affected_taxa ${TODO})"
[ -n "${TAXA}" ] || die "could not resolve any taxon for: ${TODO}"
log "affected genomes (taxon ids): ${TAXA}"

# maize differential needs the v4->v5 projection before attributes are scored
case " ${TAXA} " in *" 4577 "*) log "maize affected — running 56_project_maize_v4v5"
  bash "${BUILD_DIR}/stages/56_project_maize_v4v5.sh" ;; esac

# ── 5. expression attributes for those genomes only ──────────────────────────────────
EXPR_ONLY="${TAXA}" bash "${BUILD_DIR}/stages/58_expression_attributes.sh"

# ── 6. patch the genes core in place + rebuild the expr suggestion category ──────────
bash "${BUILD_DIR}/stages/62_attr_atomic.sh" expression

# ── 7. summary ───────────────────────────────────────────────────────────────────────
log "──────── incremental add complete ────────"
printf '  %-24s %10s -> %s\n' \
  "experiments"           "${B_EXP}"  "$(mongo_count experiments)" \
  "assays"                "${B_ASY}"  "$(mongo_count assays)" \
  "expression (docs)"     "${B_XPR}"  "$(mongo_count expression)" \
  "expression_attributes" "${B_ATR}"  "$(mongo_count expression_attributes)" \
  "solr ${SOLR_GENES_CORE}" "${B_SOLR}" "$(solr_numdocs "${SOLR_GENES_CORE}")" >&2
log "studies added: ${TODO}"
log "genomes rebuilt: ${TAXA}"
warn "note: 'expression' doc count barely moves — a new study mostly ADDS A FIELD to existing gene docs"
stage_end
