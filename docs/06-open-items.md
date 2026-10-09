# Open items

Everything unfinished as of **2026-10-08**, with enough context to act without the conversation that
produced it. Ordered by what blocks what.

This release's pipeline was propagated from the SorghumBase v11 subsite on 2026-10-08; the
`pre-v11-propagation-20261008` tag in each repo marks the state before it. The previous version of
this file described v11's open items and has been replaced — see that tag if you need it.

---

## Build status

The build is **resuming**, not starting: it died at `45_homologs` on 2026-07-10 and the stages
through `40_genes_dump` were banked and verified intact (267 maps, 170,249 genetrees, 267
gzip-clean gene dumps, 9 aux collections).

| stage | state |
| --- | --- |
| 00–40 | done (stamps restored after the propagation; outputs verified present) |
| `45_homologs` | **done** — 9,083,100 gene docs / 964,496,164 homolog values |
| `25_reactome` | **blocked** — Plant Reactome ContentService is down (see below) |
| `55_atlas` | running |
| `50`, `52`, `56`, `58`, `60`, `65`, `70` | not started |

`50_genes_decorate` needs `25_reactome`, so the ContentService outage is on the critical path.

### 1. Plant Reactome ContentService is down — blocks `25_reactome`

`https://plantreactome.gramene.org/ContentService/data/*` hangs until timeout, while the same host
answers `/` in 60 ms and serves `/download/current/...` normally. So the web server is up and the
ContentService backend is not.

**This is Gramene-operated infrastructure** — a restart on our side fixes it, which is faster than
waiting.

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 25 \
  'https://plantreactome.gramene.org/ContentService/data/species/all'   # 200 = up, 000 = hung
```

The stage failed *safely*: the empty `merge_into_taxonomy.json` tripped an invalid-JSON guard and
`genes_to_pathways.json` was left untouched. The ZMY append is idempotent, so once the service is
back, `make 25_reactome` is all that is needed.

**Gate when it runs:** `Zm00001eb*` keys in `reactome/genes_to_pathways.json` should go from **0
filled of 1,587** (the current, verified baseline) to about **1,518 of 1,675**. Test
`annotations.pathways.entries` — every key has a wrapper object, so a truthy test reports success
when nothing has changed.

---

## 2. 364 rice `Os*` pathway keys are empty — a v69 regression

`search69.genes` has ~1,590 rice genes with pathways; this release's artifact has 364 rice keys with
**no** pathway entries, because the japonica/UniProt enhancement that fills them is deliberately
skipped (`25_reactome.sh:7-10`).

**Decide before publishing.** Shipping as-is is a visible regression against r69 for rice. To apply
it, do the awk/pack munge from the original recipe against `merged_lut.txt` before
`get_pathways.js` runs — the same insertion point the ZMY supplement uses.

---

## 3. saved_search will restore 0 of 14 — expected, recorded here so it isn't read as a bug

`genes69` carries `saved_search` tags on **14 documents across 8 hashes**, and **none of those
hashes exists in any `genelists` collection** — all 62 surviving lists are `site:'sorghum'`. The
restore tool correctly keeps only hashes with surviving metadata, so it will report 0.

The orphaned hashes, for the record:

| hash | tagged docs |
| --- | --- |
| 632734279 | 2 |
| 796382183 | 3 |
| 1654857188 | 3 |
| 2031365501 | 1 |
| 2816589576 | 4 |
| 3132912727 | 4 |
| 3181543302 | 2 |
| 4102227627 | 1 |

The tooling was propagated anyway because it protects the *next* rebuild — and because the main
release has had no gene-list API at all until the swagger merge in this propagation, so there was
nothing to restore *into* before now.

---

## 4. Deployment steps not done

`70_services` has not run. When it does it prints the full checklist; these are the ones that need a
human:

* **Apache reverse proxy** on gorgonzola (`conf/extra/httpd-ssl.conf`, under `data.gramene.org`):
  `/v70` → `squam:10070`, then `apachectl configtest && apachectl graceful`
* **Firewall** — open 10070 (swagger) and 11070 (ebeye)
* **Ensembl REST registry** — add this release's databases to
  `/usr/local/ensembl-87/ensembl-rest/reg.pm` using `make_reg_pm.js` + `merge_reg_pm.pl`; do not
  hand-edit the shared file. Note the registry is **not** what the build uses for maps QC (that is
  `https://rest.ensembl.org`), but it is what the genome browser and BLAST need.
