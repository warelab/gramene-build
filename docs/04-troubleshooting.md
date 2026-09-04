# Troubleshooting

Failure modes that have actually happened, organised by symptom. Most of the guards in the build
exist because of something on this page.

The recurring lesson: **this pipeline's failures are usually silent.** Counts stay plausible,
processes stay alive, exit codes stay zero, and the index is wrong. Almost every guard here checks
something that a naive "did it finish?" test would have passed.

---

## Decorate stalls

**Symptom.** `50_genes_decorate` stops producing output at a specific gene number. The process is
alive, CPU is idle, nothing is logged, and it never returns.

**This happened four times at exactly gene 1,764,371.** Three wrong theories were pursued first
(heap exhaustion, an unbounded `xrefsToProcess` array, LMDB memory behaviour). All wrong.

**Actual cause:** the gene dumps embed `taxon_id`, and the synthetic per-genome taxon ids are
*reassigned* whenever the genome set changes. 78 of the 128 dumps were left over from an earlier run
with different taxon ids. Decorate looked up a taxon that no longer existed in `maps` and wedged.

The dump stage's resume logic compared **line counts** — which were identical — so it saw nothing
wrong and skipped re-dumping.

**Fix, now enforced by `40_genes_dump`:** dumps older than `.state/10_maps.done` are re-dumped, and
every dump's `taxon_id` must equal `maps.taxon_id` for that genome.

**If it stalls anyway:** compare the last gene written to Mongo against the next gene in the dump.

```bash
mongosh --quiet sorghum11 --eval 'db.genes.find().sort({$natural:-1}).limit(1).toArray()'
# then find that gene's neighbour in ../gramene-mongodb/search/tmp/<genome>.json.gz
```

A second, structural reason decorate can hang: most adders are `promise.then(… done())` with **no
rejection handler**, so a thrown error leaves `done()` uncalled and the pipeline deadlocks with no
output at all. Per-stage counters and a watchdog now name the adder that swallowed a gene and exit
rather than hanging. If you add an adder, give it a rejection handler.

---

## The config symlink

**Symptom.** A stage dies with something like `Cannot read property 'mongoCollection' of undefined`,
usually deep inside a later stage, for a collection you know exists.

**Cause.** `gramene-mongodb-config` is a local path dependency (`file:../gramene-mongodb-config`).
**npm copies it instead of symlinking**, so edits to `collections.js` — including newly added
collections — are invisible to the ETL. A clean build failed at `45_homologs` this way:
`collections.homologs` was `undefined` because npm had installed a stale copy.

**Fix.** `05_install` forces the symlink back after npm runs, and `00_preflight` asserts that all 16
collections resolve. If you ever run `npm install` by hand in one of the consumer repos, re-run
`make 05_install` afterwards.

Related, and worse: the consumer repos used to depend on the config through *GitHub branch pins*
(`#sorghum_v10_fable`, `#sorghum_v7`). Those resolved to the **oryza7 / sorghum7** configs, which
would have silently built sorghum data into the wrong database. Never reintroduce a branch pin here.

---

## Stale intermediates being reused

Three variants of the same bug, each now guarded:

**Attribute JSON.** `60_solr_genes` reused an existing `solr_genes.attribs.json` even when an input
attribute table was newer. Mongo held correct poplar expression values while Solr served
`no_baseline`. Now: any attribute table newer than the merged JSON forces a re-merge.

**Suggestions.** `65_solr_suggestions` once produced ~170,000 suggestions for genes that no longer
existed, from a well-formed but stale `genes.json`. Now: inputs older than `.state/60_solr_genes.done`
are regenerated, and the primary-id count must equal the genes core.

