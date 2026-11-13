# oryza rebuild — staging names (v10), serving /oryza_v9

Port of the hand-built oryza v9 subsite onto the staged build harness, by way of
maize v6. v9 had no `build/` directory at all: no stages, no `config.sh`, no
`.state`, no logs, no docs. This is a port onto a harness, not a version bump —
the third such port after grapevine v5 and maize v6.

## What this is, and what it is not

**This build carries the v10 NAMES but serves the EXISTING v9 public path.** The
request was to rebuild v9 under staging names and then swap, keeping
`/oryza_v9`. So:

| thing | live v9 | this build |
| --- | --- | --- |
| tree | `subsites/rice/v9` | `subsites/rice/v10` |
| mongo db | `oryza9` | `oryza10` |
| solr cores | `oryza_genes9` / `oryza_suggestions9` | `oryza_genes10` / `oryza_suggestions10` |
| swagger port | 20009 | 20010 while verifying, then 20009 |
| pm2 name | `oryza_swagger9` | `oryza_swagger10` |
| public path | `/oryza_v9` | **`/oryza_v9` — unchanged** |

**Why the staging names are the "10" set and not something like `9b`:**
`config.sh` does `$((DB_VERSION-1))` in four places, so a non-numeric version
dies immediately with *"9b: value too great for base"*. Using 10 keeps the
arithmetic valid **and** makes `PREV_DB`/`PREV_GENES_CORE` resolve to the live v9
automatically, which is exactly what the harness wants them for (solr conf
templates, conf diffs, `make restore-saved-search`).

`collections.js` (`dbName='oryza'`, `dbVersion='10'`) is the single source for
both the mongo db and the solr core version — `api/helpers/solr.js` reads
`getMongoConfig().version`, so one value governs both and they cannot drift.
`app.js`'s `var version = +basePath.match(/\d+/)` is dead code (assigned, never
read) and cannot conflict with `/oryza_v9`.

## Branches

All six cut from **`maize_v6`**, so this port inherits every fix made there:
the expression base-taxon fix, the `solr_chunk_load` byte bound, the gxa 302
redirect, and the germplasm fixes of 2026-11-09.

| repo | base | branch |
| --- | --- | --- |
| `build` | `maize_v6` @ 13e872c | `oryza_v10` |
| `gramene-mongodb` | `maize_v6` @ 64f7399 | `oryza_v10` |
| `gramene-mongodb-config` | `maize_v6` @ df20a76 | `oryza_v10` |
| `gramene-solr` | `maize_v6` @ 06ff652 | `oryza_v10` |
| `gramene-swagger` | `maize_v6` @ 2f7006f | `oryza_v10` |
| `gramene-ebeye` | `maize_v6` @ ca287e6 | `oryza_v10` |

Cloned **fresh** rather than copied. That matters: maize v6's worktrees hold 37 GB
(solr) and 5.1 GB (mongodb) of untracked build artifacts, including per-genome
dumps carrying *maize* taxon ids, which `40_genes_dump`'s taxon check would
correctly reject. The `.git` dirs are only ~40 MB in total, so a clean clone is
both cheaper and safer than a copy.

## Source databases — frozen

v9's `ensembl_db_info.json`, copied unchanged: **37 cores (20 anchored), 6
variation dbs, compara `ensembl_compara_7_87_rice1025`**, host `cabot`. Reusing
v9's exact set is what makes the rebuild's gene and tree counts comparable to
v9's as *exact* numbers rather than approximations.

**Never run `get_ensembl_db_info.js` in this tree.** Note also this is a
mixed-schema site: the compara is schema 87 (`_7_87_`) while most cores are
`_8_108_`, with two on `_7_87_`/`_7_108_`.

Caveat inherited from every other site: this file contains the MySQL password in
plaintext and **is tracked in a public GitHub repo**. That predates this build;
see the note at the end.

## Config changes, with the reasons

Measured, not assumed. Several of maize's values fail outright on rice.

