#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# config.sh — single source of truth for the SorghumBase search-index build.
#
# Everything that varies between releases / hosts lives HERE. No other script in
# build/ should hardcode a db name, host, port, or path. The mongo db name and
# version are read straight out of gramene-mongodb-config/collections.js so this
# file can never disagree with what the ETL code actually writes to.
#
# Source it:  . "$(dirname "$0")/../config.sh"   (stage scripts do this for you)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# --- repo layout -------------------------------------------------------------
export RELEASE_ROOT="/usr/local/gramene/subsites/sorghum/v11"
export BUILD_DIR="${RELEASE_ROOT}/build"
export MONGODB_REPO="${RELEASE_ROOT}/gramene-mongodb"
export MONGOCONFIG_REPO="${RELEASE_ROOT}/gramene-mongodb-config"
export SOLR_REPO="${RELEASE_ROOT}/gramene-solr"
export SWAGGER_REPO="${RELEASE_ROOT}/gramene-swagger"
export EBEYE_REPO="${RELEASE_ROOT}/gramene-ebeye"
export STATE_DIR="${BUILD_DIR}/.state"
export LOG_DIR="${BUILD_DIR}/logs"
export WORK_TMP="${BUILD_DIR}/tmp"

# --- node / heap -------------------------------------------------------------
export NODE_BIN="$(command -v node)"
export BIG_HEAP="--max-old-space-size=8192"
export DUMP_HEAP="--max-old-space-size=4096"
# how many genome dumps to run at once in the gene-dump stage
export DUMP_PARALLELISM="${DUMP_PARALLELISM:-6}"

# --- target databases (DERIVED from collections.js, never hardcoded) ---------
# getMongoConfig() returns {host,port,version,db}. We trust collections.js.
_mongo_json="$("${NODE_BIN}" -e 'try{var c=require("'"${MONGOCONFIG_REPO}"'/collections.js");process.stdout.write(JSON.stringify(c.getMongoConfig()));setTimeout(()=>process.exit(0),50)}catch(e){process.stderr.write("CONFIG_LOAD_FAILED: "+e.message);process.exit(3)}' 2>/dev/null || true)"
if [ -z "${_mongo_json}" ]; then
  echo "FATAL: could not load ${MONGOCONFIG_REPO}/collections.js — run build/stages/05_install.sh first" >&2
  return 1 2>/dev/null || exit 1
fi
export MONGO_HOST="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).host))')"
export MONGO_PORT="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).port))')"
export DB_VERSION="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"
export MONGO_DB="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).db))')"
export MONGO_URI="mongodb://${MONGO_HOST}:${MONGO_PORT}"

# species prefix + previous release (for diffs / core conf templates)
export SPECIES="sorghum"
export PREV_DB="${SPECIES}$((DB_VERSION-1))"          # sorghum10
export SOLR_GENES_CORE="${SPECIES}_genes${DB_VERSION}"        # sorghum_genes11
export SOLR_SUGG_CORE="${SPECIES}_suggestions${DB_VERSION}"   # sorghum_suggestions11
export PREV_GENES_CORE="${SPECIES}_genes$((DB_VERSION-1))"
export PREV_SUGG_CORE="${SPECIES}_suggestions$((DB_VERSION-1))"

# --- solr gene attribute tables (merged into solr docs via add_attributes.pl) ---
# MAKER (AED/QI gene-model quality scores) and VEP (germplasm/PTV from the variation
# DB) are keyed by gene id. The sorghum variation DB and gene IDs are unchanged from
# the previous release, so by default we REUSE the prior tables. Regenerate them for
# a new variation/MAKER release (VEP: vep/dump_gene_level_VEP_table.pl + munge_vep.pl;
# MAKER: /scratch/olson/28_sorg_maker_AED/munge_MAKER.pl + process_gff3.sh) and point
# these at the new files. grassius_homolog is always projected fresh (build/grassius_homolog_table.js).
export PREV_RELEASE_ROOT="${PREV_RELEASE_ROOT:-/usr/local/gramene/subsites/${SPECIES}/v$((DB_VERSION-1))}"
# v11 has its own MAKER table: the 28 genomes carried over from release 10 PLUS the 9 pan-genome
# accessions whose MAKER GFFs arrived for this release (built by
# /scratch/olson/sorghum_v11_maker_AED/build_maker_tables.sh). It is a real file here rather than
# the previous release's — v10 serves its copy through a symlink, so that one must not be edited.
export MAKER_TABLE="${MAKER_TABLE:-${SOLR_REPO}/genes/maker_attrib_table_for_solr.txt}"
export VEP_TABLE="${VEP_TABLE:-${PREV_RELEASE_ROOT}/gramene-solr/vep/vep_attributes.txt}"

