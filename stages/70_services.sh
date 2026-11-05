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
# The MAIN release serves a bare /v<N> (r69 serves /v69); only the species subsites use a
# <species>_v<N> prefix. Getting this wrong points Apache at a path swagger never answers.
# Main release serves /v70; a subsite serves /<species>_v<N> (/grapevine_v5, /sorghum_v11).
# config.sh sets it, so honour that rather than forcing the main-release shape.
BASEPATH="${BASEPATH:-/v${DB_VERSION}}"
SWAGGER_URL_LOCAL="http://localhost:${SWAGGER_PORT}${BASEPATH}/swagger"
# ebeye's defaultServer is what BROWSERS resolve, so it must be the public proxied URL, not the
# localhost one -- ebeye hands it to the client, which cannot reach squam directly. Every other
# release follows this shape: r69 https://data.gramene.org/v69/swagger, r68 .../v68/swagger,
# maize .../maize_v5/swagger, sorghum https://data.sorghumbase.org/sorghum_v11/swagger.
# Override with SWAGGER_URL_PUBLIC if the proxy ever lands somewhere else.
# NB the data.${SPECIES}.org form only works for SorghumBase. There is no data.grapevine.org:
# the grapevine subsite is served under data.gramene.org/grapevine_v4 today, and v5 at
# data.gramene.org/grapevine_v5. config.sh sets this explicitly; the default below is
# data.gramene.org so a site that forgets to does not end up with a hostname that does not exist.
SWAGGER_URL_PUBLIC="${SWAGGER_URL_PUBLIC:-https://data.gramene.org${BASEPATH}/swagger}"

log "swagger basePath=${BASEPATH} port=${SWAGGER_PORT}; ebeye port=${EBEYE_PORT}"

# ---- gramene-swagger edits (idempotent perl -pi) ----
SY="${SWAGGER_REPO}/api/swagger/swagger.yaml"
perl -pi -e "s{^basePath:.*}{basePath: ${BASEPATH}};" "${SY}"
# r69's title is "API for gramene release 69" -- SPECIES is already "gramene" here, so the
# subsite's "${SPECIES}base" would read "gramenebase".
perl -pi -e "s{^  title:.*}{  title: API for ${SPECIES} release ${DB_VERSION}};" "${SY}"

# REMOVE any pinned `host:`. swagger-client fetches the spec and then builds every API request URL
# from the spec's own host/schemes/basePath, so a stale host sends the client somewhere else
# entirely: release70 inherited `host: data.sorghumbase.org` from the sorghum_v11 lineage, which
# would have had ebeye fetch the spec from data.gramene.org/v70/swagger and then issue its API
# calls against data.sorghumbase.org/v70/... r69, r68 and maize/v5 all OMIT host, which is both the
# main-release convention and the robust choice -- the client then infers it from wherever it got
# the spec, so the same spec works via the public proxy and over localhost.
perl -ni -e 'print unless /^host:/' "${SY}"
grep -qE '^host:' "${SY}" && die "swagger.yaml still pins a host: $(grep -E '^host:' "${SY}")" \
  || ok "swagger.yaml host: removed (client infers it from the spec URL)"
grep -qE "^basePath: ${BASEPATH}\$" "${SY}" || die "swagger.yaml basePath is not ${BASEPATH}"
ok "swagger.yaml basePath -> ${BASEPATH}"

# point solr.js at the live solr host (was hardcoded squam)
SJ="${SWAGGER_REPO}/api/helpers/solr.js"
solr_host="$(echo "${SOLR_URL}" | sed -E 's#https?://##; s#/solr.*##')"
# Main-release cores are BARE (genes70/suggestions70); only subsites prefix them
# (sorghum_genes11). solr.js builds `${urlBase}genes${version}`, so urlBase must end at
# /solr/. The old pattern required the existing value to already read /solr/${SPECIES}_ --
# after the sorghum_v11 merge it reads /solr/sorghum_, so it matched nothing, warned, and
# would have left the API querying a core named sorghum_genes70 that does not exist.
# This is a SUBSITE, so cores are prefixed and urlBase must end at /solr/${SPECIES}_ -- it is
# the main release that wants a bare /solr/. Getting this wrong is how the v4 checkout shipped
# `/solr/oryza_` in the repo for two years with only an uncommitted local edit papering over it.
# The genesURL assertion below is what actually catches it either way; this just makes it right.
perl -pi -e "s{var urlBase = '[^']*';}{var urlBase = '${SOLR_URL}/${SPECIES}_';}" "${SJ}"
want_core="${SOLR_URL}/${SOLR_GENES_CORE}"
got_core="$(cd "${SWAGGER_REPO}" && "${NODE_BIN}" -e 'process.stdout.write(require("./api/helpers/solr.js").genesURL)' 2>/dev/null)"
[ "${got_core}" = "${want_core}" ] \
  && ok "solr.js genesURL -> ${got_core}" \
  || die "solr.js genesURL is '${got_core}', expected '${want_core}' — check ${SJ}"

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
perl -pi -e "s{defaultServer: \"[^\"]*\"}{defaultServer: \"${SWAGGER_URL_PUBLIC}\"}" "${EA}"
grep -q "const DEFAULT_PORT = ${EBEYE_PORT};" "${EA}" && grep -q "defaultServer: \"${SWAGGER_URL_PUBLIC}\"" "${EA}" \
  && ok "ebeye app.js DEFAULT_PORT=${EBEYE_PORT}, defaultServer=${SWAGGER_URL_PUBLIC}" \
  || die "could not set the ebeye port/defaultServer in ${EA} — check it by hand"

