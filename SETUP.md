# Grapevine v5 — how this release root was set up

Modelled on `release70/build/SETUP.md`, which is the other instance of moving the
staged build harness onto a different site. Written while doing it, 2026-11-04.

The goal was narrow: re-run the modern pipeline so grapevine picks up the data and features added
since its 2023 build, **without** changing Ensembl core, variation or compara databases, so gene
models and gene trees stay identical. They did: `grapevine5.genes` = 1,371,275 and
`grapevine5.genetree` = 34,196, both exactly matching `grapevine4`.

## Names

| | v4 (live) | v5 |
| --- | --- | --- |
| release root | `subsites/grapevine/v4` | `subsites/grapevine/v5` |
| mongo db | `grapevine4` | `grapevine5` |
| solr cores | `grapevine_genes4`, `grapevine_suggestions4` | `grapevine_genes5`, `grapevine_suggestions5` |
| pm2 / ports | `grapevine_swagger4` 40004, `grapevine_ebeye4` 41004 | `grapevine_swagger5` 40005, `grapevine_ebeye5` 41005 |
| public | `data.gramene.org/grapevine_v4` | `data.gramene.org/grapevine_v5` |

Ports follow grapevine's own **40000+/41000+** convention, not the sorghum `10000+`/`11000+` one.
`70_services.sh` honours `SWAGGER_PORT`/`EBEYE_PORT`, so `config.sh` sets them and the stage needed
no patching for ports. The gorgonzola proxy for `/grapevine_v5` → `squam:40005` and the ebeye route
→ `squam:41005` were opened before the build, so **starting the services publishes the site** —
there is no internal-only window. Verify against local solr/mongo before `70_services`.

## Branches — and why `release70`, not `grapevine_v4`

| repo | base | branch here |
| --- | --- | --- |
| `build` | `release70` | `grapevine_v5` |
| `gramene-mongodb` | `release70` | `grapevine_v5` |
| `gramene-mongodb-config` | **`main_v70`** | `grapevine_v5` |
| `gramene-solr` | `release70` | `grapevine_v5` |
| `gramene-swagger` | `release70` | `grapevine_v5` |
| `gramene-ebeye` | `release70` | `grapevine_v5` |

Not `grapevine_v4`: its `collections.js` declares 13 collections and `00_preflight.sh` requires 16
(`homologs`, `expression_attributes`, `germplasm`, `genelists`, `savedviews` are all absent there).
Not `sorghum_v11` for the harness either: every feature this rebuild exists to pick up
(`pubmed_title_adder`, `species_rank`, `supertrees`, the decorate stall diagnostics, corrected
`_terms`) lives only on `release70`. Sorghum v11's `build/docs/05-release-playbook.md` remains the
*procedure* document.

This root was created by **cloning**, not `cp -r` from v4 — v4 is 18 GB of 2023 artifacts on the
wrong branches. One consequence to know about: git does not track empty directories, so `build/tmp`
did not exist and `check_stable_id_collisions.sh` failed inside `mktemp`. `40_genes_dump.sh` now
`mkdir -p`s it.

### Three release70 repos were ahead of their remotes, and a clone is broken without them

Audit before trusting any fresh clone:
`git -C <repo> rev-list --left-right --count origin/<branch>...HEAD`

- **`gramene-mongodb-config` +2** — adds `tree_shape.js`. Without it `trees/genetree.js` dies with
  `MODULE_NOT_FOUND` and no gene trees build at all.
- **`gramene-swagger` +44** — includes `/genetrees` rebuilding the tree from the **flat** stored
  shape. The flat *storage* in `gramene-mongodb`'s `release70` branch **is** pushed, so
  `origin/release70` is mutually inconsistent across the two repos: clone both and the site serves
  broken gene trees.
- **`gramene-ebeye` +3** — exports `alt_id`, and stops *requiring* it on every doc. Only 22,074 of
  1,371,275 genes have one, so the export would have rejected nearly all of them.

