# Upstream data defects found building release 70

Reported **2026-10-13**. Source: Ensembl Plants release 70 cores and
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

Defects 1 and 2 are visible in the **published release 69** data as well.

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

---

Defects 1, 2 and 4 have been worked around in our own copies of the cores and compara; nothing
upstream has been modified. The id mapping tables we generated for defect 1 (75,711 gene, transcript
and translation mappings) can be supplied for a re-import.