# ---- primers subsystem ----
# config/default.yaml is the only place `primers.enabled` can be set persistently: the DEFAULTS
# in api/helpers/primers/config.js hardcode `enabled: true`, and that file is deep-frozen, so a
# site that cannot serve primers must say so here. This site needs it off unless its genomes are
# configured in the primers config (site_key -> genome list -> assembly/BLAST paths); the helper
# also expects primer3_core/ntthal/blastn to exist. Derived from config.sh, not hand-edited, so
# it cannot drift the way the old uncommitted serving-tier edits did.
PCFG="${SWAGGER_REPO}/config/default.yaml"
if [ -f "${PCFG}" ] && grep -qE '^primers:' "${PCFG}"; then
  # only the `enabled:` directly inside the primers block -- NOT repeat_mask.enabled or
  # variation.enabled, which are nested two spaces deeper and must keep their own values.
  perl -0pi -e "s{(^primers:\n(?:[^\S\n][^\n]*\n)*?[ ]{2}enabled:[ ]*)(?:true|false)}{\${1}${PRIMERS_ENABLED}}m" "${PCFG}"
  grep -qE "^[ ]{2}enabled:[ ]*${PRIMERS_ENABLED}\b" "${PCFG}" \
    && ok "swagger primers.enabled -> ${PRIMERS_ENABLED}" \
    || die "could not set primers.enabled in ${PCFG} — check it by hand"
else
  log "  no primers block in ${PCFG} — nothing to set"
fi

