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

# --- services ----------------------------------------------------------------
export SOLR_URL="${SOLR_URL:-http://localhost:8983/solr}"
export SOLR_DATA_DIR="${SOLR_DATA_DIR:-/solr/data}"
export ENSEMBL_REST="${ENSEMBL_REST:-http://localhost:3000}"
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