Each was merged from release70's working copy (`git fetch /usr/local/gramene/release70/<repo>
<branch>` then `git merge FETCH_HEAD`) rather than cherry-picked, so the commits keep their identity
instead of becoming divergent copies. **None of it is pushed. It still needs pushing.**

## Source databases — frozen

`gramene-mongodb/ensembl_db_info.json` is byte-identical to v4's: compara
`ensembl_compara_5_87_grape1023v2`, 39 cores on the `_87_` line, 2 variation dbs
(`oryza_sativa_variation_7_87_7`, `sorghum_bicolor_variation_6_87_30`), 0 `anchor` flags, host
`cabot`. All 42 verified present. **Never run `get_ensembl_db_info.js` here** — it would regenerate
the file and silently build a different genome set. `00_preflight` catches drift against
`EXPECT_CORES=39` / `EXPECT_VARIATIONS=2` / the compara name.

The `v4_108/` directory is an abandoned, never-completed re-run (131 MB vs v4's 18 GB, no gene
dumps, serving tier never patched). It stages a *different* 27-core `_108_` set against a different
compara, which would have changed gene trees and dropped 12 wild Vitis species. Deliberately unused.

## Six main-release gates fail on a correct 39-genome build

All parameterised in `config.sh` rather than deleted, so each assertion stays live where it holds:

| knob | why |
| --- | --- |
| `MAPS_MIN=35` | `10_maps`, `20_variation`, `25_reactome` hardcode `maps 100` for "125 cores"; this site has 39 |
| `TAXONOMY_MIN=100` | passes at 147, parameterised so it is not luck |
| `EXPECT_TREES` | this compara has ONE tree set (`default`, 34,196), not five |
| `EXPECT_SUPERTREES=0` | zero `tree_type='supertree'` rows; otherwise stage 60 dies after its ~1h load |
| `EXPECT_DEEP_TREES=0` | `verify_tree_shape --deep-report` demands a tree >112 levels because r70 had 147. Measured here: deepest 69, none over 80, `max_depth` written on all 34,196 — which rules out both failures it guards |
| `45_homologs` probes | probed a maize id; now probes `VIT_01s0010g03900` so the gate covers this site's own species |

Also: `15_ontologies` now fetches InterPro over https → ftp → `INTERPRO_REUSE_FROM`, because
EBI's `https://ftp.ebi.ac.uk` TLS listener goes down intermittently while `ftp://` and
`www.ebi.ac.uk` stay up. A single-URL curl turned that into a dead build.

## The two PN40024 assemblies — the thing to understand about this site

They are the **same genome at two annotation versions**, not a reference and a cultivar, which is
why the pathway crosswalk is named `vv_orthologs.v3.v4.txt`:

- `vitis_viniferapn40024` — taxon **29760020**, "PN40024 v4", `Vitvi`-keyed, 35,197 genes. The
  current annotation, the site's `targetTaxonId` and curation taxon, `species_idx` **1**.
- `vitis_vinifera` — taxon **29760019**, "PN40024 v3", `VIT_`-keyed, 29,971 genes. `species_idx` 2.

Two consequences that bit three separate places:

1. **Anything keyed on `taxon_id // 1000` collides across the pair** (both → 29760). That is how the
   expression pipeline would have given them one shared reference distribution and one panel entry
   (fixed by keying on the full `taxon_id`), and how `manifest.json`'s `short` — which names
   `<short>_attributes.jsonl` — would have made both write one file (now `grape_v4`/`grape_v3`).
2. **`reactome/update_vv.pl` rewrites rather than duplicates.** It replaces each `Vitvi` pathway key
   with its `VIT_` partner, which on this site *moves* annotations between the two genomes and nets
   nothing: v4 coverage was pn40024 1,113 and vinifera **0**. `reactome/duplicate_vv.js` emits both
   keys instead, giving **1,153 / 1,106**.

