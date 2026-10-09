# Architecture

How the pieces fit together. See [README.md](../README.md) for what each individual build stage does.

## Data flow

```
 Ensembl MySQL (colden)             External sources
 ├─ 267 core databases              ├─ EBI Expression Atlas (GXA)
 ├─ ensembl_compara_plants_70_116   ├─ Plant Reactome (+ a local maize ver5 supplement)
 └─ 24 variation databases          ├─ GO / PO / TO ontologies + InterPro
          │                         ├─ Grassius (TF families)
          │                         ├─ NCBI GeneRIFs (via redis db 3)
          │                         └─ thalemine / RAP-DB (curated names)
          │                                   │
          └──────────────┬────────────────────┘
                         ▼
              MongoDB  search70              ← the assembly stage
                genes (16.1M, decorated)
                genetree 170,249, homologs 9.08M, maps 267, taxonomy 733,
                domains 54,190, GO 48,329, PO 1,793, TO 4,676,
                pathways 2,451, qtls 12,966,
                experiments 123, assays 2,102, expression,
                expression_attributes
                         │
                         ▼
              Solr  genes70 (≈16.1M docs)
                    suggestions70
                         │
                         ▼
              gramene-swagger  :10070  (REST API, /v70)
              gramene-ebeye    :11070  (EBI search export)
                         │
                         ▼
              Apache on gorgonzola → data.gramene.org
```

Three things are worth internalising:

**Mongo is the assembly area, Solr is the query surface.** The website never reads Mongo for gene
search — it queries Solr. Mongo holds the decorated documents so that a Solr core can be rebuilt
without re-running the expensive ETL. The one exception is user data (see below).

