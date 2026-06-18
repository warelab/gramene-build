#!/usr/bin/env bash
# 00_preflight — verify the environment is sane BEFORE we write any data.
# Fails loudly on anything that would make a downstream stage silently produce
# garbage (wrong db version, unreachable mysql, missing anchor flags, etc.).
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 00_preflight

fail=0
need() { command -v "$1" >/dev/null 2>&1 && ok "tool: $1" || { warn "MISSING tool: $1"; fail=1; }; }
for t in node npm "${MONGOSH##*/}" redis-cli curl perl mysql gzip; do need "$t"; done

log "target mongo db   = ${MONGO_DB} (version ${DB_VERSION})"
log "previous release  = ${PREV_DB}"
log "solr genes core   = ${SOLR_GENES_CORE}"
log "solr suggest core = ${SOLR_SUGG_CORE}"
log "compara           = ${COMPARA_DB}"
log "mysql source      = ${MYSQL_USER}@${MYSQL_HOST}"

# --- config is the LOCAL checkout (single source of truth) -------------------
cfg_link="${MONGODB_REPO}/node_modules/gramene-mongodb-config"
if [ -L "${cfg_link}" ]; then ok "gramene-mongodb-config is a symlink to the local checkout"; \
  else warn "gramene-mongodb-config in node_modules is NOT a symlink — local edits may not take effect"; fi
got_db="$(cd "${MONGODB_REPO}" && "${NODE_BIN}" -e 'var c=require("gramene-mongodb-config");process.stdout.write(c.getMongoConfig().db);setTimeout(()=>process.exit(0),50)')"
[ "${got_db}" = "${MONGO_DB}" ] && ok "ETL config resolves to ${got_db}" || { warn "ETL config resolves to ${got_db}, expected ${MONGO_DB}"; fail=1; }

# --- ensembl_db_info.json invariants ----------------------------------------
[ -f "${ENSEMBL_DB_INFO}" ] || { warn "missing ${ENSEMBL_DB_INFO}"; fail=1; }
read -r ncores nvar nanchor jcompara < <("${NODE_BIN}" -e '
  const j=require("'"${ENSEMBL_DB_INFO}"'");
  const anchors=(j.cores||[]).filter(c=>c.anchor).length;
  console.log((j.cores||[]).length, (j.variations||[]).length, anchors, j.compara.database);')
[ "${ncores}" = "${EXPECT_CORES}" ]     && ok "cores=${ncores}"           || { warn "cores=${ncores}, expected ${EXPECT_CORES}"; fail=1; }
[ "${nvar}" = "${EXPECT_VARIATIONS}" ]  && ok "variations=${nvar}"        || { warn "variations=${nvar}, expected ${EXPECT_VARIATIONS}"; fail=1; }
[ "${nanchor}" = "${EXPECT_ANCHORS}" ]  && ok "anchor cores=${nanchor}"   || { warn "anchor cores=${nanchor}, expected ${EXPECT_ANCHORS}"; fail=1; }
[ "${jcompara}" = "${COMPARA_DB}" ]     && ok "compara matches"           || { warn "compara mismatch: ${jcompara} vs ${COMPARA_DB}"; fail=1; }

# --- live services ----------------------------------------------------------
"${MONGOSH}" --quiet "${MONGO_URI}/admin" --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 \
  && ok "mongo reachable at ${MONGO_URI}" || { warn "mongo unreachable"; fail=1; }
if "${MONGOSH}" --quiet "${MONGO_URI}/${PREV_DB}" --eval 'db.genes.countDocuments({})' >/dev/null 2>&1; then
  ok "previous release ${PREV_DB} present (will NOT be modified)"
fi
curl -sf "${SOLR_URL}/admin/cores?action=STATUS&wt=json" >/dev/null && ok "solr reachable at ${SOLR_URL}" || { warn "solr unreachable"; fail=1; }
redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping >/dev/null 2>&1 && ok "redis reachable" || { warn "redis unreachable"; fail=1; }
curl -sf "${ENSEMBL_REST}/info/ping?content-type=application/json" >/dev/null && ok "ensembl-rest reachable at ${ENSEMBL_REST}" || warn "ensembl-rest unreachable (only needed for maps QC + VEP)"

# --- mysql source dbs exist -------------------------------------------------
mysqlq() { mysql -h "${MYSQL_HOST}" -u "${MYSQL_USER}" -p"${MYSQL_PASS}" -N -e "$1" 2>/dev/null; }
ccount="$(mysqlq "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${COMPARA_DB}'")"
[ "${ccount}" = "1" ] && ok "compara db present on ${MYSQL_HOST}" || { warn "compara db ${COMPARA_DB} not found on ${MYSQL_HOST}"; fail=1; }

# --- source data actually LOADED, not just schema present -------------------
# (release70 cores can exist as empty shells before the data import runs; without
#  this, the build fails mid-stage with a cryptic 'taxon_id in ()' SQL error.)
gdb_rows="$(mysqlq "SELECT COUNT(*) FROM ${COMPARA_DB}.genome_db")"
[ "${gdb_rows:-0}" -gt 0 ] 2>/dev/null \
  && ok "compara has data (genome_db=${gdb_rows})" \
  || { warn "compara ${COMPARA_DB} is EMPTY (genome_db=${gdb_rows:-0}) — source data not loaded on ${MYSQL_HOST}"; fail=1; }
core1="$("${NODE_BIN}" -e 'console.log((require("'"${ENSEMBL_DB_INFO}"'").cores[0]||{}).database||"")')"
if [ -n "${core1}" ]; then
  c1g="$(mysqlq "SELECT COUNT(*) FROM ${core1}.gene")"
  [ "${c1g:-0}" -gt 0 ] 2>/dev/null \
    && ok "cores loaded (e.g. ${core1}: ${c1g} genes)" \
    || { warn "core ${core1} has 0 genes — cores not loaded on ${MYSQL_HOST}"; fail=1; }
fi

vdb="$("${NODE_BIN}" -e 'const v=(require("'"${ENSEMBL_DB_INFO}"'").variations||[]); process.stdout.write(v[0]&&v[0].database?v[0].database:"")')"
if [ -n "${vdb}" ]; then
  vcount="$(mysqlq "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${vdb}'")"
  [ "${vcount}" = "1" ] && ok "variation db ${vdb} present on ${MYSQL_HOST}" || warn "variation db ${vdb} not found"
else
  log "no variation dbs declared in ensembl_db_info.json (skipping variation check)"
fi

if [ "${fail}" -ne 0 ]; then die "preflight failed — fix the warnings above before building"; fi
stage_end