Both grape crosswalks were expanded from `atlas/new_old.lut.txt`'s 22,048 `Vitvi`↔`VIT_` pairs (all
44,096 ids verified to be real genes), unioned with the original curated rows:
`reactome/vv_orthologs.v3.v4.txt` 1,033 → 22,078 and `search/vitis_crosswalk.tsv` 1,033 → 22,074.
They are **different files read by different code** — the reactome one by `duplicate_vv.js`, the
search one by `vitis_synonym_adder.js` — so expanding one does not expand the other.

## Expression: v5's `expression` collection is SMALLER and that is correct

Compare raw collection counts and v5 looks like a 69% regression. It is not. Join each
`expression` doc to a gene in this subsite:

| | v4 | v5 |
| --- | --- | --- |
| `expression` docs total | 1,060,326 | 329,702 |
| ...joining a real gene here | 257,008 | **274,682** |
| ...for genes absent from this subsite | 803,318 | 55,020 |
| `assays` | 1,801 | **6,583** |
| `experiments` | 117 | **381** |

v4's collection was **76% dead weight**: it loaded the whole Expression Atlas set without
restricting to this site's 39 genomes, so it carried wheat (`TraesCS` 107,891 docs),
*Brassica napus* (`GSBRNA` 101,040), barley (`HORVU` 63,814), soybean (`GLYMA_` 55,897),
poplar (`POPTR_` 41,335) and more — each with **zero** matching gene records, so none of it
could ever surface. That 257,008 equals the solr `expression` capability count in the v4
baseline confirms it: only the joining docs were ever served.

Real coverage is **up 6.9%**, every genome is equal or better (arabidopsis 32,548 → 37,872),
and Drosophila is newly covered (0 → 18,101).

Of v5's 55,020 non-joining docs, ~41,614 are maize **v4** `Zm00001d` ids retained
deliberately as stage 56's projection source (see below), and 5,901 are Drosophila
transposons and transcripts (`FBti`, `FBtr`) which are not genes and never join.

### Drosophila is excluded from `expression_attributes` — and chlamydomonas is not

`mongo_source.discover_genomes` auto-discovers every genome with expression data, which is
right: coverage should track the build. It found **9** genomes here, one more than the
manifest lists, because Drosophila is present as an outgroup. All 17,559 of its docs came out
**empty** — taxon 7227 has no `po_map.CLADE_OF_TAXON` entry, so it falls to clade `other`,
which has no `CLADE_PANELS` organ panel, and the plant stress classifier matches none of its
contrasts. That is 6.4% of the collection advertising a capability holding nothing.

`discover_genomes` now honours an `"exclude": true` manifest override beside the existing
`clade`/`short`/`name` ones; filtering there covers the stage's SHORTS listing, `build.py` and
the completeness check at once. Raw `expression` docs (18,101) are untouched.

**The test for exclusion is zero information, not zero organs.** Chlamydomonas also resolves
to a 0-organ panel, but that is deliberate — algae and bryophytes are stress-only
(`CLADE_PANELS`: grass 13 organs, eudicot 17, bryophyte 0, algae 0) — and it carries real
data: 4,130 docs with stress attributes, 1,913 `activated_by`, 2,217 `repressed_by`. Setting
its clade to `algae` rather than `other` is what keeps it working.

Final collection: **257,123 docs over 8 genomes**, each genome's count equal to its
genes-with-expression. The drosophila docs were removed surgically rather than by re-running
the ~1h stage, which is sound here because there is no cross-genome coupling to redo:
`expression_panel.json`'s `species` dict is per-taxon with per-genome `reference` breakpoints,
while `expression_level`/`specificity`/`differential` are config constants, not data-derived.
The stage's own completeness check was then re-run standalone and passes, with no stray
`*_attributes.jsonl` left for its import glob to re-add.

### `56_project_maize_v4v5` is needed here — and it does not remap ids

The plan listed "is 56 actually needed?" as an open question. It is. It does **not** convert
the 41,614 `Zm00001d` docs into v5 docs; it copies their *differential* data onto the
already-joining `Zm00001eb` docs via `geneIDhistory.maizeV5`: 33,240 LUT keys, 22,737 v4
docs read, **24,472 v5 docs updated**. `Zm00001eb000010` went 31 keys → 64, gaining 43
experiments. Without this stage those 24,472 maize docs would carry baseline only.

