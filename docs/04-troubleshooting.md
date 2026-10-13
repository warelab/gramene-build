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
*reassigned* whenever the genome set changes. 78 of the subsite's 128 dumps were left over from an
earlier run with different taxon ids. Decorate looked up a taxon that no longer existed in `maps` and wedged.

The dump stage's resume logic compared **line counts** — which were identical — so it saw nothing
wrong and skipped re-dumping.

**Fix, now enforced by `40_genes_dump`:** dumps older than `.state/10_maps.done` are re-dumped, and
every dump's `taxon_id` must equal `maps.taxon_id` for that genome.

**If it stalls anyway:** compare the last gene written to Mongo against the next gene in the dump.

```bash
mongosh --quiet search70 --eval 'db.genes.find().sort({$natural:-1}).limit(1).toArray()'
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

`00_preflight` asserts the expected counts — for this release `EXPECT_CORES=267`,
`EXPECT_ANCHORS=0`, `EXPECT_VARIATIONS=24` — so a selection mistake fails immediately rather than at
ingest time. **`EXPECT_ANCHORS=0` is correct here, not an unset placeholder:** anchor genomes are a
SorghumBase concept and this release has none.

---

## Gene trees look wrong

**Synthetic ids.** Trees whose compara `stable_id` is NULL get `SB<version>GT_<root_id>`, derived
from `collections.getVersion()`. **This never fires on a plants release** — all 170,249 trees in
`search70` carry real compara ids (`EPlGT*`), as do r69's. If it ever does, note that the default
`SB` prefix is a SorghumBase artifact and wrong for the main release; set `GT_PREFIX` explicitly.

**Family roots.** Resolving a tree's root taxon by *stripping digits* off a synthetic taxon id is
wrong — `45580072` becomes `4558007`, which is a different genome ("chinese amber"). Walk the taxon
parent chain instead. This was caught before shipping; if you see a tree rooted at a suspiciously
specific accession, suspect this class of bug.

**Representatives.** Selection is scored, with anchor genomes pinned and non-anchor genomes taking a
+25 penalty. With `EXPECT_ANCHORS=0` here, *every* genome takes the non-anchor penalty, so the
scoring reduces to the remaining criteria — a uniform shift, not a bug. Changing that scoring requires re-running `make 35_genetrees` — the choices are stored,
not computed at read time.

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

**Do not scope `62_attr_atomic` to one genome.** It looks like an obvious optimisation — the table
is regenerated in full (247k rows) even when one genome changed, and it is about half the runtime of
an incremental add. But `solr_atomic_attr.js:122` computes removals as
`capabilities:"expression_attributes"` over the **entire core**, then strips the capability from
anything not in the new table. Feed it a single-genome table and it will strip expression from every
other genome's genes. Scoping is possible, but only if the removals query is scoped by the same
taxon at the same time.

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

## A resumable work dir is not a manifest

A durable, resumable work dir also holds **the partial output a failed step wrote before it
aborted**, plus anything left by earlier runs with different parameters. Assembling a final artifact
with `cat "${TMP}"/*.tsv` therefore includes whatever happens to be lying around — excluding
something from the *run* does nothing to exclude it from the *glob*. On the subsite this silently
added 58,181 rows for two deliberately-excluded genomes to an otherwise structurally perfect table;
every validator passed, because every structural property still held.

**The rule:** drive the final assembly from the list of things you meant to include
(`for g in "${GENOMES[@]}"`), never a glob, and reconcile the output count against that list. Delete
a unit's output when it fails, so no partial file survives. This applies directly to
`search/tmp/` (267 gene dumps) and `search/tmp_homologs/` here — both are globbed, both are durable,
and in `tmp_homologs` a truncated file is caught only because the skip check is `gzip -t` rather
than a size or count test.

## Maize has no pathways (capabilities:pathways returns zero maize genes)

**Symptom.** `q=*:* AND ((capabilities:pathways))` returns pathway genes for every species except
maize. `sorghum_genes10` had 1,518 maize pathway genes; `10b` and `11` had none. **v70 is the first
build to actually prove the fix** — v11 committed it but never re-decorated, so `search69` and
`sorghum11` both still show 0.

**Cause.** Plant Reactome files maize **twice**: `Zea mays` (taxId 4577, prefix **ZMA**) and
`Zea mays ver5` (taxId 381124, prefix **ZMY**). The two inputs `get_pathways.js` reads disagree:

| input | maize content |
|---|---|
| `gene_ids_by_pathway_and_species.tab` | B73 **v5** ids (`Zm00001eb…`), prefix ZMY |
| `Ensembl2PlantReactomeReactions.txt` (public) | **v4** ids only (`Zm00001d…`), prefix ZMA |

`get_pathways.js` creates one skeleton per gene from the `.tab` and fills `ancestors`/`entries`
from the reactions file. Our cores carry only v5 genes, so every maize gene got a skeleton that
nothing ever filled — `annotations.pathways = {}` on 1,587 genes. `mongo2solr.join.js` emits a
`<field>__ancestors` + capability only `if (ancestors || entries)`, so it correctly skipped them:
**the conversion was right and the data was empty.** The `speciesCode ZMY not in taxonLUT` line in
the stage log is a symptom of the same split, not the cause — the code self-heals that lookup.

**Fix.** `Ensembl2PlantReactomeReactions_Zmy_ver5.txt` (in `gramene-mongodb/reactome/`) supplies
the missing ZMY reaction rows. `25_reactome.sh` appends it to the downloaded reactions file before
`get_pathways.js` runs. It is **not published upstream** — its download URL 301s to the Plant
Reactome home page — so it is carried in-repo. It came from the release69/v10 build, which is why
v10 had maize pathways and v11 did not.

**Coverage.** It covers 1,518 genes; 157 of the 1,587 skeletons have no data in any artifact and
stay empty. That matches v10, which also had 1,518.

**Verify** after a rebuild:

```bash
# this release's maize genome is zea_mays (B73 v5), not zea_maysb73
curl -s 'http://localhost:8983/solr/genes70/select?q=capabilities:pathways+AND+system_name:zea_mays&rows=0&wt=json'
# expect ~1518 of 44,303, not 0
```

Upstream of Solr, check the stage's own artifact — `Zm00001eb*` keys in
`reactome/genes_to_pathways.json` should go from **0 filled of 1,587** to about **1,518 of 1,675**
(`annotations.pathways.entries` is the field to test; every key has a wrapper object, so testing for
a truthy value will tell you everything is fine when nothing is).

Note the suggestion category `Plant Reactome: Pathway` is faceted from the genes core, so it must
be regenerated after this is fixed or its per-genome counts will still omit maize.

**364 rice `Os*` keys are still empty**, for a different reason: the japonica/UniProt enhancement
that would fill them is deliberately skipped (`25_reactome.sh`). `search69` has ~1,590 rice genes
with pathways, so this is a v70-vs-v69 regression to settle before publishing.

## A stage aborts with a bare "Error 1" and no explanation

**Symptom.** `make: *** [Makefile:112: .state/45_homologs.done] Error 1`, the stage log ends on the
command it was running with no error text, and the expensive output is sitting on disk looking
complete.

**Cause seen here.** `45_homologs` ended a line with `rmdir "${TMP}/sorttmp" 2>/dev/null`. The sort
temp is pointed at a filesystem big enough for a ~38 GB external sort by **symlink** (`/usr/local`
is not), and `rmdir` on a symlink exits `ENOTDIR`. Being the last command on its line under
`set -e`, that aborted the stage *immediately after a successful ten-minute sort* — and the
`2>/dev/null` discarded the only clue.

**The general shape:** `set -e` plus a trailing cleanup command whose failure is expected and
suppressed. `2>/dev/null` hides the message, not the status. Any cleanup you do not care about needs
`|| true`.

**How to find it fast.** The log's last line is the command that *succeeded*; the failure is in
whatever ran after it. Re-run that tail by hand without `2>/dev/null` and read the status:

```bash
bash -x stages/<stage>.sh 2>&1 | tail -40     # or just run the suspect cleanup line directly
```

---

## An external service is down

Two stages depend on external HTTP and will sit there producing nothing:

| stage | depends on | note |
| --- | --- | --- |
| `25_reactome` | `plantreactome.gramene.org/ContentService` | **Gramene-operated** — ask for a restart |
| `55_atlas` | `www.ebi.ac.uk/gxa` | EBI |

A down ContentService is easy to misread, because the *host* stays healthy: `/` answers in 60 ms
while every `/ContentService/data/*` path hangs until timeout. The file host
(`/download/current/...`) is separate again and may be fine while the API is not — so the stage
logs "✓ file ok" for its downloads and then stalls on the species-prefix step.

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}s
' --max-time 25 \
  'https://plantreactome.gramene.org/ContentService/data/species/all'   # 200 = up, 000 = hung
```

`25_reactome` fails *safely* when this happens: the empty `merge_into_taxonomy.json` trips an
invalid-JSON guard, and `genes_to_pathways.json` is left untouched rather than half-rewritten. The
ZMY append is idempotent (the `curl -o` above it overwrites the base file every run), so simply
re-run the stage once the service returns.

---

## Re-running an early stage re-runs everything after it

**Symptom.** You re-run `00_preflight` or `05_install` to verify something, then `make -n all`
proposes re-dumping 267 genomes and rebuilding maps.

**Cause.** The stamp targets encode the DAG as stamp-file dependencies, and make compares **mtimes**.
A freshly re-run `00_preflight.done` is newer than every stamp below it, so the whole chain looks
stale — even though nothing about the data changed.

**Fix.** Don't delete and re-run the downstream stages. Bump the completed stamps' mtimes past the
one you just refreshed, in dependency order, after confirming their outputs really are present:

```bash
D=$(date +%Y-%m-%d)
touch -d "$D 19:16" .state/10_maps.done
touch -d "$D 19:17" .state/15_ontologies.done .state/20_variation.done \
                    .state/30_curated.done .state/40_genes_dump.done
touch -d "$D 19:18" .state/35_genetrees.done
make -n all        # should now propose only what you actually want
```

Verify before you stamp, not after: collection counts for the mongo stages, and for
`40_genes_dump` that all 267 `search/tmp/*.json.gz` exist and pass `gzip -t`. A stamp asserts "this
completed"; bumping one you have not checked is how a stale intermediate gets blessed.

---

## Deleting a Solr core by directory name

On this host a core's **name does not match its `instanceDir`**, and for the r69 cores every name
was shifted one place off its directory — the core named `genes69` lives in `/solr/data/genes69c`,
while the directory called `genes69` held a disposable copy. `rm -rf` by directory name is a coin
flip on the live index.

```bash
curl -s 'http://localhost:8983/solr/admin/cores?action=STATUS&wt=json' \
  | python3 -c 'import json,sys; [print(n, c["instanceDir"], c["index"]["numDocs"]) for n,c in json.load(sys.stdin)["status"].items()]'
```

Confirm which name is live from the code that queries it — `gramene-swagger/api/helpers/solr.js`
builds `` `${urlBase}genes${version}` `` from `getMongoConfig().version` — then remove by **name**:

```bash
curl -s 'http://localhost:8983/solr/admin/cores?action=UNLOAD&core=<name>&deleteInstanceDir=true'
```

Re-query the live core between deletions. `deleteInstanceDir=true` leaves `conf/` behind (~700 KB)
but does remove `core.properties`, so the emptied directory is **not** re-discovered as a core on the
next restart — which matters, because a stale `core.properties` is what produced a
`CoreContainer is either not initialized` 404 after an earlier restart here.

---

## Two genomes claim the same gene stable id

**Symptom, if you are lucky.** `40_genes_dump` fails its third gate naming the colliding genome
pair. **Symptom, if you are not.** `50_genes_decorate` dies in `genetree_adder` with
`Cannot read properties of undefined (reading 'score')` after loading every tree — because a tree
held two leaves with the same `gene_stable_id` and only one of them got a representative. That is
how this was found, nine minutes into a 16.1M-gene stage.

**Why it matters more than it looks.** `<db>.genes` keys on the gene stable id, and so does the
Solr core (`uniqueKey` is `id`, set from `mongo._id`). If two genomes claim one id, the second
write *replaces* the first. Nothing errors, and the collection total stays plausible, so only a
per-genome completeness check can see it.

**It has already shipped.** In `search69`, `triticum_aestivum_alchemy` owns the `TraesCS*` ids and
reference wheat retains **17,705 of its 120,744 genes** — 85% of a flagship genome missing from the
live site. An audit of all 233 r69 genomes found wheat to be the *only* one more than 1% short, so
this is isolated but severe.

### The two cases in v70

| pair | shared ids | nature |
| --- | --- | --- |
| `triticum_aestivum` ↔ `triticum_aestivum_alchemy` | 103,039 | **a core regression — fixable** |
| `lablab_purpureus_gca030347555v1cm` ↔ `medicago_truncatula` | 24,925 | no stable ids ever assigned |

**Wheat is a prefix regression.** `..._alchemy_core_69_114_1` labels its genes `TraesALC*`;
`..._alchemy_core_70_116_1` labels the very same annotation `TraesCS*`, which is the reference's
namespace. Same assembly (GCA951799155v1), same accession, same genebuild, same 106,786 genes, and
joining the two cores on `REPLACE(stable_id,'TraesALC','TraesCS')` matches 106,786 of 106,786 with
identical seq_region/start/end/strand. Compara agrees the prefix belongs to the reference: both
`ensembl_compara_plants_69_114` and `_70_116` contain **zero** alchemy genome_dbs and zero
`TraesALC*` members, while all 107,545 `TraesCS*` `gene_member` rows belong to genome_db 2102 =
`triticum_aestivum` (IWGSC). So renaming alchemy back to `TraesALC*` desyncs nothing, and since
alchemy is not in compara it has no trees or homologs either way.

**The legumes are not a regression.** `medicago_truncatula_core_69_114_3` and `_70_116_3` both use
placeholder `geneNNNN` ids on MtrunA17r5.0_ANR (the older MedtrA17_4.0 core used proper `MTR_*`
ids — they were lost at the assembly switch), and `lablab_purpureus` does the same. Compara
*contains* both (genome_db 2282 and 2308) with the colliding ids, distinguishing them only by
`genome_db_id`, so there is no correct prefix to restore and any rename would have to be applied to
the compara reads in `35_genetrees`/`45_homologs` as well.

### Diagnosing a new one

```bash
make check-stable-ids          # the same check 40_genes_dump gates on
```

Then compare the suspect genome's core against the **previous release's core for the same
assembly** — that is what identified the wheat regression in minutes:

```sql
SELECT LEFT(stable_id,10), COUNT(*) FROM gene GROUP BY 1 ORDER BY 2 DESC LIMIT 5;  -- in each core
```

If the prefixes differ while assembly, accession, genebuild and gene count match, it is a labelling
regression in the newer core and belongs upstream, not in a workaround here. Confirm with a join on
the expected prefix swap, asserting identical coordinates.

### Accepting one deliberately

`STABLE_ID_COLLISION_ALLOW="genomeA:genomeB,genomeC:genomeD"` (order-insensitive) stops a pair
blocking the build. It does **not** stop the genes being dropped, and anything unlisted still
fails, so a newly introduced collision cannot pass silently. Record *why* in
[docs/06-open-items.md](06-open-items.md) whenever you add one.

---

## A compara-driven stage is 100x slower than its own last run

`35_genetrees` ran the same 170,253 trees in **48 minutes on 2026-07-08** and, restarted on
2026-10-13, settled at **24.7 trees/min — a 115-hour projection**. Nothing about the query had
changed; `EXPLAIN` was optimal (every join `eq_ref` on `PRIMARY`, driven by a range scan on
`gene_tree_root`). The cause was colden's **OS page cache**, and the same trap applies to any stage
that reads compara in many small batches.

Why compara is unusually exposed: the tables are **MyISAM** and `key_buffer_size` on colden is
**32 MB** against ~11 GB of MyISAM indexes, so the page cache is doing essentially all of the
caching. `genetree.js` fetches 100 root_ids at a time and assembles ~200-270k rows per batch from
scattered primary-key lookups across ~33 GB (`gene_align_member` 13.1, `gene_tree_node` 7.3,
`sequence` 4.1, `seq_member` 3.8, `gene_member` 3.0, `gene_tree_node_attr` 2.2). Cold, that is
~1.7M random reads per batch; warm, it is memory.

**The measurement that identifies it.** Time one batch twice. Pull the real query out of the stage
log, swap in 100 root_ids the stage has *not* reached yet, and run it twice in a row:

```bash
awk '/^select r.root_id,/{f=1} f{print} /order by r.root_id, n.left_index;/{if(f)exit}' \
  logs/35_genetrees.log > /tmp/batch.sql
# replace the IN list with ids from the far end: order by root_id desc limit 100
time mysql ... < /tmp/batch.sql | wc -l   # cold
time mysql ... < /tmp/batch.sql | wc -l   # warm
```

Measured 2026-10-13: **63s cold, 9s then 8.6s warm**. A large, *repeatable* cold/warm gap on an
unchanged query with a good plan means page cache, not the query.

**Do not** read a single `SHOW PROCESSLIST` sample as a stall. That connection sat in
`Copying to tmp table` for 741s and looked wedged, but the node driver holds **one persistent
connection**, so the `id` never changes and only `time` resetting reveals that batches are
completing. Sample the state repeatedly instead, and confirm progress independently
(`db.genetree.count()`), before concluding anything is stuck. Note also that `Copying to tmp table`
is unavoidable here rather than a symptom: `sq.sequence` is a TEXT column, so MySQL cannot use an
in-memory temp table for the `ORDER BY` and always goes to disk.

Two readings that looked like evidence and were not: a 10.5s timing of "the same query", which was
fast only because it re-read the rows the stage had *just* pulled into cache; and a 1.2% CPU reading
from `ps`, which is a lifetime average, not the instantaneous figure (`top -b -n 2` gave the real
0.0%). Low CPU plus `currentOp` showing zero active mongo ops is what localised it to the server.

**The fix.** [`trees/warm_compara_cache.sh`](../../gramene-mongodb/trees/warm_compara_cache.sh)
sequentially scans the six tables, ~81 seconds for all 33 GB, strictly read-only, with
www.gramene.org measured at 24-72 ms throughout. It works on an **already-running** stage — applied
mid-run it took the rate 24.7 -> 2,625 trees/min with no restart. Each scan is a `SUM()` over a
non-indexed column on purpose: on MyISAM a bare `COUNT(*)` comes from stored metadata and reads
nothing.

The cache is cold precisely *after maintenance* — the stable-id rename UPDATEs, a compara dump, or
any exploratory full scan evicts it — so treat a cold cache as the normal state following that work
and warm before a tree or homology stage rather than diagnosing it again. Do not edit
`35_genetrees.sh` to call it while the stage is executing: bash reads a script incrementally and
editing it mid-run corrupts execution.

## Diagnosing something new

An approach that has worked repeatedly here, in order:

1. **Compare against the previous release.** `search69` / `genes69` are right there, and r69 is
   live. Counts, field presence, a specific gene's document — diff them. (Mind the core naming:
   `genes69`, not `gramene_genes69`.)
2. **Check freshness, not just validity.** The intermediate is almost always well-formed; the
   question is whether it is *current*. Compare mtimes against stage stamps.
3. **Verify the assumption you are most confident about.** The four-times-repeated stall was
   diagnosed the moment someone questioned whether the dumps matched `maps` — the part everyone
   assumed was fine.
4. **Query the source directly.** MySQL on colden, Mongo, and Solr are all reachable; when a
   derived artifact looks wrong, go back to what it was derived from rather than reasoning about the
   code.
5. **Check whether the upstream service is simply down.** Two stages depend on external HTTP
   (`25_reactome` on Plant Reactome, `55_atlas` on EBI GXA). A hang with no output is as likely to
   be an unresponsive dependency as a bug — see
   [An external service is down](#an-external-service-is-down) below.
