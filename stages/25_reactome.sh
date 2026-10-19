#!/usr/bin/env bash
# 25_reactome — Plant Reactome: build the pathways collection, stamp reactomePrefix
# onto taxonomy, and emit genes_to_pathways.json (the -p associations file that
# decorate.js requires). get_pathways.js is drop-based on pathways (safe rerun).
# Requires maps (is_anchor) + taxonomy collections -> run after 10_maps.
#
# NOTE: the old recipe also hand-munged Ensembl2PlantReactomeReactions.txt to add
# Oryza japonica UniProt->gene mappings (see merged_lut.txt). That enhancement is
# OPTIONAL and rice-japonica-specific; it is intentionally skipped here. To apply
# it, see build/README.md "Reactome japonica enhancement".
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 25_reactome

assert_mongo_min maps 100
assert_mongo_min taxonomy 100

R="${MONGODB_REPO}/reactome"
cd "${R}"
PR=https://plantreactome.gramene.org/download/current

log "downloading Plant Reactome mapping files"
curl -fsSL "${PR}/UniProt2PlantReactomeReactions.txt"        -o UniProt2PlantReactomeReactions.txt
curl -fsSL "${PR}/gene_ids_by_pathway_and_species.tab"       -o gene_ids_by_pathway_and_species.tab
curl -fsSL "${PR}/Ensembl2PlantReactomeReactions.txt"        -o Ensembl2PlantReactomeReactions.txt
assert_nonempty_file Ensembl2PlantReactomeReactions.txt
assert_nonempty_file gene_ids_by_pathway_and_species.tab

# ---- maize ver5 (ZMY) supplement -------------------------------------------
# Plant Reactome files maize TWICE: "Zea mays" (taxId 4577, prefix ZMA) and "Zea mays ver5"
# (taxId 381124, prefix ZMY). The public Ensembl2PlantReactomeReactions.txt carries ONLY the v4
# ZMA mappings (Zm00001d ids, which this release does not have -- our cores are B73 v5), while
# gene_ids_by_pathway_and_species.tab DOES list v5 ZMY genes (Zm00001eb). get_pathways.js builds
# a skeleton per gene from the .tab and fills ancestors/entries from the reactions file, so every
# v5 maize gene came out with an empty {} -- 1,587 genes with no pathways in the v11 build, and
# zero maize hits for capabilities:pathways.
# This supplement is NOT published upstream (its download URL 301s to the Plant Reactome home
# page); it is a local artifact carried over from the release69/v10 build, which is why v10 has
# maize pathways and v11 did not. Appending it after the download keeps this idempotent -- curl
# above overwrites the base file on every run.
ZMY_SUPP="${R}/Ensembl2PlantReactomeReactions_Zmy_ver5.txt"
if [ -s "${ZMY_SUPP}" ]; then
  cat "${ZMY_SUPP}" >> Ensembl2PlantReactomeReactions.txt
  ok "appended $(wc -l < "${ZMY_SUPP}") maize ver5 (ZMY) reaction lines"
else
  warn "missing ${ZMY_SUPP} — maize v5 genes will get EMPTY pathways (see docs/04-troubleshooting.md)"
fi