**Dumps.** See [decorate stalls](#decorate-stalls) above.

If you hit a fourth variant, the pattern to apply is the same: compare the intermediate's mtime
against the stamp of the stage that produces its inputs, and regenerate rather than trusting a
count.

---

## Wrong or duplicate source databases

**Symptom.** Gene counts inflated by a plausible-looking amount; extra genomes in `maps`.

**Cause.** Several genomes have more than one core database for the same release — e.g.
`…_core_11_108_1` *and* `…_core_11_108_2`. A `LIKE '%_core_11_108_%'` selection matched both,
producing 3 phantom genomes and **169,944 spurious genes**.

**Rule for choosing between duplicates:** default to the core that was actually used in the compara
run. Verify by cross-checking gene stable ids against compara's `gene_member` table — do not assume
the higher-numbered database is the right one. It often isn't.

`00_preflight` asserts the expected counts (`EXPECT_CORES=128`, `EXPECT_ANCHORS=9`,
`EXPECT_VARIATIONS=2`) so a selection mistake fails immediately rather than at ingest time.

---

## Gene trees look wrong

**Synthetic ids.** Trees whose compara `stable_id` is NULL get `SB<version>GT_<root_id>`, derived
from `collections.getVersion()`. This was previously hardcoded and labelled v11 trees with the
release-10 prefix. Override with `GT_PREFIX` if a release needs another scheme.

**Family roots.** Resolving a tree's root taxon by *stripping digits* off a synthetic taxon id is
wrong — `45580072` becomes `4558007`, which is a different genome ("chinese amber"). Walk the taxon
parent chain instead. This was caught before shipping; if you see a tree rooted at a suspiciously
specific accession, suspect this class of bug.

**Representatives.** Selection is scored, with anchor genomes pinned and non-anchor genomes taking a
+25 penalty. Changing that scoring requires re-running `make 35_genetrees` — the choices are stored,
not computed at read time.

---

## MAKER attribute tables

Two properties of the pan-gene GFF inputs, both of which produced wrong output on the first run:

**Transcript ids are not unique across genomes.** These are pan-gene sets, so
`3381.casb001g000110.635.1` occurs in five of the nine v11 accessions. `munge_MAKER.pl` keys on the
transcript id, so one shared `geneID.canonical.txt` collapsed 391,601 canonical transcripts into
114,114 gene ids and attributed one genome's scores to another's genes. **Munge each genome
separately.** Do not "optimise" by concatenating the score files first.

**Gene ids join the stable-id map only partially**, because the GFF and the stable-id assignment do
not always pick the same source annotation as a gene's representative id (for `sorghum_pi655993`,
14,387 of 46,077 join by id). The files *are* correctly paired — every id that joins has identical
coordinates. The extractor joins by id first, then falls back to `(chr,start,end)`.

Scripts and full notes: `../gramene-solr/maker_pipeline/README.md`.

---

## Shell and process hazards

**`pkill -f 'make all'` kills your own shell.** The pattern matches the cmdline of the interactive
shell you typed it in. Use `pgrep -af` to find the PID, then `kill <pid>`.

