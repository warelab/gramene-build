#!/usr/bin/env bash
# 45_homologs — load the cross-species homolog hash into redis db ${REDIS_HOMOLOG_DB}.
# dump_homologs.js emits SELECT <db> + FLUSHDB then HSETs, so piping to redis-cli
# --pipe is self-cleaning (drop-then-rebuild) and idempotent. decorate.js's
# homolog_adder reads the SAME redis db.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 45_homologs

before="$(redis_dbsize "${REDIS_HOMOLOG_DB}")"
log "redis db ${REDIS_HOMOLOG_DB} before: ${before} keys"

cd "${MONGODB_REPO}/search"
# dump_homologs reads compara from ensembl_db_info.json; output is redis protocol
run bash -c "'${NODE_BIN}' ${BIG_HEAP} dump_homologs.js | redis-cli -h '${REDIS_HOST}' -p '${REDIS_PORT}' --pipe"

after="$(redis_dbsize "${REDIS_HOMOLOG_DB}")"
[ "${after:-0}" -gt 0 ] && ok "redis db ${REDIS_HOMOLOG_DB} now has ${after} homolog keys" \
  || die "redis db ${REDIS_HOMOLOG_DB} is empty after dump_homologs"
stage_end