# ---- Oryza sativa japonica (OSA) supplement ---------------------------------
# Rice had essentially NO pathways before this: 1 gene with a pathways key in r70 against 1,590 in
# r69. Three facts, each measured:
#   * Ensembl2PlantReactomeReactions.txt contains ZERO rice-keyed rows. Plant Reactome publishes
#     rice reactions keyed on UNIPROT instead, in UniProt2PlantReactomeReactions.txt (3,431 Oryza
#     rows, 1,773 distinct accessions).
#   * gene_ids_by_pathway_and_species.tab -- which seeds the skeleton -- lists rice almost entirely
#     as RAP-DB TRANSCRIPT ids (Os01t0649100-01, Os07t0695800-02). Only ONE rice row is in gene
#     form. genes_to_pathways.json is consumed against GENE ids, so those can never join, and the
#     364 empty rice keys in the artifact are exactly those transcript ids.
#   * merged_lut.txt is the missing bridge: UniProt accession -> rice gene id, covering 1,614 of
#     the 1,773 accessions and yielding 1,612 gene ids, of which 1,598 exist in this build.
#
# So translate the UniProt rows into the 6-column Ensembl2... shape. get_pathways.js CREATES a gene
# when a reaction's id is absent from the skeleton (its `if (!genes.hasOwnProperty(fields[0]))`), so
# these fill even though the .tab never mentions them in gene form.
#
# DERIVED on every run from the published files plus the lut, not carried as a static artifact like
# the ZMY one -- so it tracks upstream instead of silently going stale. Appended after the curl, so
# re-running is idempotent.
OSA_LUT="${R}/merged_lut.txt"
OSA_SUPP="${R}/Ensembl2PlantReactomeReactions_Osa.txt"
if [ -s "${OSA_LUT}" ]; then
  awk -F'\t' -v OFS='\t' '
    NR==FNR { lut[$1] = $2; next }
    $6 ~ /Oryza sativa/ && ($1 in lut) { print lut[$1], $2, $3, $4, $5, $6 }
  ' "${OSA_LUT}" UniProt2PlantReactomeReactions.txt | sort -u > "${OSA_SUPP}"
  n_osa="$(wc -l < "${OSA_SUPP}")"
  [ "${n_osa}" -gt 0 ] || die "derived no OSA reaction lines from ${OSA_LUT} + UniProt2PlantReactomeReactions.txt — has the UniProt file's species column or the lut changed?"
  cat "${OSA_SUPP}" >> Ensembl2PlantReactomeReactions.txt
  ok "appended ${n_osa} Oryza sativa (OSA) reaction lines derived from merged_lut.txt"
else
  warn "missing ${OSA_LUT} — rice genes will get EMPTY pathways (this is the r69->r70 rice regression)"
fi

