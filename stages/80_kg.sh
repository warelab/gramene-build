#!/usr/bin/env bash
# 80_kg — build the gramene-kg knowledge graph of this release (kg00 .. kg70 in /usr/local/gramene/gramene-kg).
#
# Reads this release's mongo db, Solr cores and files; writes only its own kg_<release>_b<build> db and
# Solr core (and kg_curation.attach_reports). Promotion (make -C .../gramene-kg/build promote) stays manual.
# Not in `all` and the Makefile target has no stamp prerequisites: this script checks the stages the KG
# reads instead, so `make 80_kg` can never trigger a rebuild of the release's own collections or cores.
# Every run starts a NEW kg build (NEW_BUILD=1: kg00 mints a BUILD_ID and clears the kg stamps), because
# nothing here can tell whether the release data or the published curation changed since the last one;
# KG_RESUME=1 make 80_kg resumes the current kg build instead (after a failed stage). .state/80_kg.done
# only records that the last run succeeded (removed at start and by the refresh-* targets). MySQL
# credentials from config.sh are not passed on (the KG never reads MySQL).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 80_kg

is_done 65_solr_suggestions && is_done 22_germplasm \
  || die "80_kg needs 65_solr_suggestions and 22_germplasm done (make status)"
stamp_clear 80_kg

# NEW_BUILD on the make command line, so a NEW_BUILD left in the caller's environment cannot change it
if [ "${KG_RESUME:-0}" = 1 ]; then new_build=; log "KG_RESUME=1: resuming the current kg build"; else new_build=1; fi
run env -u MYSQL_PASS -u MYSQL_USER -u MYSQL_HOST make -C /usr/local/gramene/gramene-kg/build RELEASE_ROOT="$RELEASE_ROOT" NEW_BUILD="$new_build" build \
  || die "gramene-kg build failed; see /usr/local/gramene/gramene-kg/logs/ and make -C /usr/local/gramene/gramene-kg/build RELEASE_ROOT=$RELEASE_ROOT status"

stage_end
