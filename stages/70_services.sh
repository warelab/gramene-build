#!/usr/bin/env bash
# 70_services — prepare the serving tier (gramene-swagger + gramene-ebeye) for this
# release: apply the deterministic per-release source edits the old recipe did by
# hand, then print the manual infra checklist (apache proxy / firewall / ensembl
# REST registry / BLAST). Does NOT start anything unless START_SERVICES=1.
#
# Ports follow the convention PORT = 10000 + dbVersion unless overridden:
#   SWAGGER_PORT (default $((10000+DB_VERSION)))   EBEYE_PORT (default $((11000+DB_VERSION)))
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 70_services

SWAGGER_PORT="${SWAGGER_PORT:-$((10000+DB_VERSION))}"
EBEYE_PORT="${EBEYE_PORT:-$((11000+DB_VERSION))}"
BASEPATH="/${SPECIES}_v${DB_VERSION}"
SWAGGER_URL_LOCAL="http://localhost:${SWAGGER_PORT}${BASEPATH}/swagger"

log "swagger basePath=${BASEPATH} port=${SWAGGER_PORT}; ebeye port=${EBEYE_PORT}"

# ---- gramene-swagger edits (idempotent perl -pi) ----
SY="${SWAGGER_REPO}/api/swagger/swagger.yaml"
perl -pi -e "s{^basePath:.*}{basePath: ${BASEPATH}};" "${SY}"
perl -pi -e "s{^  title:.*}{  title: API for ${SPECIES}base release ${DB_VERSION}};" "${SY}"
ok "swagger.yaml basePath -> ${BASEPATH}"

# point solr.js at the live solr host (was hardcoded squam)
SJ="${SWAGGER_REPO}/api/helpers/solr.js"
solr_host="$(echo "${SOLR_URL}" | sed -E 's#https?://##; s#/solr.*##')"
perl -pi -e "s{var urlBase = 'https?://[^/]+/solr/${SPECIES}_';}{var urlBase = '${SOLR_URL}/${SPECIES}_';}" "${SJ}"
grep -q "${SOLR_URL}/${SPECIES}_" "${SJ}" && ok "solr.js urlBase -> ${SOLR_URL}/${SPECIES}_" || warn "solr.js urlBase not updated — check ${SJ} manually"

# swagger port. Both `var port = 5010;` and `var port = process.env.PORT || 5010;` occur in the
# wild — the older pattern only matched the first, silently left the port untouched, and still
# printed ok. That mismatch is how ebeye ended up pointed at a port swagger never listened on.
# Match either form, then VERIFY rather than assume.
perl -pi -e "s{var port = (?:process\.env\.PORT \|\| )?\d+;}{var port = process.env.PORT || ${SWAGGER_PORT};}" "${SWAGGER_REPO}/app.js"
grep -qE "var port = process\.env\.PORT \|\| ${SWAGGER_PORT};" "${SWAGGER_REPO}/app.js" \
  && ok "swagger app.js port -> ${SWAGGER_PORT}" \
  || die "could not set the swagger port in ${SWAGGER_REPO}/app.js — check it by hand"

# ---- gramene-ebeye edits ----
EA="${EBEYE_REPO}/app.js"
perl -pi -e "s{const DEFAULT_PORT = \d+;}{const DEFAULT_PORT = ${EBEYE_PORT};}" "${EA}"
perl -pi -e "s{defaultServer: \"[^\"]*\"}{defaultServer: \"${SWAGGER_URL_LOCAL}\"}" "${EA}"
grep -q "const DEFAULT_PORT = ${EBEYE_PORT};" "${EA}" && grep -q "defaultServer: \"${SWAGGER_URL_LOCAL}\"" "${EA}" \
  && ok "ebeye app.js DEFAULT_PORT=${EBEYE_PORT}, defaultServer=${SWAGGER_URL_LOCAL}" \
  || die "could not set the ebeye port/defaultServer in ${EA} — check it by hand"

# ---- optionally (re)start under pm2 ----
if [ "${START_SERVICES:-0}" = "1" ] && command -v pm2 >/dev/null; then
  log "starting services under pm2"
  ( cd "${SWAGGER_REPO}" && pm2 start app.js --name "${SPECIES}_swagger${DB_VERSION}" --update-env || pm2 restart "${SPECIES}_swagger${DB_VERSION}" )
  sleep 2
  ( cd "${EBEYE_REPO}" && pm2 start app.js --name "${SPECIES}_ebeye${DB_VERSION}" --update-env || pm2 restart "${SPECIES}_ebeye${DB_VERSION}" )
  curl -sf "http://localhost:${SWAGGER_PORT}${BASEPATH}/swagger" >/dev/null && ok "swagger responding on ${SWAGGER_PORT}" || warn "swagger not responding yet"
else
  warn "services not started (set START_SERVICES=1 to pm2-start swagger+ebeye)"
fi

cat >&2 <<EOF
──────────────────────────────────────────────────────────────────────────────
 MANUAL DEPLOYMENT CHECKLIST (infra steps the build cannot safely automate)
──────────────────────────────────────────────────────────────────────────────
 1. Apache reverse proxy (gorgonzola: conf/extra/httpd-ssl.conf, under
    data.${SPECIES}base.org):  ${BASEPATH} -> $(hostname):${SWAGGER_PORT}
    then: apachectl configtest && apachectl graceful
 2. Open firewall to ${SWAGGER_PORT} (swagger) and ${EBEYE_PORT} (ebeye).
 3. Ensembl REST (${ENSEMBL_REST}): add the new sorghum11 cores/compara/variation
    to the registry (reg.pm) and restart so the genome browser + maps QC resolve
    every genome (preflight/maps flagged genomes missing from the registry).
 4. BLAST: re-run ensure_blast.pl with the updated registry --out_dir the blast
    BLAST_DB_ROOT, then restart the gramene-blast api under pm2.
 5. gene-tree curation UI (gramene-genetree-vis): point defaultServerSb at
    ${SWAGGER_URL_LOCAL}.
──────────────────────────────────────────────────────────────────────────────
EOF
stage_end