Note the storage shape when checking this by hand: differential data lives in per-experiment
arrays keyed by accession (`"E-CURD-113": [{group, p_value, l2fc}]`), **not** in fields named
after the metric. Grepping doc keys for `l2fc` finds nothing and looks like a failed stage.
`mongo_source.flatten_expr` is what turns that into the `E_CURD_113_g1_g2_l2fc_attr_f` shape
`expr_lib.parse_diff_field` expects, and the two round-trip exactly.

## Two solr capabilities are LOWER than v4. Both are correct. Verify, do not "fix".

The plan treats v4's capability counts as a floor that nothing may fall below. Two fall.
Neither is data loss, and both were confirmed by recomputing the number from mongo
independently of solr.

| capability | v4 | v5 | |
| --- | --- | --- | --- |
| `expression` | 257,008 | 242,725 | definition changed |
| `domains` | 1,031,165 | 1,030,307 | upstream InterPro churn (-0.083%) |

### `expression`: the capability changed meaning, the data did not shrink

v4's `gramene-solr/genes/mongo2solr.js` pushed it unconditionally:

```js
// check if this gene has expression data
if (expressionData[mongo._id]) { solr.capabilities.push('expression'); }
```

So v4's per-genome counts are exactly each genome's expression-doc totals — every gene with a
record got the flag. The current `mongo2solr.join.js` instead requires evidence of expression:
a sample `value >= 0.5`, or `p_value < 0.05` with `|l2fc| >= 1.0`. 242,725 of 274,682 joining
docs (88%) qualify. Recomputing that rule directly in mongo reproduces solr to the gene —
tomato 25,265, `vitis_vinifera` 25,589, `vitis_viniferapn40024` 20,080 — so the narrowing is
the rule working, not a load fault. **No gene lost expression data**; `expression_attributes`
(257,123) is the richer successor signal anyway.

This is client-visible, in the same class as the suggestion-category rename already flagged
under Risks: a front-end that gates an expression panel on `capabilities:expression` will stop
offering it for 14,283 genes that have no evidence of being expressed.

### `domains`: InterPro retired some models since 2023

Spread thin across all 39 genomes (-55 to +8 each; 5 genomes *gained*), net -858 of 1,031,165.
Not a pipeline fault: mongo and solr agree exactly in both releases. For `vitis_riparia`, the
worst case, both releases hold the same 32,797 genes with an `annotations.domains` object, but
genes with **at least one entry** are 32,764 in v4 and 32,709 in v5 — matching solr's 32,764
and 32,709 to the gene. So 55 genes lost their last resolvable entry because the accession no
longer exists upstream; `15_ontologies` fetches InterPro fresh while v4's is frozen at 2023.

Note for anyone re-checking this: `{"annotations.domains": {$exists: true}}` over-counts,
because the object can be present with its `entries` key absent entirely (not an empty array —
there are zero of those). Count `"annotations.domains.entries.0"` instead.

## Deliberately not carried over

- **v4's uncommitted serving-tier edits** (`solr.js` `urlBase`, swagger port/basePath/title, ebeye
  `DEFAULT_PORT`/`defaultServer`, and the `#grapevine_v4`/`#main68`/`#oryza_v5.1` dep pins). Every
  one is now a *derived* value `70_services.sh` writes from `config.sh`. Re-applying them by hand
  reintroduces exactly the drift the harness exists to remove. The one piece worth salvaging was
  `suggestions/aux.js`'s `d.ancestors` guard, which is committed here.
- **GitHub branch pins.** All repos use `"gramene-mongodb-config": "file:../gramene-mongodb-config"`
  and `05_install` forces `node_modules/gramene-mongodb-config` to be a symlink, because npm
  *copies* a `file:` dependency. A re-introduced `#` pin is how older builds silently targeted
  `oryza7`/`sorghum7`. The stale per-repo READMEs will tempt you to add `#grapevine_v5`. Don't.
