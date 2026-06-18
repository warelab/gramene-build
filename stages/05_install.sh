#!/usr/bin/env bash
# 05_install — install node deps in every repo. Uses the LOCAL gramene-mongodb-config
# (file:../gramene-mongodb-config) so the on-disk collections.js (sorghum11) is the
# single source of truth — no GitHub branch drift (the old git+ssh pins resolved to
# oryza7 / sorghum_v7 and silently targeted the wrong db).
#
# Self-contained: does NOT source config.sh up front, because config.sh derives the
# db name by require()-ing collections.js, which needs node_modules to exist first.
set -euo pipefail
RELEASE_ROOT="/usr/local/gramene/subsites/sorghum/v11"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*" >&2; }

# 1) config module first (its own deps: old mongodb@2 driver, lodash@3, q@1)
say "installing gramene-mongodb-config deps"
( cd "${RELEASE_ROOT}/gramene-mongodb-config" && npm install --no-audit --no-fund --ignore-scripts )

# 2) consumers — each now has file:../gramene-mongodb-config
for repo in gramene-mongodb gramene-solr gramene-swagger gramene-ebeye; do
  say "installing deps in ${repo}"
  ( cd "${RELEASE_ROOT}/${repo}" && npm install --no-audit --no-fund --ignore-scripts )
done

# 3) now config.sh can load — verify the config the ETL code will actually use
. "${RELEASE_ROOT}/build/config.sh"
. "${RELEASE_ROOT}/build/lib.sh"
stage_begin 05_install
for repo in "${MONGODB_REPO}" "${SOLR_REPO}"; do
  got="$(cd "${repo}" && "${NODE_BIN}" -e 'var c=require("gramene-mongodb-config");process.stdout.write(c.getMongoConfig().db);setTimeout(()=>process.exit(0),50)')"
  [ "${got}" = "${MONGO_DB}" ] || die "${repo} resolves gramene-mongodb-config to '${got}', expected '${MONGO_DB}'"
  ok "${repo} -> gramene-mongodb-config = ${got}"
done
stage_end
