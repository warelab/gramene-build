#!/usr/bin/env bash
# 51_synonym_conflicts — drop synonyms that are another LOCUS's identifier.
#
# Runs BETWEEN decorate and the solr build on purpose. decorate writes gene.synonyms from the
# stage-40 dumps, which carry the contamination (see synonym_conflict_patch.js for the mechanism:
# dump_genes.js joins external_synonym against the display xref, and a Uniprot_gn xref row is keyed
# on the bare gene SYMBOL, so two genes abbreviating to the same symbol inherit each other's ids).
# Cleaning here means 60_solr_genes builds the core from already-clean mongo and no index patch is
# needed on a full build.
#
# Idempotent, so re-running `make all` over a built site is harmless.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 51_synonym_conflicts

assert_mongo_min genes 1000

MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" \
  "${NODE_BIN}" "${BUILD_DIR}/synonym_conflict_patch.js" --apply || die "synonym_conflict_patch failed"

# Report what is left, so a change in the upstream xrefs shows up as a number rather than silence.
remaining="$(MONGO_URI="${MONGO_URI}" MONGO_DB="${MONGO_DB}" \
  "${NODE_BIN}" "${BUILD_DIR}/synonym_conflict_patch.js" | grep -E '^genes to change' | awk '{print $NF}')"
[ "${remaining:-0}" -eq 0 ] || die "synonym conflicts remain after the patch (${remaining}) -- not idempotent"
ok "no cross-locus synonyms remain"

stage_end
