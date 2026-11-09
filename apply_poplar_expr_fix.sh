#!/usr/bin/env bash
# apply_poplar_expr_fix.sh — retarget Atlas poplar expression from the v3 gene-id form
# (Potri.<locus>) to this release's v4 genes (Potri.<locus>.v4.1), then rebuild the
# expression attributes + solr genes/suggestions so the `expression` capability attaches.
#
# Poplar was upgraded v3->v4 in r11, but new_old.lut.txt still targeted the old id form,
# so the 41k POPTR_*v3 Atlas docs projected onto Potri.<locus> (no v4) which match 0 genes.
# Coverage of the corrected mapping is 100% (30924/30924 loci -> a real v4 gene).
#
# Safe to run ONLY after `make all` has fully completed (checks the stamps below).
set -euo pipefail
cd "$(dirname "$0")"
. ./config.sh
. ./lib.sh
A="${MONGODB_REPO}/atlas"
POPLUT="${A}/poplar_v4.lut.txt"
mkdir -p logs
LOG="logs/poplar_expr_fix.log"
exec > >(tee -a "$LOG") 2>&1
echo "════════ poplar expr fix start $(date) ════════"

# 0) guard: build must be complete (do not race a running build)
for s in 58_expression_attributes 60_solr_genes 65_solr_suggestions; do
  [ -f ".state/${s}.done" ] || { echo "ABORT: .state/${s}.done missing — build not complete"; exit 1; }
done
[ -s "${POPLUT}" ] || { echo "ABORT: ${POPLUT} missing"; exit 1; }
echo "poplar LUT rows: $(wc -l < "${POPLUT}")"

# 1) durable fix: retarget poplar rows in the committed new_old.lut.txt (idempotent)
cp "${A}/new_old.lut.txt" "${A}/new_old.lut.txt.bak.prePoplarV4"
"${NODE_BIN}" -e '
const fs=require("fs");const f=process.argv[1];
const lines=fs.readFileSync(f,"utf8").split("\n");let n=0;
const out=lines.map(l=>{ if(/^Potri\./.test(l)){const p=l.split("\t"); if(p[0] && !/\.v4\.1$/.test(p[0])){n++; return p[0]+".v4.1\t"+p.slice(1).join("\t");}} return l;});
fs.writeFileSync(f,out.join("\n"));
console.log("retargeted "+n+" poplar rows in new_old.lut.txt (durable)");
' "${A}/new_old.lut.txt"

# 2) delete the stale projected Potri.<locus> (no-v4) expression docs.
#    Derive the exact stale-id set from the LUT (target minus .v4.1) so we touch nothing else.
STALE="${A}/tmp_poplar_stale_ids.txt"
cut -f1 "${POPLUT}" | sed 's/\.v4\.1$//' | sort -u > "${STALE}"
echo "stale ids to remove: $(wc -l < "${STALE}")"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval '
const fs=require("fs");
const ids=fs.readFileSync("'"${STALE}"'","utf8").split("\n").filter(Boolean);
let del=0;
for(let i=0;i<ids.length;i+=5000){ del += db.expression.deleteMany({_id:{$in:ids.slice(i,i+5000)}}).deletedCount; }
print("deleted stale Potri.<locus> (no-v4) expression docs: "+del);
print("remaining Potri.* (no v4): "+db.expression.countDocuments({$and:[{_id:/^Potri\.[0-9]+G/},{_id:{$not:/v4/}}]}));
'

# 3) re-project POPTR_*v3 -> Potri.<locus>.v4.1 using the poplar-only corrected LUT
echo "projecting poplar expression onto v4 gene ids ..."
( cd "${MONGODB_REPO}" && "${NODE_BIN}" --max-old-space-size=49152 "${A}/project_expression_via_lut.js" "${POPLUT}" )
NV4="$("${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval 'print(db.expression.countDocuments({_id:/^Potri\..*v4/}))')"
echo "Potri.*.v4.1 expression docs now: ${NV4}"
[ "${NV4}" -gt 0 ] || { echo "ABORT: projection produced 0 v4 poplar expression docs"; exit 1; }

# 4) rebuild the expression-attributes + solr layers (atlas/56 stamps stay -> no re-download).
#    CRITICAL: 60_solr_genes reuses a complete solr_genes.json / solr_genes.attribs.json if present
#    (resume guard), so removing the .state stamp alone is NOT enough — delete the stale merged
#    intermediates so mongo2solr.join.js regenerates them with the corrected poplar expression.
rm -f "${SOLR_REPO}/genes/solr_genes.json" "${SOLR_REPO}/genes/solr_genes.attribs.json"
rm -f .state/58_expression_attributes.done .state/60_solr_genes.done .state/65_solr_suggestions.done
echo "re-running 58 -> 60 -> 65 via make all (fresh solr_genes.json + core) ..."
REBUILD_CORE=1 make all

# 5) verify poplar expression attached in solr
echo "──── verification ────"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval '
print("mongo genes with a matching v4 poplar expression doc (sample check):");
var g=db.genes.findOne({_id:/^Potri\..*v4/});
if(g) print("  gene "+g._id+" has expression doc: "+(db.expression.countDocuments({_id:g._id})>0));
'
GENES_CORE="${SOLR_GENES_CORE}"
POPEXP=$(curl -s "${SOLR_URL}/${GENES_CORE}/select?q=id:Potri.*+AND+capabilities:expression&rows=0&wt=json" 2>/dev/null | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).response.numFound)}catch(e){console.log("?")}})')
echo "solr ${GENES_CORE}: poplar genes with expression capability = ${POPEXP}"
echo "════════ poplar expr fix done $(date) ════════"
