# Operations

Keeping the live services healthy. Nothing here is specific to a build being in progress.

## The services

Both run under **pm2** as user `olson` on squam.

| pm2 name | repo | port | serves |
| --- | --- | --- | --- |
| `sorghum_swagger11` | `gramene-swagger` | 50011 | REST API at `/sorghum_v11` |
| `sorghum_ebeye11` | `gramene-ebeye` | 51011 | EBI Search XML export |
| `sorghum_swagger10b` | v10b | 50010 | **live public site** |
| `sorghum_ebeye10b` | v10b | 51010 | live |

```bash
pm2 list                      # everything on the host (there are ~45 processes)
pm2 list | grep sorghum
pm2 logs sorghum_swagger11 --lines 100
pm2 restart sorghum_swagger11
```

### ⚠ Never run `pm2 restart all`

This host runs services for a dozen releases, and **several are deliberately stopped**. `pm2 restart
all` starts them, which causes `EADDRINUSE` port collisions with the releases that are supposed to
own those ports. This has happened. Restart processes by name.

## Health checks

```bash
# API up, and serving the right spec
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:50011/sorghum_v11/swagger

# Solr answering
curl -s 'http://localhost:8983/solr/sorghum_genes11/select?q=*:*&rows=0' | grep -o '"numFound":[0-9]*'

# Mongo up and holding the expected collections
mongosh --quiet sorghum11 --eval 'db.getCollectionNames().length'

# a real query end to end
curl -s 'http://localhost:50011/sorghum_v11/search?q=SORBI_3001G000200&rows=1' | head -c 300
```

If the API returns 502/connection-refused, check pm2 first (`pm2 list`), then whether Mongo and Solr
are actually up — swagger starts fine without them and fails per-request.

## When you change swagger/ebeye code

pm2 does **not** hot-reload. After editing anything under `gramene-swagger/api/` or `app.js`:

```bash
pm2 restart sorghum_swagger11
```

Verify the running process is newer than your edit — the timestamps are the proof:

```bash
pm2 jlist | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const p=JSON.parse(s).find(x=>x.name==="sorghum_swagger11");
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

```bash
cd ../gramene-solr
MONGO_URL='mongodb://localhost:27017/userData1,mongodb://localhost:27017/sorghum10b' \
SOURCE='http://localhost:8983/solr/sorghum_genes10b' \
TARGET='http://localhost:8983/solr/sorghum_genes11' \
node scripts/sync_saved_search.js --dry-run     # then without --dry-run
```

As of 2026-08-05 this reconciles 1,760/1,760 cleanly. The API for creating and reading lists is
documented in `../gramene-swagger/docs/gene_lists_api.md`.

## Backups and blast radius

There is no automated backup of `sorghum11` or the Solr cores — they are reproducible from source by
re-running the build. **`userData1` is not reproducible.** It holds real user content (29 gene lists,
21 saved views as of this writing) and nothing in the build regenerates it. If you are doing
anything that could touch it, dump it first:

```bash
mongodump --db userData1 --out ~/backups/userData1-$(date +%F)
```
