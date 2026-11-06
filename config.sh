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
export RELEASE_ROOT="/usr/local/gramene/subsites/maize/v6"
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

# --- target databases (DERIVED from collections.js: dbName='maize', dbVersion='6') ---
_mongo_json="$("${NODE_BIN}" -e 'try{var c=require("'"${MONGOCONFIG_REPO}"'/collections.js");process.stdout.write(JSON.stringify(c.getMongoConfig()));setTimeout(()=>process.exit(0),50)}catch(e){process.stderr.write("CONFIG_LOAD_FAILED: "+e.message);process.exit(3)}' 2>/dev/null || true)"
if [ -z "${_mongo_json}" ]; then
  echo "FATAL: could not load ${MONGOCONFIG_REPO}/collections.js -- run 'make 05_install' first (it needs node_modules); expects dbName='maize' dbVersion='6'" >&2
  return 1 2>/dev/null || exit 1
fi
export MONGO_HOST="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).host))')"
export MONGO_PORT="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).port))')"
export DB_VERSION="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"
export MONGO_DB="$(echo "$_mongo_json" | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).db))')"   # maize6
export MONGO_URI="mongodb://${MONGO_HOST}:${MONGO_PORT}"

# --- solr cores: a SUBSITE prefixes its cores with $SPECIES (maize_genes6) ---
export SPECIES="maize"
export PREV_DB="${SPECIES}$((DB_VERSION-1))"                   # maize5
export SOLR_GENES_CORE="${SPECIES}_genes${DB_VERSION}"         # maize_genes6
export SOLR_SUGG_CORE="${SPECIES}_suggestions${DB_VERSION}"    # maize_suggestions6
export PREV_GENES_CORE="${SPECIES}_genes$((DB_VERSION-1))"     # maize_genes5 (conf template + diffs)
export PREV_SUGG_CORE="${SPECIES}_suggestions$((DB_VERSION-1))"
# The core the LIVE v5 site serves, and so the source of saved_search tags for
# `make restore-saved-search`. NB this is a core NAME, not a directory: on this host core
# names are shifted off their instanceDirs -- maize_genes5 and maize_genes5a BOTH hold
# 2,834,112 docs under directories of the same two names, and grapevine_suggestions3 lives in
# /solr/data/grapevine_suggestions3.1. Always address it by name, never by path.
export PREV_LIVE_GENES_CORE="${PREV_LIVE_GENES_CORE:-${SPECIES}_genes$((DB_VERSION-1))}"

# --- solr gene attribute tables ------------------------------------------------
# MAKER is SorghumBase-only: maize_genes5 has no MAKER capability, so leave it empty
# (stage 60 warns + skips a missing table).
# VEP is different here -- maize_genes5 DOES carry a VEP capability on 75,237 genes, but no
# reusable table survived: gramene-solr/vep/ in v5 holds only the generator
# (dump_gene_level_VEP_table.pl, munge_vep.pl) and 69-72 byte stubs, and v5's actual input was a
# solr_genes.VEP.json with no surviving source. So the table is REGENERATED for v6 from
# zea_maysb73_variation_9_108_8 -- see `make vep-table`. Until that has run the file is absent
# and stage 60 will warn and skip, which would silently drop a v5 capability: check the
# "genes with VEP capability" line stage 60 prints against v5's 75,237.
# grassius_homolog projects fresh regardless; report that count, do not assert it.
export MAKER_TABLE="${MAKER_TABLE:-}"
export VEP_TABLE="${VEP_TABLE:-${SOLR_REPO}/vep/vep_attributes.txt}"

