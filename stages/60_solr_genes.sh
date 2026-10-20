#!/usr/bin/env bash
# 60_solr_genes — convert mongo genes -> flat solr docs and load the genes core.
#   * recreates the ${SOLR_GENES_CORE} core fresh from the repo conf (no stale docs)
#   * mongo2solr.js streams every gene; it process.exit(2)s if any gene lacks a
#     canonical transcript, so a non-zero exit here means a data problem, not a
#     partial load — we refuse to load a truncated solr_genes.json.
#   * merges gene-level attribute tables into the solr docs (add_attributes.pl):
#     MAKER (AED/QI), VEP (germplasm/PTV), and grassius_homolog (TF families
#     projected onto homologs). MAKER/VEP reuse the prior release's tables.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 60_solr_genes

assert_mongo_min genes 1000

GENES="${SOLR_REPO}/genes"
cd "${GENES}"

# 1) core. Prefer the REPO conf (gramene-solr/genes/conf) — it is now the authoritative,
# complete schema: synced from the deployed prev-release conf (atlas_id, closest_rep_identity,
# model_rep_identity) plus the alt_id field, and it matches mongo2solr's output. Fall back to
# the previous release's deployed core conf only if the repo conf is missing.
# Recreate fresh only when the core is empty/absent (or REBUILD_CORE=1); if it
# already holds docs from an interrupted load, KEEP them and let the chunk loader
# resume (it skips the already-committed docs).
CONF="${GENES}/conf"
[ -d "${CONF}" ] || CONF="${SOLR_DATA_DIR}/${PREV_GENES_CORE}/conf"

# ── GATE: refuse a schema whose fields atomic updates cannot preserve ────────────────────────
# Solr implements an atomic update by reconstructing the doc from its STORED fields and
# reindexing. A field that is indexed but neither stored nor docValues, and is not a copyField
# destination, cannot be reconstructed and is silently lost from every doc touched. 62_attr_atomic
# already refuses on this -- but it checks the LIVE core, i.e. after this stage has spent hours
# building it. `_terms` (indexed, stored=false, no docValues, no copyField, written directly by
# mongo2solr.js) was wiped from 247,323 docs that way, breaking free-text search for them and
# feeding through to the suggestions core, which facets on _terms.
#
# So apply the same predicate to the conf BEFORE the core is created, and fail in seconds instead
# of after the build. Same four conditions as 62, so the two cannot disagree. _terms itself is
# stored=true as of dab1932; this exists so that a future schema edit cannot quietly undo it.
log "checking ${CONF}/managed-schema for fields atomic updates cannot preserve"
UNSAFE_FIELDS="$("${NODE_BIN}" -e '
  const fs = require("fs");
  // Strip XML comments first: managed-schema keeps a commented-out <field name="_root_" .../>
  // which otherwise reads as a live indexed-but-unstored field and blocks the stage on a false
  // positive. (Found by testing the gate rather than by reading it.)
  const xml = fs.readFileSync(process.argv[1], "utf8").replace(/<!--[\s\S]*?-->/g, "");
  const dests = new Set();
  for (const m of xml.matchAll(/<copyField\b[^>]*\bdest="([^"]+)"/g)) dests.add(m[1]);
  const bad = [];
  for (const m of xml.matchAll(/<field\b([^>]*)\/>/g)) {
    const a = m[1];
    const name = (a.match(/\bname="([^"]+)"/) || [])[1];
    if (!name) continue;
    const on = (k) => new RegExp("\\b" + k + "=\"true\"").test(a);
    if (on("indexed") && !on("stored") && !on("docValues") && !dests.has(name)) bad.push(name);
  }
  console.log(bad.join(" "));
' "${CONF}/managed-schema" 2>/dev/null)"
if [ -n "${UNSAFE_FIELDS}" ]; then
  die "schema has indexed-but-unrecoverable field(s): ${UNSAFE_FIELDS}
 Each is indexed, not stored, has no docValues and is not a copyField destination, so any atomic
 update (62_attr_atomic) silently erases it from every document it touches. Set stored=\"true\"
 on them in ${CONF}/managed-schema before building the core."
fi
ok "schema is atomic-update safe (no indexed-but-unrecoverable fields)"
existing="$(solr_numdocs "${SOLR_GENES_CORE}" 2>/dev/null || echo 0)"
if [ "${existing:-0}" -eq 0 ] || [ "${REBUILD_CORE:-0}" = "1" ]; then
  log "using genes conf: ${CONF}"
  solr_recreate_core "${SOLR_GENES_CORE}" "${CONF}"
else
  log "resuming load into existing ${SOLR_GENES_CORE} (${existing} docs already committed)"
fi