| setting | maize v6 | here | why |
| --- | --- | --- | --- |
| `SPECIES` | `maize` | `oryza` | drives `PREV_DB`, both core names, `BASEPATH`, pm2 names, swagger `urlBase` |
| `RELEASE_ROOT` | `…/maize/v6` | `…/rice/v10` | **the real path**. `subsites/oryza` is a symlink to `rice`, and `05_install` derives its own root with `readlink -f`; using the symlink here gives two stamp paths for one tree |
| `EXPECT_CORES` | 63 | **37** | hard `die` in preflight otherwise |
| `EXPECT_ANCHORS` | 8 | **20** | counted in the frozen json. Unlike grapevine (0 anchors), rice is the ordinary case |
| `EXPECT_VARIATIONS` | 3 | **6** | five `oryza_*` + `sorghum_bicolor_variation_8_108_30` |
| `MAPS_MIN` | 55 | **35** | **maize's value FAILS this site**: rice has exactly 37 maps, asserted in `10_maps`, `20_variation` and `25_reactome` |
| `EXPECT_TREES[gene_tree]` | 39709 | **45273** | see below |
| `STABLE_ID_COLLISION_ALLOW` | `zea_maysb73v3:zea_maysb73v4` | **empty** | verified no collisions; rice has no `v3`, and the inherited pair would only ever *permit* a real collision silently |
| `SWAGGER_PORT` / `EBEYE_PORT` | 30006 / 31006 | **20010 / 21010** | see below |
| `BASEPATH` | `/maize_v6` | **`/oryza_v9`** | serve the existing public path |
| `VEP_TABLE` | maize's table | **v9's table, reused exactly** | SNPeff-derived, not variation-derived — see below |
| `EXPECT_SUPERTREES` | 0 | 0 | verified zero `tree_type='supertree'` rows in this compara. Setting it to 1 dies *after* the multi-hour solr load |

**The ports are pinned literals, not derived.** `70_services.sh` would default to
`10000+DB_VERSION`, but `config.sh` pins them — so copying maize's file and
changing only `SPECIES` leaves **30006/31006**, which would collide with the
*live* `maize_swagger6` and point rice's ebeye at maize's spec URL. Rice uses the
20000+/21000+ band (v9 = 20009); 20010 and 21010 verified free.

**`EXPECT_TREES` is a verified number, not a guess.** Queried directly:
`SELECT COUNT(*) FROM gene_tree_root WHERE clusterset_id='default' AND
tree_type='tree'` on `ensembl_compara_7_87_rice1025` → **45,273**, which equals
`oryza9.genetree` exactly. The rest of that compara is `nj-*`/`phyml-*`
alternative clustersets, which Gramene does not index, and there is **no**
`rice_cultivars` clusterset. Worth stating because maize's 39,709 would have
*passed* the stage's ±bounds check (lo 35,738, hi 59,563) while being wrong.

## Rice-specific source changes

**`search/species_rank.js` — the rice site was about to lead with maize.** The
map keys on `system_name` and maize's version ranks `zea_maysb73: 1`. The rice
site *hosts* `zea_maysb73`, so copied unchanged it silently makes maize the first
genome of a rice site. `species_idx` drives `gene_idx`, which drives presentation
order — and `60_solr_genes`'s freshness gate only checks that mongo's rank-1
genome matches solr's lowest `gene_idx`, so it is satisfied either way and would
**not** have caught it. Now `oryza_sativa` 1, arabidopsis 2, sorghum 3,
`zea_maysb73` 4, `zea_maysb73v4` 5.

For the record, live v9 ranks arabidopsis 1 and `oryza_sativa` 2 — because its
rank-3 key was `zea_mays`, which rice's maps do not contain. So v9's ordering was
itself accidental, and this is a deliberate departure, not a regression.

**`suggestions/aux.js` — the QTL taxon facet was wrong on every site.** It
hardcoded `taxon_id: [4558,39947]`, which are NCBI *base* ids, while every other
suggestion category gets full per-genome ids from the solr facet pivot. Now
`[4558001,39947013]` — sorghum BTx623 (`GCA_000003195.3`) and *O. sativa*
Japonica (`GCA_001433935.1`), the two QTL-bearing genomes. **Not rice-specific;
belongs upstream.**

**`expression_pipeline/manifest.json`** — `api_base` → `/oryza_v9`. Nothing else
needed: the genomes list keys on `system_name`, and all seven expression-bearing
genomes here (`zea_maysb73`, `zea_maysb73v4`, `oryza_sativa`, `sorghum_bicolor`,
`arabidopsis_thaliana`, `vitis_vinifera`, `chlamydomonas_reinhardtii`) already
have entries with distinct `short` names, so no artifact filenames collide, and
the drosophila exclusion carries over correctly.

**`Makefile` — `22_germplasm` is now a prerequisite of `all`.** It is deliberately
excluded on the main release, which ships without germplasm. Rice has **19,256**
germplasm docs, and that exclusion is exactly how maize v6 shipped with an empty
Germplasm tab.

## Traps specific to this site

### 1. Solr core names are crossed with their directories, in both directions

    name oryza_genes9        -> dir /solr/data/oryza_genes9a
    name oryza_genes9a       -> dir /solr/data/oryza_genes9
    name oryza_suggestions9  -> dir /solr/data/oryza_suggestions9a
    name oryza_suggestions9a -> dir /solr/data/oryza_suggestions9

`rm -rf /solr/data/oryza_genes9` destroys **`oryza_genes9a`**, not
`oryza_genes9`. Resolve name→instanceDir from the STATUS API and unload by
**name** with `deleteInstanceDir=true`. The `…9a` cores are separate live cores
and are not ours to touch. The live site serves the `…9` names (from
`collections.js` version `9`).