# --- gene stable id collisions ------------------------------------------------
# 40_genes_dump refuses to pass dumps in which two genomes claim the same gene stable id, because
# <db>.genes and the Solr core both key on it, so one copy would silently replace the other. List
# "genomeA:genomeB" pairs here ONLY after examining them and accepting the loss; anything not
# listed fails the stage. Empty is the correct value for a healthy release.
# 151 gene stable ids are claimed by BOTH zea_maysb73v3 and zea_maysb73v4. Examined, and accepted
# rather than "fixed": every one of the 151 is a miRBase name (zma-MIR1432, zma-MIR156a, ...) with
# zero exceptions. miRBase names are not assembly-versioned, so the same miRNA gene carries the
# same id in the B73 v3 and v4 annotations. This is correct upstream naming, not the wrong-prefix
# error the checker's message suggests looking for (cf. triticum_aestivum_alchemy, where r69 used
# TraesALC* and r70 the reference's TraesCS*).
#
# The live v5 site already ships this collapse, and v6 reproduces it exactly. The dump holds
# 2,834,263 ids of which 2,834,112 are distinct -- and 2,834,112 is maize5.genes to the document.
# Which copy survives is decided by load order, and the arithmetic says v3 wins: v4 dumps 44,474
# ids and maize5 stores 44,323 for it, exactly 151 fewer, while v3 keeps all 39,625.
#
# So 151 v4 miRNA genes are genuinely dropped, here as in v5. That is a real if small data loss
# and the checker says so plainly ("genes are still being dropped for those pairs -- this only
# stops it blocking"). Giving each annotation version its own id space would be a source-core
# change affecting the live site, so it is recorded here rather than done as a side effect of a
# rebuild whose premise is that gene models do not move.
export STABLE_ID_COLLISION_ALLOW="${STABLE_ID_COLLISION_ALLOW:-zea_maysb73v3:zea_maysb73v4}"

# --- node heaps ---------------------------------------------------------------
# The stage defaults (atlas 48G, decorate 24G, solr 16G) are sized for the 267-genome main
# release. This site is 1.37M genes against 16.1M -- about 1/12 -- and squam runs ~53 other
# services plus mongod and solr, so take proportionate heaps and leave the box headroom.
# maize is 2.83M genes over 63 genomes -- about 2x grapevine v5 and ~1/6 of the 16.1M main
# release -- so these sit between the two. Measured headroom when this was set: 251 GB total,
# 97 GB available, with mongod holding 90 GB of WiredTiger cache and solr 26 GB. Stages run
# sequentially so only one of these is live at a time. Never restart mongod to reclaim memory
# (it would drop maize5, sorghum11, search69/70 and every other live db); cap WiredTiger at
# runtime instead if decorate pressures the box.
export ATLAS_HEAP="${ATLAS_HEAP:---max-old-space-size=32768}"
export DECORATE_HEAP="${DECORATE_HEAP:---max-old-space-size=24576}"
export SOLR_HEAP="${SOLR_HEAP:---max-old-space-size=16384}"

# --- services ----------------------------------------------------------------
export SOLR_URL="${SOLR_URL:-http://localhost:8983/solr}"
export SOLR_DATA_DIR="${SOLR_DATA_DIR:-/solr/data}"
# Serving tier. Maize uses a 30000+/31000+ port convention, NOT the 10000+/11000+ one
# 70_services.sh defaults to -- v5 runs on 30005/31005. Both 30006 and 31006 are free.
# UNLIKE grapevine v5, the gorgonzola proxy is NOT open yet: https://data.gramene.org/maize_v6
# returns 404 (not 503), i.e. no route exists. It must be pointed at squam:30006, and the ebeye
# route at squam:31006, before 70_services can verify the public URL. Build everything else
# first; that stage is last for exactly this reason.
export SWAGGER_PORT="${SWAGGER_PORT:-30006}"
export EBEYE_PORT="${EBEYE_PORT:-31006}"
export BASEPATH="${BASEPATH:-/${SPECIES}_v${DB_VERSION}}"          # /maize_v6
# NB data.maize.org does not exist; the subsite is served under data.gramene.org.
export SWAGGER_URL_PUBLIC="${SWAGGER_URL_PUBLIC:-https://data.gramene.org${BASEPATH}/swagger}"
# The swagger merged from release70 carries the primer-design and genotyping subsystems. Both
# default to enabled and derive their site_key from swagger.yaml's basePath, so without this they
# would advertise endpoints on /maize_v6 with no site configuration behind them. Disabled here
# for the same reason as grapevine v5: the per-site config (site_key -> genome list -> assembly
# paths) is its own piece of work, not a by-product of this build. Unlike grapevine, maize DOES
# have a variation database for its reference (zea_maysb73_variation_9_108_8), so genotyping is
# a credible follow-up here rather than impossible -- but it still needs that configuration.
export PRIMERS_ENABLED="${PRIMERS_ENABLED:-false}"
# Used ONLY by the 10_maps assembly QC, which warns and never fails. 56 of these 63 genomes are
# zea/pan-maize cultivar assemblies that the public plants REST does not carry, so the local
# registry is the right target, as for grapevine. UNVERIFIED for this genome set: read the
# coverage warning 10_maps prints and re-point this if it is poor.
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

