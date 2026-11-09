#!/usr/bin/env bash
# 57_jgi_expression — load the JGI/Mullet sorghum expression study (the first non-EBI source)
# into the experiments / assays / expression collections.
#
# 55_atlas DROPS all three collections, so this MUST run after it; 58_expression_attributes
# derives from them, so this MUST run before that. Idempotent: accessions and group ids are
# assigned deterministically and every write is an upsert/merge, so re-running is a no-op.
#
# Sorghum-only by construction (the matrix is keyed by Phytozome Sbicolor v3.1.1 gene ids), so
# it skips cleanly on builds with no sorghum genes.
# Depends on: 50_genes_decorate (genes, for the Sobic->SORBI map) + 55_atlas.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 57_jgi_expression

# Target database. Defaults to the build's MONGO_DB, but this study is sorghum-only, so a
# subsite build targets its own db (e.g. JGI_TARGET_DB=sorghum11) without touching search<N>.
DB="${JGI_TARGET_DB:-${MONGO_DB}}"
URI="${MONGO_URI}/${DB}"
[ "${DB}" = "${MONGO_DB}" ] || log "targeting ${DB} (override of build db ${MONGO_DB})"

J="${MONGODB_REPO}/jgi"
WORK="${J}/tmp"
[ -d "${J}" ] || { warn "no ${J} — skipping JGI expression load"; stage_end; exit 0; }
command -v python3 >/dev/null || die "python3 required for the JGI loader"
mkdir -p "${WORK}"

n_sorghum="$("${MONGOSH}" --quiet "${URI}" --eval \
  'print(db.genes.countDocuments({system_name:"sorghum_bicolor"}))' 2>/dev/null || echo 0)"
if [ "${n_sorghum:-0}" -lt 1000 ]; then
  warn "only ${n_sorghum:-0} sorghum_bicolor genes — skipping JGI expression load"
  stage_end; exit 0
fi
MONGO_DB="${DB}" assert_mongo_min experiments 1   # 55_atlas must have run (it drops this collection)

# ── 1. source sheets ────────────────────────────────────────────────────────────────────────
# Published Google Sheets from the submitter. Cached: an existing non-empty file is reused, so
# re-runs are offline and a hand-edited local export is respected.
declare -A SHEET=(
  [samples.csv]=12AkmzQu42IVnI5R9m9u9-nG0jjA423j5DeACPOCqFxg
  [libraries.csv]=1SDRTtwx2Is58cmp2AkVfxFHlbUQvEejARgQY77i4lcI
  [tpm.csv]=1dkSV7SV6M-CPfkUUGNkge71GzwPlTnx_tJiOdVTCZOQ
)
for f in "${!SHEET[@]}"; do
  if [ -s "${WORK}/${f}" ]; then
    log "  reusing cached ${f} ($(wc -c <"${WORK}/${f}") bytes)"
  else
    log "  downloading ${f}"
    curl -sfL --max-time 600 \
      "https://docs.google.com/spreadsheets/d/${SHEET[$f]}/export?format=csv" \
      -o "${WORK}/${f}" || die "download of ${f} failed"
  fi
  assert_nonempty_file "${WORK}/${f}"
done

# ── 2. Sobic.* -> SORBI_3* map, straight from genes.alt_id ──────────────────────────────────
# Gramene already carries the Phytozome id as an alt_id, so no string munging is needed. The
# naive transform is applied only as an assertion.
log "building Sobic->SORBI map from genes.alt_id"
"${MONGOSH}" --quiet "${URI}" --eval '
  db.genes.find({system_name:"sorghum_bicolor", alt_id:/^Sobic\./},{alt_id:1}).forEach(function(g){
    g.alt_id.forEach(function(a){ if(/^Sobic\./.test(a)) print(a+"\t"+g._id); });
  });' > "${WORK}/sobic2sorbi.tsv" || die "Sobic->SORBI map query failed"