# ---- OPTIONAL: reuse another release's gene->pathway associations ----------
# Steps 1 and 3 below are the only ContentService-dependent parts of this stage, and that service
# goes down (2026-10-08: every /ContentService/data/* path hung for hours while the same host served
# / and the download files normally). Plant Reactome itself publishes infrequently, so when the
# upstream files have not changed, another release's genes_to_pathways.json is byte-for-byte what
# this release would compute -- the per-gene output holds pathway/reaction ids, not taxon ids.
#
# This mode is explicit and never guessed, because it is only valid while upstream is unchanged --
# which it VERIFIES by md5 rather than assuming. It supplies ONLY the associations file. The
# pathways collection and taxonomy.reactomePrefix are keyed on this release's synthetic per-genome
# taxon ids (`ancestors_4558001` here vs `ancestors_4558006` in sorghum v11, same values), so they
# are release-specific, are NOT copied, and must already be populated by an earlier successful run.
#
#   make 25_reactome REACTOME_REUSE_FROM=/usr/local/gramene/subsites/sorghum/v11/gramene-mongodb/reactome
if [ -n "${REACTOME_REUSE_FROM:-}" ]; then
  SRC="${REACTOME_REUSE_FROM%/}"
  log "REUSE MODE: sourcing gene->pathway associations from ${SRC}"
  [ -d "${SRC}" ] || die "REACTOME_REUSE_FROM is not a directory: ${SRC}"
  [ "${SRC}" != "${R}" ] || die "REACTOME_REUSE_FROM is this release's own reactome dir"

  # (a) upstream must be IDENTICAL, or the reuse is not equivalent to a real run. The reactions
  # file is compared with the ZMY rows stripped, since each tree appends its own copy; the
  # supplement is then compared on its own.
  for f in gene_ids_by_pathway_and_species.tab UniProt2PlantReactomeReactions.txt \
           Ensembl2PlantReactomeReactions_Zmy_ver5.txt; do
    [ -f "${SRC}/${f}" ] || die "reuse source lacks ${f}"
    a="$(md5sum < "${R}/${f}" | cut -d' ' -f1)"
    b="$(md5sum < "${SRC}/${f}" | cut -d' ' -f1)"
    [ "${a}" = "${b}" ] || die "upstream ${f} differs from ${SRC} (${a} vs ${b}) -- Plant Reactome has changed, so re-run this stage fully instead"
    ok "upstream unchanged: ${f}"
  done
  a="$(grep -vE 'R-ZMY|R-OSA' "${R}/Ensembl2PlantReactomeReactions.txt" | md5sum | cut -d' ' -f1)"
  b="$(grep -vE 'R-ZMY|R-OSA' "${SRC}/Ensembl2PlantReactomeReactions.txt" | md5sum | cut -d' ' -f1)"
  [ "${a}" = "${b}" ] || die "upstream Ensembl2PlantReactomeReactions.txt differs from ${SRC} (${a} vs ${b}) -- re-run this stage fully instead"
  ok "upstream unchanged: Ensembl2PlantReactomeReactions.txt (ZMY + OSA rows excluded)"

  # (b) the release-specific outputs this mode does NOT supply must already exist, from a previous
  # successful run of this stage against THIS release's genome set.
  assert_mongo_min pathways 100
  pfx="$(mongo_eval "db.taxonomy.countDocuments({reactomePrefix:{\$exists:true}})" | tr -d '[:space:]')"
  [ "${pfx:-0}" -gt 0 ] || die "taxonomy has no reactomePrefix -- reuse cannot supply it; run this stage fully once"
  ok "taxonomy docs with reactomePrefix: ${pfx}"

  # (c) and the pathways collection must be keyed on THIS release's taxa, not the source's. Picking
  # a genome from maps that carries a reactomePrefix, some pathway must have its ancestors_<taxon>.
  keyed="$(mongo_eval '
    const t = db.taxonomy.find({reactomePrefix:{$exists:true}},{_id:1}).toArray().map(d=>d._id);
    const hit = t.find(id => db.pathways.countDocuments({["ancestors_"+id]:{$exists:true}}) > 0);
    print(hit === undefined ? "NONE" : hit);' | tr -d '[:space:]')"
  [ "${keyed}" != "NONE" ] && [ -n "${keyed}" ] \
    || die "no pathways doc is keyed on any of this release's taxa -- the pathways collection belongs to another genome set; run this stage fully"
  ok "pathways collection is keyed on this release's taxa (e.g. ancestors_${keyed})"

  # (d) take the associations
  [ -s "${SRC}/genes_to_pathways.json" ] || die "reuse source lacks a non-empty genes_to_pathways.json"
  cp -p "${SRC}/genes_to_pathways.json"     "${R}/genes_to_pathways.json"
  [ -s "${SRC}/genes_to_pathways.raw.json" ] && cp -p "${SRC}/genes_to_pathways.raw.json" "${R}/genes_to_pathways.raw.json"
  assert_valid_json genes_to_pathways.json
  n_keys="$("${NODE_BIN}" --max-old-space-size=4096 -e 'process.stdout.write(String(Object.keys(require("'"${R}"'/genes_to_pathways.json")).length))')"
  ok "reused genes_to_pathways.json (${n_keys} gene keys) from ${SRC}"
  ln -sf "${R}/genes_to_pathways.json" "${MONGODB_REPO}/search/genes_to_pathways.json"
  warn "associations were REUSED, not rebuilt -- valid only because upstream is byte-identical (verified above)"
  stage_end
  exit 0
fi

# 1) reactome species prefixes from the anchor genomes
log "deriving reactome species prefixes"
"${NODE_BIN}" get_species_prefixes.js > merge_into_taxonomy.json
assert_valid_json merge_into_taxonomy.json