# 2) mongo -> solr docs (must reach ']' or it exited 2 on a bad gene).
# Uses mongo2solr.join.js (the newer implementation; the original recipe pinned the
# older mongo2solr.js by mistake). It joins the expression collection server-side via
# a $lookup aggregation (allowDiskUse) and streams each gene, so it does NOT load the
# whole expression collection into Node memory the way mongo2solr.js did (which OOMed
# at 8G). It also emits expressed_in_gxa_attr_ss (GXA experiments a gene is expressed
# in), region-padded compara_idx, canonical_transcript__attr_s, supertree, and pan-gene
# capabilities. The heap below is now precautionary, not required.
# Resumable: if a complete solr_genes.json already exists (ends with ']' and has
# 2*genes+1 lines — '[ '+doc for the first gene, ','+doc for each other, ']'),
# reuse it instead of re-running the ~20min conversion.
SOLR_HEAP="${SOLR_HEAP:---max-old-space-size=16384}"
want_lines=$(( $(mongo_count genes) * 2 + 1 ))

# ── SPACE: these intermediates are enormous, and there was no check at all ───────────────────
# solr_genes.json holds one JSON doc per line (want_lines = genes*2+1), and
# solr_genes.attribs.json is that file piped through add_attributes.pl, so BOTH exist at once.
# Measured 2026-10-16: 4.4 KB/line, i.e. ~131 GB each at 16,127,051 genes -> ~265 GB of
# intermediates. With no check, mongo2solr.join.js wrote 106 GB and filled /usr/local to 100%
# (20K free) -- the filesystem that also carries the live subsites and release69. The stage then
# died on ENOSPC having left a 106 GB truncated file behind.
#
# SOLR_DUMP_DIR relocates both files (e.g. to /scratch). The stage refers to them by bare
# relative name in a dozen places, so they are symlinked rather than every reference rewritten.
BYTES_PER_LINE="${SOLR_DUMP_BYTES_PER_LINE:-4400}"
need_gb=$(( want_lines * BYTES_PER_LINE * 2 / 1073741824 ))

if [ -n "${SOLR_DUMP_DIR:-}" ]; then
  mkdir -p "${SOLR_DUMP_DIR}" || die "cannot create SOLR_DUMP_DIR=${SOLR_DUMP_DIR}"
  for f in solr_genes.json solr_genes.attribs.json; do
    # Leave a real, complete file alone so the resume path still works.
    if [ -f "$f" ] && [ ! -L "$f" ]; then
      log "keeping existing real ${f} in $(pwd) (not relocating)"
    else
      rm -f "$f"
      ln -s "${SOLR_DUMP_DIR}/$f" "$f" || die "could not link ${f} -> ${SOLR_DUMP_DIR}/$f"
    fi
  done
  log "intermediates relocated to ${SOLR_DUMP_DIR} (via symlink)"
fi

# Check the filesystem the dump will actually land on, following any symlink above.
space_target="$(dirname "$(readlink -f solr_genes.json 2>/dev/null || echo "$(pwd)/solr_genes.json")")"
avail_gb=$(( $(df -P --block-size=1 "${space_target}" | awk 'NR==2{print $4}') / 1073741824 ))
log "intermediates need ~${need_gb} GB; ${space_target} has ${avail_gb} GB free"
if [ "${avail_gb}" -lt "${need_gb}" ]; then
  die "not enough space for the solr intermediates: ${space_target} has ${avail_gb} GB free, need ~${need_gb} GB
 (${want_lines} lines x ~${BYTES_PER_LINE} B x 2 files). Point them at a bigger filesystem, e.g.
   SOLR_DUMP_DIR=/scratch/\${USER}/release70_solr make 60_solr_genes
 Writing 106 GB and then dying on ENOSPC filled /usr/local to 100% on 2026-10-16; this check
 exists so that cannot happen silently again."
fi
ok "space for intermediates confirmed (${avail_gb} GB free >= ~${need_gb} GB needed)"
if [ -s solr_genes.json ] && tail -c 3 solr_genes.json | grep -q ']' \
   && [ "$(wc -l < solr_genes.json)" = "${want_lines}" ]; then
  log "reusing existing complete solr_genes.json ($(wc -c <solr_genes.json) bytes, ${want_lines} lines)"