- **Sorghum/maize-only stages**: `57_jgi_expression`, `28_grassius_source`, `29_curated_sources`
  (the CSHL feed is 1,072 `SORBI_*` + 5 `AT*`, zero Vitis), MAKER/VEP/rsID. None is in `make all`.
- **Primers and genotyping** — `PRIMERS_ENABLED=false`. Disabled for scope, not for missing data:
  `/scratch/olson/fasta/vitis_*` has complete BLAST databases including `dna.toplevel`, the same set
  sorghum has, and `primer3_core`/`blastn` are installed. Only the per-site config (`site_key` →
  genome list → assembly paths) is missing, so primer *design* here is a credible follow-up.
  Genotyping is not: the variation map is `{sorghum_bicolor}` and Vitis has no variation database.

**Stages that DO apply despite looking sorghum/maize-shaped:** `zea_maysb73` here is
`Zm00001eb*` = B73 **v5**, so `fix_maize_v5`, the ZMY Reactome supplement and
`56_project_maize_v4v5` all matter (maize carries 1,519 pathway genes). Rice is `Os…`, so the OSA
supplement, `rapdb` and `msu6_adder` apply. `20_variation` matters even though Vitis has no
variation db — the rice and sorghum variation dbs produce the 55,440 `QTL_TO` genes.

## The Vitis crosswalk had to be made bidirectional

`search/vitis_synonym_adder.js` keyed its LUT only on the 12X `VIT_` id, because on the main
release VIT_ is the only grapevine genome loaded and is therefore canonical. Here **both**
PN40024 annotations are separate genomes and **v4 (Vitvi) is the reference** — `targetTaxonId`,
`species_idx` 1. So the one-way mapping put `alt_id` on 22,074 `vitis_vinifera` genes and
**zero** `vitis_viniferapn40024` genes.

Caught by diffing the API against v4, not by any gate:

```
/search?q=VIT_01s0010g03900   grapevine_v4 -> 2 genes   grapevine_v5 -> 1
```

v4 returned the legacy gene **and** its current pn40024 partner, because the old hand-built
site had the mapping the other way round, as `synonyms` on the pn40024 gene. So the one-way
LUT was a regression against v4, not merely a gap: a user searching a legacy VIT_ id reached
only the deprecated v3 gene, never the current reference one.

The adder now keys on every scheme and accumulates (the mapping is 1:many in both directions,
so reverse keys collide by design). The VCost xref stays one-way — a Vitvi gene's own `_id`
already IS its VCost identifier — so the xref count is unchanged. On a site carrying only the
VIT_ assembly the reverse keys match no gene, so it is a strict no-op there and safe for the
lineage. LUT 22,074 → 45,049 ids.

**This is the third instance of one assumption**: that VIT_ is the only grapevine genome
present. It broke `reactome/update_vv.pl` (replaced instead of duplicating), the expression
pipeline (`taxon_id // 1000` collapsing both assemblies), and this adder. When touching
anything grapevine-specific in a shared repo, check which of the two assemblies it assumes.

## Do not drive the stages by hand without checking `make all`

`52_tree_domains` is a dependency of `all` (`Makefile:96`) but not of `65_solr_suggestions`,
so running the stages individually in data order skips it silently and the build still looks
finished. It pushes domain architecture, taxa, transcript counts and exon junctions onto gene-
tree leaves, and it must run after `50_genes_decorate` (needs `genes`) and `15_ontologies`
(needs `domains`). Check `ls .state/` against `sed -n '/^all:/,/^$/p' Makefile` before
declaring a build complete.

## A release70 suggestions bug — found here, FIXED here, still live upstream

`Trait ontology` suggestions came out 342 against v4's 704. The cause is a latent bug in the
shared `gramene-solr/suggestions/aux.js` that release 70 exposed. It is fixed on this branch;
it is **still live on the main site and SorghumBase**.