# 2) merge reactomePrefix onto taxonomy docs (upsert: leaves other docs intact)
log "merging reactomePrefix into ${MONGO_DB}.taxonomy"
mongoexport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c taxonomy 2>/dev/null \
  | "${NODE_BIN}" "${MONGODB_REPO}/search/merge_into_mongo_docs.js" -l "${R}/merge_into_taxonomy.json" \
  | mongoimport -h "${MONGO_HOST}" --port "${MONGO_PORT}" -d "${MONGO_DB}" -c taxonomy --upsert 2>/dev/null
pfx="$(mongo_eval "db.taxonomy.countDocuments({reactomePrefix:{\$exists:true}})")"
[ "${pfx:-0}" -gt 0 ] && ok "taxonomy docs with reactomePrefix: ${pfx}" || warn "no taxonomy docs got a reactomePrefix"

# 3) build pathways collection + the gene->pathway associations json
log "building pathways collection + genes_to_pathways.json"
"${NODE_BIN}" ${BIG_HEAP} get_pathways.js \
  --gtr Ensembl2PlantReactomeReactions.txt \
  --gtp gene_ids_by_pathway_and_species.tab \
  --api https://plantreactome.gramene.org/ContentService \
  > genes_to_pathways.raw.json

assert_valid_json genes_to_pathways.raw.json
assert_mongo_min pathways 100

# 4) grape v4->v3 key rewrite (vitis is an anchor); fall back if it breaks json
if "${MONGODB_REPO}/reactome/update_vv.pl" < genes_to_pathways.raw.json > genes_to_pathways.json 2>/dev/null \
   && "${NODE_BIN}" -e 'JSON.parse(require("fs").readFileSync("genes_to_pathways.json"))' 2>/dev/null; then
  ok "applied grape v4->v3 key rewrite"
else
  warn "update_vv.pl produced invalid json — using raw associations"
  cp genes_to_pathways.raw.json genes_to_pathways.json
fi
assert_valid_json genes_to_pathways.json

# 5) assert the two supplements actually FILLED something, per species.
#
# "valid json with N keys" is not the property we care about, and it is how both failures here got
# through: maize shipped 1,587 v5 genes whose pathways were `{}`, and rice shipped 364 keys that
# were both empty AND keyed on transcript ids. In each case the artifact was well-formed and the
# stage said ok. So check filled-ness by species, on GENE-form ids only.
log "checking per-species pathway fill in genes_to_pathways.json"
"${NODE_BIN}" --max-old-space-size=4096 -e '
  const d = require(process.argv[1]);
  const pat = { "maize v5 (Zm00001eb)": /^Zm00001eb\d+$/, "rice (Os..g..)": /^Os\d+g\d+$/ };
  let bad = [];
  for (const [label, re] of Object.entries(pat)) {
    const keys = Object.keys(d).filter(k => re.test(k));
    const filled = keys.filter(k => ((((d[k]||{}).annotations||{}).pathways||{}).entries||[]).length);
    console.error("  " + label + ": " + filled.length + " filled of " + keys.length + " keys");
    if (!filled.length) { bad.push(label); }
  }
  // Rice is also listed upstream as RAP-DB TRANSCRIPT ids, which can never join a gene-keyed
  // consumer. Report them so the count is never mistaken for coverage.
  const tx = Object.keys(d).filter(k => /^Os\d+t\d+/.test(k));
  if (tx.length) { console.error("  note: " + tx.length + " rice keys are TRANSCRIPT ids (upstream shape; they cannot join genes)"); }
  if (bad.length) { console.error("EMPTY: " + bad.join("; ")); process.exit(1); }
' "${R}/genes_to_pathways.json" \
  && ok "maize v5 and rice both have filled pathway entries" \
  || die "a species supplement produced NO filled entries (see above).
 maize needs ${ZMY_SUPP}; rice needs ${OSA_LUT} + the OSA rows derived from UniProt2PlantReactomeReactions.txt.
 Both are appended to Ensembl2PlantReactomeReactions.txt earlier in this stage."

ln -sf "${R}/genes_to_pathways.json" "${MONGODB_REPO}/search/genes_to_pathways.json"
stage_end
