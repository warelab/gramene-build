# Open items

State as of **2026-10-19**, when the build reached `70_services` and the API went public.

The previous revision was written on 2026-10-08, before most of the work, and by the time it was
read again it was wrong in several places — three of its items had already been fixed and were
chased anyway (see [A note on this document](#a-note-on-this-document)). Everything below is
either verified against the live databases on 2026-10-19 or carries the command to verify it.

---

## Build status: COMPLETE

All stages `00_preflight` → `70_services` have stamps. Both services are online and the public
API serves.

| artifact | value | cross-check |
| --- | --- | --- |
| `search70.genes` | 16,127,051 | == `sum(maps.num_genes)` |
| `solr genes70` | 16,127,051 | == mongo |
| `search70.homologs` | 13,786,532 docs / 2,091,049,122 values | 98.9% of compara's 1,057,465,164 homologies |
| `search70.genetree` | 224,197 over 5 tree sets | gene_tree 170,249 + barley 12,114 + oat 12,833 + wheat 12,752 + rice 16,249 |
| `search70.expression` | 1,371,654 | incl. 24,024 projected medicago |
| `expression_attributes` | 1,016,275 over 24 genomes | jsonl lines == docs loaded |
| `solr suggestions70` | 35,836,046 | r69 had 37,287,102 (different gene set; not comparable) |
| `search70.maps` | 267 genomes | |

Live: `https://data.gramene.org/v70/swagger` → 200, `pm2` `gramene_swagger70` (10070) and
`gramene_ebeye70` (11070) both online.

---

## Resolved since the last revision

Listed so the next reader does not re-investigate them. Each says what the evidence was.

* **Plant Reactome ZMY fix — proven.** `25_reactome` ran once the ContentService came back.
  **1,518 of 44,303** `zea_mays` genes carry pathway entries, matching the predicted gate. Both
  `search69` and `sorghum11` show 0 here, so this is the first build to actually demonstrate it.
* **Gene stable id collisions — gone.** Alchemy wheat was renamed `TraesCS*` → `TraesALC*` in the
  core (868,839 rows); medicago and lablab were given their community ids in the cores *and*
  compara. The `40_genes_dump` gate now passes clean: **16,127,051 ids extracted, 16,127,051
  distinct, 0 claimed by more than one genome**. Both defects are written up for upstream in
  [07-upstream-defects.md](07-upstream-defects.md).
* **`_terms` stored="true"** — already fixed by `dab1932` (landed here as `fcb3138`). The previous
  revision said it was `stored="false"`; it was not. `60_solr_genes` now also *refuses* any schema
  with an indexed-but-unrecoverable field before building the core.
* **All four claimed `70_services` defects** — `BASEPATH`, the title, the `solr.js` rewrite and the
  checklist were already correct and parameterised. What the stage *did* lack is in `e1a09f5`.

---

## Open

### 1. `suggestions70` `taxon_freq` is now correct, and therefore differs from r69

The old Solr-facet path double-counted: each taxon's count was added once from the
`_terms,taxon_id` pivot and again in the per-taxon loop, while `num_genes` was incremented only
once. Audited over 3,000 multi-gene docs in the old output: **2,285 wrong, mostly exactly 2.0×**.
The new build has 0 wrong (`sum(taxon_freq) == num_genes` for all sampled).

**So multi-gene suggestion frequencies are roughly half what the live r69 site shows.** Release 69
has the inflated values, because the same code built it. If anything in the UI displays or sorts on
`taxon_freq`, expect a visible change, and do not treat a side-by-side difference as a regression.

    curl -s --get localhost:8983/solr/suggestions70/select \
      --data-urlencode 'q=category:"Genes: symbol/name"' \
      --data-urlencode 'fq=num_genes:[2 TO *]' -d 'rows=200&fl=num_genes,taxon_freq&wt=json'

### 2. Rice `Os*` pathway keys with no entries — decide before announcing

`25_reactome.sh:7-10` deliberately skips the japonica/UniProt enhancement that fills these, so some
rice genes carry a `pathways` key with an empty `entries`. `search69` has ~1,590 rice genes with
pathways. Still a v69→v70 regression for rice if shipped as-is. To apply it, do the awk/pack munge
from the original recipe against `merged_lut.txt` before `get_pathways.js` runs — the same insertion
point the ZMY supplement uses. Verify the current count with:

    mongo --quiet search70 --eval 'print(db.genes.count({system_name:"oryza_sativa", \
      "annotations.pathways":{$exists:true},"annotations.pathways.entries.0":{$exists:false}}))'

### 3. Remaining deployment steps

Apache proxy and firewall are **done** (`/v70` → squam:10070 verified end to end). Left:

* **Ensembl REST registry** — add this release's 267 cores + compara to
  `/usr/local/ensembl-87/ensembl-rest/reg.pm` via `make_reg_pm.js` + `merge_reg_pm.pl`; do not
  hand-edit the shared file. Needed by the genome browser and BLAST, *not* by the API.
* **BLAST** — `ensure_blast.pl` against the updated registry, then restart `gramene-blast` under pm2.
* **gene-tree curation UI** (`gramene-genetree-vis`) — point `defaultServerSb` at
  `https://data.gramene.org/v70/swagger`.

⚠️ **Never `pm2 restart all`** — 61 processes on this host, 10 deliberately stopped.

**How is ebeye exposed?** `https://data.gramene.org/ebeye69/` returns 404, so r69's ebeye is not
proxied under that path and port 11070's external reachability is untested. Worth settling before
anything depends on it.

### 4. `saved_search` will restore 0 of 14 — expected, not a bug

`genes69` carries tags on 14 docs across 8 hashes and **none of those hashes exists in any
`genelists` collection** — all surviving lists are `site:'sorghum'`. The restore tool correctly
keeps only hashes with surviving metadata. Orphaned hashes: 632734279, 796382183, 1654857188,
2031365501, 2816589576, 3132912727, 3181543302, 4102227627.

### 5. maps QC over-reports failures against the public REST

`maps/check_maps_in_ensembl_rest.js` has a concurrency-limited pool with no retry and no backoff,
and `https://rest.ensembl.org` rate-limits — a 25-genome sample produced 9 HTTP 500s in one burst,
all of which returned 200 when retried spaced out. Non-fatal (`|| warn`). Fixing it means adding
retry with `Retry-After` handling.

### 6. Capacity — three filesystems and one Redis worth watching

* **`/` is 20 GB and `/tmp` lives on it.** It hit 100% (5.4 MB free) on 2026-10-19 because a
  multi-GB test file was written to `/tmp`. `/usr` alone is 10.5 GB, so `/tmp` has ~7 GB of real
  headroom. **Put large intermediates on `/scratch`.**
* **`/usr/local` is at 96% (98 GB free).** `60_solr_genes` needs **~265 GB** of intermediates
  (`solr_genes.json` ~131 GB plus `solr_genes.attribs.json` ~131 GB, both present at once) and now
  refuses to start without the room — use `SOLR_DUMP_DIR=/scratch/...`.
* **`/solr`**: 178 GB free. `genes70` 2.9 GB + `suggestions70` 2.9 GB. ~275 GB is reclaimable in 65
  directories that are not the `instanceDir` of any loaded core. ⚠️ Resolve by **`instanceDir` from
  the STATUS API**, never by name: the core *named* `genes69` lives in `genes69c`, so deleting the
  directory called `genes69` is safe while deleting `genes69c` destroys the live r69 index. And
  `solr.xml`, `zoo.cfg`, `filestore` and `userfiles` are not cores.
* **Redis** holds 22 GB with **`maxmemory` unset, `noeviction`, and no AOF**, across 8.9 M keys in
  db1–db4. An unbounded dataset there takes the box down rather than degrading, and a restart loses
  everything until a rebuild. Settle a budget before putting anything load-bearing in it.

### 7. A connection leak was stopped but not root-caused

pm2 process `auth_testing` (`/home/olson/src/warelab/gramene-swagger`, a dev checkout proxied from
`data.sorghumbase.org/auth_testing`) held **2,929** mongo connections and was creating **~31,000 per
minute**, with 11,123 sockets in TIME-WAIT and established connections growing ~150/min. mongod's
`totalCreated` was 53.9 M over 78 days. Stopping it dropped `connections.current` from 3,145 to 142
and the creation rate to 1/min.

It was leaking **with zero inbound traffic**, so it is an internal loop or a per-operation client
that never closes, not request volume. It also showed 359 pm2 restarts. Files touching mongo there:
`api/helpers/mongo.js`, `api/controllers/mongo.js`, `api/controllers/gxa.js`. Also:
`/var/log/mongodb/mongod.log` is 306 MB with no rotation.

### 8. JGI sorghum expression is loaded but deliberately not scored

`57_jgi_expression` loaded 4 experiments / 99 assays / 34,118 genes into `search70`
(`source: "JGI"`). `58_expression_attributes` **excludes** it via `EXPR_SOURCES=EBI`, so `tau`,
`breadth` and the level bands stay on GXA-only input. Verified: loading it left all 34,118 sorghum
`expression_attributes` docs byte-identical (md5 `5ceae8ab487bb40bd8b180d3b7cd1a09`).

Two independent reasons to keep it excluded, both in
[../../gramene-mongodb/jgi/README.md](../../gramene-mongodb/jgi/README.md):

1. **No citation.** All 288 libraries claim `publication.status = published` but give no DOI or
   PMID; the description still reads "Submitted via JGI; awaiting citation."
2. **Its group values are means, where every other source's are medians.** GXA ships a five-number
   summary per assay group and `parseBaseline.js` takes the median; the JGI matrix arrives
   pre-aggregated as one *mean* per group, and library-level values never reach us. Measured over
   1.9 M GXA assay-group cells, right skew beats left 48.5%/31.4%, so those means sit high. And 56
   of its 99 groups are stem, so the bias lands almost entirely on one organ whose median would
   also be set by a single lab under one set of growth conditions.

To include it once the submitter supplies group medians:
`EXPR_SOURCES="EBI,JGI" make 58_expression_attributes`, then 60/62/65.

### 9. Upstream defects reported, not fixed upstream

Six verified defects in Ensembl Plants 70 / compara are written up in
[07-upstream-defects.md](07-upstream-defects.md). The one with no local workaround:
**medicago and lablab are in compara's `default` trees with zero homology rows** — 0 of 69,421
genes appear in `homology_member`, against 98% participation for a comparable genome. No
orthologues can be shown or exported for those genomes.

### 10. Flagged, not fixed: the v10b mis-pin

`subsites/sorghum/v10b/gramene-mongodb/package.json:29` pins the config at `#sorghum_v11` and its
`node_modules` copy resolves to **`sorghum11`**, so any ETL run from that repo writes to the wrong
database. Left alone deliberately — live site, outside this release — but fix it before anyone runs
a build from that tree.

### 11. `ensembl_db_info.json` tracks a plaintext MySQL password

`gramene-mongodb/ensembl_db_info.json` contains a `pass` field and **is tracked in git**. It is also
the curated record of this release's 267 cores, so it cannot simply be removed: externalise the
credential and keep the database set. One propagated-but-skipped commit would have *regenerated*
this file and destroyed the 267-core configuration — keep skipping it.

---

## Known-good baselines

| thing | value |
| --- | --- |
| `search70.genes` / `genes70` | 16,127,051 |
| `search69.genes` | 11,773,843 |
| `search70.homologs` | 13,786,532 docs / 2,091,049,122 values |
| compara homologies kept | 1,046,239,795 of 1,057,465,164 (98.9%) |
| `Os01g0517500` homologs | 278 — equals its compara row count (r69: 239; the broken build: 42) |
| `search70.genetree` | 224,197 across 5 sets |
| distinct `_terms` in `genes70` | 20,983,024, of which 2,526,566 appear in ≥2 genes |
| `suggestions70` | 35,836,046 |
| maize v5 pathway genes | 1,518 of 44,303 |
| medicago LeGOO annotation | 4,197 names + 4,388 descriptions; 24,024 expression docs projected |
| live r69 core names | `genes69` (dir `genes69c`), `suggestions69` (dir `suggestions69b`) |

---

## A note on this document

The previous revision was ten days old and wrong in three places that cost real time: it said
`_terms` was `stored="false"` (already fixed), and it listed four `70_services` defects (all four
already fixed, each with a comment explaining the trap). Both were chased before being checked.

So: **when an item here is acted on, verify it against the live system first**, and when it is
resolved, move it to *Resolved since the last revision* with the evidence rather than deleting it.
An item that silently disappears is indistinguishable from one nobody looked at.

The same lesson runs through the gates added during this build — each exists because something
reported success while being wrong:

| gate | asserts, instead of |
| --- | --- |
| `dump_compara_tables.sh` | row counts == table, instead of `gzip -t` passing |
| `45_homologs` | cross-species orthology present, instead of a non-empty collection |
| `52_tree_domains` | leaf decoration per tree set, instead of "updated N trees" |
| `60_solr_genes` | schema is atomic-update safe *before* the hours-long build; and that there is disk room |
| `70_services` | the public spec serves before ebeye starts; and stability, instead of a listener |
