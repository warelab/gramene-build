# Upstream data defects found building release 70

Reported **2026-10-13**; defect 7 added **2026-10-30**, and remediated locally **2026-10-31**
(see [Resolution](#resolution-the-e114-cores-were-the-local-source)) --- the defect remains
open upstream. Source: Ensembl Plants release 70 cores and
`ensembl_compara_plants_70_116`. Every figure below was taken from the release databases, and the
queries in [Reproducing these](#reproducing-these) return the numbers quoted.

Shareable version: <https://claude.ai/artifact/ECp1Ds2PbmJaYsPrdQdU4q>

| # | Defect | Genomes | Scale | For |
| --- | --- | --- | --- | --- |
| 1 | GFF3 `ID=` imported as the stable id instead of `locus_tag` / `Name` | medicago, lablab | 75,711 genes | Ensembl Plants |
| 2 | `triticum_aestivum_alchemy` labelled with the reference's `TraesCS` namespace | wheat (2) | 868,839 features | Ensembl Plants |
| 3 | Two genomes in the gene trees with no homology rows at all | medicago, lablab | 69,421 genes | Compara |
| 4 | `GCA_030347555.1` labelled cv. Natoba; INSDC says Highworth | lablab | 1 genome | Ensembl Plants |
| 5 | 198 duplicate gene models sharing coordinates and exon structure | lablab | 396 loci | ILRI / LegumeInfo |
| 6 | Maize v5 genes get empty pathways: reactions file carries only v4 | maize | 1,587 genes | Plant Reactome |
| 7 | `gene.description` empty in the e116 cores where e114 had it | 225 of 267 | **2,323,799 genes** --- since rescued locally from e114 | Ensembl Plants |

Defects 1 and 2 are visible in the **published release 69** data as well. Defect 7 is new in this
release and is, by scale, the largest of the seven: it removes a gene description from roughly one
plant gene in seven across the whole site.

---

## 1. The GFF3 `ID=` attribute is being used as the stable id

In `medicago_truncatula_core_70_116_3` all 50,739 genes are named `gene0`…`geneNNNNN`, and
transcripts `rna0`…. In `lablab_purpureus_gca030347555v1cm_core_70_116_1`, 24,972 of 25,505 are the
same. `ID=gene0` / `ID=rna0` is the NCBI GFF3 idiom for a file-local handle and was never intended
as a stable identifier; the citable identifier sits in another attribute that was not used.

**The identifier that was available.** Medicago's INSDC record `CM010651.1` carries
`/locus_tag="MtrunA17_Chr4g0000001"` — the `MtrunA17_Chr<N>g<7 digits>` scheme of MtrunA17r5.0-ANR,
published by the Toulouse portal. For lablab the native id is the community GFF3's
`Name=Labpu01g000050`.

**Why this is the importer and not the submitted data.**

* Medicago *translations* kept their GenBank `/protein_id`: all 44,450 are accessions of the form
  `RHN38382.1`. The protein id survived the import; the gene id did not.
* In lablab the split is exactly by feature class. The 533 tRNA genes, which came from a separate
  GFF3 whose `ID=` *was* the native id, kept `Labpu_tRNA000010`. All 24,971 protein-coding genes,
  whose native id was in `Name=`, became `geneNNNN`.

**Consequence.** The two genomes share **24,925** identical gene ids (`gene1`, `gene10`,
`gene100`…). Any resource keying gene records on the stable id can hold only one of each pair. The
ids are also not citable and resolve nowhere.

**Also in the public release.** Ensembl Plants REST returns the same ids — `gene1` for lablab,
`gene20129` for medicago — so this is not specific to our import.

**Suggested fix.** Re-import both genomes taking the gene stable id from `locus_tag` (medicago) and
`Name` (lablab). Worth auditing which other genomes were loaded from NCBI-style GFF3: the same rule
would produce the same result wherever it applied, and would only be *visible* where two such
genomes collide.

## 2. The Alchemy wheat core carries the reference's stable-id namespace

`triticum_aestivum_alchemy_core_69_114_1` names its genes `TraesALC*`.
`triticum_aestivum_alchemy_core_70_116_1` names the same annotation `TraesCS*` — the namespace
belonging to reference wheat (IWGSC).

| | core_69_114_1 | core_70_116_1 |
| --- | --- | --- |
| genes | 106,786 | 106,786 |
| gene prefix | `TraesALC*` | `TraesCS*` |
| assembly | GCA951799155v1 | GCA951799155v1 |
| accession | GCA_951799155.1 | GCA_951799155.1 |
| genebuild | 2024-08 | 2024-08 |

Joining the two cores on the prefix swap matches **106,786 of 106,786** genes with identical
`seq_region`, start, end and strand. Transcripts, translations and exons carry the same change
(131,360 / 112,053 / 518,640 features).

**Compara independently confirms `TraesCS` belongs to the reference.** In both
`ensembl_compara_plants_69_114` and `_70_116`: 0 `genome_db` rows matching `%alchemy%`, 0
`gene_member` rows `TraesALC*`, and all 107,545 `TraesCS*` rows belong to `genome_db_id` 2102
(`triticum_aestivum`, IWGSC). Alchemy is absent from compara entirely, so no tree or homology record
disagrees with renaming it back.

**Consequence.** 103,039 gene ids collide with reference wheat.

**Already published.** This shipped in Gramene release 69, built while the core still had
`TraesCS*`. In `search69` the cultivar owns the colliding ids and reference wheat retains **17,705
of its 120,744 genes** — 85% of a flagship genome absent from the released data. An audit of all 233
genomes in that release found wheat to be the only one more than 1% short, so the defect is isolated
but severe.

**Suggested fix.** Restore `TraesALC*` in the release 70 core across `gene`, `transcript`,
`translation` and `exon`. Since the r69 core is already correct, this looks like a regression in the
core-build step rather than a change in the submitted annotation.

## 3. Two genomes are in the gene trees but have no homologies

In `ensembl_compara_plants_70_116`, `medicago_truncatula` (genome_db 2282) and
`lablab_purpureus_gca030347555v1cm` (genome_db 2308) are both members of the `default` protein-trees
species set and have full `gene_member` coverage. Neither appears in `homology_member` at all.

| genome | gene_member | in homology_member |
| --- | --- | --- |
| medicago_truncatula | 44,450 | 0 |
| lablab_purpureus_gca030347555v1cm | 24,971 | 0 |
| hordeum_vulgare_akashinriki *(for contrast)* | 51,076 | 50,205 |

A clean zero across both genomes, against 98% participation for a comparable genome, reads as a
pipeline gap rather than biology — as though the orthologue/paralogue step did not run for them.

**Consequence.** Both genomes present gene trees with no homology relationships attached, so no
orthologues or paralogues can be shown or exported for 69,421 genes.

These are the same two genomes as defect 1. We have not established whether the two are related.

## 4. Cultivar label on `GCA_030347555.1`

The Ensembl Plants page titles this assembly *Lablab purpureus Natoba*. The INSDC record for its
chromosomes (`CM059256.1`) reads:

```
DEFINITION  Lablab purpureus cultivar Highworth chromosome 3, whole genome
            Assembly Name :: ILRI_Lpur
            Assembly Method :: Flye v. 2.7.1
```

LegumeInfo hosts the same assembly as `Highworth.gnm1`, also Flye v2.7.1. The label appears simply to
be wrong, and it cost us time establishing that the LegumeInfo annotation and the Ensembl assembly
were the same thing.

---

## 7. `gene.description` is empty in the e116 cores

The `gene.description` column is populated in the release-69 (e114) cores and empty in the
release-70 (e116) cores, for almost every species. Across all 267 `*_core_70_116_*` cores only
**114,089 of 16,127,051** genes carry a description — 0.71%. Of the 225 species that have a core in
both releases:

| | e114 | e116 |
| --- | --- | --- |
| genes with a non-empty `description` | 2,374,970 | **51,171** |
| net loss | | **2,323,799 genes** |
| cores losing >90 percentage points of coverage | | 53 |
| cores losing 50–90 points | | 8 |
| cores losing 10–50 points | | 23 |
| cores within 10 points of e114 | | 141 |

Exactly **one** e116 core is above 50% description coverage — `arabidopsis_thaliana`, at 96.8%
(31,770 / 32,833). The next highest is `medicago_truncatula` at 8.9%, and that is only because we
loaded those descriptions ourselves from LeGOO. The 42 cores new in release 70 carry descriptions on
62,918 of 4,551,499 genes (1.4%), so this is not confined to carried-over species.

**This is not a re-annotation side effect.** The gene sets are byte-for-byte the same size:

| species | genes e114 | genes e116 | described e114 | described e116 |
| --- | --- | --- | --- | --- |
| brassica_napus | 104,573 | 104,573 | 66,227 | **104** |
| triticum_turgidum | 66,559 | 66,559 | 62,801 | **0** |
| eragrostis_curvula | 56,849 | 56,849 | 56,809 | **0** |
| glycine_max | 57,147 | 57,147 | 57,012 | 1,528 |
| rosa_chinensis | 50,517 | 50,517 | 47,018 | 52 |
| zea_mays | 44,303 | 44,303 | 39,980 | 234 |
| sorghum_bicolor | 35,567 | 35,567 | 35,264 | 216 |
| arabidopsis_thaliana | 32,833 | 32,833 | 31,771 | 31,770 |

Same number of current genes in every pair, with the description column emptied. Whatever populates
that column during the core build did not run, or ran against nothing, for all but one species.

The loss reaches users unchanged, because the pipeline is faithful to the core. `dump_genes.js:164`
selects `g.description` directly, and the stage-40 dumps agree with the cores exactly:

| | core | our dump |
| --- | --- | --- |
| brassica_napus | 104 | 104 |
| glycine_max | 1,528 | 1,528 |
| rosa_chinensis | 52 | 52 |
| glycine_soja | 114 | 114 |

A `brassica_napus` gene that read `"BnaCnng61390D protein [Source:UniProtKB/TrEMBL;Acc:A0A078JNA5]"`
in release 69 now has `description: null`.

What partly masks it is our own annotation layer: the release serves 139,793 gene descriptions
against the cores' 114,089, and the extra **25,704** come from file-based adders — `fix_sorghum_v2`
deflines (15,504), MaizeGDB and `fix_maize_v5` (9,827) and ThaleMine (373). That backfill exists for
four genomes only. For the other 263 there is nothing to fall back on, which is why 53 cores lost
more than 90 points of coverage.

### Resolution: the e114 cores were the local source

**The assessment first recorded here --- that there was no local source for these descriptions and
the column had to be repopulated upstream --- was wrong.** The release-69 (e114) cores are still on
disk, they carry the 2,374,970 descriptions intact, and for 190 of the 225 paired species the gene
stable ids are unchanged between the two releases. That makes the rescue a join, not a re-derivation.

`build/rescue_descriptions.py` generates the SQL for it. The join requires **both** the same
`stable_id` and the same `species.production_name`, the latter read from each core's `meta` table
rather than inferred from the database name, and it only ever fills a description that is currently
empty:

```sql
UPDATE `brassica_napus_core_70_116_1`.gene n
  JOIN `brassica_napus_core_69_114_1`.gene o ON o.stable_id = n.stable_id
   SET n.description = o.description
 WHERE n.is_current = 1 AND o.is_current = 1
   AND (n.description IS NULL OR n.description = '')
   AND o.description IS NOT NULL AND o.description <> '';
```

Never overwriting means any description e116 did ship wins, so the operation cannot lose upstream
content. Two species present in two e114 cores apiece were skipped rather than guessed at. Because
the core tables are MyISAM and give no transaction to roll back, the script emits a per-core
`rescue_desc_bak` backup table and a matching revert script in the same pass, and refuses to run
where a backup table already exists.

Applied on 2026-10-31 across 190 species / 2,295,784 genes, then rebuilt through stages
40 -> 50 -> 60 -> 65:

| | before | after |
| --- | --- | --- |
| described genes, e116 cores (paired species) | 51,171 | **2,346,955** |
| usable descriptions in `search70.genes` | 139,793 | **2,407,548** |
| genomes below 10% coverage that had >90% in r69 | 53 | **0** --- min 91.2%, median 99.8% |
| genes still rescuable after the run | 2,295,784 | **0** |

The release-wide ledger balances to the gene against release 69:

```
search69 total                     2427124
- retired genomes (8)                -73992
+ new genomes (42)                    62918
+ gains on shared genomes             20376
- losses on shared genomes           -28878
= search70 total                    2407548
```

`medicago_truncatula` is the single genome in the release still below its r69 description count
(33,379 -> 4,501 of 50,739), and it is the one species a stable-id join cannot reach --- because of
defect 1 at the top of this document. Release 69 shipped medicago keyed on the GFF3 `ID=` values
(`gene36912`, `gene10054`); release 70 carries the corrected locus names
(`MtrunA17_Chr6g0478551`). Both releases hold exactly 50,739 medicago genes and **zero ids in
common**, so the join has nothing to match on. That is the cost of having fixed defect 1 rather than
a second upstream fault, and it is the right trade: the ids are now correct.

A coordinate join gated on an identical `assembly.accession` would recover roughly 28,878 of them,
and is deliberately not done here --- matching a description to a gene by position is a weaker claim
than matching it by stable id, and nothing in the result would show a reader which kind of match
produced it.

**None of this reduces what is needed upstream.** The rescue works only for species that existed in
release 69 and kept their ids; the 42 genomes new in release 70 have no e114 core to join against and
still carry descriptions on just 1.4% of their genes. Each future release would need this same rescue
run against the one before it, with the recoverable set shrinking as ids turn over. The column still
needs to be repopulated at the source.

---

## Items for other maintainers

### 5. 198 duplicate gene models in the lablab annotation — ILRI / LegumeInfo

In the lablab gene-model GFF3, 199 mRNA coordinate sets are each shared by more than one gene locus,
and 198 of those pairs have byte-identical exon structures. They appear to be the same model recorded
twice under two ids:

```
Labpu07g018080.1   chr07  28,717,942-28,753,423  -  9 exons
Labpu07g018090.1   chr07  28,717,942-28,753,423  -  9 exons
                   identical exon boundaries throughout
```

Any consumer matching genes by position has to choose arbitrarily between the two ids.

### 6. Maize v5 genes receive empty pathway annotation — Plant Reactome

Plant Reactome files maize twice: *Zea mays* (taxId 4577, prefix `ZMA`, v4 `Zm00001d` ids) and
*Zea mays ver5* (taxId 381124, prefix `ZMY`, v5 `Zm00001eb` ids). The two published inputs under
`/download/current` disagree:

| file | maize content |
| --- | --- |
| `gene_ids_by_pathway_and_species.tab` | v5 ids (`Zm00001eb*`), prefix ZMY |
| `Ensembl2PlantReactomeReactions.txt` | v4 ids only (`Zm00001d*`), prefix ZMA |

A consumer that builds one record per gene from the `.tab` and fills reactions from the reactions
file therefore produces 1,587 v5 maize genes with no pathway data. A supplementary file containing
the ZMY reactions exists but is not published — its download URL redirects to the Plant Reactome home
page — so each consumer has to carry a private copy. Publishing the ZMY reactions alongside the
others would fix this for everyone.

---

## Reproducing these

All read-only against the public release databases.

**Defect 1** — generic ids, and the locus_tag that was available:

```sql
SELECT COUNT(*), SUM(stable_id REGEXP '^gene[0-9]+$')
  FROM medicago_truncatula_core_70_116_3.gene;        -- 50739, 50739
```
```bash
efetch -db nuccore -id CM010651.1 -format gbwithparts | grep locus_tag | head
```

**Defect 2** — the two alchemy cores are one annotation:

```sql
SELECT COUNT(*) FROM triticum_aestivum_alchemy_core_69_114_1.gene o
  JOIN triticum_aestivum_alchemy_core_70_116_1.gene n
    ON n.stable_id = REPLACE(o.stable_id,'TraesALC','TraesCS')
  JOIN triticum_aestivum_alchemy_core_69_114_1.seq_region osr ON osr.seq_region_id=o.seq_region_id
  JOIN triticum_aestivum_alchemy_core_70_116_1.seq_region nsr ON nsr.seq_region_id=n.seq_region_id
 WHERE osr.name=nsr.name
   AND o.seq_region_start=n.seq_region_start
   AND o.seq_region_end=n.seq_region_end;              -- 106786 of 106786
```

**Defect 3** — tree membership without homology membership:

```sql
SELECT gm.genome_db_id, COUNT(*) AS members,
       SUM(gm.gene_member_id IN (SELECT gene_member_id FROM homology_member)) AS in_homology
  FROM gene_member gm
 WHERE gm.genome_db_id IN (2282, 2308)
 GROUP BY gm.genome_db_id;                             -- 44450/0 and 24971/0
```

On a release-sized `homology_member` this is far cheaper run as two sorted extracts joined outside
the database than as the correlated subquery above.

**Defect 7** — same gene set, emptied description column:

```sql
SELECT 'e116' AS rel, COUNT(*) AS genes,
       SUM(description IS NOT NULL AND description<>'') AS described
  FROM brassica_napus_core_70_116_1.gene WHERE is_current=1
UNION ALL
SELECT 'e114', COUNT(*), SUM(description IS NOT NULL AND description<>'')
  FROM brassica_napus_core_69_114_1.gene WHERE is_current=1;
-- e116  104573  104
-- e114  104573  66227
```

Release-wide, loop that over `SHOW DATABASES LIKE '%\_core\_70\_116\_%'` pairing each core with its
`_core_69_114_` counterpart; the totals above come from that sweep over all 267 cores. The
user-visible figure is the same question asked of the search collections:

```javascript
// 2,427,140 in search69 -> 139,793 in search70
db.genes.aggregate([{$group: {_id: null, described: {$sum:
  {$cond: [{$let: {vars: {v: {$ifNull: ['$description', null]}},
    in: {$and: [{$ne: ['$$v', null]}, {$ne: ['$$v', '']},
                {$ne: ['$$v', 'NULL']}, {$ne: ['$$v', '\"\"']}]}}}, 1, 0]}}}}])
```

`$ifNull` before the comparison is not optional: `{$ne: ['$description', null]}` is **true** for a
document with no `description` field at all, because a missing path yields `undefined` and BSON sorts
`undefined` and `null` as distinct types. Comparing the raw path counts every doc that lacks the
field as having one.

---

Defects 1, 2 and 4 have been worked around in our own copies of the cores and compara; nothing
upstream has been modified. The id mapping tables we generated for defect 1 (75,711 gene, transcript
and translation mappings) can be supplied for a re-import.

Defect 7 has since been worked around too, by joining the e116 cores back to the e114 ones on
stable id --- 2,295,784 genes recovered, detailed under [Resolution](#resolution-the-e114-cores-were-the-local-source)
above. That fix does not generalise: it reaches only species that were in release 69 and kept their
ids, leaving the 42 new genomes at 1.4% coverage and medicago at 4,501 of 50,739, and it has to be
re-run against each previous release for as long as the column keeps arriving empty. The column
still needs to be repopulated at the source.