| core | QTLs | Trait ontology | `id:"TO:0000008"` |
| --- | --- | --- | --- |
| `suggestions69` | 13,024 | **716** | `Trait ontology` (pre-bug) |
| `suggestions70` | 13,461 | **342** | `QTLs` — bug live |
| `sorghum_suggestions11` | 13,461 | 332 | — bug live |
| `grapevine_suggestions5` (before fix) | 13,461 | 342 | `QTLs` |
| `grapevine_suggestions5` (after fix) | 13,461 | **741** | `Trait ontology` |

**Mechanism.** For `key === "QTL_TO"`, `aux.js` switches to the TO collection on purpose
("change the key to TO so we get QTL suggestions", ~line 328), so `TO.json` (category
`Trait ontology`, `fq_field: TO__ancestors`) and `QTL_TO.json` (category `QTLs`, `fq_field:
QTL_TO__ancestors`) are both built from the same TO terms, and both keyed the solr doc's `id`
on the bare accession. The schema sets `<uniqueKey>id</uniqueKey>`
(`suggestions/conf/managed-schema:173`) and stage 65 loads `TO.json` **before** `QTL_TO.json`,
so shared terms lost their trait doc. Measured: `TO.json` 741, `QTL_TO.json` 495, intersection
exactly **399**; 741 - 399 = 342, matching solr to the document.

Not a cosmetic relabel — the survivor carried `fq_field: QTL_TO__ancestors`, so picking it
filtered by QTL association rather than trait annotation, over a very different gene set (`TO`
capability 4,405 genes vs `QTL_TO` 72,845).

It was latent because the collision needs a term to be both a gene TO-annotation ancestor and
a QTL_TO ancestor; r70's QTL_TO coverage growth (55,440 -> 72,845 genes here) took
`QTL_TO.json` from roughly 60 docs to 495.

**The fix** is one line in the `QTL_TO` builder: `id: 'QTL_' + doc.id`, so the two docs no
longer share a uniqueKey. Both now coexist — `Trait ontology` 741 and `QTLs` 13,461, and the
core grew by exactly the 399 recovered docs (3,117,425 -> 3,117,824).

Reordering the two loads is NOT a fix — it just loses 399 QTL suggestions instead.

**On client safety.** An earlier draft of this note deferred the fix on the grounds that `id`
is "both the uniqueKey and the displayed accession". That was wrong, and it is worth recording
why, because it is the reason this sat unfixed. The front end never sees the suggestion `id`:
`gramene-search/src/components/suggestions.js` renders `sugg.display_name` and `sugg.num_genes`
and keys its list on array indices, and `src/bundles/filters.js:81` builds the filter with
`_.pick(payload, ['fq_field', 'fq_value', 'name', 'category'])` — `id` is not among them. The
swagger `Suggestion` definition requires `id` but assigns it no semantics. The accession also
remains available unprefixed in `int_id`. Checked against the only front-end checkout on this
host, `release69/gramene-meta/modules/gramene-search`.

**Applying it upstream** is a separate deliverable: the same one-line change on `release70`,
then a reload of stage 65 for `suggestions70` and `sorghum_suggestions11`. Nothing else needs
to move — no schema change, no reindex of the genes core.

My own `suggestions/aux.js` change here (`829b11a`, the `d.ancestors` guard) was NOT implicated:
TO has zero docs lacking `ancestors` in either release, and the stage log shows all 4,676
passing through.

### Two TO observations that are drift, not defects

`TO` in mongo is 4,676 here against v4's 4,920, but real trait terms went **up**: 1,667 ->
1,697. The 244 net drop is entirely foreign-namespace cross-references pulled in by the OBO
import (ENVO/PECO/CHEBI/NCBITaxon): 299 lost, 25 gained. Exactly one real trait left,
`TO:0000192 "leaf-roller resistance"`, and it was *merged* rather than deleted — it is now an
`alt_id` of `TO:0000403 "rice leaf folder response trait"`.