else
  log "converting mongo genes -> solr docs via mongo2solr.join.js (heap ${SOLR_HEAP})"
  # SOLR_TERMS_TSV makes the same pass also write the (term, taxon_id) pairs that
  # 65_solr_suggestions needs. Emitting them here is what lets genes.js stop faceting the genes
  # core for a field this script derives from mongo -- 1,743s of round trip that was also the only
  # part of stage 65 that ever failed. Same code path, so the terms cannot drift from what the
  # genes core indexes.
  export SOLR_TERMS_TSV="${SOLR_TERMS_TSV:-${SOLR_DUMP_DIR:-.}/terms.tsv}"
  log "  also writing term/taxon pairs -> ${SOLR_TERMS_TSV}"
  "${NODE_BIN}" ${SOLR_HEAP} ./mongo2solr.join.js > solr_genes.json
  [ -s "${SOLR_TERMS_TSV}" ] || die "mongo2solr.join.js produced no ${SOLR_TERMS_TSV}"
  log "  term/taxon rows: $(wc -l < "${SOLR_TERMS_TSV}")"
  tail -c 3 solr_genes.json | grep -q ']' || die "mongo2solr.join.js did not finish (no closing ']') — check for genes lacking a canonical transcript"
fi
assert_nonempty_file solr_genes.json

LOAD_FILE="solr_genes.json"

# 3) merge gene-level attribute tables into the solr docs via add_attributes.pl:
#    - MAKER  : per-genome gene-model AED/QI scores       (${MAKER_TABLE})
#    - VEP    : germplasm/PTV alleles from the variation DB (${VEP_TABLE})
#    - grassius_homolog : Grassius TF families projected onto homologs (this build)
# MAKER/VEP reuse the prior release's tables by default (same variation DB + gene IDs);
# grassius_homolog is generated fresh from the decorated genes collection.
attr_tables=()
if [ -s "${MAKER_TABLE}" ]; then attr_tables+=("${MAKER_TABLE}"); ok "MAKER table: ${MAKER_TABLE}"; else warn "MAKER table missing (${MAKER_TABLE}) — skipping"; fi
if [ -s "${VEP_TABLE}" ];   then attr_tables+=("${VEP_TABLE}");   ok "VEP table: ${VEP_TABLE}";   else warn "VEP table missing (${VEP_TABLE}) — skipping"; fi

log "projecting Grassius TF families onto homologs"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" "${BUILD_DIR}/grassius_homolog_table.js" > grassius_homolog_attrib_table.txt
gh_rows=$(( $(wc -l < grassius_homolog_attrib_table.txt) - 1 ))
if [ "${gh_rows}" -gt 0 ]; then ok "grassius_homolog rows: ${gh_rows}"; attr_tables+=("${GENES}/grassius_homolog_attrib_table.txt"); else warn "no grassius_homolog rows"; fi

# expression summary attributes (tissue specificity / breadth / stress / per-organ
# level), generated fresh from the expression_attributes collection.
if "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval 'db.expression_attributes.countDocuments({})>0?quit(0):quit(1)' >/dev/null 2>&1; then
  log "generating expression-attribute table from ${MONGO_DB}.expression_attributes"
  "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" "${BUILD_DIR}/expression_attributes_table.js" > expression_attributes_table.txt
  ea_rows=$(( $(wc -l < expression_attributes_table.txt) - 1 ))
  if [ "${ea_rows}" -gt 0 ]; then ok "expression_attributes rows: ${ea_rows}"; attr_tables+=("${GENES}/expression_attributes_table.txt"); else warn "no expression_attributes rows"; fi
else
  warn "no expression_attributes collection — skipping expression attributes"
fi

if [ "${#attr_tables[@]}" -gt 0 ]; then
  # Reuse a complete attribs file across kill-resumes — but ONLY if it is newer than every input.
  # "Complete" (closing ']' + matching line count) says nothing about whether the merged VALUES are
  # current: several of these tables are regenerated from mongo on every run, so a rebuilt
  # expression_attributes collection produced a fresh expression_attributes_table.txt while this
  # file was reused untouched, and the index kept serving the previous release's values.
  attribs_stale=0
  if [ -s solr_genes.attribs.json ]; then
    for t in "${attr_tables[@]}" solr_genes.json; do
      if [ -e "$t" ] && [ "$t" -nt solr_genes.attribs.json ]; then
        log "attribute input newer than solr_genes.attribs.json: $(basename "$t") — will re-merge"
        attribs_stale=1
      fi
    done
  fi
  if [ "${attribs_stale}" -eq 0 ] && [ -s solr_genes.attribs.json ] && tail -c 3 solr_genes.attribs.json | grep -q ']' \
     && [ "$(wc -l < solr_genes.attribs.json)" = "$(wc -l < solr_genes.json)" ]; then
    log "reusing existing complete solr_genes.attribs.json"
  else
    log "merging ${#attr_tables[@]} attribute tables into solr docs"
    pipe="cat solr_genes.json"
    for t in "${attr_tables[@]}"; do pipe="${pipe} | '${GENES}/add_attributes.pl' '${t}'"; done
    eval "${pipe}" > solr_genes.attribs.json
    tail -c 3 solr_genes.attribs.json | grep -q ']' || die "attribute merge produced a truncated solr_genes.attribs.json"
    [ "$(wc -l < solr_genes.attribs.json)" = "$(wc -l < solr_genes.json)" ] || die "solr_genes.attribs.json line count != solr_genes.json (merge dropped docs)"
  fi
  LOAD_FILE="solr_genes.attribs.json"