**"Decoration" is where the cost is.** `50_genes_decorate` takes the raw per-genome gene dumps and
folds in every auxiliary collection — trees, homologs, ontology terms, pathways, QTLs, curated
names, GeneRIFs, Grassius families. It is the longest stage and the one most likely to stall. At
16.1M genes this release is roughly three times the size of the SorghumBase subsite the pipeline
was built on, so plan memory accordingly — see [Resource budget](#resource-budget-on-squam) below
and [docs/04-troubleshooting.md](04-troubleshooting.md).

**Homologs are a mongo collection, not an in-process store.** `45_homologs` writes one doc per gene
(9,083,100 docs / 964M homolog values for this release) and `decorate`'s `homolog_adder` reads it in
`$in` batches. It used to be an LMDB bulk-load, but LMDB's memory map grew without bound *inside*
decorate's own RSS (~1 GB per 175k genes). mongod owns that cache now, so decorate's footprint stays
flat. `homolog_adder()` therefore takes **no argument** — if you see it being handed a path, you are
looking at the superseded design.

## The six repositories

All on `github.com/warelab`, all under `/usr/local/gramene/release70/`.

| repo | branch | role |
| --- | --- | --- |
| **build** | `release70` | this repo — orchestration (`Makefile`, `config.sh`, `stages/*.sh`) |
| **gramene-mongodb-config** | `main_v70` | `collections.js` — the single source of truth for db name, version, and collection list |
| **gramene-mongodb** | `release70` | the ETL: dumps, decoration, trees, ontologies, atlas loaders |
| **gramene-solr** | `release70` | Mongo → Solr conversion, attribute merging, suggestions, core configs |
| **gramene-swagger** | `release70` | the REST API served to the website |
| **gramene-ebeye** | `release70` | EBI Search XML export |

The four consumer repos depend on the config repo through a **local path** dependency
(`file:../gramene-mongodb-config`), not a GitHub branch. This matters — see
[docs/04-troubleshooting.md](04-troubleshooting.md#the-config-symlink).

Note that `gramene-mongodb-config` is on a differently-named branch (`main_v70`) whose merge base
with the others is old. It is **hand-edited, never cherry-picked** from a subsite branch: the
branches disagree on `dbName`/`dbVersion`, so a pick there retargets the whole build at another
database.

## Databases and services

| what | where | notes |
| --- | --- | --- |
| MySQL (source) | `colden:3306`, user `gramene_web` | read-only; 267 cores + compara + 24 variation |
| MongoDB | `localhost:27017` | db `search70`; **user data is in `userData1`** |
| Solr | `localhost:8983` | cores `genes70`, `suggestions70` |
| Redis | `localhost:6379` | db **3** = GeneRIFs (keyed by ensembl id), db **9** = homologs (legacy, unused) |
| Ensembl REST | `https://rest.ensembl.org` | maps QC. The **public plants** service — see below. |

### Which Ensembl REST

This is a repeated trap, because there are three plausible endpoints and two of them are wrong:

| endpoint | resolves (of 267 genomes) |
| --- | --- |
| `http://localhost:3000` | **0** — HTTP 400 for every one; its registry is dated 2024-03-14 |
| `https://data.gramene.org/pansite-ensembl-115` | **18** — it is the SorghumBase pan-genome panel |
| `https://rest.ensembl.org` | **all 267** |

The subsite moved to the pan-site because that genome set *is* the pan-site's. For the main release
that would leave ~250 genomes unverified. Expect intermittent HTTP 500s from the public service
under burst load — that is rate limiting, not a missing species, and the QC script currently has no
retry or backoff, so it over-reports "unavailable". maps QC is non-fatal, so this warns rather than
aborting.

### User data lives outside the release database

`userData1` holds `genelists` (saved gene lists) and `savedviews`. It is **shared across every
release** so a user's saved lists survive a version bump. A release rebuild must never drop it.

The link between a saved list and its genes is a hash: a list's genes are the Solr docs carrying
`saved_search:<hash>`. Nothing else records membership — `genelists` stores the hash, label and
count, never the member ids. Because the Solr core is rebuilt per release, those tags must be
propagated into each new core — `gramene-solr/scripts/sync_saved_search.js` does this
(`make restore-saved-search DRY=1` first). This is the one piece of state that flows *between*
releases.

The subsite additionally kept lists in per-site databases (`sorghum10`, `sorghum11`); the main
release uses the shared `userData1` alone.

## Ports

The convention is `SWAGGER_PORT = 10000 + version`, `EBEYE_PORT = 11000 + version`.

| release | swagger | ebeye | status |
| --- | --- | --- | --- |
| v70 | 10070 | 11070 | building |
| v69 | **10069** | 11069 | **live public site** |

`basePath` is `/v70` — bare, matching r69's `/v69`. Only the species subsites use
`/<species>_v<N>`, and they also run on a different port block (50000+), which is why a value
carried over from the subsite will not collide loudly; it will just quietly not answer.

Ports collide easily across the many releases on this host. `70_services` verifies the port edits it
makes rather than assuming them, because an earlier version silently left a port unchanged and
pointed ebeye at a port swagger never listened on. It likewise asks `solr.js` for its own `genesURL`
instead of grepping for the string it just wrote.

## Where things live

| path | what |
| --- | --- |
| `build/logs/<stage>.log` | per-stage logs (gitignored) |
| `build/.state/<stage>.done` | completion stamps (gitignored) |
| `build/tmp/` | scratch (gitignored) |
| `gramene-mongodb/search/tmp/*.json.gz` | the raw per-genome gene dumps (267 files, 4.3 GB) |
| `gramene-mongodb/search/tmp_homologs/` | compara column dumps + the sorted homolog flatfile (~15 GB) |
| `gramene-mongodb/search/tmp_homologs/sorttmp` | **symlink** to a filesystem that can hold a ~38 GB external sort |
| `gramene-mongodb/reactome/` | Plant Reactome downloads + the local maize ver5 (ZMY) supplement |
| `gramene-solr/genes/` | generated Solr JSON + attribute tables |
| `/usr/local/ensembl-87/ensembl-rest/reg.pm` | the shared local Ensembl REST registry (stale; see above) |

## Gene attribute layers

Beyond the decorated fields, the Solr gene docs carry several *attribute* layers merged in at
`60_solr_genes` by `add_attributes.pl`. Each becomes a `capability` plus typed fields:

* **grassius_homolog** — TF families projected onto homologs through the gene trees, so assemblies
  missing from Grassius still get a family annotation. Regenerated every build. **This is the layer
  that covers maize**, since GRASSIUS publishes v3/v4 maize ids and this release's maize is v5.
* **expression** — baseline expression summaries derived from the Atlas collections (stage 58).

**MAKER** and **VEP** are sorghum-specific and intentionally absent here (`MAKER_TABLE` and
`VEP_TABLE` are empty; stage 60 warns and skips a missing table). So is the **rsID** layer — a ~10M
doc suggestion category and `rsid__attr_ss` on the gene docs, built only for SorghumBase.

A layer can be refreshed *in place* without rebuilding the core:
`make refresh-attr ATTR=maker|vep|grassius|expression`.

⚠️ In-place refresh uses Solr atomic updates, which reconstruct each document from its **stored**
fields. A field that is indexed but not stored, and not a `copyField` target, is silently erased —
this once wiped `_terms` from 247,323 docs with every count still looking healthy.
`62_attr_atomic.sh --preflight` refuses to run against a schema that cannot survive it.

## Resource budget on squam

squam has ~251 GB of RAM and also runs mongod, the production Solr (8 GB heap, ~90 cores) and two
further Solr instances. The decorate stage is the pressure point.

* **Cap WiredTiger before `50_genes_decorate`.** At its 50%-of-RAM default mongod will hold ~125 GB,
  which plus a 48 GB decorate heap plus Solr pushes the box into swap.
  `db.adminCommand({setParameter:1, wiredTigerEngineRuntimeConfig:"cache_size=64G"})` takes effect
  immediately with no restart, and the live r69 site keeps serving through it.
* **`DECORATE_HEAP=--max-old-space-size=49152`** for the decorate itself.
* **`/solr`**: `genes70` projects to ~60 GB. Before freeing space by deleting old cores, read the
  **core name → `instanceDir`** mapping from `/solr/admin/cores?action=STATUS` — on this host the
  two do not match (the core named `genes69` lives in `/solr/data/genes69c`), so deleting by
  directory name is a coin flip. Unload by **name** with `deleteInstanceDir=true`, and re-query the
  live core between deletions.
* **`/usr/local`** is too small for the homolog sort; that is why `sorttmp` is a symlink.