### 2. `taxon_id` 39947013 is shared by three genomes

Not a base-taxon collapse but a **full `taxon_id` collapse**, in the source data:

| system_name | db_type | ids | genes |
| --- | --- | --- | --- |
| `oryza_sativa` | `core` | `Os*` | 38,993 |
| `oryza_sativamsu` | **`otherfeatures`** | `LOC_Os*` | 55,986 |
| `oryza_sativacshl` | **`cdna`** | `OsNip_*` | 37,403 |

132,382 genes over one `taxon_id` and one `maps._id` (`GCA_001433935.1`),
separated only by `system_name` + `db_type`. Any per-genome grouping keyed on
`taxon_id` alone merges or destroys two of the three.

The expression pipeline is **safe**: `mongo_source.discover_genomes` groups on
the compound key `{system_name, taxon_id}`, and only `oryza_sativa` carries
expression. But `db_type` is load-bearing in `mongo2solr`'s sort, and
`dump_qtls.js` builds its map lookup from `maps`, which has no MSU/CSHL rows.

### 3. The expression base-taxon fix is load-bearing here too

Rice has one colliding **base** taxon: `4577001` and `4577002` (B73 v5 and v4),
both expression-bearing. Under the pre-maize-v6 code they would have shared one
`ref_4577.json` and one panel slot, and `58_expression_attributes`'s per-genome
completeness check would compare one genome's output against the other's
expectation. The fix is inherited from `maize_v6`; **do not regress it**, and keep
that completeness gate.

### 4. Stages that must not run, and one that must

- **`57_jgi_expression` — never invoke.** Its skip guard tests
  `system_name:"sorghum_bicolor" < 1000`, and rice *hosts* sorghum with 35,479
  genes, so it will **not** skip; it runs and hits hard assertions on sorghum-only
  counts. It has no Makefile target, so simply never call it.
- **`29_curated_sources` §2 (MaizeGDB)** gates on `system_name:"zea_mays"`, which
  is 0 here (rice has `zea_maysb73`), so the guard skips the validation and
  promotes the file unvalidated. Dead weight; not in `all`.
- **`56_project_maize_v4v5` is KEPT**, contrary to first expectations: rice hosts
  both `zea_maysb73` (v5) and `zea_maysb73v4`, both with expression, so the
  projection is genuinely applicable. Dropping it would also require rewiring
  `Makefile:135` and `60_solr_genes.sh:151`'s staleness list.
- **`22_germplasm` must run** — see above.

## VEP — v9's table is reused exactly, and must not be regenerated

`VEP_TABLE` points at `gramene-solr/vep/vep_attributes.txt`, copied from v9's
`vep/vep_attributes.redo.txt`.

**It is not derived from the Ensembl variation databases.** It comes from SNPeff,
so there is nothing to regenerate from the `oryza_*_variation_*` dbs — and running
`dump_gene_level_VEP_table.pl` against them would produce a different table from a
different source and silently change the site's VEP content. The same decision was
taken for maize v6, which reused v5's table exactly.

**Which of v9's three generations, and how that was settled.** v9's `vep/` holds
`vep_attributes.txt` and `vep_attributes.fixed.txt` at 124,082 data rows each, and
`vep_attributes.redo.txt` at 122,731. `oryza_genes9` carries the VEP capability on
**122,535** genes, so `.redo.txt` is the one that fed the live index — 196 of its
rows name ids the index does not carry, a 0.16% miss. Its mtime, five minutes
before v9's final `solr_genes2.vep.json`, agrees. Picked on the count, not the
timestamp.

Because `suggestions/germplasm.js` builds its docs by faceting
`VEP__merged__{EMS,NAT}__attr_ss`, reusing the table also restores **Germplasm
PTVs**, which would otherwise have been 0 against v9's 18,935 — the same shape of
regression that shipped on maize v6.

**Verify both after stage 60**, rather than assuming the reuse was faithful:
`capabilities:VEP` on `oryza_genes10` should land at ~122,535, and Germplasm PTVs
in `oryza_suggestions10` at ~18,935. A VEP count far from 122,535 means the table's
gene ids no longer match the index — `vep/update_stable_ids.pl` exists precisely
because they drifted once before (`Os117425` → `OsARC`, `Osmh63.` → `OsMH63_`).

## Baseline to verify against (oryza9)

`genes` 1,437,629 · `genes_fixed` 1,437,629 · `genetree` 45,273 ·
`expression` 1,362,192 · `germplasm` 19,256 · `qtls` 12,966 · `GO` 48,196 ·
`domains` 49,674 · `TO` 4,917 · `PO` 1,791 · `assays` 6,541 · `pathways` 2,451 ·
`experiments` 364 · `taxonomy` 139 · `maps` 37.

