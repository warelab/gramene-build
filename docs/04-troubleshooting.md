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