* **BLAST** — `ensure_blast.pl` with the updated registry, then restart `gramene-blast` under pm2
* **Gene-tree curation UI** (`gramene-genetree-vis`) — point its default server at the v70 swagger

**Never `pm2 restart all`.** 59 processes on this host, several deliberately stopped.

---

## 5. maps QC over-reports failures against the public REST

`ENSEMBL_REST` is now `https://rest.ensembl.org`, which is the only endpoint that resolves this
release's genomes (measured: 267/267, versus 0 for `localhost:3000` and 18 for the SorghumBase
pan-site). But `maps/check_maps_in_ensembl_rest.js` has a concurrency-limited pool with **no retry
and no backoff**, and the public service rate-limits — a 25-genome sample produced 9 HTTP 500s in
one contiguous burst, all of which returned 200 when retried spaced out.

So the QC report will name genomes as unresolvable that are perfectly fine. It is non-fatal
(`|| warn`) and stage 10 is already banked, so nothing is blocked. Fixing it means adding retry with
`Retry-After` handling to that script.

---

## 6. Housekeeping

### `/solr`

151 GB was reclaimed by unloading the three unserved `genes69*` cores (82 GB free → 232 GB). Still
present and **not** reclaimed:

* `/solr/data/suggestions69` (1.5 GB) and `/solr/data/suggestions69.1` (1.4 GB) — the live
  suggestions core is the one **named** `suggestions69`, whose instanceDir is
  `/solr/data/suggestions69b`. Only ~2.9 GB, so not urgent.
* The three unloaded `genes69*` directories remain as ~700 KB `conf/` stubs. Harmless —
  `core.properties` is gone, so they are not re-discovered as cores on restart.

⚠️ Core names do **not** match their directories on this host. Resolve the mapping from
`/solr/admin/cores?action=STATUS` and unload by **name** before deleting anything.

### `ensembl_db_info.json` tracks a plaintext MySQL password

`gramene-mongodb/ensembl_db_info.json` contains a `pass` field and **is tracked in git**. This was
flagged in v11's open items and is still true. It is also the curated record of this release's 267
cores, so it cannot simply be removed — the fix is to externalise the credential and keep the
database set. Note that one propagated-but-skipped commit would have *regenerated* this file and
destroyed the 267-core configuration; keep skipping it.

### Untracked / uncommitted

| repo | file | disposition |
| --- | --- | --- |
| `build` | `stages/57_jgi_expression.sh` | orphaned sorghum JGI expression stage; not referenced by the Makefile. Delete unless the main release takes on a non-EBI expression source. |
| `gramene-mongodb` | `jgi/` | same provenance; delete with the above |
| `gramene-mongodb` | `search/tmp_homologs/` | **keep** — 15 GB of compara dumps plus the sorted flatfile; `45_homologs` resumes from these |
| `gramene-mongodb` | `trees/inserts.jsonl` | build scratch; delete |
| all | `package-lock.json` | npm churn from `05_install`; ignore or commit, not meaningful here |

---

## 7. Flagged, not fixed: the v10b mis-pin

`subsites/sorghum/v10b/gramene-mongodb/package.json:29` pins the config at `#sorghum_v11`, and its
`node_modules` copy resolves to **`sorghum11`**. Any ETL run from that repo writes to the wrong
database. Left alone deliberately — it is a live site and outside this release's scope — but it is
exactly the failure mode the `file:../` dependency exists to prevent, and it should be fixed before
anyone runs a build from that tree.

---

## 8. Known-good baselines for comparison

Useful when something downstream looks wrong:

| thing | value |
| --- | --- |
| expected `genes70` / `search70.genes` | 16,127,051 (= `sum(maps.num_genes)`) |
| `search69.genes` | 11,773,843 |
| `search70.homologs` | 9,083,100 docs / 964,496,164 values |
| `search70.genetree` | 170,249 (all real `EPlGT*` ids — no synthetic prefixes) |
| `search70.maps` | 267 genomes |
| maize pathway genes, once 25 re-runs | ~1,518 of 44,303 (`zea_mays`, B73 v5) |
| live r69 core names | `genes69` (dir `genes69c`), `suggestions69` (dir `suggestions69b`) |