Solr `oryza_genes9` 1,437,629 · `oryza_suggestions9` 3,987,454. Capabilities on
`oryza_genes9` that must not fall: `GO` 711,711 · `domains` 944,749 ·
`QTL_TO` 108,440 · `expression` 184,348 · `VEP` 122,535 · `pathways` 12,641 ·
`Grassius` 12,203. No MAKER. `expression_attributes` and `homologs` are new here
(both 0 in v9).

Gene counts should land **exact** — same cores, same compara.

**Two checks that would have caught the two defects found on earlier ports:**

1. **Per-genome counts for all 39 `system_name` values, not 37.**
   `ensembl_db_info.json` lists 37 cores, but v9's dumps number **39** — it also
   had `oryza_sativaMSU` (`otherfeatures`) and `oryza_sativaCSHL` (`cdna`),
   supplied by hand and absent from the frozen file. A harness iterating `cores[]`
   produces 37 genomes and silently loses **93,389** genes. Decide explicitly
   whether to add them.
2. **A collection-set diff `oryza9` → `oryza10`, requiring no missing
   collections.** Comparing the collections you *expect* is what let maize v6 ship
   without germplasm; diffing the sets is what caught it.

## Build results — FINAL, measured 2026-11-10 after the MSU/CSHL + tree-id rebuild

Every number below was read off the finished build, not predicted. This table supersedes
the 2026-11-09 one taken before `42_extra_genomes` and the tree-id restoration; the two
rows that changed are marked **▲**.

| | oryza9 | oryza10 | verdict |
| --- | --- | --- | --- |
| mongo `genes` | 1,437,629 | **1,437,629** | **▲ exact.** All **39** `(system_name, db_type)` pairs diffed individually: 0 differing, 0 only-v9, 0 only-v10 |
| `genetree` | 45,273 | 45,273 | exact, and **▲ the id SETS are identical** — 0 v9 ids absent from v10, 0 v10 ids not in v9 |
| `genes.homology.gene_tree.id` `ORYZA9GT_*` | 1,253,026 | **1,253,026** | ▲ exact; 0 genes carry a tree id of any other shape |
| `alt_id` carrying `LOC_Os*` (v9: `MSU_id`) | 33,938 | **33,938** | all 33,938 values byte-identical; field renamed by design — see open items |
| PlantReactome refs | 6,695 genes / 133,620 recs | **6,831 / 134,456** | ▲ regenerated from the real source; 20.0 refs/gene both sides, every record carries a title |
| solr `capabilities:pubs` | 14,164 | **21,057** | v9's index was **5,198 genes behind its own mongo** (19,362); v10's index and mongo agree exactly |
| `germplasm` | 19,256 | 19,256 | exact |
| `qtls` | 12,966 | 12,966 | exact |
| `expression` | 1,362,192 | 335,908 | **not a loss** — see below |
| `TO` | 4,917 | 4,676 | obo-artifact change, already established |
| `domains` | 49,674 | 72,944 | new InterPro release |
| solr `oryza_genes*` | 1,437,629 | **1,437,629** | ▲ matches mongo |
| `capabilities:VEP` | 122,535 | **122,535** | the reused SNPeff table transferred exactly |
| `capabilities:expression` | 184,348 | 201,472 | better |
| searchable GXA studies | 321 | **354** | none lost, 33 gained |
| solr `oryza_suggestions*` | 3,987,454 | 4,097,663 | ▲ primary-id suggestions match the genes core (1,437,629) |
| `Germplasm PTVs` | 18,935 | **18,935** | exact |
| `Trait ontology` suggestions | 716 | **741** | the `QTL_` uniqueKey fix holds |

**`expression` 1,362,192 → 335,908 is orphan removal, not lost coverage.**
Per-genome coverage is identical for all eight covered genomes (`oryza_sativa`
38,921, `zea_maysb73` 44,303, `arabidopsis_thaliana` 32,833, …) and drosophila is
newly covered at 17,737. The whole difference is documents keyed on gene ids that
are not in `genes`: **1,120,284** of them in v9 — 82% of that collection was
unreachable — against 76,263 here.

Those orphans are also why stage 60's expression gate had to learn a second
escape hatch. 40,745 expression documents are keyed on retired indica `BGIOSGA*`
stable ids (indica now ships `Osind.*`), and five studies have *all* of their
qualifying evidence there. `oryza_genes9` returns 0 for those five as well, so it
is the source data, not the build.

One v9 suggestion is *wrong* rather than merely different: `/suggest?q=potassium`
returns `TO:0000053` "pollen sterility" from `oryza_suggestions9`, and that term
is absent from **both** `oryza9.TO` and `oryza10.TO`. v9's suggestion core carries
a stale doc; this build does not.

