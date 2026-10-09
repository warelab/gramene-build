# Gramene plants search-index build (`build/`)

A robust, re-runnable orchestration of the Gramene gene search-index ETL across the five repos in
this directory. It replaces the hand-followed recipe with idempotent, validated, logged stages that
are safe to re-run and easy to update when new data arrives (new genomes, new compara, new
expression, …).

**Target of this build** (read from `gramene-mongodb-config/collections.js`, the single source of
truth): mongo db **`search70`**, solr cores **`genes70`** and **`suggestions70`**. The previous
release (`search69`, `genes69`, `suggestions69`) is read for comparison and for carrying user gene
lists forward, and is **never modified** — `00_preflight` asserts it is present and the build only
ever reads it.

Note the core naming: the main release uses **bare** `genes<N>`/`suggestions<N>`. Only the species
subsites prefix them (`sorghum_genes11`). Several stages derive core names from `DB_VERSION`, so
this is handled for you — but it is the single most common source of "why is this core empty".

> **This pipeline came from the SorghumBase v11 subsite.** Most of it is release-agnostic, but a
> handful of values and assumptions were specific to that subsite. See
> [Differences from the SorghumBase subsite](#differences-from-the-sorghumbase-subsite) before
> trusting anything that mentions sorghum, MAKER, VEP, or rsIDs.

## Quick start

```bash
cd build
make all          # full build: mongo collections + solr genes + suggestions
make status       # see which stages are done
```

Run a single stage: `make 25_reactome` (or `bash stages/25_reactome.sh`).
Every stage tees to `logs/<stage>.log` and, on success, stamps `.state/<stage>.done`.

After a full reindex, carry user gene lists into the new core:

```bash
make restore-saved-search DRY=1   # inspect first
make restore-saved-search
```

## Design principles (why this is more robust than the recipe)

1. **One source of truth for the target db.** `config.sh` reads `getMongoConfig()` from
   `collections.js`, so the db name/version can never drift from what the ETL code writes. All
   consumer repos depend on the **local** config via `file:../gramene-mongodb-config` instead of a
   mutable GitHub branch — the old `#sorghum_v10_fable` / `#sorghum_v7` pins resolved to
   *oryza7 / sorghum7* and would have silently built into the wrong db. Do not reintroduce a
   `git+ssh://…#branch` pin; `00_preflight` checks the symlink, not just the dependency string.
2. **Every stage is idempotent.** Collections that the underlying scripts only *insert* into
   (qtls, domains, genetree, genes) are dropped first; drop-based loaders (maps, GO/PO/TO,
   pathways, homologs) are re-run as is; the Atlas loaders are upsert-based. Solr cores are
   recreated fresh (no stale/orphaned docs). Re-running any stage reproduces the same result.
3. **Every stage validates and fails loudly.** Counts are checked against expectations; the gene
   dumps are gated against `maps.num_genes` *before* ingestion (the recipe's "moral of the story"
   check, now enforced); empty JSON / empty facet outputs abort instead of silently shipping a
   half-built index.
4. **Resumable + targeted refresh.** Stamps let `make` skip completed stages. The long stages are
   additionally resumable *internally* — the compara dumps and the sorted homolog flatfile are
   skipped when they pass `gzip -t`, so an abort late in `45_homologs` does not re-run an hour of
   merge-join. `make refresh-compara|refresh-genes|refresh-expression|refresh-reactome|refresh-ontologies`
   invalidate exactly the stages affected by a given upstream change and rebuild.

## Stage graph

```
05_install ─ 00_preflight ─ 10_maps ┬ 15_ontologies ──────────────┐
                                    ├ 20_variation  ──────────────┤
                                    ├ 25_reactome   ──────────────┼─ 50_genes_decorate ─ 52_tree_domains ┐
                                    ├ 30_curated ─ 35_genetrees ──┤                        │             │
                                    └ 40_genes_dump ──────────────┤                        │             │
                       00_preflight ─ 45_homologs ────────────────┘                        │             │
                            10_maps ─ 55_atlas ─ 56_project_maize_v4v5 ─ 58_expression_attributes ───────┤
                                                                                                        │
                                                      60_solr_genes ─ 65_solr_suggestions ─ 70_services ┘
```

`make all` builds `52_tree_domains` + `65_solr_suggestions`. **`22_germplasm` is deliberately not a
prerequisite** — this release ships without germplasm (as r69 effectively does) and its source is
not available, so requiring it could only fail the build. The target is kept for a one-off run if a
source appears.

`58_expression_attributes` depends on **both** `56_project_maize_v4v5` and `50_genes_decorate`, and
`60_solr_genes` depends on `58`. Expression is therefore part of the normal build, not an optional
add-on as it was in the subsite.

| stage | builds | source | idempotency |
|-------|--------|--------|-------------|
| 05_install | node_modules (local config) | npm | safe; forces the config symlink |
| 00_preflight | (validation only) | — | safe |
| 10_maps | maps, taxonomy | mysql cores/compara | drop-based |
| 15_ontologies | GO, PO, TO, domains | OBO + InterPro | drop-based |
| 20_variation | qtls | mysql variation | drops first |
| 22_germplasm *(not in `all`)* | germplasm | — | source unavailable |
| 25_reactome | pathways, taxonomy.reactomePrefix, genes_to_pathways.json | Plant Reactome | drop-based |
| 28_grassius_source *(not in `all`)* | search/grassius.tsv | grassius.org | overwrite |
| 30_curated | curated/curated.json | thalemine/rapdb + redis db3 | overwrite |
| 35_genetrees | genetree | mysql compara + curated.json | drops first |
| 40_genes_dump | search/tmp/*.json.gz | mysql cores | resumable; gated vs maps |
| 45_homologs | homologs | mysql compara | drop-based; internally resumable |
| 50_genes_decorate | genes (+ indexes) | tmp dumps + all aux collections | drops first |
| 52_tree_domains | genetree (domains on leaves) | genes + domains | updateOne |
| 55_atlas | experiments, assays, expression | EBI Atlas | upsert-based |
| 56_project_maize_v4v5 | expression (maize v4→v5) | expression | idempotent |
| 58_expression_attributes | expression_attributes | expression + maps | per-genome rebuild |
| 60_solr_genes | genes70 | mongo genes + attribute tables | recreates core |
| 62_attr_atomic *(manual)* | one attribute layer, in place | attribute tables | atomic update |
| 65_solr_suggestions | suggestions70 | genes core + mongo | recreates core |
| 70_services | swagger/ebeye config | — | idempotent, verified edits |

## Prerequisites (verified by `00_preflight`)

* mongo, solr (`http://localhost:8983/solr`), redis
* **Ensembl REST at `https://rest.ensembl.org`** — the *public plants* service. Not the local
  `:3000` one: its registry is dated 2024-03-14 and resolves **0** of this release's genomes
  (HTTP 400 for every one). The SorghumBase pan-site (`pansite-ensembl-115`) is also wrong here —
  it is the sorghum pan-genome panel and resolves 18 of 267. Used only for maps QC and VEP, so a
  failure warns rather than aborts.
* mysql access to host **`colden`** (compara + 267 cores + 24 variation databases)
* `ensembl_db_info.json` with **267 cores, 0 `anchor` flags, 24 variations**, and compara
  `ensembl_compara_plants_70_116`. Anchors are a SorghumBase concept; this release has none, and
  `EXPECT_ANCHORS=0` is correct, not a placeholder.
* **GeneRIFs in redis db 3** — loaded separately from NCBI (see below); reused across builds.

## Differences from the SorghumBase subsite

The staged pipeline was developed on `sorghum_v11` and propagated here. These are the places where
the main release deliberately differs — each one has bitten someone:

* **Core names are bare.** `genes70`, not `gramene_genes70`. `70_services` rewrites
  `api/helpers/solr.js` accordingly and then asks the module for its own `genesURL` to verify,
  rather than grepping for the string it just wrote.
* **`basePath` is `/v70`**, matching r69's `/v69`. Only subsites use `/<species>_v<N>`.
* **No MAKER, no VEP.** `MAKER_TABLE` and `VEP_TABLE` are intentionally empty; `60_solr_genes`
  warns and skips a missing table. Those capabilities are sorghum-specific.
* **No rsID attributes or suggestions.** The `Variants: rsID` suggestion layer (~10M docs) and
  `rsid__attr_ss` exist only on SorghumBase. `65_solr_suggestions` should produce no rsID category
  here.
* **Gene lists live in the shared `userData1` only.** The subsite moved them into per-site dbs
  (`sorghum10`, `sorghum11`); `restore-saved-search` here reads `userData1` and nothing else.
* **Grassius coverage comes from homolog projection, not from source.** See below.
* **Maize is B73 v5** (`Zm00001eb*`, `zea_mays`), which drives the Plant Reactome ZMY handling
  below. `zea_maysb73` is not a genome in this release.

## Plant Reactome and the maize ver5 (ZMY) supplement

Plant Reactome files maize **twice**: `Zea mays` (taxId 4577, prefix `ZMA`, v4 `Zm00001d` ids) and
`Zea mays ver5` (taxId 381124, prefix `ZMY`, v5 `Zm00001eb` ids). The public
`Ensembl2PlantReactomeReactions.txt` carries only the **ZMA** mappings, while
`gene_ids_by_pathway_and_species.tab` *does* list the ZMY genes. `get_pathways.js` builds a skeleton
per gene from the `.tab` and fills ancestors/entries from the reactions file, so every v5 maize gene
came out with empty `annotations.pathways.entries` — 1,587 genes with no pathways, and zero maize
hits for `capabilities:pathways`.

`25_reactome` therefore appends `reactome/Ensembl2PlantReactomeReactions_Zmy_ver5.txt`, a local
artifact **not published upstream** (its download URL 301s to the Plant Reactome home page), carried
over from the release-69/v10 build. The append is idempotent because the `curl -o` above it
overwrites the base file every run. If that file goes missing the stage warns loudly rather than
silently shipping empty maize pathways.

Expected after a correct run: `Zm00001eb*` goes from **0 filled of 1,587** to roughly **1,518 of
1,675**. The ~157 residual empties are correct.

**Known gap:** 364 rice `Os*` keys are still empty here, because the japonica/UniProt enhancement
below is skipped. `search69` has ~1,590 rice genes with pathways, so this is a v70-vs-v69 regression
to decide on before publishing.

## Incremental updates (new Atlas studies)

Stages are full rebuilds by default. Where an update genuinely affects only part of the index, there
is an explicit incremental entry point — the stages never *guess* which mode is wanted, since a
wrong guess would ship a partially-updated index with a zero exit code. Each incremental mode
validates its preconditions and dies naming the full target if they do not hold.

```bash
make add-studies ACCESSIONS="E-MTAB-8969,E-MTAB-10280"
```

`55_atlas` (`ATLAS_ADD=`) upserts only those experiments; `58_expression_attributes` (`EXPR_ONLY=`)
rebuilds only the affected genomes; `62_attr_atomic expression` patches the genes core in place.
This works because the `expression` collection is keyed on gene id with **one field per
experiment**, so adding a study is a `$set` — the loaders (`parseData.js`,
`project_expression_via_lut.js`, `getAtlasData.js`) are upsert-based and idempotent, which also
means a re-run of the full `55_atlas` is no longer destructive.

Granularity is per genome, not per gene: a new study shifts that genome's reference quantiles
(`ref_<taxon>.json`), which changes scores for every gene of that genome.

## Gene attribute capabilities

`60_solr_genes` merges gene-level attribute tables into the solr docs via `add_attributes.pl`
(chained), then loads. Re-do just this layer without re-decorating: `make refresh-attributes`. A
single layer can be patched into a live core with `make refresh-<layer>` → `62_attr_atomic.sh`.

⚠️ **`62_attr_atomic` relies on Solr reconstructing each document from its *stored* fields.** A
field that is indexed but not stored, and not a `copyField` target, is **silently erased** by an
atomic update — this once wiped `_terms` from 247,323 docs with every count still looking healthy.
`62_attr_atomic.sh --preflight` refuses to run against a schema that cannot survive it; do not
bypass it.

* **MAKER / VEP** — not used in this release (see above).
* **Grassius (direct)** — TF family applied in *decorate* from `search/grassius.tsv`
  (`Grassius__xrefs`). `28_grassius_source` can refresh that file from grassius.org, but it is
  **not part of `make all`**, and for good reason: GRASSIUS publishes v3 (`GRMZM*`) and v4
  (`Zm00001d*`) maize ids while this release's maize is v5, and these dumps carry very few legacy
  synonyms, so coverage from source is near zero for maize. The checked-in `grassius.tsv` is what
  the build reads. Check the coverage report if you do re-run it.
* **grassius_homolog** — Grassius TF families projected onto homologs via the gene trees
  (`grassius_homolog__attr_ss`), so assemblies whose gene IDs aren't in Grassius still get a
  TF-family annotation. Generated fresh each build by `build/grassius_homolog_table.js` and merged
  in `60_solr_genes`. **This is the path that covers maize.**
* **expression** — baseline expression summaries from `expression_attributes` (stage 58).

## Carrying user gene lists across a reindex

A saved gene list's membership is recorded **only** as a `saved_search:<hash>` tag on the Solr gene
docs; `genelists` stores the hash, label and count but never the member ids. A full core rebuild
therefore drops every list, and `gramene-solr/scripts/sync_saved_search.js` (via
`make restore-saved-search`) is the only thing that carries them forward. Run it with `DRY=1`
first, and note that it keeps only hashes that still exist in a `genelists` collection.

It also accepts `SOURCE=file:<path>` — a Solr envelope, bare array, or JSONL dump — for restoring
from a backup rather than from the previous live core, with a completeness guard that refuses a
dump whose `numFound` exceeds the documents actually present.

**Expect 0 restored on the first v70 build.** `genes69` carries tags on only 14 docs across 8
hashes, and none of those hashes exists in any `genelists` collection — every surviving list is
`site:'sorghum'`. The tooling is here to protect the *next* rebuild, so "0 restored" is the correct
result, not a bug.

## Things still done out-of-band

* **GeneRIFs (redis db 3 / db 2).** Download `generifs_basic` from NCBI and load per the scripts in
  `~olson/src/.../genetrees/database/update_geneRIFs.README.txt`. db2 = entrezgene-keyed, db3 =
  ensembl-id-keyed (what decorate reads). The build reuses whatever is in db3; refresh it before a
  release if you want current RIFs.
* **Reactome japonica enhancement (optional).** The recipe appended UniProt→gene mappings for
  *Oryza sativa japonica* to `Ensembl2PlantReactomeReactions.txt` using `merged_lut.txt`. Skipped
  here — which is exactly why 364 rice keys are empty (see above). To apply, do the awk/pack munge
  from the recipe before `25_reactome`'s `get_pathways.js`.
* **Deployment** (apache proxy, firewall, ensembl REST registry, BLAST dumps): see the checklist
  printed by `70_services` — infra steps the build won't auto-apply.

## Build invariants enforced by the stages

Each of these exists because a violation shipped, or nearly shipped, a silently wrong index. They
fail the build rather than warn.

* **`05_install` relinks `gramene-mongodb-config`.** npm *copies* the `file:../` dependency instead
  of symlinking it, so edits to `collections.js` are invisible to the ETL and a newly added
  collection comes back `undefined` deep inside a later stage. The stage forces a symlink after npm
  runs; `00_preflight` additionally asserts every required collection resolves. This is a live
  failure mode, not a theoretical one — check all four consumer repos, not just the two the stage
  reports on.
* **`40_genes_dump` gates dumps against maps.** Gene docs embed `taxon_id`, and the synthetic
  per-genome taxon ids are *reassigned* whenever the genome set changes — with gene counts
  unchanged, so a line-count check cannot see it. Dumps older than `.state/10_maps.done` are
  re-dumped, and every dump's `taxon_id` must equal `maps.taxon_id` for that genome.
* **`40_genes_dump` also refuses colliding gene stable ids.** `<db>.genes` and the Solr core both
  key on the stable id, so two genomes claiming one means the second write silently replaces the
  first with every count still plausible. This shipped in r69, where reference wheat serves 17,705
  of its 120,744 genes. `make check-stable-ids` runs the check on demand;
  `STABLE_ID_COLLISION_ALLOW` accepts a pair deliberately, and anything unlisted fails.
* **`45_homologs` resumes from the sorted flatfile.** The sorted pairs file is phase 4's only input;
  it is skipped when it passes `gzip -t`. Point its sort temp (`tmp_homologs/sorttmp`) at a
  filesystem that can hold a ~38 GB external sort — a symlink is fine and expected.
* **`58_expression_attributes` has a per-genome completeness invariant.** Let it fail rather than
  overriding it: that check caught maize shipping 17,468 of 44,303 genes in the v11 build.
* **`65_solr_suggestions` gates suggestions against the genes core.** Both suggestion layers are
  derived from that core; a well-formed but stale `genes.json` once produced ~170k suggestions for
  genes that no longer existed. Inputs older than `.state/60_solr_genes.done` are regenerated, and
  the primary-id count must equal the genes core.
* **`decorate` reports stalls instead of hanging.** Most adders are `promise.then(... done())` with
  no rejection handler, so a throw leaves `done()` uncalled and deadlocks the pipeline with no
  output. Per-stage counters plus a watchdog name the stage that swallowed a gene and exit;
  `ancestor_adder` and `homolog_adder` surface their own errors.
* **`70_services` verifies its edits.** Both `var port = 5010;` and
  `var port = process.env.PORT || 5010;` occur in the wild; the older pattern matched only the
  first, silently left the port unchanged, and still printed ok — which is how ebeye ended up
  pointed at a port swagger never listened on.

## Gene-tree stable ids

Trees whose compara `stable_id` is NULL get a synthetic id from `GT_PREFIX`, which defaults to
`SB<version>GT_`. **For plants releases this never fires**: all 170,249 trees in `search70` carry
real compara ids (`EPlGT*`), as do r69's. If it ever does fire, the default `SB` prefix is a
SorghumBase artifact and wrong for the main release — set `GT_PREFIX` explicitly.

## Resource notes for this host

The decorate stage is the memory pressure point: ~16.1M genes with ~170k trees held in heap, on a
box that also runs mongod and several Solr instances.

* Cap WiredTiger before `50_genes_decorate` — at its 50%-of-RAM default, mongod's cache plus the
  decorate heap plus Solr will push the box into swap:
  `db.adminCommand({setParameter:1, wiredTigerEngineRuntimeConfig:"cache_size=64G"})`. This is a
  runtime change needing no restart, and the live previous-release site keeps serving through it.
* `DECORATE_HEAP=--max-old-space-size=49152` for the decorate itself.
* `/solr` headroom: `genes70` projects to ~60 GB. Before deleting old cores, read the
  **core name → `instanceDir`** mapping from `/solr/admin/cores?action=STATUS`; on this host the two
  do not match (the core named `genes69` lives in `/solr/data/genes69c`), so deleting by directory
  name is a coin flip. Unload by **name** with `deleteInstanceDir=true`.

## Tunables (env vars)

`DUMP_PARALLELISM` (default 6) · `DECORATE_HEAP` · `SOLR_URL` · `ENSEMBL_REST` · `MAKER_TABLE` ·
`VEP_TABLE` · `GT_PREFIX` · `REBUILD_CORE=1` (force-recreate the genes core) · `GRASSIUS_SPECIES`
(override `28_grassius_source` species list) · `SAVED_SEARCH_MONGO_URL` (override the
`restore-saved-search` source dbs) · `SWAGGER_PORT`/`EBEYE_PORT`/`START_SERVICES` (70_services).
