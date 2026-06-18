# SorghumBase search-index build (`build/`)

A robust, re-runnable orchestration of the Gramene/SorghumBase gene search-index
ETL across the five repos in this directory. It replaces the hand-followed recipe
with idempotent, validated, logged stages that are safe to re-run and easy to
update when new data arrives (new genomes, new compara, new expression, …).

**Target of this build** (read from `gramene-mongodb-config/collections.js`, the
single source of truth): mongo db **`sorghum11`**, solr cores
**`sorghum_genes11`** and **`sorghum_suggestions11`**. Version 11 was chosen so
the build never touches the live release-10 data (`sorghum10`, `sorghum_genes10`,
`sorghum_suggestions10`).

## Quick start

```bash
cd build
make all          # full build: mongo collections + solr genes + suggestions
make status       # see which stages are done
```

To include EBI Expression Atlas data in the index:

```bash
make 55_atlas          # downloads + loads experiments/assays/expression
make refresh-expression  # (or this — also re-runs solr genes to pick it up)
```

Run a single stage: `make 25_reactome` (or `bash stages/25_reactome.sh`).
Every stage tees to `logs/<stage>.log` and, on success, stamps `.state/<stage>.done`.

## Design principles (why this is more robust than the recipe)

1. **One source of truth for the target db.** `config.sh` reads `getMongoConfig()`
   from `collections.js`, so the db name/version can never drift from what the ETL
   code writes. All consumer repos now depend on the **local** config via
   `file:../gramene-mongodb-config` instead of a mutable GitHub branch — the old
   `#sorghum_v10_fable` / `#sorghum_v7` pins resolved to *oryza7 / sorghum7* and
   would have silently built into the wrong db.
2. **Every stage is idempotent.** Collections that the underlying scripts only
   *insert* into (qtls, domains, genetree, genes, experiments/assays/expression)
   are dropped first; drop-based loaders (maps, GO/PO/TO, pathways) are re-run as
   is. Solr cores are recreated fresh (no stale/orphaned docs). Re-running any
   stage reproduces the same result.
