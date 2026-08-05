# SorghumBase v11 — handoff

**Start here.** This is the orientation document for taking over the SorghumBase v11 search-index
pipeline. It tells you what the system is, what state it is in right now, and what needs doing.
Everything else is in [`docs/`](docs/).

Written 2026-08-05 for a vacation handover. If you are reading this much later, treat the "current
state" section as history and re-derive it with `make status` and the health checks in
[docs/03-operations.md](docs/03-operations.md).

| I want to… | read |
| --- | --- |
| understand how the pieces fit together | [docs/01-architecture.md](docs/01-architecture.md) |
| run, resume, or refresh the build | [docs/02-build-runbook.md](docs/02-build-runbook.md) |
| keep the live services healthy | [docs/03-operations.md](docs/03-operations.md) |
| fix something that broke | [docs/04-troubleshooting.md](docs/04-troubleshooting.md) |
| cut the next release (v12) | [docs/05-release-playbook.md](docs/05-release-playbook.md) |
| know what is unfinished | [docs/06-open-items.md](docs/06-open-items.md) |
| know what each build stage does | [README.md](README.md) — the stage reference |

## What this is

An ETL pipeline that builds the gene search index behind **data.sorghumbase.org**. It reads Ensembl
MySQL databases (128 core genomes, 1 compara, 2 variation) plus a dozen external sources, assembles
a decorated gene document per gene in MongoDB, and loads two Solr cores that the website queries.

Roughly: **128 MySQL databases → 5.4M MongoDB gene docs → 5.4M Solr gene docs + 7.5M suggestions.**

The build is 20 numbered stages orchestrated by `make`. Each stage is idempotent, validates its own
output, logs to `logs/<stage>.log`, and stamps `.state/<stage>.done` on success. A full build from
scratch takes roughly **4 hours**.

## Current state (2026-08-05)

**The v11 build is complete and the services are running.** It is *not* yet public — the Apache
reverse proxy has not been pointed at it (item 1 below).

| | |
| --- | --- |
| Mongo | `sorghum11` — 5,407,132 genes, 50,826 gene trees, 2,682,615 homologs |
| Solr | `sorghum_genes11` (5,407,132 docs), `sorghum_suggestions11` (7,517,359 docs) |
| Services | `sorghum_swagger11` on **50011**, `sorghum_ebeye11` on **51011**, both online under pm2 |
| Source compara | `ensembl_compara_11_87_sorghum0626` on host `cabot` |
| Build stages | all 20 stamped done (`make status`) |

The previous release, **v10b**, is still the live public site and must keep working. Do not touch
`sorghum10b`, `sorghum_genes10b`, `sorghum_suggestions10b`, or the v10b services.

## The five things that need doing

Ordered by what blocks what. Details in [docs/06-open-items.md](docs/06-open-items.md).

1. **Publish v11** — the manual infra steps the build deliberately does not automate: Apache proxy
   `/sorghum_v11` → `squam:50011`, firewall, Ensembl REST registry, BLAST, gene-tree curation UI.
   Printed as a checklist by `make 70_services`. **Nothing else on this list is user-visible until
   this is done.**
2. **Merge the Ensembl REST registry** — v11's 131 databases need to reach the shared REST registry
   without disturbing the other 91 species. Tooling and a verified merged file are ready; see
   [docs/06-open-items.md](docs/06-open-items.md#1-ensembl-rest-registry-merge).
3. **Update the web client for the new gene-lists API** — the save/validate contract changed. One
   of the changes fails *silently* in old clients. Full spec in
   `../gramene-swagger/docs/gene_lists_api.md`.
4. **Re-run `make 35_genetrees`** — tree representatives were chosen before two fixes landed, so the
   stored trees are stale in a cosmetic-but-visible way.
5. **Commit or discard the uncommitted files** scattered across five repos — listed exactly in
   [docs/06-open-items.md](docs/06-open-items.md#uncommitted-work).

## Ground rules

* **`config.sh` is the only place that knows db names, hosts, ports, and paths.** No stage script
  hardcodes them. If you find yourself editing a path in a stage script, edit `config.sh` instead.
* **The Mongo db name comes from `gramene-mongodb-config/collections.js`**, not from a constant.
  This is deliberate — a stale GitHub dependency pin once silently pointed a sorghum build at the
  *rice* database.
* **Stages fail loudly rather than warning.** Every guard in the build exists because a violation
  shipped, or nearly shipped, a silently wrong index. If a guard fires, something is genuinely
  wrong — do not delete the guard to get past it. [docs/04-troubleshooting.md](docs/04-troubleshooting.md)
  explains what each one is protecting against.
* **Never edit anything under a previous release's directory.** v10 serves some files (notably its
  MAKER table) through symlinks that v11 also reads.

## Who and where

* Host: **squam** (`/usr/local/gramene/subsites/sorghum/v11`)
* MySQL source: **cabot** (read-only, user `gramene_web`)
* Public front end: **gorgonzola** (Apache reverse proxy → squam)
* Git: everything is under `github.com/warelab`, branch **`sorghum_v11`** in every repo