**`pm2 restart all` starts deliberately-stopped services** and causes `EADDRINUSE` collisions across
releases. Restart by name. See [docs/03-operations.md](03-operations.md#-never-run-pm2-restart-all).

**Long-running commands need explicit timeouts.** Several build steps will happily hang forever on a
network stall; `search/curated.js` needed a 60s abort added because a fetch in the decorate hot path
had no timeout and could wedge the entire stage.

---

## Incremental updates: two traps

`make add-studies` adds Atlas studies without a full rebuild. Two things about it are easy to get
wrong, and both were hit while building it.

**`batch.py` resumes by appending.** It counts the lines already in `<short>_attributes.jsonl` and
appends from there (`batch.py:49,53`), so if a complete file from an earlier run is still on disk it
writes *nothing* — and stage 58 then reports success and imports stale attributes. Clearing the
caches (`ref_<taxon>.json`, `inv_<taxon>.json`, `<taxon>.assays_cache.json`) is **not** enough; the
outputs must go too. The stage's own completeness check cannot catch this, because it compares line
counts and the line count is unchanged — the gene set is the same, only the values would differ.
This is the same shape as the stale gene dumps in `40_genes_dump`: well-formed, right size, wrong
vintage. There is now an invariant asserting each rebuilt JSONL's mtime post-dates the run.

**Scoping `62_attr_atomic` to one genome requires scoping the remove pass too.** It looks like an
obvious optimisation — the table is regenerated in full even when one genome changed. But
`solr_atomic_attr.js` computes removals as `capabilities:"<token>"` over the **entire core**, then
strips the capability from anything not in the new table. Feed it a single-genome table unscoped and
it strips the layer from every other genome's genes.

This is now **supported for rsid** and **guarded for every layer**:

* `REMOVE_SCOPE` narrows the remove pass (`make refresh-rsid-genome GENOME=x` sets
  `REMOVE_SCOPE=system_name:x` for you).
* A **shrink guard** aborts any run whose remove pass would clear more than half the genes carrying
  the token. It was verified against exactly this mistake: an unscoped single-genome rsid run
  reported it would clear **4,106,661 of 4,106,661** genes (100%) and refused, before writing
  anything. Override with `ALLOW_SHRINK=1` only when a mass removal is genuinely intended.

`expression` still has no per-genome path — its table is regenerated wholesale — so the warning
stands there; what changed is that the failure is now caught rather than silently applied.

---

## Atomic updates erase indexed-but-not-stored fields

**Symptom.** Free-text gene search silently returns nothing for a large subset of genes.
`_terms:msd2` → 0 hits, while the same query against the previous release's core returns 1.

**Cause.** Solr implements an atomic update by reconstructing the document from its **stored**
fields and reindexing it. A field that is indexed but neither `stored` nor `docValues`, and is not a
copyField destination, cannot be reconstructed — it is silently dropped from every document the
update touches.

`_terms` was exactly that shape (`indexed=true stored=false docValues=false`, no copyField rule,
written directly by `genes/mongo2solr.js:263`). A single `62_attr_atomic expression` run erased it
from **247,323 documents**. Nothing failed: the stage reported success, doc counts were unchanged,
and only search was broken. It would also have propagated into the suggestions core, since
`suggestions/genes.js:93` builds gene suggestions by faceting on `_terms`.

**Fixed** by making `_terms` `stored="true"` in `genes/conf/managed-schema` and reindexing. Atomic
updates are safe against it now.

**Guard.** `62_attr_atomic` inspects the live schema before doing anything and refuses if it finds
any indexed field that is neither stored nor docValues nor a copyField destination, naming the
offenders. `add_studies` runs the same check as `--preflight` *before* stage 55, so an incremental
add cannot update mongo and then discover it has no way to update Solr. If you add an indexed field
to the genes schema, either make it stored or expect this guard to block every `refresh-attr`.

**If it happens again**, the damage is recoverable without a full rebuild as long as the file the
core was loaded from still exists: `_terms` values derive from names/synonyms/alt_ids, so
`solr_genes.attribs.json` holds correct values, and an atomic update that *explicitly provides*
`_terms` restores it losslessly. A full reindex fixes it too, at the cost of core downtime.

## rsID VCFs projected onto the wrong assembly

**Symptom.** None, until something checks the sequence. `build_rsid_table.sh` aborts with

```
FATAL [sorghum_353]: REF allele disagrees with the CDS sequence for 74.36% of coding SNVs
```

**Cause.** Two of the 104 projected VCFs (`sorghum_353`, `sorghum_pi154844`) address a *different
build* of that accession than the cores in this release. Everything superficial about them is
right — chromosome names `1`–`10`, plausible coordinate ranges, normal variant counts, and every
position lands inside some gene. Only the underlying sequence differs, so the gene→rsID assignments
are confidently wrong.

74.36% is the giveaway: a random base disagrees 75% of the time.

**Confirmed two ways that do not depend on the CDS offset arithmetic:** VCF REF vs the *genomic*
base scores 24.67% / 23.13% for these two against exactly 100.00% for all 102 others (a bimodal
split, no borderline cases); and `sorghum_353`'s variants run **7.5 Mb past the end of chr10**,
which no offset or liftover slip can produce.

**Handled** by `RSID_SKIP_GENOMES` in `config.sh` — a visible, documented exclusion rather than a
silent drop. Clear it once the projection is redone against the assemblies we serve.

**Screen before running**, it takes about two minutes:

```bash
../gramene-solr/rsid_pipeline/check_vcf_assembly.sh
```

**The general lesson**, and the reason consequence calling paid for itself immediately: this was
only detectable because something compared the data against the *reference sequence*. Counts,
ranges, and names all looked correct. When a new projected dataset arrives, check it against
sequence, not against plausibility.

## A work dir glob sweeping in excluded genomes

**Symptom.** The rsID table had **4,164,842** rows where the 102 included genomes account for
**4,106,661**. The 58,181-row surplus was exactly `sorghum_353` (31,830) + `sorghum_pi154844`
(26,351) — the two genomes that had just been deliberately excluded.

**Cause.** `build_rsid_table.sh` assembled the table with `cat "${TMP}"/*.tsv`. The work dir is
durable and resumable by design, so it also holds the **partial output a failed genome wrote before
it aborted**, plus anything left by earlier runs with different parameters. Excluding a genome from
the *run* did nothing to exclude it from the *glob*.

Nothing downstream could have caught it: the rows are well-formed, the gene ids are unique, and
`validate_rsid_table.sh` passed on the polluted table because every structural property still held.
The only signal was the row count failing to reconcile against the sum of the per-genome files.

**Fixed** by concatenating the selected genomes **by name** (`for g in "${GENOMES[@]}"`), never a
glob, and by deleting a genome's `.tsv` when it fails so no partial file survives.

**The general rule:** in a resumable pipeline, the work dir is not a manifest. Drive the final
assembly from the list of things you meant to include, and reconcile the output count against that
list — a glob will faithfully include whatever happens to be lying around.

## Diagnosing something new

An approach that has worked repeatedly here, in order:

1. **Compare against the previous release.** `sorghum10b` is right there. Counts, field presence, a
   specific gene's document — diff them.
2. **Check freshness, not just validity.** The intermediate is almost always well-formed; the
   question is whether it is *current*. Compare mtimes against stage stamps.
3. **Verify the assumption you are most confident about.** The four-times-repeated stall was
   diagnosed the moment someone questioned whether the dumps matched `maps` — the part everyone
   assumed was fine.
4. **Query the source directly.** MySQL on cabot, Mongo, and Solr are all reachable; when a derived
   artifact looks wrong, go back to what it was derived from rather than reasoning about the code.