3. **Every stage validates and fails loudly.** Counts are checked against
   expectations; the gene dumps are gated against `maps.num_genes` *before*
   ingestion (the recipe's "moral of the story" check, now enforced); empty JSON
   / empty facet outputs abort instead of silently shipping a half-built index.
4. **Resumable + targeted refresh.** Stamps let `make` skip completed stages.
   `make refresh-compara|refresh-genes|refresh-expression|refresh-reactome|refresh-ontologies`
   invalidate exactly the stages affected by a given upstream change and rebuild.

## Stage graph

```
05_install ─ 00_preflight ─ 10_maps ┬ 15_ontologies ┐
                                    ├ 20_variation  │
                                    ├ 25_reactome   ├─ 50_genes_decorate ─ 52_tree_domains
                                    ├ 30_curated ─ 35_genetrees             │
                                    └ 40_genes_dump                        │
                          00_preflight ─ 45_homologs ──────────────────────┤
                                    (55_atlas, optional) ──────────────────┤
                                                                 50 ─ 60_solr_genes ─ 65_solr_suggestions ─ 70_services
```

| stage | builds | source | idempotency |
|-------|--------|--------|-------------|
| 05_install | node_modules (local config) | npm | safe |
| 00_preflight | (validation only) | — | safe |
| 10_maps | maps, taxonomy | mysql cores/compara | drop-based |
| 15_ontologies | GO, PO, TO, domains | OBO + InterPro | drop-based |
| 20_variation | qtls | mysql variation | drops first |
| 25_reactome | pathways, taxonomy.reactomePrefix, genes_to_pathways.json | Plant Reactome | drop-based |
| 30_curated | curated/curated.json | thalemine/rapdb + redis db3 | overwrite |
| 35_genetrees | genetree | mysql compara + curated.json | drops first |
| 40_genes_dump | search/tmp/*.json.gz | mysql cores | resumable; gated vs maps |
| 45_homologs | redis db9 | mysql compara | self-flushing |
| 50_genes_decorate | genes (+ indexes) | tmp dumps + all aux collections | drops first |
| 52_tree_domains | genetree (domains on leaves) | genes + domains | updateOne |
| 55_atlas *(optional)* | experiments, assays, expression | EBI Atlas | drops first |
| 60_solr_genes | sorghum_genes11 | mongo genes (+VEP opt) | recreates core |
| 65_solr_suggestions | sorghum_suggestions11 | genes core + mongo | recreates core |
| 70_services | swagger/ebeye config | — | idempotent edits |

## Prerequisites (verified by `00_preflight`)

* mongo, solr (`http://localhost:8983`), redis, ensembl REST (`http://localhost:3000`)
* mysql access to host `cabot` (compara + 125 cores + variation)
* `ensembl_db_info.json` with 125 cores, 9 `anchor` flags, 1 variation, the right compara
* **GeneRIFs in redis db 3** — loaded separately from NCBI (see below); reused across builds.

## Source fixes applied (genuine bugs the recipe glossed over)

* `gramene-mongodb`, `gramene-solr`, `gramene-swagger` `package.json` → config via
  `file:../gramene-mongodb-config` (was stale GitHub branches → wrong db).
* `search/decorate.js` required `./addQtlXrefs` (missing) → now `./qtl_adder`.
* `search/msu6_adder.js` hard-required a missing rice LUT → now optional passthrough.
* `createDumpCommandsfromCores.js`, `ontologies/populate.js`, `curated/get_curated.js`,
  `reactome/get_species_prefixes.js`, `reactome/get_pathways.js`,
  `search/dump_homologs.js` left the config's mongo connection open and **hung after
  finishing** → each now closes/exits cleanly.
* `search/curated.js` fetch (in the decorate hot path) had no timeout → added a 60s
  abort + empty-LUT fallback so a network stall can't hang the whole decorate.
* Removed the unused `xml-stream` dep (its native `node-expat` broke `npm install`).

## Gene attribute capabilities (MAKER / VEP / Grassius)

`60_solr_genes` merges gene-level attribute tables into the solr docs via
`add_attributes.pl` (chained), then loads. Re-do just this layer without
re-decorating: `make refresh-attributes`.

* **MAKER** — per-genome gene-model AED/QI quality scores (`MAKER` capability,
  `MAKER__*__attr_[fi]`). Table: `${MAKER_TABLE}` (defaults to the prior release's
  `maker_attrib_table_for_solr.txt`, built from `/scratch/olson/28_sorg_maker_AED/`
  `*.maker.gene_only.AED_QI.scores` via `munge_MAKER.pl`). Same gene IDs across
  releases, so reused as-is; regenerate + repoint `MAKER_TABLE` for new annotations.
* **VEP / germplasm** — loss-of-function / PTV alleles per population (`VEP`
  capability, `VEP__<consequence>__<homo|het>__<pop>__attr_ss` + `VEP__merged__{EMS,NAT}__attr_ss`).
  Table: `${VEP_TABLE}` (prior release's `vep_attributes.txt`). Built by
  `vep/dump_gene_level_VEP_table.pl --registry <reg.pm> -s <species>` → `vep/munge_vep.pl`.
  The sorghum variation DB (`sorghum_bicolor_variation_9_108_30`) is unchanged, so
  reused as-is; regenerate for a new variation DB.
* **Grassius (direct)** — TF family on the reference genomes, applied in *decorate*
  from `search/grassius.tsv` (`Grassius__xrefs`). Pull a fresh copy from grassius.org
  (old assembly IDs mapped to current gene IDs via synonyms, **merged** so curated
  coverage is never lost) with `make refresh-grassius` (regenerates `grassius.tsv`,
  then re-decorates + rebuilds solr). NOTE: the grassius.org download currently has
  *less* sorghum coverage than the curated file, which is why we merge rather than replace.
* **grassius_homolog** — Grassius TF families projected onto homologs via gene trees
  (`grassius_homolog__attr_ss`), so the 124 pan-genome assemblies (whose gene IDs
  aren't in Grassius) still get a TF-family annotation. Generated fresh each build by
  `build/grassius_homolog_table.js` and merged in `60_solr_genes`.

## Things still done out-of-band

* **GeneRIFs (redis db 3 / db 2).** Download `generifs_basic` from NCBI and load
  per the scripts in `~olson/src/.../genetrees/database/update_geneRIFs.README.txt`.
  db2 = entrezgene-keyed, db3 = ensembl-id-keyed (what decorate reads). The build
  reuses whatever is in db3; refresh it before a release if you want current RIFs.
* **Reactome japonica enhancement (optional).** The recipe appended UniProt→gene
  mappings for *Oryza sativa japonica* to `Ensembl2PlantReactomeReactions.txt` using
  `merged_lut.txt`. Skipped here (rice-japonica-specific). To apply, do the awk/pack
  munge from the recipe before `25_reactome`'s `get_pathways.js`.
* **Regenerating VEP/MAKER tables** (only when the variation DB or MAKER run changes):
  VEP via `vep/dump_gene_level_VEP_table.pl` + `munge_vep.pl` (needs the Ensembl Perl
  API + a registry); MAKER via `/scratch/olson/28_sorg_maker_AED/munge_MAKER.pl`. Then
  point `MAKER_TABLE`/`VEP_TABLE` at the new files. Otherwise both are reused as-is.
* **Deployment** (apache proxy, firewall, ensembl REST registry, BLAST dumps): see
  the checklist printed by `70_services` — infra steps the build won't auto-apply.

## Tunables (env vars)

`DUMP_PARALLELISM` (default 8) · `SOLR_URL` · `ENSEMBL_REST` · `MAKER_TABLE` · `VEP_TABLE` ·
`REBUILD_CORE=1` (force-recreate the genes core) · `GRASSIUS_SPECIES` (override `28_grassius_source`
species list) · `SWAGGER_PORT`/`EBEYE_PORT`/`START_SERVICES` (70_services).