# --- preflight invariants (maize v6 on cabot) --------------------------------
# v6 reuses the LIVE v5 source set, so gene models and gene trees are unchanged -- with two
# corrections, because v5's ensembl_db_info.json records two databases that no longer exist:
#
#  * compara. v5 records ensembl_compara_4_87_maize0225, which is ABSENT from cabot (wrong
#    version prefix AND wrong schema). The real source is ensembl_compara_5_108_maize0225,
#    identified by matching tree counts: it has exactly 39,709 tree_type='tree'
#    clusterset_id='default' rows, and maize5.genetree holds exactly 39,709 docs. Using it keeps
#    trees identical to the live v5 site, which is the point of reusing the set at all.
#  * sorghum variation. v5 records sorghum_bicolor_variation_8_108_30, also absent; versions
#    7/9/10/11 exist at schema 108. Replaced with _11_108_30 (newest) by explicit decision, so
#    QTL and QTL_TO counts may come out ABOVE v5's floor rather than matching it -- check them
#    rather than assuming a match.
#
# All 67 dbs (1 compara + 63 cores + 3 variations) verified present on cabot after those edits.
# ensembl_db_info.json is otherwise copied from v5 and FROZEN: never run
# get_ensembl_db_info.js here, or a different genome set builds silently.
#
# NB this is a schema-108 site throughout (all 63 cores are *_core_*_108_*, the compara is _108_).
# grapevine v5 was schema 87 and the main release is 116, so the harness is known to tolerate
# all three -- but any schema-specific SQL is worth a second look if a stage misbehaves.
export EXPECT_CORES=63         # 56 zea/pan-maize assemblies + 7 outgroups: arabidopsis,
                               # chlamydomonas, drosophila, oryza, selaginella, sorghum, vitis.
export EXPECT_ANCHORS=8        # the 7 outgroups + zea_maysb73. Unlike grapevine (0 anchors), this
                               # is the ordinary case for reactome/get_species_prefixes.js.
export EXPECT_VARIATIONS=3     # oryza_sativa_variation_8_108_7, zea_maysb73_variation_9_108_8,
                               # sorghum_bicolor_variation_11_108_30 (substituted, see above).
                               # The oryza + sorghum pair is what produces QTL_TO genes, joined
                               # positionally not by id; the zea one additionally feeds VEP.

# --- subsite scale knobs ------------------------------------------------------
# Several stages hardcode floors written for a ~125-core release. Grapevine has 39 genomes,
# so those gates fail on a CORRECT build. Parameterised here rather than edited per stage.
export MAPS_MIN="${MAPS_MIN:-55}"            # 63 genomes; cores with 0 genes/no taxon are skipped
export TAXONOMY_MIN="${TAXONOMY_MIN:-100}"   # v5 produced 157, so 100 holds
# Verified on ensembl_compara_5_108_maize0225: gene_tree_root holds tree_type='tree' (185,139
# across all clustersets, of which 39,709 are clusterset_id='default' -- matching maize5.genetree
# exactly) and tree_type='clusterset' (13). There are ZERO tree_type='supertree' rows, so despite
# 56 cultivar assemblies there are no cultivar supertrees and stage 60's supertree assertion must
# not fire.
export EXPECT_SUPERTREES="${EXPECT_SUPERTREES:-0}"
# trees/verify_tree_shape.js --deep-report asserts that SOME tree exceeds 112 levels, because
# release 70 had 147 such trees and once lost them silently. That is a property of a 267-genome
# compara, not of the storage model. NOT yet measured for this build -- set to 0 (report instead
# of assert) so a first run cannot fail on it, and read the depth histogram stage 35 prints. With
# 63 genomes maize may well be deeper than grapevine (max 69), so if trees over 112 do exist
# here, turn this back on rather than leaving the guard disabled.
export EXPECT_DEEP_TREES="${EXPECT_DEEP_TREES:-0}"

export MONGOSH="$(command -v mongosh || command -v mongo)"
