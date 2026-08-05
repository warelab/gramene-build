# Architecture

How the pieces fit together. See [README.md](../README.md) for what each individual build stage does.

## Data flow

```
 Ensembl MySQL (cabot)              External sources
 ├─ 128 core databases              ├─ EBI Expression Atlas (GXA)
 ├─ ensembl_compara_11_87_…         ├─ Plant Reactome
 └─ 2 variation databases           ├─ GO / PO / TO ontologies + InterPro
          │                         ├─ Grassius (TF families)
          │                         ├─ NCBI GeneRIFs (via redis db 3)
          │                         └─ thalemine / RAP-DB (curated names)
          │                                   │
          └──────────────┬────────────────────┘
                         ▼
              MongoDB  sorghum11          ← the assembly stage; 16 collections
                genes (5.4M, decorated)
                genetree, homologs, maps, taxonomy, domains,
                GO/PO/TO, pathways, qtls, germplasm,
                experiments/assays/expression, expression_attributes
                         │
                         ▼
              Solr  sorghum_genes11 (5.4M docs)
                    sorghum_suggestions11 (7.5M docs)
                         │
                         ▼
              gramene-swagger  :50011  (REST API, /sorghum_v11)
              gramene-ebeye    :51011  (EBI search export)
                         │
                         ▼
              Apache on gorgonzola → data.sorghumbase.org
```

Two things are worth internalising:

**Mongo is the assembly area, Solr is the query surface.** The website never reads Mongo for gene
search — it queries Solr. Mongo holds the decorated documents so that a Solr core can be rebuilt
without re-running the expensive ETL. The one exception is user data (see below).

**"Decoration" is where the cost is.** `50_genes_decorate` takes the raw per-genome gene dumps and
folds in every auxiliary collection — trees, homologs, ontology terms, pathways, QTLs, curated
names, GeneRIFs, Grassius families. It is the longest stage (~1 hour) and the one most likely to
stall. See [docs/04-troubleshooting.md](04-troubleshooting.md).

## The six repositories

All on `github.com/warelab`, all checked out on branch **`sorghum_v11`**, all under
`/usr/local/gramene/subsites/sorghum/v11/`.

| repo | role |
| --- | --- |
| **build** | this repo — orchestration (`Makefile`, `config.sh`, `stages/*.sh`) |
| **gramene-mongodb-config** | `collections.js` — the single source of truth for db name, version, and collection list |
| **gramene-mongodb** | the ETL: dumps, decoration, trees, ontologies, atlas loaders |
| **gramene-solr** | Mongo → Solr conversion, attribute merging, suggestions, core configs |
| **gramene-swagger** | the REST API served to the website |
| **gramene-ebeye** | EBI Search XML export |

The four consumer repos depend on the config repo through a **local path** dependency
(`file:../gramene-mongodb-config`), not a GitHub branch. This matters — see
[docs/04-troubleshooting.md](04-troubleshooting.md#the-config-symlink).

## Databases and services

| what | where | notes |
| --- | --- | --- |
| MySQL (source) | `cabot:3306`, user `gramene_web` | read-only; 128 cores + compara + 2 variation |
| MongoDB | `localhost:27017` | db `sorghum11`; **user data is in `userData1`** |
| Solr | `localhost:8983` | cores `sorghum_genes11`, `sorghum_suggestions11` |
| Redis | `localhost:6379` | db **3** = GeneRIFs (keyed by ensembl id), db **9** = homologs (legacy) |
| Ensembl REST | `localhost:3000` | genome browser + maps QC; shared across all releases |

### User data lives outside the release database

`userData1` holds `genelists` (saved gene lists) and `savedviews`. It is **shared across every
release** so a user's saved lists survive a version bump. A release rebuild must never drop it.

The link between a saved list and its genes is a hash: a list's genes are the Solr docs carrying
`saved_search:<hash>`. Because the Solr core is rebuilt per release, those tags must be propagated
into each new core — `gramene-solr/scripts/sync_saved_search.js` does this (run it with
`--dry-run` first). This is the one piece of state that flows *between* releases.

## Ports

The convention is `SWAGGER_PORT = 10000 + version`, `EBEYE_PORT = 11000 + version`.

| release | swagger | ebeye | status |
| --- | --- | --- | --- |
| v11 | 50011 | 51011 | built, not yet public |
| v10b | 50010 (10b instance) | **51010** | **live public site** |

Ports collide easily across the many releases on this host. `70_services` verifies the port edits
it makes rather than assuming them, because an earlier version silently left a port unchanged and
pointed ebeye at a port swagger never listened on.

## Where things live

| path | what |
| --- | --- |
| `build/logs/<stage>.log` | per-stage logs (gitignored) |
| `build/.state/<stage>.done` | completion stamps (gitignored) |
| `build/tmp/` | scratch (gitignored) |
| `gramene-mongodb/search/tmp/*.json.gz` | the raw per-genome gene dumps |
| `gramene-solr/genes/` | generated Solr JSON + attribute tables |
| `/scratch/olson/sorghum_v11_maker_gff/` | MAKER GFF inputs for the v11 genomes |
| `/scratch/olson/28_sorg_maker_AED/` | release-10 MAKER table + `munge_MAKER.pl` — **read-only** |
| `/usr/local/ensembl-87/ensembl-rest/reg.pm` | the shared Ensembl REST registry (91 species) |

## Gene attribute layers

Beyond the decorated fields, the Solr gene docs carry several *attribute* layers merged in at
`60_solr_genes` by `add_attributes.pl`. Each becomes a `capability` plus typed fields:

* **MAKER** — gene-model quality (AED/QI) per genome. 37 genomes covered as of v11.
* **VEP** — loss-of-function / PTV alleles per population, from the variation database.
* **grassius_homolog** — TF families projected onto homologs through the gene trees, so pan-genome
  assemblies missing from Grassius still get a family annotation. Regenerated every build.
* **expression** — baseline expression summaries derived from the Atlas collections.

These can be refreshed *in place* without rebuilding the core:
`make refresh-attr ATTR=maker|vep|grassius|expression`.
