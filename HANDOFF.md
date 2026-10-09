# Gramene plants release 70 — handoff

**Start here.** This is the orientation document for taking over the Gramene v70 search-index
pipeline. It tells you what the system is, what state it is in right now, and what needs doing.
Everything else is in [`docs/`](docs/).

Written 2026-10-08, with the build in progress. If you are reading this later, treat the "current
state" section as history and re-derive it with `make status`, `make running`, and the health checks
in [docs/03-operations.md](docs/03-operations.md).

| I want to… | read |
| --- | --- |
| understand how the pieces fit together | [docs/01-architecture.md](docs/01-architecture.md) |
| run, resume, or refresh the build | [docs/02-build-runbook.md](docs/02-build-runbook.md) |
| keep the live services healthy | [docs/03-operations.md](docs/03-operations.md) |
| fix something that broke | [docs/04-troubleshooting.md](docs/04-troubleshooting.md) |
| cut the next release (v71) | [docs/05-release-playbook.md](docs/05-release-playbook.md) |
| know what is unfinished | [docs/06-open-items.md](docs/06-open-items.md) |
| know what each build stage does | [README.md](README.md) — the stage reference |

## What this is

An ETL pipeline that builds the gene search index behind **data.gramene.org**. It reads Ensembl
MySQL databases (267 core genomes, 1 compara, 24 variation) plus a dozen external sources, assembles
a decorated gene document per gene in MongoDB, and loads two Solr cores that the website queries.

Roughly: **267 MySQL databases → 16.1M MongoDB gene docs → 16.1M Solr gene docs + suggestions.**

The build is ~22 numbered stages orchestrated by `make`. Each stage is idempotent, validates its own
output, logs to `logs/<stage>.log`, and stamps `.state/<stage>.done` on success. A full build takes
**well over a day** at this size — budget several days with verification.

### This pipeline is new to the main release

v70 is the first main release built with this staged `build/` pipeline. It was developed on the
SorghumBase v11 subsite and propagated here on 2026-10-08; previously the main release was built via
`gramene-meta`. The `pre-v11-propagation-20261008` tag in each repo marks the state before that.

Practical consequence: anything in this tree that mentions sorghum, MAKER, VEP, rsIDs, or anchor
genomes deserves a second look. [README.md](README.md#differences-from-the-sorghumbase-subsite) lists
the places the main release deliberately differs — the most consequential being that **Solr core
names are bare** (`genes70`, not `gramene_genes70`) and **`basePath` is `/v70`**.

## Current state (2026-10-08)

**The build is resuming, not starting.** It died at `45_homologs` on 2026-07-10; the stages through
`40_genes_dump` were banked, and their outputs were verified present and intact before the stamps
were restored.

| | |
| --- | --- |
| Mongo | `search70` — 267 maps, 170,249 gene trees, **9,083,100 homolog docs**, GO/PO/TO, domains, pathways, qtls; `genes` **not yet built** |
| Solr | `genes70` / `suggestions70` **do not exist yet** |
| Services | `gramene_swagger70` / `gramene_ebeye70` **not created yet** (10070 / 11070 when they are) |
| Source compara | `ensembl_compara_plants_70_116` on host **colden** |
| Build stages | 00–45 done; `25_reactome` blocked; `55_atlas` running; 50/52/56/58/60/65/70 to go |

The previous release, **v69**, is the live public site and must keep working. It serves `/v69` on
port **10069** from the Solr core named `genes69` and the mongo db `search69`. Do not drop or edit
any of them.

⚠️ **Solr core names do not match their directories on this host.** The core named `genes69` lives in
`/solr/data/genes69c`. Deleting by directory name is a coin flip on the live index — resolve the
mapping from `/solr/admin/cores?action=STATUS` and unload by **name**.

## The things that need doing

Ordered by what blocks what. Details in [docs/06-open-items.md](docs/06-open-items.md).

1. **Get the Plant Reactome ContentService restarted.** It is hanging
   (`/ContentService/data/*` times out while the same host serves `/` in 60 ms), which blocks
   `25_reactome` and therefore `50_genes_decorate` — the critical path. It is **Gramene-operated**,
   so this is a request to ourselves, not a wait on a third party. Then `make 25_reactome`.
2. **Finish the build**: 50 → 52 → 56 → 58 → 60 → 65 → 70. Before the decorate, cap mongod's
   WiredTiger cache or this box swaps — see
   [README.md](README.md#resource-notes-for-this-host).
3. **Decide about the 364 empty rice pathway keys.** r69 has ~1,590 rice genes with pathways and
   this release would ship with none, because the japonica/UniProt enhancement is skipped. A visible
   regression if left.
4. **The deployment steps** `70_services` cannot automate: Apache proxy, firewall, the Ensembl REST
   registry merge, BLAST, and the gene-tree curation UI.
5. **Housekeeping**: delete the orphaned sorghum JGI stage (`stages/57_jgi_expression.sh`, `jgi/`)
   unless the main release takes on a non-EBI expression source, and externalise the plaintext MySQL
   password that `gramene-mongodb/ensembl_db_info.json` tracks in git.

## Ground rules

* **`config.sh` is the only place that knows db names, hosts, ports, and paths.** No stage script
  hardcodes them. If you find yourself editing a path in a stage script, edit `config.sh` instead.
* **The Mongo db name comes from `gramene-mongodb-config/collections.js`**, not from a constant, and
  the consumer repos reach it through a `file:../` path dependency — never a GitHub branch pin. A
  stale pin once silently pointed a sorghum build at the *rice* database, and the same mis-pin is
  live in the v10b tree today.
* **Stages fail loudly rather than warning.** Every guard in the build exists because a violation
  shipped, or nearly shipped, a silently wrong index. If a guard fires, something is genuinely wrong
  — do not delete the guard to get past it.
  [docs/04-troubleshooting.md](docs/04-troubleshooting.md) explains what each one is protecting
  against. The corollary: **this pipeline's failures are usually silent**, so a stage finishing is
  not evidence it was right.
* **`ensembl_db_info.json` is curated, not generated.** It records which core database was chosen
  for each genome. One commit in the ETL repos regenerates it from a database pattern; that commit
  was deliberately skipped during propagation and must stay skipped.
* **Never edit anything under a previous release's directory**, and never `pm2 restart all` — 59
  processes run on this host and several are deliberately stopped.

## Who and where

* Host: **squam** (`/usr/local/gramene/release70`)
* MySQL source: **colden** (read-only, user `gramene_web`)
* Ensembl REST for maps QC: **`https://rest.ensembl.org`** — the public plants service. The local
  `:3000` registry resolves 0 of this release's 267 genomes; the SorghumBase pan-site resolves 18.
* Public front end: **gorgonzola** (Apache reverse proxy → squam)
* Git: everything is under `github.com/warelab`, branch **`release70`** in every repo except
  `gramene-mongodb-config`, which is on **`main_v70`**