## Open items needing a decision, not a guess

- ~~**`MSU_id` has no generator.**~~ **WRONG, and RESOLVED 2026-11-10.** The generator
  exists and ran: `search/msu6_adder.js` reads the tracked `search/OsNipp_IRGSP_MSU_lut.json`
  (1.4 MB, committed in b5d2a95). The data is NOT lost -- all 33,938 values are present in
  v10 and byte-identical to v9's, verified one id at a time, 0 differing, 0 absent. The
  newer lineage deliberately moved alternate ids out of ad-hoc top-level fields into
  `gene.alt_id` ("Separate alternate ids from synonyms into a dedicated gene.alt_id field"),
  which is strictly better placed: v9's `MSU_id` reached **no Solr field at all** (absent
  from the schema, and its value appears in no indexed field), while `alt_id` is indexed and
  earns an "Alternate IDs" suggestion. The two 175 MB artifacts were the hand re-upsert of
  this same mapping.

  **The one consequence is API-visible and is the open question for cutover:** the public
  `/oryza_v9/genes` response changes key for those 33,938 genes, and scalar becomes array.

      v9  (port 20009):  "MSU_id": "LOC_Os10g38278"
      v10 (port 20010):  "alt_id": ["LOC_Os10g38278"]

  Verified on the wire for `gene-rps2`. Any consumer reading `MSU_id` sees it disappear.
  This is the same class of breakage the gene-tree id decision was taken to avoid, so it
  wants the same deliberate call: accept the rename (it matches maize v6, sorghum v10/v11
  and grapevine v5), or have the API alias `MSU_id` back onto `alt_id` for this subsite.

