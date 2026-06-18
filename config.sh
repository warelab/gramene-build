#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# config.sh — build config for the MAIN Gramene release 70 (colden / _70_116).
#
# Adapted from the SorghumBase v11 build (subsites/sorghum/v11/build/config.sh) for
# the main release: dbName='search' (mongo search70), solr cores genes70/suggestions70
# (no species prefix), source DBs on colden (ensembl _70_116, compara_plants_70_116),
# 266 cores, 0 anchors, 24 variations, no MAKER/VEP. Drop this into release70/build/
# (replacing the sorghum config.sh) once the repos are checked out.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# --- repo layout -------------------------------------------------------------
export RELEASE_ROOT="/usr/local/gramene/release70"
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
export DUMP_PARALLELISM="${DUMP_PARALLELISM:-6}"

# --- target databases (DERIVED from collections.js: dbName='search', dbVersion='70') ---
_mongo_json="$("${NODE_BIN}" -e 'try{var c=require("'"${MONGOCONFIG_REPO}"'/collections.js");process.stdout.write(JSON.stringify(c.getMongoConfig()));setTimeout(()=>process.exit(0),50)}catch(e){process.stderr.write("CONFIG_LOAD_FAILED: "+e.message);process.exit(3)}' 2>/dev/null || true)"
if [ -z "${_mongo_json}" ]; then
  echo "FATAL: could not load ${MONGOCONFIG_REPO}/collections.js (need the main_v70 branch, dbName='search')" >&2
  return 1 2>/dev/null || exit 1
fi
export MONGO_HOST="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).host))')"
export MONGO_PORT="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).port))')"
export DB_VERSION="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"
export MONGO_DB="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).db))')"   # search70
export MONGO_URI="mongodb://${MONGO_HOST}:${MONGO_PORT}"

# --- solr cores: MAIN release uses bare genes<N>/suggestions<N> (no species prefix) ---
export SPECIES="gramene"                                       # for log messages only
export PREV_DB="search$((DB_VERSION-1))"                       # search69
export SOLR_GENES_CORE="genes${DB_VERSION}"                    # genes70
export SOLR_SUGG_CORE="suggestions${DB_VERSION}"              # suggestions70
export PREV_GENES_CORE="genes$((DB_VERSION-1))"               # genes69 (conf template + diffs)
export PREV_SUGG_CORE="suggestions$((DB_VERSION-1))"

# --- solr gene attribute tables -- main release has NO sorghum MAKER/VEP; leave empty
# (stage 60 warns + skips a missing table). grassius_homolog still projects fresh.
export MAKER_TABLE="${MAKER_TABLE:-}"
export VEP_TABLE="${VEP_TABLE:-}"

# --- services ----------------------------------------------------------------
export SOLR_URL="${SOLR_URL:-http://localhost:8983/solr}"
export SOLR_DATA_DIR="${SOLR_DATA_DIR:-/solr/data}"
export ENSEMBL_REST="${ENSEMBL_REST:-http://localhost:3000}"
export REDIS_HOST="${REDIS_HOST:-localhost}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_HOMOLOG_DB=9
export REDIS_GENERIF_DB=3

# --- ensembl mysql source (colden) — read from ensembl_db_info.json ----------
export ENSEMBL_DB_INFO="${MONGODB_REPO}/ensembl_db_info.json"
if [ -f "${ENSEMBL_DB_INFO}" ]; then
  export COMPARA_DB="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.database)')"   # ensembl_compara_plants_70_116
  export MYSQL_HOST="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.host)')"        # colden
  export MYSQL_USER="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.user)')"
  export MYSQL_PASS="$("${NODE_BIN}" -e 'console.log(require("'"${ENSEMBL_DB_INFO}"'").compara.password||"")')"
fi

# --- preflight invariants (release70 on colden, discovered) ------------------
export EXPECT_CORES=266        # *_core_70_116_* on colden
export EXPECT_ANCHORS=0        # main release: no pan-genome anchors
# get_ensembl_db_info.js discovers cores only (variations:[] -> 0). colden HAS 24
# *_variation_70_116_* dbs; to enable VEP, add them to ensembl_db_info.json's
# "variations" array and bump this to 24. Left at 0 so preflight passes as-generated.
export EXPECT_VARIATIONS=0

export MONGOSH="$(command -v mongosh || command -v mongo)"
