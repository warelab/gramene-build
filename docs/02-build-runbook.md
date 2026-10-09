# Build runbook

Operating the build. For what each stage *does*, see [README.md](../README.md).

## The basics

```bash
cd /usr/local/gramene/release70/build
make status          # which stages are stamped done
make running         # what is executing RIGHT NOW (status only shows completions)
make all             # build everything that isn't done
```

`make status` shows completion stamps, which is not the same as "nothing is running". Use
`make running` to see live activity — it greps for the known stage processes and shows the three
most recently touched logs.

A full build from nothing takes well over a day on this release. Measured here: `45_homologs`
~1 h 40 m (a ~60 min merge-join over 1.06B compara homologies, a 10 min external sort of 964M
lines, then a 16 min load of 9.08M gene docs), and `50_genes_decorate` / `60_solr_genes` scale from
the subsite's ~1 h / ~1.5 h by roughly 3x on gene count (16.1M vs 5.4M). Budget accordingly, and
read [the resource notes](../README.md#resource-notes-for-this-host) *before* starting the
decorate — at mongod's default cache size this box swaps.

## Running a single stage

```bash
make 25_reactome              # via make (respects dependencies)
bash stages/25_reactome.sh    # directly (ignores dependencies — you are on your own)
```

Every stage tees to `logs/<stage>.log` and stamps `.state/<stage>.done` only on success. A failed
stage leaves no stamp, so re-running `make all` retries exactly it.

## Resuming after a failure or an interruption

Just re-run `make all`. Stamps make it skip what already completed. Stages are idempotent — they
drop and rebuild their own target — so re-running one never leaves half-merged data.

If you need to force a stage to re-run, delete its stamp:

```bash
rm .state/50_genes_decorate.done && make all
```

`make clean-stamps` forgets *all* completions without touching any data. That means a full rebuild,
so use it deliberately.

## Refreshing after new upstream data

Each target invalidates exactly the stamps affected by that kind of change, then rebuilds:

| new data | command |
| --- | --- |
| new compara | `make refresh-compara` |
| new / changed cores | `make refresh-genes` |
| new Expression Atlas | `make refresh-expression` |
| new Plant Reactome | `make refresh-reactome` |
| new GO/PO/TO/InterPro | `make refresh-ontologies` |
| new Grassius download | `make refresh-grassius` |

### Adding a few new Atlas studies (much cheaper than a refresh)

A new Expression Atlas study affects **one genome**, so rebuilding everything is the wrong shape —
a full `make refresh-expression` costs about **3 hours** (55: 19 min, 58: 50 min, 60: 103 min,
65: 7 min) and drops the Solr genes core. Instead:

```bash
make add-studies                                        # auto-discover new RNA-Seq studies
make add-studies ACCESSIONS="E-MTAB-8969,E-MTAB-10280"   # explicit
FORCE=1 make add-studies ACCESSIONS="E-MTAB-8969"        # re-load one already present
```

It fetches and upserts just those experiments, rebuilds expression attributes for **only the
affected genomes**, then patches the genes core **in place** via Solr atomic updates — no drop, no
downtime — and rebuilds the `expr` suggestion category. Studies already loaded are skipped unless
`FORCE=1`; each addition is recorded in `.state/atlas_studies.tsv`.

Discover what is available first with
`MONGO_DB=search70 node ../gramene-mongodb/atlas/check_new_atlas_experiments.js` (see
[docs/03-operations.md](03-operations.md)).

Use `make refresh-expression` instead for a first build or a wholesale reload.

**A new study barely changes the `expression` document count** — it adds a *field* to existing
gene documents rather than creating new ones. Judge success by experiment presence, not doc counts.

### Attribute-only refreshes (much cheaper)

When only an attribute table changed and the decorated genes did not, patch the Solr core **in
place** — no drop, no downtime:

```bash
make refresh-attr ATTR=grassius     # or expression  (maker/vep are not used in this release)
```

The heavier `make refresh-attributes` regenerates the merged attribute JSON and reloads all 16.1M
docs. Use it when several layers changed at once; use `refresh-attr` for one.

⚠️ In-place refresh uses Solr atomic updates, which rebuild each document from its **stored** fields
— an indexed-but-unstored field is silently erased. `62_attr_atomic.sh --preflight` blocks this and
should not be bypassed; see
[docs/04-troubleshooting.md](04-troubleshooting.md#atomic-updates-erase-indexed-but-not-stored-fields).

## Monitoring a long stage

```bash
tail -f logs/50_genes_decorate.log
make running
```

Decorate prints per-adder counters. If the counters stop advancing but the process is alive, see
[docs/04-troubleshooting.md](04-troubleshooting.md#decorate-stalls) — this has happened, four times
in a row, and the cause was not what it looked like.

## Killing a build safely

**Do not `pkill -f 'make all'`.** The pattern matches the cmdline of the shell you are typing in and
will kill your own session. Find the PID and kill it explicitly:

```bash
pgrep -af 'make all|stages/[0-9]'
kill <pid>
```

A killed stage leaves no stamp, so the next `make all` re-runs it from the top. Stages are
idempotent, so this is safe — but a killed `60_solr_genes` may leave a partially loaded core, which
the next run recreates from scratch anyway.

## Tunables

Set as environment variables:

| var | default | what |
| --- | --- | --- |
| `DUMP_PARALLELISM` | 6 | concurrent genome dumps in `40_genes_dump` |
| `SOLR_URL` | `http://localhost:8983/solr` | |
| `ENSEMBL_REST` | `https://rest.ensembl.org` | the **public plants** service; `:3000` resolves 0 of 267 genomes |
| `MAKER_TABLE` / `VEP_TABLE` | **empty** | sorghum-only; stage 60 warns and skips a missing table |
| `REBUILD_CORE=1` | — | force-recreate the Solr genes core |
| `GT_PREFIX` | `SB<version>GT_` | synthetic gene-tree id prefix; never used here (all trees have real `EPlGT*` ids) |
| `SWAGGER_PORT` / `EBEYE_PORT` | 10070 / 11070 | `70_services` |
| `DECORATE_HEAP` | see `config.sh` | node heap for `50_genes_decorate`; use `--max-old-space-size=49152` here |
| `SAVED_SEARCH_MONGO_URL` | `…/userData1` | source dbs for `restore-saved-search` |
| `START_SERVICES=1` | off | let `70_services` pm2-start the services |

## Verifying a finished build

Beyond the stage guards, sanity-check the result before publishing:

```bash
# Solr doc counts should match Mongo (expect ~16,127,051 = sum of maps.num_genes)
mongosh --quiet search70 --eval 'db.genes.countDocuments({})'
curl -s 'http://localhost:8983/solr/genes70/select?q=*:*&rows=0&wt=json' | grep -o '"numFound":[0-9]*'

# every genome represented, with sane counts (267 genomes; none >1% short of maps.num_genes)
mongosh --quiet search70 --eval 'db.maps.find({type:"genome"},{system_name:1,num_genes:1,taxon_id:1}).toArray()'

# attribute coverage (grassius_homolog and expression; MAKER/VEP are absent by design)
curl -s 'http://localhost:8983/solr/genes70/select?q=grassius_homolog__attr_ss:*&rows=0&wt=json' | grep -o '"numFound":[0-9]*'

# the maize pathway fix actually landed (expect ~1518, not 0)
curl -s 'http://localhost:8983/solr/genes70/select?q=capabilities:pathways+AND+system_name:zea_mays&rows=0&wt=json' | grep -o '"numFound":[0-9]*'

# no rsID suggestion category leaked in from the subsite
curl -s 'http://localhost:8983/solr/suggestions70/select?q=category:*rsID*&rows=0&wt=json' | grep -o '"numFound":[0-9]*'

# the API answers
curl -s 'http://localhost:10070/v70/swagger' | head -c 200
```

Compare against the previous release rather than against absolute numbers: `search69.genes` holds
11,773,843 and this release expects **16,127,051**, a jump driven by added genomes. A change of
*zero*, or of 10x, means something is wrong. `genes69` is still live and queryable for side-by-side
field checks — mind that its core name is bare (`genes69`), and that on this host core names do not
match their directories.
