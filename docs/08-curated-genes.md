# Functionally curated genes in release 70

Reviewed **2026-10-29** against `search70` / the `genes70` core and by streaming each upstream file.
Every figure below was measured, not quoted from documentation; the queries are in
[Reproducing these](#reproducing-these).

Five sources of curated gene function were in scope: NCBI GeneRIF, RAP-DB curated genes, TAIR,
MaizeGDB, and the in-house curation sheet behind the site's own "Curate Gene Function" form.

**All five were already wired into the pipeline.** This was not a missing integration. What was
broken was the data flow, in seven distinct ways, every one of them silent.

| # | Defect | Scale | Fixed in r70 |
| --- | --- | --- | --- |
| 1 | The in-house curation feed was frozen at 2024-10-10 | 158 of 1,087 genes reached the site | yes |
| 2 | 45% of curation-sheet rows use ids the loaders could not match | 551 of 1,220 rows | yes |
| 3 | MaizeGDB curation was dropped between r69 and r70 | 9,983 maize genes | yes |
| 4 | The RAP-DB URL in the code is a dead host, masked by a stale mirror | 1,041 missing entries | yes |
| 5 | Curated GO and CHEBI terms had nowhere to land; evidence codes were the literal `"IDK"` | 2,126 `IDK` codes per 4,000 rice genes | yes |
| 6 | DOI-keyed references became broken PubMed links | 250 rice genes | yes |
| 7 | ThaleMine's absent-value sentinels were written into `gene.summary` and `gene.description` | 15,475 + 3,740 Arabidopsis genes | yes |

Two further findings are recorded but **not** fixed: curation reaches only one assembly per species
(§8), and the client's cross-reference registry knows 24 of the collection's 107 xref dbs, so every
curation-bearing xref is invisible in the UI (§9).

---

## What reached users before this review

`genes70` faceted on `capabilities:pubs` — 19,911 genes of 16,127,051, or 0.12%:

| genome | genes with `pubs` |
| --- | --- |
| arabidopsis_thaliana | 7,334 |
| oryza_sativa | 5,714 |
| medicago_truncatula | 4,271 |
| zea_mays | 423 |
| glycine_max | 351 |
| triticum_aestivum_kariega | 232 |
| chlamydomonas_reinhardtii | 174 |
| sorghum_bicolor | 168 |
| triticum_aestivum (reference) | 71 |
| 31 further genomes | ≤ 76 each |

That total overstates curation by about a fifth. Broken down by the `source` tag the UI displays:

| `source` | xref records | genomes |
| --- | --- | --- |
| `geneRIF` | 28,934 | 63 |
| `rap-db` | 7,663 | 1 |
| `CSHL` | 174 | 2 |
| **absent** | **4,271** | **1 — medicago_truncatula** |

Medicago's entire contribution arrives from its Ensembl core, not from any curation source, and so
renders with an empty "Curation source" cell. Genuinely curated: **≈15,640 genes**.

Curated ontology terms were narrower still — `PO` on arabidopsis (19,805) and rice (2,341) only, `TO`
on rice only (3,855).

## Upstream availability versus what we ingested

| source | upstream curated content | we ingested | id burden |
| --- | --- | --- | --- |
| **RAP-DB** | 7,031 curated genes with symbols, names, PO/TO and structured references | 5,990 entries from a stale mirror | none — `Os01g0100100` is already our stable id |
| **TAIR** (via ThaleMine) | 38,194 rows; 13,269 with a real curator summary | symbol + summary + brief description | none — AGI codes are native |
| **MaizeGDB** | 9,983 genes with a curated symbol and full name | **nothing** | none — `Zm00001eb*` is already our stable id |
| **GeneRIF** | 34,796 plant statements over 11,185 genes, **2.05%** of 1,694,784 total, 73% of the plant slice Arabidopsis. No symbols, names or evidence codes | a Feb-2025 snapshot, 11,006 genes in redis db 3 | heaviest — Entrez GeneID only, and `gene2ensembl.gz` has **zero rows** for Arabidopsis and rice |
| **in-house sheet** | 1,221 rows / 1,087 distinct ids, 1,013 rows submitted in 2026 | **158 entries, frozen since 2024-10-10** | 45% of rows need an id crosswalk |

GeneRIF is worth singling out: it is the source with by far the highest mapping cost and the lowest
curated-content density. Refreshing the snapshot would add roughly 155 genes. It was left alone.

---

## 1. The in-house curation feed was frozen for two years

Every gene page's Curated publications tab links a Google Form, "Curate Gene Function", prefilled
with the gene id. It writes to the sheet *Curated Genes (Responses)*, which now holds 1,221 rows —
101 submitted in 2023, 97 in 2024, 10 in 2025 and **1,013 in 2026**.

The build read `https://dev.gramene.org/cshl_curated_genes.json`, whose `Last-Modified` was
**Thu, 10 Oct 2024** and which held **158 entries**. No generator for that file existed anywhere on
squam; its only other copies were three hand-made files in `/home/olson/` dated July–October 2024. So
the site had been soliciting curation and then discarding it, and the host serving the feed
(`brie.cshl.edu`) is not one this build controls.

**Fixed** by `build/fetch_cshl_curation.js` + `build/stages/29_curated_sources.sh`, which read the
sheet over its anonymous CSV export and emit a **tracked in-tree artifact**,
`gramene-mongodb/search/cshl_curated_genes.json`. Staleness is now visible in git rather than in an
HTTP header, and the build no longer depends on live access to another host.

## 2. Forty-five percent of sheet rows used ids the loaders could not match

The adders key on `gene._id`. The sheet uses three sorghum namespaces and, in many rows, transcript
or protein ids rather than gene ids:

| form in the sheet | rows | example |
| --- | --- | --- |
| `SORBI_3*` — the hosted stable id | 662 | `SORBI_3009G030300` |
| `Sobic.*` — Phytozome v2 | 316 | `Sobic.001G341700` |
| `Sb##g*` — v1 | 235 | `Sb01g032830` |
| transcript / protein suffixes, across all of the above | — | `SORBI_3001G320200.1`, `Sobic.001G025700.1.p`, `Sobic.006G175700.v5.1` |

**Fixed** by resolving each id through an ordered candidate list — the id as written, then with
transcript/protein suffixes peeled — against gene `_id`, then `search/sorghum_v5_lut.txt` (the
crosswalk `fix_sorghum_v2.js` already reads forward), then `alt_id`. Result:

| | ids |
| --- | --- |
| distinct ids in the sheet | 1,087 |
| resolved by `_id` | 621 — **99 of them only after stripping a suffix** |
| resolved via `sorghum_v5_lut.txt` | 331 |
| resolved via `alt_id` | 116 |
| **total resolved** | **1,063 (97.8%)** |
| unresolved, and now reported to the curators | 19 |

The 19 are genuinely dead: six retired `SORBI_3*` ids, one unplaced-scaffold `SORBI_3K007000`, ten v1
`Sb##g*` ids absent from the crosswalk, and one malformed `Sobic.004034000`.

So the in-house set goes from **158 genes / 174 references** to **1,063 genes / 1,153 references**.

## 3. MaizeGDB curation was dropped between r69 and r70

r69 had `gramene-mongodb/search/maizeGDB.js`, reading `maizegdb_genes_all.txt` — 36,268 rows over
20,812 maize genes with symbol, full name and a provenance column (MaizeGDB gene model 22,467,
GenBank 5,734, Grassius 3,515, Arabidopsis Ortholog 728, **Classical Genes 425**, UniProt 108, …). In
r70 the same variable, `fixMaizeV4`, was repointed at `fix_maize_v5.js`, which reads a 13,941-row,
three-column file with no provenance.

Maize was not left nameless — 15,747 of its 44,303 genes have a `name` differing from the id. What was
lost is roughly 7,000 symbols and, for a curation review, **any record of which names were curated**.
There is no `MaizeGDB` xref anywhere in the collection (0 records), and the `Grassius` xref on 3,707
maize genes holds a TF *family* name, not a gene symbol.

One claim worth correcting: r69 did **not** publish MaizeGDB's GenBank accessions either. It collected
them into `lut[].ids` and then had an empty `if` block (`maizeGDB.js:96-98`).

**Fixed** by `gramene-mongodb/search/maizegdb.js`, reading MaizeGDB's current
`Zm-B73-REFERENCE-NAM-5.0-GMs-GOTerms.csv.gz`. Its 44,303 distinct `gene_model` ids are **exactly**
this build's 44,303 `zea_mays` genes, so no mapping is involved. Filtering to rows with a curated
`locus_name` gives **9,983 genes** — `gbss2`/"granule-bound starch synthase2", `thk1`/"thick
aleurone1", `mha11`/"membrane H(+)-ATPase11". It writes `name`, `synonyms`, `description` and an
explicit `MaizeGDB` xref.

Two things this deliberately does *not* do. It does not load the file's `obo_terms` GO (30,481 rows):
that column has no evidence codes and no stated provenance, and MaizeGDB publishes its explicitly
computational GO separately, so importing it would file probably-computational annotation under a
curation banner. And it adds **no literature**, so maize's `pubs` count stays at 423.

The adder runs **after** `fix_maize_v5`, not before, because `fix_maize_v5.js:114-118` overwrites
`gene.name` and `gene.description` unconditionally — unlike every curated adder, which is guarded on
`name === _id`. Placed before it, every curated name would be clobbered.

## 4. The RAP-DB URL in the code is a dead host

`rapdb.js:9` carried `https://rapdb.dna.affrc.go.jp/...`, which does not answer at all (curl exit
000). It was dead code regardless: the next line overwrote it with a mirror on dev.gramene.org,
holding **5,990** entries against upstream's **7,031**.

`rapdb.js` also had no fetch guard where `curated.js` had both a 60s `AbortController` and a `.catch`
— so the build's most fragile fetch was the unguarded one. That is not hypothetical: during this work
dev.gramene.org connect-timed-out, which in the old code is an uncaught rejection that kills a 5h30m
decorate run.

**Fixed**: upstream `naro.go.jp` primary, the mirror as an explicit fallback, both behind the shared
guard. The same dead URL and unguarded fetch in `curated/get_curated.js` were fixed the same way.

## 5. Curated ontology content was discarded at ingest

`curated.js` and `rapdb.js` both declared `const ontologies = ['po','to']`, so **GO and CHEBI terms
had nowhere to land** — and GO is 88% of the sheet's ontology column (76 GO, 7 PO, 2 TO, 1 CHEBI).
Both also wrote ontology xrefs as `ids: terms.map(t => [t,"IDK"])`: the evidence code was the literal
string `"IDK"`, which is not a GO evidence code. Every curated PO/TO annotation this build has ever
shipped carried it — 2,126 occurrences in a 4,000-gene rice sample, and visible today on
`Os03g0122600`.

**Fixed**: GO and CHEBI are read; per-term evidence codes come from the feed, falling back to `IEA`.

This fix had a prerequisite that is worth recording, because getting it wrong would have been far
worse than the defect. `ancestor_adder.js:30` does `_.keyBy(obj.xrefs,'db')`, and lodash `keyBy`
keeps only the **last** entry per key — so pushing a second `{db:'GO'}` xref would have made every
Ensembl GO term on that gene invisible. The trap was latent: no gene has a duplicated `GO`/`PO`/`TO`
xref today, because the genomes receiving curated PO/TO have no Ensembl PO/TO to collide with (rice's
2,341 `PO` xrefs are all from RAP-DB). It fires the moment GO arrives, and **22,669 rice, 24,176
sorghum and 27,548 maize genes already carry a GO xref**. The adders now merge into the existing xref,
and a term both sides claim keeps the Ensembl evidence code.

Codes outside the GO evidence set are reported, not rewritten: the sheet's `IPP` (14 rows) is almost
certainly `IPI`, but guessing on a curator's behalf is worse than telling them. Four unparseable
ontology terms are likewise reported (`OMIT:0023522`, a bare `identifiers.org` URL, and two
free-text entries).

## 6. DOI-keyed references became broken PubMed links

RAP-DB keys 246 of its references by DOI and a handful by free-text citation. The old test was
`_.isNumber(+pmid)` — which is **true for `NaN`** — so every DOI passed as a PubMed id. **250 rice
genes in the live collection** carry one, and the Curated publications tab renders each as a link to
`/pubmed/DOI:10.1016/...`, which resolves to nothing.

**Fixed**: references are routed by form — numeric to `PUBMED`, `DOI:` to a `DOI` xref, and the seven
with neither counted and skipped rather than fabricated into an identifier. Fixing this exposed a
second defect: `mongo2solr.join.js` assigned rather than appended `<db>__xrefs`, so a gene with two
DOI references would lose one. PUBMED had been special-cased for exactly that reason; the generic
branch now accumulates.

## 7. ThaleMine's absent-value sentinels were written into the gene doc

ThaleMine uses **two** sentinels for an absent value, and `thalemine.js:43-45` screened one of them
for one field:

| field | sentinel | screened before? | live arabidopsis docs carrying it |
| --- | --- | --- | --- |
| `summary` | the four-character `NULL` | no — the guard tested `!= '""'` | **15,475** |
| `description` | the two-character `""` | no — only tested truthiness, and `""` is truthy | **3,740** |

19,850 of ThaleMine's 38,194 rows have a sentinel curator summary and 4,279 a sentinel brief
description. Both strings reach the index and the API. The client screens `summary !== "NULL"`
(`GeneList.js:32`) so nothing displayed wrong there, but nothing screened `description`.

**Fixed** with one `usable()` predicate covering both sentinels, applied to summary, description and
symbol alike. The measured effect, and the two numbers are different in character:

* `summary`: **28,279 docs → ≈13,269**, all real. A *decrease*, and it is the defect being removed —
  15,475 of the originals were the string `NULL`. The count of genuinely curated summaries does not
  move: 12,804 before, 12,804 after.
* `description`: **real descriptions 29,093 → 32,143, a gain of 3,050**, with 3,740 `""` placeholders
  removed. Not screening the sentinel had caused it to *overwrite* a gene's real Ensembl description;
  screening it lets 3,050 genes fall back to the real one, and leaves only 690 with no description at
  all because there was none to fall back to.

The raw field count for `description` falls from 32,833 to 32,143, which looks like a loss of 690 and
is in fact a gain of 3,050 real values. Worth stating explicitly, because a gate counting merely
truthy values reports the opposite of the truth here — `curated_dryrun.js` counts usable values for
exactly this reason.

---

## What the fixes measure out to

From `build/curated_dryrun.js`, which runs decorate's full species-adder block over the stage-40
dumps and compares against the live collection. Nothing was written to produce these.

| | sorghum | maize | rice | arabidopsis |
| --- | --- | --- | --- | --- |
| genes in the genome | 35,567 | 44,303 | 38,993 | 32,833 |
| genes with a real name | 1,933 → **2,517** | 15,747 → **17,333** | 14,323 → **14,620** | 11,148 → 11,149 |
| genes with synonyms | 2,821 → 2,826 | 4,225 → **10,071** | 6,789 → **7,325** | 21,859 → = |
| curated literature records | 171 → **1,148** (CSHL) | 647 → = (geneRIF only) | 7,663 → **8,517** (rap-db) | 3 → 5 (CSHL) |
| references rerouted to `DOI` | — | — | 0 → **244** | — |
| `MaizeGDB` xref | — | 0 → **9,983** | — | — |
| curated `PO` / `TO` | 0 → 4 / 0 → 2 | — | 2,341 → **2,733** / 3,855 → **4,401** | 19,805 → = / — |
| `IDK` evidence codes | 0 | 0 | **27,422 → 0** | 0 |
| genes with a duplicated annotation-bearing xref db | **0** | **0** | **0** | **0** |

Four things in that table are load-bearing as *non*-changes, and each is a gate:

* **`geneRIF` records do not move anywhere** (sorghum 15, maize 647, rice 886, arabidopsis 24,771).
  Nothing in this work touches redis db 3, so any change there would be an accidental regression.
* **`GO` xref counts do not move** — sorghum 24,176 (+1 from the curation sheet), maize 27,548, rice
  22,669, arabidopsis 28,174. This is the proof that the merge fix of §5 works: the adders now add
  curated terms into the gene's existing GO xref instead of pushing a second one, so no Ensembl term
  is displaced. Maize staying at exactly 27,548 also confirms MaizeGDB's unattributed `obo_terms` GO
  was deliberately not imported.
* **No gene anywhere ends up with two xrefs for one annotation-bearing db**, which is the `keyBy`
  trap asserted directly rather than reasoned about.
* **Arabidopsis's curated summary count does not move**: 12,804 before, 12,804 after. Only the 15,475
  `NULL` sentinels disappear.

Arabidopsis descriptions deserve their own line because the raw count is misleading: the field count
falls 32,833 → 32,143, while **real** descriptions rise 29,093 → **32,143**, a gain of 3,050, because
3,740 `""` placeholders stop overwriting genuine Ensembl descriptions. See §7.

Projected effect on the served index once `make refresh-curated` runs: `capabilities:pubs` rises from
19,911 toward roughly 21,000, with sorghum going 168 → ~900 and rice ~5,714 → ~6,300. Maize stays at
423, because MaizeGDB supplies names rather than literature.

---

## 8. Recorded, not fixed: curation is stranded on reference genomes

Gramene hosts 267 genomes, but curation reaches one assembly per species. RAP-DB reaches **1 of 17**
*O. sativa* genomes; TAIR the single Arabidopsis; `QTL_TO` only rice japonica and sorghum. The 16
other rice, 18 other wheat and **76 other barley** assemblies get only whichever per-assembly GeneRIF
ids happened to map — which is why `triticum_aestivum_kariega` (232 genes) outscores the wheat
reference (71).

This is the same shape as the pathway-hierarchy defect fixed in `get_pathways.js`: a per-species
annotation filed under one genome's key while sibling genomes of the same species have no key to look
up. The hooks for a fan-out exist in the gene doc (`alt_id`, and
`homology.homologous_genes.syntenic_ortholog_one2one`).

It is **not** mechanical, which is why it was not done: an ortholog is not the same claim as a curated
gene, and projecting a curator's statement onto another assembly asserts something the curator did
not. That is a scientific decision, not a build decision.

## 9. Recorded, not fixed: the client xref registry is the narrowest point in the chain

`Xrefs.js:92` filters on `dbxrefs.isKnown(xr.db)`, a plain `hasOwnProperty` against a static 24-entry
table in the `gramene-dbxrefs` package. The collection holds **107 distinct `xrefs.db` values**, so 83
never render — and the missing ones include **every curation-bearing xref**: `TAIR_SYMBOL` (9,793
genes), `Oryzabase` (8,051), `RAP-DB` (1,175), `Grassius` (8,796), `external_wheat_gene_names` (257).
They are in the API and invisible in the UI.

The new `MaizeGDB` and `DOI` xrefs are in the same position. `gramene-dbxrefs` is a separate
repository, present on squam only as an installed dependency, so extending it is a client-side change
outside this build.

## Other items recorded for the next release

* **Barley GeneRIF mapping shortfall** — 352 upstream barley GeneRIFs, 17 `HORVU` keys in redis db 3.
* **Wheat GeneRIF ids land on pangenome assemblies** rather than the reference.
* **`xrefs[].source` and `.text`** — the two fields the UI actually renders — are undocumented in the
  swagger `GeneDocument` schema and absent from the gramene-ebeye export.
* **Stage 30's `curated.json`** computes a 22,863-locus curation roster, uses it only to bias genetree
  representative-member choice, and discards it. It does not know about the in-house set or MaizeGDB.
  Teaching it would cascade `30 → 35 → 50 → …`, so it is deferred.
* **`fix_maize_v5.js:120-122`** blanks `description` for every `taxon_id == 4577` gene it does not
  know. The MaizeGDB adder masks this for ~10,000 genes; the unconditional blanking is still wrong.
* **The data-hygiene list**: rice `synonyms` carry quote-split artifacts (`"sd1 (d47`, `sd1-1)"`);
  `PUBMED.ids` are strings from `rap-db` and integers from `geneRIF`; Arabidopsis `PO` xref pairs
  carry an empty evidence code on 473,528 terms; `maps.is_anchor` is `false` on all 267 genomes.

---

## Reproducing these

```bash
# user-visible footprint, and the per-genome breakdown
curl -s 'http://localhost:8983/solr/genes70/select?q=*:*&rows=0&facet=true&facet.field=capabilities&facet.limit=40'
curl -s 'http://localhost:8983/solr/genes70/select?q=capabilities:pubs&rows=0&facet=true&facet.field=system_name&facet.mincount=1'

# literature by curation source (the `source` tag the UI shows)
mongo search70 --eval 'db.genes.aggregate([{$match:{"xrefs.db":"PUBMED"}},{$unwind:"$xrefs"},
  {$match:{"xrefs.db":"PUBMED"}},{$group:{_id:"$xrefs.source",n:{$sum:1}}}],{allowDiskUse:true})'

# the frozen feed
curl -sI https://dev.gramene.org/cshl_curated_genes.json | grep -i last-modified

# plant share of GeneRIF, from the local snapshot
cd ~olson/src/ajo2995/genetrees/database
awk -F'\t' 'NR==FNR{p[$1]=1;next} FNR>1 && ($1 in p){n++; g[$2]=1} END{print n, length(g)}' taxa generifs_basic

# MaizeGDB gene set versus ours
curl -s https://download.maizegdb.org/Zm-B73-REFERENCE-NAM-5.0/Zm-B73-REFERENCE-NAM-5.0-GMs-GOTerms.csv.gz \
  | zcat | tail -n +2 | cut -d, -f1 | tr -d '"' | sort -u | wc -l
mongo search70 --quiet --eval 'db.genes.count({system_name:"zea_mays"})'

# ThaleMine's NULL sentinel, and the live docs carrying it
curl -s 'http://localhost:8983/solr/genes70/select?q=summary:%22NULL%22&rows=0'

# the whole set of fixes, before committing to a rebuild
cd /usr/local/gramene/release70/build && node curated_dryrun.js
```
