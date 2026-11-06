#!/usr/bin/env bash
# 15_ontologies — build GO, PO, TO (from OBO) and domains (from InterPro XML).
#   * GO/PO/TO via populate.js -> mongoimport --drop (idempotent).
#   * domains via parseInterpro.js which is insert-only, so we DROP it first.
#   * ancestor indexes via index.js.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 15_ontologies

ONT="${MONGODB_REPO}/ontologies"
cd "${ONT}"
mkdir -p tmp

# ---- InterPro domains ----
# Fetch with a fallback chain, because the single https URL this used to be broke the stage on
# 2026-11-04: https://ftp.ebi.ac.uk/ refuses the connection outright (curl exit 7) while plain
# ftp://ftp.ebi.ac.uk/ answers and https://www.ebi.ac.uk/ is fine -- i.e. the ftp host's TLS
# listener, not our network. A one-URL curl turns that into a dead build for a transport problem.
#
# Order: https (preferred, resumes cleanly), then ftp (verified working), then reuse an existing
# known-good copy via INTERPRO_REUSE_FROM -- e.g.
#   make 15_ontologies INTERPRO_REUSE_FROM=/usr/local/gramene/release70/gramene-mongodb/ontologies/tmp
# Reuse is a deliberate last resort: it pins domains to another release's InterPro snapshot, so the
# stage says loudly which copy it used.
INTERPRO_BASE_HTTPS="https://ftp.ebi.ac.uk/pub/databases/interpro/current_release"
INTERPRO_BASE_FTP="ftp://ftp.ebi.ac.uk/pub/databases/interpro/current_release"

fetch_interpro() {   # $1 = filename
  local f="$1"
  if curl -fsSL --max-time 1800 "${INTERPRO_BASE_HTTPS}/${f}" -o "tmp/${f}.part"; then
    mv "tmp/${f}.part" "tmp/${f}"; log "  ${f}: https"; return 0
  fi
  warn "  ${f}: https failed, trying ftp"
  if curl -fsS --max-time 1800 "${INTERPRO_BASE_FTP}/${f}" -o "tmp/${f}.part"; then
    mv "tmp/${f}.part" "tmp/${f}"; log "  ${f}: ftp"; return 0
  fi
  rm -f "tmp/${f}.part"
  if [ -n "${INTERPRO_REUSE_FROM:-}" ] && [ -s "${INTERPRO_REUSE_FROM}/${f}" ]; then
    cp -p "${INTERPRO_REUSE_FROM}/${f}" "tmp/${f}"
    warn "  ${f}: REUSED from ${INTERPRO_REUSE_FROM} (not freshly downloaded)"
    return 0
  fi
  die "could not obtain ${f} over https or ftp, and INTERPRO_REUSE_FROM is unset or has no ${f}.
 Check https://ftp.ebi.ac.uk/ and ftp://ftp.ebi.ac.uk/ by hand, or point INTERPRO_REUSE_FROM at a
 directory holding a known-good copy."
}

log "downloading InterPro ParentChildTreeFile + interpro.xml.gz"
fetch_interpro ParentChildTreeFile.txt
fetch_interpro interpro.xml.gz
assert_nonempty_file tmp/ParentChildTreeFile.txt
assert_nonempty_file tmp/interpro.xml.gz
gzip -t tmp/interpro.xml.gz || die "tmp/interpro.xml.gz is not a valid gzip -- a partial or
 error-page download would otherwise surface as a confusing parseInterpro failure."

mongo_drop domains      # parseInterpro is insert-only; clear for a clean rebuild
log "parsing InterPro into ${MONGO_DB}.domains"
gzip -cd tmp/interpro.xml.gz | "${NODE_BIN}" ${BIG_HEAP} parseInterpro.js tmp/ParentChildTreeFile.txt /dev/fd/0

# ---- GO / PO / TO ----
# populate.js downloads each OBO, runs obo2json.pl, mongoimports with --drop.
log "building GO/PO/TO collections"
"${NODE_BIN}" populate.js -t tmp

# ---- ancestor-lookup indexes ----
log "creating ancestor indexes"
"${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" index.js

assert_mongo_min GO 30000
assert_mongo_min PO 1000
assert_mongo_min TO 3000
assert_mongo_min domains 30000
stage_end