n_lut=$(grep -c . "${WORK}/sobic2sorbi.tsv" || true)
n_key=$(cut -f1 "${WORK}/sobic2sorbi.tsv" | sort -u | wc -l)
n_val=$(cut -f2 "${WORK}/sobic2sorbi.tsv" | sort -u | wc -l)
log "  ${n_lut} entries (${n_key} distinct Sobic, ${n_val} distinct SORBI)"
[ "${n_lut}" -ge 30000 ] || die "Sobic->SORBI map has only ${n_lut} entries — genes not decorated yet?"
[ "${n_lut}" = "${n_key}" ] && [ "${n_lut}" = "${n_val}" ] || die "Sobic->SORBI map is not 1:1"
awk -F'\t' '{d="SORBI_3" substr($1,7)} d!=$2 {print; n++} END{exit n?1:0}' "${WORK}/sobic2sorbi.tsv" \
  || die "alt_id disagrees with the Sobic->SORBI_3 transform (see lines above)"

# ── 3. experiments + assays ─────────────────────────────────────────────────────────────────
log "building experiments/assays from the metadata sheets + curator tables"
python3 "${J}/build_jgi_experiments.py" --dir "${WORK}" --out "${WORK}" || die "metadata build failed"
assert_nonempty_file "${WORK}/experiments.ndjson"
assert_nonempty_file "${WORK}/assays.ndjson"

for c in experiments assays; do
  log "  upserting ${c}"
  mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${DB}" -c "${c}" \
    --mode=upsert --upsertFields _id --file "${WORK}/${c}.ndjson" >/dev/null 2>&1 \
    || die "mongoimport of ${c}.ndjson failed"
done

# ── 4. expression ───────────────────────────────────────────────────────────────────────────
# --mode=merge adds the JGI-SB-* keys to the existing gene documents without disturbing the
# EBI keys already on them (and inserts a doc for any gene that had none).
log "parsing the TPM matrix"
python3 "${J}/parse_jgi_tpm.py" --dir "${WORK}" --out "${WORK}/expression_jgi.ndjson" \
  || die "TPM parse failed"
assert_nonempty_file "${WORK}/expression_jgi.ndjson"
log "  merging into ${DB}.expression"
mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${DB}" -c expression \
  --mode=merge --upsertFields _id --file "${WORK}/expression_jgi.ndjson" >/dev/null 2>&1 \
  || die "mongoimport of expression_jgi.ndjson failed"

# ── 5. assertions ───────────────────────────────────────────────────────────────────────────
read -r n_exp n_assay n_expr < <("${MONGOSH}" --quiet "${URI}" --eval '
  print(db.experiments.countDocuments({source:"JGI"}) + " " +
        db.assays.countDocuments({experiment:/^JGI-SB-/}) + " " +
        db.expression.countDocuments({"JGI-SB-1":{$exists:true}}));')
log "loaded: ${n_exp} experiments, ${n_assay} assays, ${n_expr} genes with JGI expression"
[ "${n_exp}"   -eq 4     ] || die "expected 4 JGI experiments, got ${n_exp}"
[ "${n_assay}" -eq 99    ] || die "expected 99 JGI assays, got ${n_assay}"
[ "${n_expr}"  -ge 30000 ] || die "only ${n_expr} genes carry JGI expression"

# every JGI assay must resolve to an organ, or it contributes to nothing downstream
log "checking organ resolution for the JGI assays"
( cd "${SOLR_REPO}/expression_pipeline" && python3 - "${WORK}/assays.ndjson" <<'PY'
import json, sys, collections, po_map
miss = collections.Counter()
for line in open(sys.argv[1]):
    a = json.loads(line)
    op = next((f for s in ("factor","characteristic") for f in (a.get(s) or [])
               if f.get("type") == "organism part"), None)
    if not po_map.organ_for(op.get("int_id") if op else None, op.get("label") if op else None):
        miss[op.get("label") if op else "<no organism part>"] += 1
if miss:
    print("UNRESOLVED organism parts: %s" % dict(miss), file=sys.stderr); sys.exit(1)
PY
) || die "some JGI assays resolve to no organ — fix jgi/tissue_po_map.tsv or po_map.py"

ok "JGI expression loaded (${n_assay} assays across ${n_exp} experiments)"
warn "expression_attributes is now stale — re-run 58_expression_attributes, then 60/62/65"
stage_end