fi

# 4) load + commit. The genes file is multi-GB, so stream it in batches rather
# than handing Solr one giant update request.
solr_load_json_chunked "${SOLR_GENES_CORE}" "${LOAD_FILE}"

# 5) validate count + attribute coverage
want="$(mongo_count genes)"
got="$(solr_numdocs "${SOLR_GENES_CORE}")"
log "solr ${SOLR_GENES_CORE} numDocs=${got} ; mongo genes=${want}"
[ "${got}" = "${want}" ] && ok "solr genes count matches mongo" || warn "solr genes (${got}) != mongo genes (${want})"

# ── GATE: the docs must be FRESH, not merely the right number ────────────────────────────────
# The count above passes just as happily when the load wrote nothing: a re-load into an already
# full core is exactly as many docs as mongo has. That is how solr_chunk_load's old auto-skip
# (fixed in e4436b7) could no-op a whole rebuild and still stamp this stage done. So compare
# CONTENT that only a real load can produce.
#
# 1) Ordering: the lowest gene_idx in solr must belong to the genome mongo ranks species_idx=1.
#    mongo2solr assigns gene_idx by sorting on species_idx, so a stale core fails this whenever
#    the ranking changed -- which is precisely when a silent no-op matters most.
want_first="$("${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval \
  'var g=db.genes.findOne({species_idx:1},{system_name:1}); print(g?g.system_name:"")' 2>/dev/null | tr -d '\r')"
got_first="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/select?q=*:*&rows=1&sort=gene_idx+asc&fl=system_name&wt=json" \
  | sed -n 's/.*"system_name":"\([^"]*\)".*/\1/p' | head -1)"
if [ -n "${want_first}" ] && [ "${want_first}" = "${got_first}" ]; then
  ok "solr gene_idx ordering agrees with mongo species_idx (first genome: ${got_first})"
elif [ -z "${want_first}" ]; then
  warn "no genome has species_idx=1 in mongo — cannot check ordering freshness"
else
  die "STALE CORE: solr's lowest gene_idx is '${got_first}' but mongo ranks '${want_first}' first.
 The load did not take effect (see solr_chunk_load's SOLR_RESUME/SKIP_DOCS), or decorate and the
 solr load disagree. Re-run after confirming the load actually sent docs."
fi

# 2) Tree sets: every homology set that exists in mongo must be non-empty in solr. Catches a
#    mapper that silently stops emitting a field (the cultivar tree ids were missing from solr
#    entirely until 0905463, because the emit block lived in the unused mongo2solr.js).
# One mongosh call for all five sets, and deliberately NOT $exists:true. The homology.<set>.id
# indexes are not sparse, so each carries an entry for all 16.1M genes with nulls sorting first;
# $exists:true must walk past ~11.7M null entries to reach the first real one and takes >100s per
# set. {$gt:""} seeks straight to the first string: 0.12s, and the whole check runs in under a
# second instead of ~17 minutes.
sets_in_mongo="$("${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval \
  'var out=[]; ["gene_tree","barley","oat","wheat","rice"].forEach(function(s){
     var q={}; q["homology."+s+".id"]={$gt:""};
     if (db.genes.find(q).limit(1).size() > 0) out.push(s); }); print(out.join(" "))' 2>/dev/null | tr -d '\r')"
log "homology sets present in mongo: ${sets_in_mongo:-<none>}"
for set in ${sets_in_mongo}; do
  sn="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/select?q=${set}:*&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | sed 's/.*://')"
  [ "${sn:-0}" -gt 0 ] 2>/dev/null \
    && ok "  tree set ${set}: ${sn} genes in solr" \
    || die "tree set '${set}' exists in mongo but NO solr doc carries it — the mapper is not emitting it"
done
# report how many genes carry each merged capability
for cap in MAKER VEP expression_attributes; do
  n="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/select?q=capabilities:${cap}&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | sed 's/.*://')"
  log "  genes with ${cap} capability: ${n:-0}"
done
ghn="$(curl -s "${SOLR_URL}/${SOLR_GENES_CORE}/select?q=grassius_homolog__attr_ss:*&rows=0&wt=json" | grep -o '"numFound":[0-9]*' | sed 's/.*://')"
log "  genes with grassius_homolog: ${ghn:-0}"
stage_end