`/suggest?q=potassium` returns 7 traits here against v4's 8. The missing one is `TO:0000053`,
present in both cores but renamed `OBSOLETE pollen sterility` by the current TO release, which
changed its indexed text. Note in passing that the loader keeps obsolete terms as suggestions
with the `OBSOLETE ` prefix intact; that is lineage behaviour, not something this build
introduced, and it may be worth revisiting upstream.

## ebeye crashed on every error path; v4 still does

`gramene-ebeye` answered request failures by terminating. The v4 instance of the same code is
at 863 pm2 restarts and still looping; v5 is fixed (`gramene-ebeye` commit `480dcdc`).

The misleading part is the log. v4's error log is full of
`Error: genomic_unit should be plants; instead it's protists` from `translateRequestParams.js:29`,
which looks like the culprit and is not: Express 4 catches a synchronous throw inside a handler,
so that path returns 500 and the process survives (verified directly against ebeye5). The fatal
paths are the three Express cannot see, and all three were reachable:

| path | where | proven |
| --- | --- | --- |
| `'error'` on a piped stream, no listener | `/ensemblGenomes_genome`, `/ensemblGenomes_seqregion` | died, `Unhandled 'error' event ... ECONNREFUSED` |
| throw inside an async callback | `/ensemblGenomes_variant` — `JSON.parse(response.body)` on an HTML error page, and `hit.fields.associated_gene.length` where that field is absent | died, `SyntaxError: Unexpected token '<'` |
| rejected promise, no `.catch` | `/ensemblGenomes_gene` — `grameneClient` rejects when the swagger spec at `global.gramene.defaultServer` is unreachable (the documented startup crash-loop), `translateResponseDocument` throws on an unexpected shape | fatal on node >= 15 by default |

The first two were reproduced against a dead upstream before and after the fix: the old shapes
take the process down, the new ones answer 502 and stay up.

Two things found alongside, one fixed and one not. The variant handler's
`if (err) { console.log(err); return; }` sent no response at all, so the client waited for its
own timeout — now a 502. And `src/search.js` passes only a success callback to
`client['Search'].genes`, so an error there never settles the deferred and the request hangs
rather than failing; left alone, since it is a hang and not a crash.

Note `/ensemblGenomes_seqregion` is simply slow, not broken: the EBI upstream takes ~30 s for it,
the same on v4. Allow for that before calling it a regression.

## 60_solr_genes reused a stale dump and silently dropped 50 studies

Worth reading before any rebuild that touches `expression`, because every count-based gate
passed while this was broken.

`60_solr_genes` caches its converted `solr_genes.json` (12 GB) and decides whether to reuse it
by comparing mtimes against a dependency list. That list named only `50_genes_decorate.done` and
the mapper script -- but `mongo2solr.join.js` `$lookup`s `expression`, which `55_atlas` loads and
`56_project_maize_v4v5` adds to. So after re-fetching 50 Atlas studies into mongo on 2026-11-05,
the stage logged `reusing existing complete solr_genes.json` and **not one of the 50 reached the
core**. `expressed_in_gxa_attr_ss` had 325 studies where it should have had 374.

Nothing caught it. The file is one line per gene and the gene set had not moved, so the byte
size and line count both said "complete"; `numDocs` matched mongo; every capability count looked
plausible. A study lives in a FIELD of a gene document, so losing all of them changes no count.
The only symptom was an empty expression widget, and the API 500ed on top of it for an unrelated
reason (see the gxa note in `gramene-swagger`).

This is the **second** time this exact bug has happened -- the stage's own comment records the
first, when 3.9M cultivar tree memberships never reached solr off a 2-day-old dump. The fix then
added only the two dependencies it needed at the time, which is precisely how it recurred.

Fixed in `build` commits `6ff927d` and `c598add`:
- both missing stamps added to the dependency list, with a standing rule in the comment: **if you
  add a `$lookup` to the mapper, add its stage stamp here**;
- a gate that does not rely on counts. It facets the core for the studies it can actually
  *search*, diffs that against the experiment list, and for anything missing applies the mapper's
  own evidence rule. A study with evidence in mongo that is not searchable is fatal.

