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
export RELEASE_ROOT="/usr/local/gramene/subsites/grapevine/v5"
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

# --- solr cores: a SUBSITE prefixes its cores with $SPECIES (grapevine_genes5) ---
export SPECIES="grapevine"
export PREV_DB="${SPECIES}$((DB_VERSION-1))"                   # grapevine4
export SOLR_GENES_CORE="${SPECIES}_genes${DB_VERSION}"         # grapevine_genes5
export SOLR_SUGG_CORE="${SPECIES}_suggestions${DB_VERSION}"    # grapevine_suggestions5
export PREV_GENES_CORE="${SPECIES}_genes$((DB_VERSION-1))"     # grapevine_genes4 (conf template + diffs)
export PREV_SUGG_CORE="${SPECIES}_suggestions$((DB_VERSION-1))"
# The core the LIVE v4 site serves, and so the source of saved_search tags for
# `make restore-saved-search`. NB this is a core NAME, not a directory: on this host core
# names are shifted off their instanceDirs -- grapevine_suggestions3 lives in
# /solr/data/grapevine_suggestions3.1. Always address it by name, never by path.
# (grapevine_genes4 carries 0 saved_search docs, so restore-saved-search is a no-op here.)
export PREV_LIVE_GENES_CORE="${PREV_LIVE_GENES_CORE:-${SPECIES}_genes$((DB_VERSION-1))}"

# --- solr gene attribute tables -- MAKER/VEP are SorghumBase-only; leave empty
# (stage 60 warns + skips a missing table). grassius_homolog still projects fresh: this
# site's compara includes maize, sorghum and rice, so grape genes can legitimately acquire
# TF families through the trees. Report that count, do not assert it.
export MAKER_TABLE="${MAKER_TABLE:-}"
export VEP_TABLE="${VEP_TABLE:-}"

# --- gene stable id collisions ------------------------------------------------
# 40_genes_dump refuses to pass dumps in which two genomes claim the same gene stable id, because
# <db>.genes and the Solr core both key on it, so one copy would silently replace the other. List
# "genomeA:genomeB" pairs here ONLY after examining them and accepting the loss; anything not
# listed fails the stage. Empty is the correct value for a healthy release.
export STABLE_ID_COLLISION_ALLOW="${STABLE_ID_COLLISION_ALLOW:-}"

# --- node heaps ---------------------------------------------------------------
# The stage defaults (atlas 48G, decorate 24G, solr 16G) are sized for the 267-genome main
# release. This site is 1.37M genes against 16.1M -- about 1/12 -- and squam runs ~53 other
# services plus mongod and solr, so take proportionate heaps and leave the box headroom.
export ATLAS_HEAP="${ATLAS_HEAP:---max-old-space-size=16384}"
export DECORATE_HEAP="${DECORATE_HEAP:---max-old-space-size=12288}"
export SOLR_HEAP="${SOLR_HEAP:---max-old-space-size=8192}"

# --- services ----------------------------------------------------------------
export SOLR_URL="${SOLR_URL:-http://localhost:8983/solr}"
export SOLR_DATA_DIR="${SOLR_DATA_DIR:-/solr/data}"
# Serving tier. Grapevine uses a 40000+/41000+ port convention, NOT the 10000+/11000+ one
# 70_services.sh defaults to -- v4 runs on 40004/41004. Both 40005 and 41005 are free.
# The gorgonzola proxy for /grapevine_v5 -> squam:40005 and the ebeye route -> squam:41005
# are already open (they return 503 until these backends come up), so starting these
# services PUBLISHES the site: verify against local solr/mongo before 70_services.
export SWAGGER_PORT="${SWAGGER_PORT:-40005}"
export EBEYE_PORT="${EBEYE_PORT:-41005}"
export BASEPATH="${BASEPATH:-/${SPECIES}_v${DB_VERSION}}"          # /grapevine_v5
# NB data.grapevine.org does not exist; the subsite is served under data.gramene.org.
export SWAGGER_URL_PUBLIC="${SWAGGER_URL_PUBLIC:-https://data.gramene.org${BASEPATH}/swagger}"
# Used ONLY by the 10_maps assembly QC, which warns and never fails. The public plants REST
# does not carry the 36 Vitis cultivar assemblies, so the local registry
# (/usr/local/ensembl-87/ensembl-rest/reg.pm, which serves 91 species across every subsite
# and is what the live v4 site uses) is the right target here. UNVERIFIED for these 39
# genomes: read the coverage warning 10_maps prints and re-point this if it is poor.
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

# --- preflight invariants (grapevine v5 on cabot) ----------------------------
# v5 reuses the LIVE v4 source set verbatim, so gene models and gene trees are unchanged.
# All 42 dbs verified present on cabot. ensembl_db_info.json is copied from v4 and FROZEN:
# never run get_ensembl_db_info.js here, or a different genome set builds silently.
export EXPECT_CORES=39         # 39 *_core_*_87_* : 36 Vitis assemblies + arabidopsis, chlamydomonas,
                               # drosophila, oryza, selaginella, solanum, sorghum, zea_maysb73 outgroups.
                               # The v4_108 staging dir lists a DIFFERENT 27-core _108_ set against a
                               # different compara; it is deliberately not used.
export EXPECT_ANCHORS=0        # v4 has no `anchor` keys and maps.is_anchor is 0/39. Kept at 0:
                               # release70's reactome/get_species_prefixes.js is zero-anchor safe
                               # (it queries {type:'genome'} and falls back to taxon_id/1000), and
                               # grape pathway coverage is fixed in 25_reactome instead -- see
                               # reactome/duplicate_vv.js. Anchors would be a site-semantics change
                               # with no bearing on coverage.
export EXPECT_VARIATIONS=2     # oryza_sativa_variation_7_87_7, sorghum_bicolor_variation_6_87_30.
                               # Vitis has NO variation db, yet 20_variation still matters: these two
                               # produce the 55,440 QTL_TO genes, joined positionally not by id.

# --- subsite scale knobs ------------------------------------------------------
# Several stages hardcode floors written for a ~125-core release. Grapevine has 39 genomes,
# so those gates fail on a CORRECT build. Parameterised here rather than edited per stage.
export MAPS_MIN="${MAPS_MIN:-35}"            # 39 genomes; cores with 0 genes/no taxon are skipped
export TAXONOMY_MIN="${TAXONOMY_MIN:-100}"   # v4 produced 147, so 100 holds
# This compara has gene_tree_root tree_type='tree' ONLY for clusterset_id='default' (34,196,
# matching grapevine4.genetree exactly) and ZERO tree_type='supertree' rows. So there are no
# cultivar supertrees and stage 60's supertree assertion must not fire.
export EXPECT_SUPERTREES="${EXPECT_SUPERTREES:-0}"
# trees/verify_tree_shape.js --deep-report asserts that SOME tree exceeds 112 levels, because
# release 70 had 147 such trees and once lost them silently. That is a property of a 267-genome
# compara, not of the storage model. Measured on this build's 34,196 trees: deepest max_depth=69,
# 2 trees over 50, NONE over 80, and max_depth is set on all 34,196 -- which rules out both
# failures the assertion guards (deep trees dropped, or max_depth never written). search70 for
# contrast has 164 trees over 112 of 386,398, so the assertion is correct there and stays live
# wherever the expectation holds. 0 = report instead of assert.
export EXPECT_DEEP_TREES="${EXPECT_DEEP_TREES:-0}"

export MONGOSH="$(command -v mongosh || command -v mongo)"
