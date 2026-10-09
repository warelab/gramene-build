# Operations

Keeping the live services healthy. Nothing here is specific to a build being in progress.

## The services

Both run under **pm2** as user `olson` on squam.

| pm2 name | repo | port | serves |
| --- | --- | --- | --- |
| `gramene_swagger70` | `gramene-swagger` | 10070 | REST API at `/v70` — **not created yet**; `70_services` does it |
| `gramene_ebeye70` | `gramene-ebeye` | 11070 | EBI Search XML export |
| `gramene_swagger69` | release69 | 10069 | **live public site** |
| `gramene_ebeye69` | release69 | 11069 | live |

```bash
pm2 list                      # everything on the host (59 processes as of this writing)
pm2 list | grep gramene_
pm2 logs gramene_swagger70 --lines 100
pm2 restart gramene_swagger70
```

Note the naming: main releases are `gramene_swagger<N>`; the species subsites are
`<species>_swagger<N>` on the 50000+ port block. Releases 65–69 and a dozen subsites all live on
this host.

### ⚠ Never run `pm2 restart all`

This host runs services for a dozen releases, and **several are deliberately stopped** — as of this
writing `gramene_swagger65`, `gramene_ebeye65`, four sorghum subsites, `uncc_test_swagger1` and
`gramene-mcp-sorghum10`. `pm2 restart all` starts them, which causes `EADDRINUSE` port collisions
with the releases that are supposed to own those ports. This has happened. Restart processes by
name, and never `pm2 restart all` — there is nothing in this build that needs it.

## Health checks

```bash
# API up, and serving the right spec
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:10070/v70/swagger

# Solr answering
curl -s 'http://localhost:8983/solr/genes70/select?q=*:*&rows=0&wt=json' | grep -o '"numFound":[0-9]*'

# Mongo up and holding the expected collections
mongosh --quiet search70 --eval 'db.getCollectionNames().length'

# a real query end to end
curl -s 'http://localhost:10070/v70/search?q=SORBI_3001G000200&rows=1' | head -c 300
```

The live previous release, for comparison (these should keep working throughout a build):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:10069/v69/swagger
curl -s 'http://localhost:8983/solr/genes69/select?q=*:*&rows=0&wt=json' | grep -o '"numFound":[0-9]*'
```

If the API returns 502/connection-refused, check pm2 first (`pm2 list`), then whether Mongo and Solr
are actually up — swagger starts fine without them and fails per-request.

## When you change swagger/ebeye code

pm2 does **not** hot-reload. After editing anything under `gramene-swagger/api/` or `app.js`:

```bash
pm2 restart gramene_swagger70
```

Verify the running process is newer than your edit — the timestamps are the proof:

```bash
pm2 jlist | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const p=JSON.parse(s).find(x=>x.name==="gramene_swagger70");
  console.log("started",new Date(p.pm2_env.pm_uptime).toISOString())})'
stat -c '%y %n' gramene-swagger/api/controllers/*.js
```

Better still, verify by *behaviour* — hit an endpoint and confirm it returns the new shape. A
process that restarted is not proof it loaded what you think it did.

## Logs

| what | where |
| --- | --- |
| build stages | `build/logs/<stage>.log` |
| swagger / ebeye | `pm2 logs <name>`, files under `~/.pm2/logs/` |
| gene-list cleanup cron | `~/logs/cleanup_genelists.log` |
| Solr | `/solr/logs/` (or via the Solr admin UI at `:8983`) |

## Cron jobs (user `olson`)

```
0  0 * * 0  ~/bin/truncate_blast_log.sh          # weekly
3  *  * * *  ~/bin/check_blast.sh                # hourly BLAST liveness
30 2 * * *  ~/bin/cleanup_genelists.sh           # daily; purges soft-deleted gene lists >30d
```

`cleanup_genelists.sh` runs `gramene-solr/scripts/cleanup_expired_genelists.js`. It touches **Mongo
only** — it never removes `saved_search` tags from Solr. That is deliberate: tag cleanup across
releases is a separate concern.

## User gene lists

Stored in `userData1.genelists` (shared across releases — see
[docs/01-architecture.md](01-architecture.md#user-data-lives-outside-the-release-database)).

Propagating saved lists into a new release's Solr core:

Use the make target, which wires up the right cores and databases from `config.sh`:

```bash
cd ../build
make restore-saved-search DRY=1     # then without DRY
```

It reads `userData1` only — the per-site `sorghum*` databases are a subsite thing — and copies
forward from `PREV_LIVE_GENES_CORE` (`genes69`) into `SOLR_GENES_CORE` (`genes70`), keeping only
hashes that still exist in a `genelists` collection.

**Expect 0 restored on the first v70 build, and do not read that as a bug.** `genes69` carries
`saved_search` tags on only 14 documents across 8 hashes, and none of those hashes exists in any
`genelists` collection — all 62 surviving lists are `site:'sorghum'`. The tooling is propagated to
protect the *next* rebuild.

It also accepts a file as its source, for restoring from a dump rather than the previous live core:

```bash
cd ../gramene-solr
MONGO_URL='mongodb://localhost:27017/userData1' \
SOURCE='file:/path/to/saved_search_backup.json' \
TARGET='http://localhost:8983/solr/genes70' \
node scripts/sync_saved_search.js --dry-run
```

A Solr envelope, a bare array, or JSONL all work, and a dump whose `numFound` exceeds the documents
actually present is rejected rather than partially applied. The API for creating and reading lists
is documented in `../gramene-swagger/docs/gene_lists_api.md`.

## Checking for new Expression Atlas studies

```bash
cd ../gramene-mongodb/atlas
MONGO_DB=search70 node check_new_atlas_experiments.js          # new RNA-Seq studies for hosted genomes
MONGO_DB=search70 SINCE=2026 node check_new_atlas_experiments.js
MONGO_DB=search70 ALL=1 node check_new_atlas_experiments.js    # + species GXA has that we do not host
```

Read-only: one JSON fetch from GXA diffed against the local `experiments` collection. Defaults to
**RNA-Seq only** — this pipeline has never loaded microarray, and GXA plants are roughly half
microarray, so without the filter the report is swamped by ~500 studies nobody wants.

Species matching is by name, falling back to genus. The fallback matters, because GXA's species
names and our munged display names diverge. Genus-only hits are reported separately as near matches
for eyeballing rather than silently included or dropped.

This release additionally builds a descendant→genome taxon remap from compara's `ncbi_taxa_node`
(`atlas/build_taxon_remap.js` → `taxon_remap.json`, 277 remaps for 135 genome species taxa), so a
study annotated with a subspecies or cultivar taxon still lands on the genome we host. It is
non-fatal: `getAtlasData` falls back to its static map if the file is missing.

To load what it finds, `make add-studies` (see
[docs/02-build-runbook.md](02-build-runbook.md#adding-a-few-new-atlas-studies-much-cheaper-than-a-refresh)).

## Backups and blast radius

There is no automated backup of `search70` or the Solr cores — they are reproducible from source by
re-running the build. **`userData1` is not reproducible.** It holds real user content (62 gene
lists, 34 saved views as of this writing) and nothing in the build regenerates it. If you are doing
anything that could touch it, dump it first:

```bash
mongodump --db userData1 --out ~/backups/userData1-$(date +%F)
```