A caution on that gate, learned by failing a good build with it: the rule must match the mapper
EXACTLY. The differential arm needs `p < 0.05` **and** `|l2fc| >= 1` in the same sample, because
the mapper reads `Math.abs(sample.l2fc ?? 0) >= 1.0`. A first version asked only for `p < 0.05`
and flagged 7 studies that legitimately carry no evidence, killing a correct run.

Final state: 374 studies searchable, 7 absent and all 7 confirmed as having no gene that passes
the evidence bar.

## E-CURD-1 has two dead assay groups, and they are upstream

Do not spend time on this again. The Arabidopsis meta-analysis `E-CURD-1` renders two columns
with zero expression for every gene. Both are upstream; our parser is faithful.

| group | study | TPM column sum | genes > 0 | what it is |
| --- | --- | --- | --- | --- |
| `g13` | E-GEOD-49090, flower | **0** | 0 | not a library at all -- TPM sums to ~1e6 by construction, so an all-zero column means upstream shipped nothing |
| `g19` | E-GEOD-37644, flower | 1,000,001 | 9 | a real, correctly normalised library that is 84% chloroplast (`ATCG00320` + `ATCG00230` + `ATCG00140` = 839,523 TPM) plus the `AT2G01010` rDNA locus, so nuclear genes genuinely round to 0 |

Note `g19` belongs to a DIFFERENT study from `g13`. E-GEOD-49090 contributes only `g13` and
`g21`, and `g21` (leaf) is healthy at 22,600 genes.

Evidence it is not a parsing fault: our `E-CURD-1-tpms.tsv` is byte-identical to the live
upstream file and upstream's `g13` is still all zeros; mongo matches the TSV value for value,
large numbers included; the median-of-quantiles extraction checks out
(`"19,21,24,27,29"` -> 24); and the header's LEXICOGRAPHIC group order (`g1, g10, g11, ...`) is
preserved rather than re-sorted, so there is no column shift.

A sweep of all 97 baseline studies (1,896 assay groups) finds exactly these two. The next
lowest group has 363 expressed genes, so the gap is clean. Twelve of the groups just above them
belong to `E-GEOD-51662`, which is a small-RNA study ("Distinct small RNA populations act
antagonistically in formation of heterosis") -- few mapped loci is expected there and every group
sums to ~1e6, so it is correctly loaded.

Neither dead group affects the indexes: the >= 0.5 TPM evidence gate excludes both, so neither
grants the `expression` capability nor inflates a count. `g13` does render as a zero column in
the expression widget, which is how it was found.

`55_atlas` now reports all-zero TPM columns (commit `dadfbd0`), so this is visible in the build
log rather than through the UI. It warns and never fails -- the data is upstream's and we carry
it faithfully. The check is deliberately limited to arithmetically impossible columns: `g19` is
not flagged, because a sparse-but-real library is a judgement call about the biology while a
zero-sum TPM column is not. It appears on the next run of the stage; it was verified against
these 97 files rather than by re-running `55_atlas`, since refreshing that stamp would redo
`56` -> `58` -> `60` -> `65` for a logging change.

## Still outstanding

- Push the three release70 repos above, and this root's six `grapevine_v5` branches.
- Carry the `QTL_TO` uniqueKey fix above to `release70`, then reload stage 65 for
  `suggestions70` and `sorghum_suggestions11` — both are serving 342/332 trait suggestions
  today where they should serve ~716.
- Pointing the public site at v5 means bumping `grameneData` to `/grapevine_v5` in
  `gramene-meta`'s `modules/gramene-search/src/demo.js:181`. That is the only such checkout on
  squam and nothing serves it under pm2, so the deployed bundle is built elsewhere.
- v4's `gramene-ebeye` is crash-looping (863 restarts and climbing) on the error paths fixed in
  v5's copy. It is live production and off limits, so it is listed here rather than touched; the
  fix is one commit (`480dcdc`) if it is ever wanted there.
- v4 stays live. Retiring it is a separate, deliberate step — do not stop its pm2 processes, drop
  its db or cores, or edit anything under `v4/`.