- ~~**The MSU LUT disagrees with RAP-DB.**~~ **RESOLVED 2026-11-10 — fixed in this rebuild**
  on your call. `build/fetch_rap_msu_lut.js` now regenerates the LUT from RAP-DB; the numbers
  below are what it corrected. Applied to the built site with `make msu-alt-id` then
  `make msu-solr` (mongo first, then the index), and the `MSU_id` alias above was added so the
  public response keeps its old key. Result on oryza10: **29,256** genes carry an MSU alt_id
  (was 33,938 — the drop is RAP-DB's retractions) and chromosome disagreements go
  **1,738 → 0**. Both patches are idempotent. The LUT is still wrong in maize v6, sorghum
  v10/v10b/v11, grapevine v5, rice v8 and release70 — **that remains a release70 job.**

  Original finding, for the record — **not a v10 regression**, v10 reproduced v9 exactly: Measured against RAP-DB's authoritative
  `RAP-MSU.txt.gz` (`RAP-MSU_2024-07-12.txt`, 68,845 rows), which the live
  `rapdb.dna.naro.go.jp` host still serves:

  | check | LUT / v9 | RAP-DB file |
  | --- | --- | --- |
  | RAP and MSU id agree on chromosome | 32,122 ok, **1,738 DISAGREE (5.1%)** | 33,651 ok, **0 disagree** |
  | values where RAP-DB says `None` (no correspondence) | 2,853, each equal to the **preceding** row's value -- a fill-forward artifact | n/a |
  | genes with a real correspondence that are missing | **5,548 absent** | present |

  `Os01g0105300` is mapped to `LOC_Os11g36790` (chromosome 11) where RAP-DB gives
  `LOC_Os01g01560`; `Os01g0110500` to a chromosome 5 locus where RAP-DB gives chromosome 1.
  Both id schemes encode the chromosome, so a 5.1% cross-chromosome rate cannot be correct.
  The file also maps 459 RAP loci to more than one MSU gene, which a scalar LUT cannot hold.
  `OsNipp_IRGSP_MSU_lut.json` is present in maize v6, sorghum v10/v10b/v11, grapevine v5,
  rice v8 and release70, so **rebuilding it from RAP-DB also fixes every other subsite** once
  it is upstreamed.

  Two traps in RAP-DB's file, both guarded in the fetcher because each silently corrupts the
  result: **column 1 is the literal `None` on 22,967 rows** (MSU loci with no RAP counterpart —
  the reverse direction — which become a junk `"None"` LUT key if used), and **"listed with
  value `None`" must not be conflated with "not listed at all"**. The first is RAP-DB stating
  there is no correspondence, so the old value must go; the second is silence, where a
  chromosome-consistent legacy value may stand. Conflating them preserves exactly the 2,853
  fabricated values the fix exists to remove — my first run did precisely that.

  Also guarded in `msu_solr_patch.js`: the candidate set **cannot come from mongo alone**. Once
  mongo is patched, a gene whose MSU id was retracted no longer matches `alt_id:/^LOC_Os/`
  there and is not in the LUT either, so it never becomes a candidate and its stale value stays
  in the index permanently. 5,685 genes were in that state. The core is queried for
  `alt_id:loc_os*` as well and the union patched — 8,436 updates, matching the mongo side
  exactly. That script uses `set` (it must remove values, so `add-distinct` cannot work) and so
  it first proves mongo holds the whole truth about `alt_id`, aborting if any non-MSU value
  diverges; the Sobic./GRMZM/Vitvi alternate ids for other species (34,118 / 31,138 / 1,033
  genes) must survive untouched.

  **`stale_vs_genes` does not catch this.** Stage 65's regeneration check compares the
  suggestion json against the **`60_solr_genes.done` stamp**, not the core's contents — so
  patching the genes core directly leaves `Genes: alternate id` stale with the detector
  reporting nothing. Measured: 27,321 MSU suggestions against 28,902 distinct values now in the
  core, still carrying retracted `LOC_Os01g01019` and missing the corrected `LOC_Os01g01560`.
  **Any direct core patch that changes an indexed field must re-run stage 65 with
  `REGEN_AUX=1 REGEN_SUGGEST=1` explicitly.**
- ~~**PlantReactome publication xrefs are gone: 6,695 → 0.**~~ **RESOLVED 2026-11-10** — the
  real source was traced and an adder built, so a full build now produces them natively.
  `build/fetch_reactome_literature.js` carries the derivation; the rule is
  gene → R-OSA event (`Ensembl2PlantReactomeReactions.txt`) → **that event and all its
  ancestors** → `literatureReference`. The ancestor step is most of the data: Plant Reactome
  curates literature at pathway level and the genes beneath inherit it. Measured against v9:
  6,268 of 6,695 genes get the exact same pmid set, 400 get a superset, **none diverge**, and 27
  get nothing because those events have been retired upstream. Two traps are guarded in code:
  `ReactionPMIDS.txt` is reaction-level only and misses nearly all of it, and ContentService's
  `/data/query/ids` **silently caps at 20 results** with a 200 OK. Keep
  `reactome/reactome_literature.json` committed — decorate replays it, so an uncommitted artifact
  means the next build drops every reference again.
- *(historical, for the record)* **PlantReactome publication xrefs were 6,695 → 0.** v9's `genes` carries
  `{db:'PUBMED', source:'PlantReactome', text:<paper title>}` xrefs on 6,695 genes
  across 9 genomes (`zea_maysb73v4` 955, `oryza_sativa` 910, `zea_maysb73` 837,
  `selaginella_moellendorffii` 811, `sorghum_bicolor` 779, `oryza_rufipogon` 766,
  `arabidopsis_thaliana` 735, `leersia_perrieri` 712, `chlamydomonas_reinhardtii`
  190). **No generator exists** in either tree: `PlantReactome` appears only in
  `reactome/get_pathways.js`, which emits pathway/reaction xrefs and no PUBMED at
  all, and `source` is a per-adder literal (`curated.js` → CSHL, `rapdb.js` →
  RAP-DB) with no PlantReactome adder. These were applied by hand. The Publications
  tab renders `xrefs[].text`, so those genes lose their Plant Reactome references.
- **`genes_fixed` is resolved: do not reproduce it.** It is not an improved copy of
  `genes` — it is an abandoned mid-run snapshot of the PlantReactome pass above. It
  differs from `genes` only in `xrefs`, on 3.6% of genes, and it holds exactly 910
  PlantReactome-pubmed genes: the `oryza_sativa` count, with none of the other
  eight genomes' 5,785. So `genes` is a strict superset. It is declared in no
  `collections.js` in any release or subsite, so no code can reach it through the
  config layer. Drop it.
- ~~**Every gene-tree id changed shape.**~~ **RESOLVED 2026-11-10** — v9's exact ids restored.
  `trees/tree_sets.js` carries prefix `ORYZA9GT_` and `TREE_ID_ROOT_MARKER=""` drops the `root`
  marker, giving `ORYZA9GT_<root_id>` again. 35_genetrees asserts the precondition (0 published
  stable_ids in the clusterset, verified) so the marker can never be dropped where it matters.
- ~~**MSU and CSHL are absent.**~~ **RESOLVED 2026-11-10** — both added via
  `extra_cores` + `build/stages/42_extra_genomes.sh`, because neither can have a `maps`
  document: both report assembly accession `GCA_001433935.1`, which is `oryza_sativa`'s, so the
  `maps` `_id` would collide with the reference genome. That is why v9 hand-dumped them.
- *(historical, for the record)* **Every gene-tree id changed shape.** v9 ids are `ORYZA9GT_<root_id>`; this build
  mints `default_root<root_id>`. The numeric part is identical (`ORYZA9GT_1000025`
  → `default_root1000025`) because the compara is the same one, so the mapping is
  mechanical and the site is internally consistent — but the public path stays
  `/oryza_v9`, so any bookmarked or published tree URL breaks at cutover. All
  45,273 trees are affected: every one is unnamed, so every id is synthetic.
  `genetree.js` dropped the old `GT_PREFIX` fallback on purpose; `TREE_ID_PREFIX`
  gets part of the way back (`ORYZA9GT_root1000025`) but inserts a `root` marker,
  so reproducing v9's exact ids needs a one-line change as well as the prefix.
  Decide: accept the new ids, or restore v9's.
- **`germplasm_meta.txt` → `oryza_germplasm.jsonl` has no script** — the UUID →
  numeric `germplasm_dbid` resolution, the `stock_center` fill and the `tmp_N` id
  minting are unreproducible. Carrying forward from `oryza9` works; re-curating
  does not.
- **Two curation sources are `dev.gramene.org` mirrors**, not upstream
  (`rapdb.js`, `curated.js`). If that host is rebuilt, rice curation silently
  empties.
- **v9's solr work exists only as working-tree diffs** on the `oryza_v8` branch —
  including a real multi-value merge fix in `genes/add_attributes.pl`. Not
  inherited here (this tree descends from `maize_v6`); evaluate whether that fix
  is needed, since without it multi-valued VEP/germplasm attributes are malformed.

## Operational constraints

- **Never `pm2 restart all`** — ~57 apps are online, including every other subsite.
  Act on `oryza_swagger10` only.
- **Never restart mongod** — it would drop `oryza9`, `maize5/6`, `grapevine4/5`,
  `sorghum11`, `search69/70` and every other live db.
- Nothing under `v9/` may be edited, stopped or dropped. `oryza9` and its cores
  stay untouched through the whole build; the cutover is a service swap and
  **rollback is restarting the old service**.
- `dump_genes.js` takes the MySQL password as a command-line argument, visible in
  `ps` for the duration of a run. Pre-existing; do not widen it.
- The credential in `ensembl_db_info.json` is in public GitHub history across
  these repos and predates this build. Deleting the file now would not retract it;
  only rotating the password would. Flagged to the site owner.

## CUT OVER 2026-11-10 — v10 now serves /oryza_v9

`oryza_swagger9` stopped (pm2 id 46, still present and stopped, not deleted);
`oryza_swagger10` restarted onto **20009** via the app.js default. The proxy was not touched.

Verified on the **live public** path `https://data.gramene.org/oryza_v9`:

| check | result |
| --- | --- |
| /swagger /maps /germplasm /suggest /qtls /expression_attributes | all 200 |
| /search?rows=0 | **1,437,629** |
| /gxa | 302 → `https://www.ebi.ac.uk/gxa` |
| `MSU_id` alias | `gene-rps2` → `"MSU_id": "LOC_Os10g38278"` (plus `alt_id`) |
| v9 bookmarked tree id | `ORYZA9GT_3` → 1 doc |
| `oryza.gramene.org` UI | 200 |

Suggest was verified with the query the UI actually sends, not a bare term — the client builds
`{!boost b=relevance}name:T^5 ids:T^5 ids:T*^3 synonym:T^3 synonym:T*^2 text:T*^1`, and a bare
`q=<gene id>` legitimately returns `matches: 0`, which looks like a broken index and is not one.
`Os01g0100100` → `Genes: primary id`; **`LOC_Os01g01560` → `Genes: alternate id`**, i.e. the
newly CORRECTED MSU id is live and searchable; `waxy` → QTLs, Trait ontology, GO, symbol/name.

**The `Genes` suggestion category is split in this lineage** — v9 had one `Genes` (3,880,817);
v10 has `Genes: primary id` 1,437,629 + `Genes: symbol/name` 2,363,589 + `Genes: alternate id`
190,792. Checked before cutover rather than after: **maize v6 and grapevine v5 are already live
with the same three-way split**, and the UI groups on whatever categories come back
(`grouped.category.groups.forEach`) with no hardcoded names, so this is the proven convention,
not a regression.

### Rollback

```
pm2 stop oryza_swagger10 && pm2 start oryza_swagger9
```

`oryza9`, `oryza_genes9` and `oryza_suggestions9` were never written to at any point, so this is
a complete rollback. Nothing has been deleted.

### Not done, deliberately: `pm2 save`

pm2 warns that the saved process list is out of sync. Until it is saved, a pm2 resurrect or a
reboot restores the OLD list — `oryza_swagger9` on 20009 and no `oryza_swagger10` — i.e. it
silently rolls the cutover back. `pm2 save` is **your** call because it would also persist every
other unsaved change across the ~57 apps on this host, which is well outside this rebuild.

## Post-cutover data fixes — 2026-11-13

Three corrections landed on the live site after cutover. All were applied incrementally (mongo then
the genes core) rather than by rebuilding, all are idempotent, and `make all` is still a no-op.

### 1. The RAP → MSU LUT was rebuilt from RAP-DB  *(2026-11-10, recorded above)*

### 2. RAP-DB's curated gene list is now a tracked artifact, not a live fetch

`rapdb.js` fetched `rapdb.dna.naro.go.jp` during decorate with a copy on `dev.gramene.org` as its
only fallback. The mirror is gone — it was a copy of the same upstream file on a host this build
does not control. RAP-DB now gets what `curated.js` already had: `search/rapdb_curated_genes.json`,
regenerated by `29_curated_sources` (`make rap-msu-lut` is the LUT; the curated list comes with the
stage). Upstream stays as the fallback only; `affrc.go.jp` remains dead.

**Why it matters beyond provenance:** `curated_source.js`'s `fetchJson` ends with *"every source URL
failed — proceeding with an empty LUT"*, so a transient network failure during decorate silently
drops every RAP-DB name, synonym, ontology term and reference instead of failing the build. Not
hypothetical: the same URL answered 6,747 loci and then **0** within minutes while this was being
measured. No data change — the artifact reproduces the live fetch exactly (6,747 loci / 8,950
references).

**`curated.js` was already correct and needs no change.** It reads
`search/cshl_curated_genes.json`, parsed from the Google Sheet by `fetch_cshl_curation.js` in stage
29 — 1,077 loci / 1,177 references, verified loading. The `dev.gramene.org/cshl_curated_genes.json`
URL in that file is a deliberately-last legacy fallback, not the source. **Do not read a dead
`dev.gramene.org` URL as "CSHL curation is broken"** — check the `localFile` artifact first.

### 3. Synonyms naming another locus were removed — 56 genes, 119 synonyms

A `Uniprot_gn` xref row is keyed on the bare gene **symbol**, and `dump_genes.js` joins
`external_synonym` against `g.display_xref_id` — so two unrelated genes sharing a symbol inherit
each other's identifiers. `Os01g0100900` (*sphingosine-1-phosphate lyase*, UniProt `Q52RG7`,
chr1:35,623) carried `LOC_Os01g18850` and `Os01g0292900`: the ids of *OsSPL1/OsSBP1*, a
SQUAMOSA-promoter-binding transcription factor **10.6 Mb away**. Searching either returned a wrong
gene.

