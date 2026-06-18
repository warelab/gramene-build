#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib.sh — shared helpers: logging, idempotency stamps, mongo/solr/redis ops,
#          and validation gates. Sourced by every stage script (after config.sh).
#
# Design goals (the point of the rewrite):
#   * every stage is RE-RUNNABLE: collections/cores are dropped-then-rebuilt,
#     never appended to, so a second run yields the same result as the first.
#   * every stage VALIDATES its own output and fails loudly (non-zero exit) if a
#     count is zero/short — the old recipe failed silently (empty dumps, empty
#     facets) and only surfaced the problem releases later.
#   * every stage is LOGGED to build/logs/<stage>.log and STAMPED in .state/.
# ─────────────────────────────────────────────────────────────────────────────

# ---- logging ----------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(_ts)] $*" >&2; }
ok()   { echo "[$(_ts)] ✓ $*" >&2; }
warn() { echo "[$(_ts)] ⚠ $*" >&2; }
die()  { echo "[$(_ts)] FATAL: $*" >&2; exit 1; }

# run a command, echoing it first; abort on failure
run() { log "+ $*"; "$@"; }

# ---- idempotency stamps -----------------------------------------------------
# A stage marks itself done so the Makefile/build.sh can skip it on rerun unless
# forced. Stamps are advisory: the stage logic itself is also idempotent.
stamp_done()  { mkdir -p "${STATE_DIR}"; date '+%Y-%m-%dT%H:%M:%S' > "${STATE_DIR}/$1.done"; }
stamp_clear() { rm -f "${STATE_DIR}/$1.done"; }
is_done()     { [ -f "${STATE_DIR}/$1.done" ]; }

# ---- mongo helpers ----------------------------------------------------------
# count docs in a collection of $MONGO_DB
mongo_count() {
  "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval "db.getCollection('$1').countDocuments({})" 2>/dev/null | tail -1
}
# drop a collection (idempotent — no error if absent)
mongo_drop() {
  log "drop ${MONGO_DB}.$1"
  "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval "db.getCollection('$1').drop()" >/dev/null 2>&1 || true
}
# run an arbitrary mongosh eval against the target db
mongo_eval() {
  "${MONGOSH}" --quiet "${MONGO_URI}/${MONGO_DB}" --eval "$1"
}
# assert a collection has at least N docs
assert_mongo_min() {
  local coll="$1" min="$2" n
  n="$(mongo_count "$coll")"
  n="${n:-0}"
  if [ "$n" -lt "$min" ]; then die "${MONGO_DB}.${coll} has $n docs (expected >= $min)"; fi
  ok "${MONGO_DB}.${coll} = $n docs (>= $min)"
}

# ---- solr helpers -----------------------------------------------------------
solr_core_exists() {
  curl -s "${SOLR_URL}/admin/cores?action=STATUS&core=$1&wt=json" \
    | grep -q "\"name\":\"$1\""
}
solr_numdocs() {
  curl -s "${SOLR_URL}/$1/select?q=*:*&rows=0&wt=json" \
    | "${NODE_BIN}" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).response.numFound)}catch(e){console.log(0)}})'
}
# create a fresh core from a conf template dir, unloading+wiping any existing one
# usage: solr_recreate_core <core_name> <conf_src_dir>
solr_recreate_core() {
  local core="$1" conf="$2"
  local inst="${SOLR_DATA_DIR}/${core}"
  if solr_core_exists "$core"; then
    log "unloading existing solr core $core"
    curl -s "${SOLR_URL}/admin/cores?action=UNLOAD&core=${core}&deleteIndex=true" >/dev/null || true
  fi
  log "creating solr core $core (instanceDir=$inst)"
  rm -rf "${inst}/conf"        # drop any stale conf from a prior run
  mkdir -p "${inst}/conf"
  cp -r "${conf}/." "${inst}/conf/"
  # The solr daemon runs as a different user and must be able to write
  # core.properties + its data/ dir here. We can't chown to solr without sudo,
  # so make the instanceDir world-writable (solr then owns the data it creates).
  chmod -R 777 "${inst}" 2>/dev/null || warn "could not chmod ${inst}"
  curl -s "${SOLR_URL}/admin/cores?action=CREATE&name=${core}&instanceDir=${inst}&config=solrconfig.xml" >/dev/null \
    || die "solr CREATE failed for ${core}"
  solr_core_exists "$core" || die "solr core ${core} not present after CREATE"
  ok "solr core ${core} created empty"
}
solr_commit() { curl -s "${SOLR_URL}/$1/update?commit=true" -H 'Content-type:application/json' --data-binary '{}' >/dev/null; }
# bulk-load a json docs file, committing; aborts on solr error
solr_load_json() {
  local core="$1" file="$2"
  [ -s "$file" ] || die "solr load: $file is empty/missing"
  local resp
  resp="$(curl -s "${SOLR_URL}/${core}/update?commit=true" -H 'Content-type:application/json' --data-binary @"$file")"
  echo "$resp" | grep -q '"status":0' || die "solr load of $file into $core failed: $resp"
  ok "loaded $(basename "$file") into ${core}"
}
# stream-load a large mongo2solr array file into a core in batches (memory-safe;
# upserts by id so re-running is idempotent). Use for the multi-GB genes file.
solr_load_json_chunked() {
  local core="$1" file="$2" batch="${3:-10000}"
  [ -s "$file" ] || die "solr load: $file is empty/missing"
  SOLR_URL="${SOLR_URL}" "${NODE_BIN}" "${BUILD_DIR}/solr_chunk_load.js" "$core" "$file" "$batch" \
    || die "chunked solr load of $file into $core failed"
  ok "chunk-loaded $(basename "$file") into ${core}"
}

# ---- redis helpers ----------------------------------------------------------
redis_dbsize() { redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -n "$1" dbsize | awk '{print $1}'; }

# ---- file/json validation ---------------------------------------------------
assert_nonempty_file() { [ -s "$1" ] || die "expected non-empty file: $1"; ok "file ok: $1 ($(wc -c <"$1") bytes)"; }
assert_valid_json() {
  "${NODE_BIN}" -e 'const fs=require("fs");try{const j=JSON.parse(fs.readFileSync(process.argv[1]));const n=Array.isArray(j)?j.length:Object.keys(j).length;if(!n)throw new Error("empty");console.error("  json ok: "+process.argv[1]+" ("+n+" entries)")}catch(e){console.error("INVALID JSON "+process.argv[1]+": "+e.message);process.exit(1)}' "$1" \
    || die "invalid/empty json: $1"
}

# ---- stage scaffolding ------------------------------------------------------
# Call at the top of a stage:  stage_begin <name>
# It tees all output to the stage log and records start time.
stage_begin() {
  STAGE_NAME="$1"
  mkdir -p "${LOG_DIR}"
  exec > >(tee -a "${LOG_DIR}/${STAGE_NAME}.log") 2>&1
  log "════════════ STAGE ${STAGE_NAME} starting (target=${MONGO_DB}) ════════════"
}
stage_end() {
  stamp_done "${STAGE_NAME}"
  ok "════════════ STAGE ${STAGE_NAME} complete ════════════"
}