# --- rsID attributes (rsid__attr_ss) -----------------------------------------
# Variant rsIDs overlapping a gene model or its flank, so users can search genes by rsID. Built out
# of band from per-genome VCFs named <system_name>.vcf.gz by gramene-solr/rsid_pipeline; the table
# is merged like MAKER/VEP. Intronic variants further than RSID_INTRON_MAX_DIST from a canonical
# exon are dropped -- a deep intronic variant says little about the gene and only adds search noise.
export RSID_VCF_DIR="${RSID_VCF_DIR:-/scratch/olson/rsid_projection/vcf}"
export RSID_TABLE="${RSID_TABLE:-${SOLR_REPO}/genes/rsid_attrib_table_for_solr.txt}"
# Flank is UPSTREAM-ONLY and strand-aware (below start on +, above end on -). Measured on the
# anchor genome: 2kb-both-sides/50nt gave 10.6M rsID values per genome; 200bp-upstream/10nt gives
# 3.0M (-72%), with the flank component alone down 95%.
export RSID_FLANK_UP="${RSID_FLANK_UP:-200}"
export RSID_FLANK_DOWN="${RSID_FLANK_DOWN:-0}"
export RSID_INTRON_MAX_DIST="${RSID_INTRON_MAX_DIST:-10}"
# Per-gene ceiling. On sorghum_bicolor only 105 genes exceeded 1000 and the largest genuinely holds
# 3,772, so 5000 keeps every real gene intact; the cap exists to stop pathological bloat, not to
# trim ordinary long genes. A truncated gene is unfindable by its dropped rsIDs.
export RSID_MAX_PER_GENE="${RSID_MAX_PER_GENE:-5000}"
# Per-genome intermediates. MUST NOT default under /tmp: this host's /tmp is on a 20 GB root
# filesystem and a full run writes ~4 GB, which filled it and killed a run mid-way. /scratch has TB.
# Holds the per-genome extractor output (<system_name>.tsv + .ok + .log). This is not scratch that
# can be discarded: `make refresh-rsid-genome GENOME=x` patches Solr straight from these files, so
# they are the working set for incremental updates, not just resume state. "work_conseq" is the
# 5-column consequence-calling run; the older "work" dir holds the superseded 3-column output.
export RSID_WORK_DIR="${RSID_WORK_DIR:-/scratch/olson/rsid_projection/work_conseq}"
# Window mode. "cds" anchors on the coding sequence rather than the gene model, which is what makes
# the index robust to bad annotations -- some models here carry a 50 kb 5'UTR around a 360 bp CDS.
export RSID_MODE="${RSID_MODE:-cds}"
export RSID_CDS_UP="${RSID_CDS_UP:-1000}"        # bp before the start codon (strand-aware)
export RSID_CDS_DOWN="${RSID_CDS_DOWN:-500}"     # bp after the stop codon
export RSID_SPLICE="${RSID_SPLICE:-10}"          # nt each side of an intron kept in rsid__attr_ss
export RSID_SPLICE_PTV="${RSID_SPLICE_PTV:-2}"   # nt each side counting as a splice-site PTV
export RSID_NC_UP="${RSID_NC_UP:-200}"           # non-coding genes: bp before transcript start
# CDS fasta for consequence calling (rsid_PTV__attr_ss / rsid_PAV__attr_ss)
export RSID_CDS_FASTA_DIR="${RSID_CDS_FASTA_DIR:-/scratch/olson/fasta}"
# Genomes excluded from the rsID table because their projected VCF is on a DIFFERENT ASSEMBLY than
# the gene models in this release. Verified with rsid_pipeline/check_vcf_assembly.sh, which compares
# the VCF REF allele to the genomic base: 102 of 104 genomes score exactly 100.00%, these two score
# 24.67% and 23.13% -- chance. sorghum_353's variants also run 7.5 Mb past the end of chr10, so no
# coordinate offset can reconcile them. Left in, they would produce confident, wrong gene->rsID
# assignments (a variant always lands inside *some* gene) and meaningless consequence calls. Clear
# this once the projection is redone against the assemblies we actually serve.
export RSID_SKIP_GENOMES="${RSID_SKIP_GENOMES:-sorghum_pi154844}"

# --- services ----------------------------------------------------------------
export SOLR_URL="${SOLR_URL:-http://localhost:8983/solr}"
export SOLR_DATA_DIR="${SOLR_DATA_DIR:-/solr/data}"
# The public pansite REST service, not the local one on :3000. The local instance reads the shared
# registry at /usr/local/ensembl-87/ensembl-rest/reg.pm, which is dated 2024-03-14 and knows 151
# species — 91 of this release's 128 genomes do not resolve there, so the maps QC in 10_maps was
# reporting them all as missing. The public service carries 267 species and resolves all 128.
# (Verified 2026-08-07: check_maps_in_ensembl_rest.js reports 0 unresolved against 115, 91 against
# localhost:3000.) Point this back at a local instance only if its registry is actually current.
export ENSEMBL_REST="${ENSEMBL_REST:-https://data.gramene.org/pansite-ensembl-115}"
export REDIS_HOST="${REDIS_HOST:-localhost}"
export REDIS_PORT="${REDIS_PORT:-6379}"
# redis logical db assignments — these MUST match the hardcoded values in the
# ETL code: dump_homologs.js / homolog_adder.js use 9; decorate.js generifs(3).
export REDIS_HOMOLOG_DB=9
export REDIS_GENERIF_DB=3

# --- ensembl mysql (read-only source) ----------------------------------------
# Pulled from ensembl_db_info.json so there is one place that defines the source.
export ENSEMBL_DB_INFO="${MONGODB_REPO}/ensembl_db_info.json"
if [ -f "${ENSEMBL_DB_INFO}" ]; then
  export COMPARA_DB="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.database)')"
  export MYSQL_HOST="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.host)')"
  export MYSQL_USER="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.user)')"
  export MYSQL_PASS="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.password||"")')"
fi

# --- expected invariants (preflight validates against these) -----------------
export EXPECT_CORES=128
export EXPECT_ANCHORS=9
export EXPECT_VARIATIONS=2

# convenience: the mongo shell (prefer mongosh, fall back to mongo)
export MONGOSH="$(command -v mongosh || command -v mongo)"