`OsJ_01398` and `P0706B05.40` on that same xref row are UniProt's own ORF names for `Q52RG7` and
were **kept** — not every synonym on such a row is foreign. The tell that this is upstream
mis-assignment: the gene's own correct MSU id (`LOC_Os01g01080`) is *absent* from that list while
the other locus's is present.

Now `51_synonym_conflicts`, a **prerequisite of 60** (not merely a member of `all`), so a rebuild
produces a clean core with no index patch. `make synonym-conflicts` + `make synonym-conflicts-solr`
for an already-built site. Full rule, per-site scope and the four traps:
`release70/build/docs/07-upstream-defects.md` defect 10.

Live result:

    Os01g0100900 (SPL1): synonyms = [OsJ_01398, P0706B05.40, OsSPL1, OsSPL]
                         MSU_id   = LOC_Os01g01080     (alias), alt_id = [LOC_Os01g01080]
    synonyms:"LOC_Os01g18850" -> 0      synonyms:"Os01g0292900" -> 0
    id:"Os01g0292900"         -> 1      (the real gene still resolves)

Two things deliberately left as they are, so they do not read as misses:

* **Four adjacency exemptions kept.** A split or merged gene model legitimately carries its
  neighbour's retired id. Same-chromosome gaps are 0, 0, 428 and 690 bp and then jump to 13,907 bp,
  so the 2 kb threshold sits in empty space. Kept: three arabidopsis pairs with consecutive AT ids,
  plus `Os06g0610350`/`Os06g0610300`.
* **Synonyms naming an id absent from the site are left alone** — with nothing to locate there is no
  evidence it names a different locus. Rice keeps `Os11g0155900` and `Os06g0159450`, both citing the
  retired `Os06g0159501`.

**No suggestions rebuild was needed**, measured rather than assumed: every removed value is another
gene's identifier, and primary-id suggestions are derived per-gene from the `id` field — 0 of
1,437,629 with `num_genes>1`, and no symbol/name suggestion for any removed value. Re-probe this if
the suggestion builder changes.

### Why this site has far more of it than the main release

release70 builds rice from `oryza_sativa_core_70_116_7` and carries **6**; this site is pinned to
the frozen `oryza_sativa_core_8_108_7` and carried **119**. The e116 display xrefs differ — the same
gene is named `SPL` there rather than `SPL1`. Partly fixed upstream already, but not deliberately.