# ---- optionally (re)start under pm2 ----
if [ "${START_SERVICES:-0}" = "1" ] && command -v pm2 >/dev/null; then
  SWAGGER_NAME="${SPECIES}_swagger${DB_VERSION}"
  EBEYE_NAME="${SPECIES}_ebeye${DB_VERSION}"

  # ORDERING MATTERS, and getting it wrong crash-loops ebeye.
  #
  # ebeye does not merely advertise defaultServer to browsers -- swagger-client FETCHES that URL at
  # startup and builds its API request URLs from the spec it gets back (see gramene-ebeye/app.js).
  # So ebeye cannot start until the PUBLIC url serves the spec, which needs swagger running AND the
  # apache proxy configured AND the firewall open to ${SWAGGER_PORT}. On the first v70 deploy this
  # block started both two seconds apart: swagger came up fine, the public url was still 503
  # because the firewall had not been opened, and ebeye restarted 125 times before being stopped by
  # hand, hammering the proxy with a spec fetch each time.
  #
  # So: start swagger, prove it locally, then WAIT for the public url, and only then start ebeye.
  # If the public url never comes up we skip ebeye and say exactly which of the three links to fix
  # -- a stopped ebeye is recoverable in one command, a crash loop is noise in the proxy logs.
  log "starting ${SWAGGER_NAME} under pm2"
  ( cd "${SWAGGER_REPO}" && pm2 start app.js --name "${SWAGGER_NAME}" --update-env >/dev/null 2>&1 \
      || pm2 restart "${SWAGGER_NAME}" --update-env >/dev/null 2>&1 )

  SW_WAIT="${SW_WAIT:-60}"
  t0=$(date +%s)
  until curl -sf --max-time 5 "${SWAGGER_URL_LOCAL}" >/dev/null 2>&1; do
    [ $(( $(date +%s) - t0 )) -lt "${SW_WAIT}" ] || break
    sleep 3
  done
  if curl -sf --max-time 5 "${SWAGGER_URL_LOCAL}" >/dev/null 2>&1; then
    ok "swagger responding locally on ${SWAGGER_PORT} ($(( $(date +%s) - t0 ))s)"
  else
    die "swagger did not answer ${SWAGGER_URL_LOCAL} within ${SW_WAIT}s — check: pm2 logs ${SWAGGER_NAME}"
  fi

  PUB_WAIT="${PUB_WAIT:-90}"
  log "waiting for the public spec url (ebeye fetches it at startup): ${SWAGGER_URL_PUBLIC}"
  t0=$(date +%s)
  until curl -sf --max-time 8 "${SWAGGER_URL_PUBLIC}" >/dev/null 2>&1; do
    [ $(( $(date +%s) - t0 )) -lt "${PUB_WAIT}" ] || break
    sleep 5
  done
  if curl -sf --max-time 8 "${SWAGGER_URL_PUBLIC}" >/dev/null 2>&1; then
    ok "public spec url serving ($(( $(date +%s) - t0 ))s)"
    log "starting ${EBEYE_NAME} under pm2"
    ( cd "${EBEYE_REPO}" && pm2 start app.js --name "${EBEYE_NAME}" --update-env >/dev/null 2>&1 \
        || pm2 restart "${EBEYE_NAME}" --update-env >/dev/null 2>&1 )
    t0=$(date +%s)
    until [ -n "$(ss -tln 2>/dev/null | awk -v p=":${EBEYE_PORT}" '$4 ~ p"$"')" ]; do
      [ $(( $(date +%s) - t0 )) -lt 60 ] || break
      sleep 3
    done
    if [ -n "$(ss -tln 2>/dev/null | awk -v p=":${EBEYE_PORT}" '$4 ~ p"$"')" ]; then
      ok "ebeye listening on ${EBEYE_PORT}"
      # A listener is not stability: it printed "listening" on every one of those 125 restarts.
      r1="$(pm2 jlist 2>/dev/null | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s).find(x=>x.name===process.argv[1]);console.log(p?p.pm2_env.restart_time:-1)}catch(e){console.log(-1)}})' "${EBEYE_NAME}")"
      sleep 25
      r2="$(pm2 jlist 2>/dev/null | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s).find(x=>x.name===process.argv[1]);console.log(p?p.pm2_env.restart_time:-1)}catch(e){console.log(-1)}})' "${EBEYE_NAME}")"
      [ "${r1}" = "${r2}" ] \
        && ok "ebeye stable (restart count held at ${r2} over 25s)" \
        || warn "ebeye restart count moved ${r1} -> ${r2} — it is looping; pm2 logs ${EBEYE_NAME}"
    else
      warn "ebeye did not listen on ${EBEYE_PORT} within 60s — pm2 logs ${EBEYE_NAME}"
    fi
  else
    pm2 describe "${EBEYE_NAME}" >/dev/null 2>&1 && pm2 stop "${EBEYE_NAME}" >/dev/null 2>&1
    warn "public spec url ${SWAGGER_URL_PUBLIC} did not serve within ${PUB_WAIT}s — ebeye NOT started."
    warn "  ebeye fetches that url at startup, so starting it now would just crash-loop."
    warn "  Check, in order: (1) apache proxy ${BASEPATH} -> $(hostname):${SWAGGER_PORT} on the proxy host,"
    warn "  (2) firewall open to ${SWAGGER_PORT} from that host, (3) swagger itself (it IS answering locally)."
    warn "  Then: pm2 start ${EBEYE_NAME}"
  fi
else
  warn "services not started (set START_SERVICES=1 to pm2-start swagger+ebeye)"
fi

cat >&2 <<EOF
──────────────────────────────────────────────────────────────────────────────
 MANUAL DEPLOYMENT CHECKLIST (infra steps the build cannot safely automate)
──────────────────────────────────────────────────────────────────────────────
 1. Apache reverse proxy (gorgonzola: conf/extra/httpd-ssl.conf, under the
    PUBLIC host of ${SWAGGER_URL_PUBLIC} -- NOT data.${SPECIES}.org, which for a
    subsite does not exist):  ${BASEPATH} -> $(hostname):${SWAGGER_PORT}
    then: apachectl configtest && apachectl graceful
 2. Open firewall to ${SWAGGER_PORT} (swagger) and ${EBEYE_PORT} (ebeye).
 3. Ensembl REST (${ENSEMBL_REST}) and 4. BLAST: needed only if this release
    CHANGED its Ensembl cores/compara. A rebuild that reuses the previous
    release's ensembl_db_info.json (same ${EXPECT_CORES} cores, same compara --
    diff it to be sure) needs NEITHER: the registry already resolves these
    genomes and the BLAST databases already exist.
      reg.pm serves ~91 species across EVERY subsite, so editing it to add
      cores that are already there risks breaking unrelated sites. Check first:
      diff this release's gramene-mongodb/ensembl_db_info.json against the
      previous release's, and only touch the registry if the core list differs.
 5. gene-tree curation UI (gramene-genetree-vis): point defaultServerSb at
    ${SWAGGER_URL_PUBLIC}  (browser-facing, so the public proxied URL).
──────────────────────────────────────────────────────────────────────────────
EOF
stage_end
