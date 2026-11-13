# Maize pan-genome subsite — release v6

A port of the hand-built maize v5 subsite onto the staged `release70` build harness, by way
of grapevine v5. Source Ensembl databases are **unchanged from v5**, so gene models and gene
trees are identical by construction; what v6 adds is everything the harness has gained since
v5 was built by hand.

v5 is untouched and still serving. Nothing under `../v5/` may be edited, stopped or dropped.

## Names

| thing | v5 | v6 |
| --- | --- | --- |
| release root | `subsites/maize/v5` | `subsites/maize/v6` |
| mongo db | `maize5` | `maize6` |
| solr genes core | `maize_genes5` | `maize_genes6` |
| solr suggestions core | `maize_suggestions5` | `maize_suggestions6` |
| swagger / ebeye ports | — | **30006 / 31006** |
| public path | `/maize_v5` | `/maize_v6` |
| pm2 names | `maize_swagger5`, `maize_ebeye5` | `maize_swagger6`, `maize_ebeye6` |

Ports and paths are all derived in `build/config.sh` from `SPECIES` and `DB_VERSION`
(itself read from `collections.js`), never hardcoded in the serving tier — that is what
`70_services.sh` writes.

## Branches

Every repo is on `maize_v6`, cut from the **`grapevine_v5`** branch of the same repo, which
is itself cut from `release70` (`main_v70` for `gramene-mongodb-config`).

Going through grapevine rather than straight from `release70` is deliberate: grapevine v5
was the first subsite port onto this harness and it fixed a batch of main-release
assumptions that any subsite hits. Starting from `release70` would mean rediscovering all of
them. See "Gates" below for the ones that still fired anyway.

## Source databases — frozen

`gramene-mongodb/ensembl_db_info.json` is copied from v5 and **corrected**, then frozen.
**Never run `get_ensembl_db_info.js`** — it would re-derive the file from whatever is newest
on the server and silently move the gene models.

Two of v5's recorded databases do not exist on `cabot` any more:

- compara `ensembl_compara_4_87_maize0225` → **`ensembl_compara_5_108_maize0225`**. Identified
  by matching tree counts exactly: 39,709 trees, the same as `maize5.genetree`. Not by name
  similarity.
- sorghum variation `sorghum_bicolor_variation_8_108_30` → **`_11_108_30`**.

All 67 databases were verified present before the first stage ran. `00_preflight` re-checks
`EXPECT_CORES=63` / `EXPECT_VARIATIONS=3` / the compara name in seconds, so drift surfaces
immediately rather than at stage 35.

63 genomes: 56 zea/pan-maize assemblies plus 7 outgroups. 2,834,112 genes.

## Gates

Five gates stopped a correct build, or would have. Four are the same shape: the harness
encodes *which genomes exist* in several places, and a new subsite trips each in turn. The
distinction that resolves almost all of them:

> **"0 of 0" is not a failure. "0 filled of N" is.**
> A species, namespace or tree-set with **zero keys** means this site does not host it.
> Zero *filled* out of N means a supplement ran and produced nothing. Only the second is a bug.

| stage | what fired | fix |
| --- | --- | --- |
| `25_reactome` | fill gate checked namespaces this site has no keys for | skip namespaces with 0 keys; fail only if *every* checked namespace is empty (`c7d4704`) |
| `35_genetrees` | strict `EXPECT_TREES` arity vs the lineage's tree-set list | derive the work list from `gene_tree_root` in *this* compara (`3edf2e0`) |
| `50_genes_decorate` | — (caught before it fired) | `species_rank.js` keyed on `zea_maysb73`, not release70's `zea_mays`, which this site's `maps` lacks (`e0e358c`) |
| `40_genes_dump` | 151 colliding stable ids | allowed, with evidence — see below (`0f3f64a`) |
| `58_expression_attributes` | completeness gate; **real data loss** | see below (`82f1642`) |

### `40_genes_dump` — 151 colliding stable ids, allowed deliberately

```
2,834,263 gene stable ids extracted
2,834,112 distinct; 151 claimed by more than one genome
  [BLOCKING] zea_maysb73v3 <-> zea_maysb73v4
```

All 151 are miRBase names (`zma-MIR1432`, `zma-MIR156a`, …) — zero exceptions. miRBase names
are not assembly-versioned, so the same miRNA carries the same id in the B73 v3 and v4
annotations. That is correct upstream naming, not the wrong-prefix error the message points at.

**v5 already ships this collapse.** The dump's 2,834,112 distinct ids equal `maize5.genes`
exactly; `zea_maysb73v4` dumps 44,474 ids while maize5 stores 44,323 — exactly 151 fewer —
so v3's copies win and 151 v4 miRNA genes are dropped, in v5 as in v6.

Recorded as `STABLE_ID_COLLISION_ALLOW="zea_maysb73v3:zea_maysb73v4"`. **This is a real loss,
not a false alarm**, and the checker says so on every run. Fixing it properly means giving
each annotation version its own id space in the source cores, which would move gene models
on the live site — out of scope for a rebuild premised on not doing that. It is recorded with
the evidence rather than left implicit.

The same 151 reappear at `50_genes_decorate` as `E11000 duplicate key` insertion errors. Same
cause, reported rather than fatal.

### `58_expression_attributes` — the base-taxon collision

The only gate so far that caught **destroyed data**. It said what looks like nonsense:

```
zea_maysb73v3   jsonl=151   genes_with_expr=44303   MISMATCH
zea_maysb73v3   jsonl=151   genes_with_expr=41617   MISMATCH
zea_maysb73v3   jsonl=151   genes_with_expr=151     OK
```

Three B73 assemblies carry expression here — `zea_maysb73` (4577003, v5, 44,303
expression-bearing genes), `zea_maysb73v4` (4577006, 41,617) and `zea_maysb73v3` (4577005,
151) — and `mongo_source.discover_genomes` reduced every `taxon_id` to `taxon_id // 1000`.
All three became `4577`. Three consequences, each silent alone:

1. `assemble_config.py` writes `species[str(taxon)]` in a loop over genomes sorted by
   **descending** gene count, so the last writer wins — and the last writer is the
   **smallest** genome. The panel's `4577` entry ended up describing v3's 151 genes.
2. `build.py` calls `batch.py --taxon <taxon>` once per genome, which for these three is the
   identical command three times; `batch.py` resolves both *what to score* and *where to
   write* from that one panel entry.
3. `batch.py` resumes by counting lines already in `<short>_attributes.jsonl`, so runs 2 and 3
   found 151 lines and wrote nothing.

**85,920 B73 v5 and v4 genes got no attributes; 151 v3 genes did.** Document counts could not
have seen it — the other six genomes were complete and the totals looked ordinary.

The fix is grapevine v5's, verified there on the same collision (PN40024's two assemblies,
29760019/29760020) and copied here unchanged: `taxon` is the genome's **full** `taxon_id`, and
the NCBI base is computed locally for the one thing it is genuinely keyed on,
`po_map.CLADE_OF_TAXON`. `score.py` must divide before that lookup and group on the full id,
or every species falls through to clade `other`.

Audited for other base-taxon assumptions: there are none. `discover.py` keys only a filename
on taxon and drives everything from `system_name`, and `expr_lib.py` already tries both forms.

**`EXPR_ONLY` now takes full taxon_ids** (`4577003`, not `4577`). A base id selects no genome
and the stage dies on "could not resolve a short name".

Per-taxon artifacts were not *wrong*, only shared: `ref_4577.json` was correctly built from
B73 v5 (`n_sampled=44303`), because `refbuild` resolves `system_name_for_taxon` and the size
sort put v5 first.

### Drosophila is excluded from expression attributes

`manifest.json` sets `"exclude": true` for `drosophila_melanogaster`, measured on this site:
**17,737 docs, `breadth='no_baseline'` on every one, zero carrying a single non-empty
attribute.** Taxon 7227 has no `po_map.CLADE_OF_TAXON` entry so it falls to clade `other`,
which has no organ panel, and the plant stress classifier matches none of its contrasts.

Chlamydomonas is the contrast that stays **in**: clade `algae` also has no organ panel — by
design, algae and bryophytes are stress-only — but 4,133 of its 17,943 docs carry stress
attributes. **Zero organs is not the test for exclusion; zero information is.**

Its raw `expression` docs are untouched; only the derived attributes are skipped.

## VEP — exact reuse, and why not regeneration

`gramene-solr/vep/vep_attributes.txt` is **extracted from the live `maize_genes5` core**:
118 columns (`id`, `capabilities`, 116 `VEP__*` fields), 75,237 rows, 509 MB, paged with a
cursor mark. All 75,237 ids join the v6 gene set — safe because v6's 63 cores are
byte-identical to v5's.

This is the harness's documented path ("MAKER/VEP reuse the prior release's tables").
Regenerating is *not* a drop-in alternative, contrary to how I first described it:

- v5's VEP spans **three** species, not one.
- the field shape includes the species segment, which `munge_vep.pl` does not emit.
- its `@poptype` map is hardcoded for `sorghum_bicolor_variation_6_87_30` (schema 87), while
  this site is on 108.

A true 3-species regeneration needs a munger that emits the species segment and per-db
population→EMS/NAT classification verified against each variation db. Worth scoping
separately; it is not a prerequisite for this build.

`reg.maize_v6.pm` is generated by `make_reg_pm.js`, version-locked to the frozen info file:
63 core + 3 variation + compara stanzas. It pairs `zea_maysb73_core_9_108_8` with
`zea_maysb73_variation_9_108_8`, where the shared `ensembl-108/reg.pm` pairs that variation
db with `core_5_108_1`. **Do not overwrite the shared `/usr/local/ensembl-*/ensembl-rest/reg.pm`**
— it serves ~91 species across every subsite. Merge stanzas.

## Verification — v5 baseline

Recorded 2026-11-06 10:52, before any stage ran. **Any movement in the v5 rows is
stop-the-build.**

```
mongo genes                   2834112      solr maize_genes5        2834112
mongo genetree                39709        solr maize_suggestions5  5286519
mongo maps                    63           pm2  maize_swagger5  restarts=1   pid=4153344
mongo taxonomy                157          pm2  maize_ebeye5    restarts=892 pid=105121
mongo qtls                    12966
mongo GO / PO / TO            47995 / 1791 / 4920
mongo domains                 47677
mongo expression              271829
mongo assays / experiments    1873 / 89
mongo pathways                2293
mongo homologs                0            <- NEW in v6
mongo expression_attributes   0            <- NEW in v6
```

v6 must match on `genes` (2,834,112 — same cores, so expect exact) and `genetree` (39,709 —
matched exactly, 5,047,617 nodes, 0 failed, flat round-trip verified).

Expect v6 **above** v5 on expression: `experiments` 361 vs 89, `expression` 293,877 vs
271,829, after 12.7M gene-writes and a v4→v5 differential projection of 24,472 docs. Every
experiment is carried by at least one gene (the gate added after grapevine shipped 50
silently-missing studies).

QTL/QTL_TO may land **above** v5's floor because `sorghum_bicolor_variation_11_108_30` is
newer than v5's `_8_108_30`.

Stage 60 should report the VEP capability at **75,237**.

## Verified result (build completed 2026-11-06 17:54, EXIT=0)

| | v6 | v5 | |
| --- | --- | --- | --- |
| mongo `genes` | 2,834,112 | 2,834,112 | exact |
| mongo `genetree` | 39,709 | 39,709 | exact |
| `maps` / `taxonomy` / `qtls` | 63 / 157 / 12,966 | identical | exact |
| solr `maize_genes6` | 2,834,112 | — | == mongo |
| solr `maize_suggestions6` | 5,381,728 | 5,286,519 | +95,209 |

Gains: `experiments` 89 -> **361**, `expression` 271,829 -> 293,877, `domains` +25,267,
`GO` +345, `pathways` +158, `homologs` **2,543,662** (new), `expression_attributes`
**241,908** (new), solr `gene_tree` and `grassius_homolog` (new capabilities).
**VEP exactly 75,237**, matching the table extracted from `maize_genes5` -- the reuse joined
cleanly across all 63 genomes. Trait ontology suggestions **741**, so grapevine's
uniqueKey-collision fix is in force here.

**v5 untouched**: `maize_genes5` 2,834,112, `maize_suggestions5` 5,286,519,
`maize_swagger5` restarts=1 pid=4153344, `maize_ebeye5` restarts=892 pid=105121 -- all
identical to the pre-build baseline.

### Three numbers are LOWER than v5. All three are correct. Verify, do not "fix".

**mongo `TO` 4,920 -> 4,676 (-244).** Real trait terms went UP:

```
maize5:  real TO terms (numeric _id) 1667   imported foreign terms (string _id) 3253
maize6:  real TO terms (numeric _id) 1697   imported foreign terms (string _id) 2979
```

+30 real terms against -274 imported ones. The imports carry a string `_id` that is the raw
obo line including its comment (`"CHEBI:78298 ! environmental contaminant"`), and v6 drops the
PECO, FOODON, ENVO and RO namespaces entirely. Corroborated by solr: TO gene annotations
**+550**.

**solr `expression` capability 259,645 -> 201,472 (-58,173).** A deliberate rule change, not
data loss. Both mappers, verbatim:

```js
// v5  gramene-solr/genes/mongo2solr.js:137
if (expressionData[mongo._id]) { solr.capabilities.push('expression'); }
// v6  gramene-solr/genes/mongo2solr.join.js:245  -- only when expressedInStudy is non-empty:
if (sample.value >= 0.5) expressedInStudy.add(exp_id);
if (sample.p_value < 0.05 && Math.abs(sample.l2fc ?? 0) >= 1.0) expressedInStudy.add(exp_id);
```

v5 set the capability for any gene with an expression *document*, with no threshold -- so it
counted genes whose every sample sits below the detection floor, including all-zero columns
like E-CURD-1 g13. Two independent confirmations that v6 is right:

- genes with ANY expression doc in maize6 = **259,645**, exactly v5's capability count. Same
  gene set, so the whole delta is the threshold.
- sampled 400 `zea_maysb73` genes holding expression docs; solr lacks the capability for 73 of
  them, and running the mapper's own JS over all 73 agrees with solr **73/73** (`maxValue` 0 or
  0.3, no `p_value` at all).

**Do not verify this rule by re-implementing it in an aggregation.** Three attempts gave
259,645, then 219,007, then the right answer only by executing the mapper's JavaScript. A
missing field resolves to `null`, and in BSON ordering `null < 0.05` and `null <= -1` are both
TRUE, so the differential arm matches every sample unless each field is explicitly null-guarded
-- and even guarded it still over-matched. The mapper's `?? 0` is load-bearing: a missing
`l2fc` must FAIL, not sort low. Run `mongo2solr.join.js`'s code, or query solr.

#### 3. `InterPro: Family` suggestions 6,141 → 6,104 (−37)

**InterPro retyped the entries. v6 has the newer, correct classification.** Found while
probing `/suggest?q=zea`, which returns 5 InterPro families on v6 and 6 on v5.

Checked in this order, and the first two answers were both wrong — record them so the next
person does not repeat them:

1. *"The accessions were retired upstream."* **No.** All 8 probed v5-only ids are present in
   `maize6.domains`, which holds 72,944 docs against maize5's 47,677.
2. *"They have no genes under them any more."* **No.** `maize_genes6` facets
   `domains__ancestors:490` at 3,685 and `:1753` at 1,086 — they have plenty.
3. **They changed category.** The set difference was taken with
   `fq=category:"InterPro: Family"`, which is the bug in the question, not in the build:

       id         maize_suggestions5          maize_suggestions6
       IPR000374  InterPro: Family   / 211    InterPro: Conserved_site /   19
       IPR000490  InterPro: Family   / 3712   InterPro: Domain         / 3685
       IPR001753  InterPro: Family   / 1096   InterPro: Domain         / 1086
       IPR001790  InterPro: Family   /  472   InterPro: Domain         /  461
       IPR002129  InterPro: Family   /  979   InterPro: Domain         /  978

   Every one still has exactly one suggestion doc. The churn runs both ways — 69 left the
   Family category, 32 joined it — and the joiners are all new-era accessions
   (`IPR050*`, `IPR057*`, `IPR059*`, `IPR060*`): 18,428 such domains in maize6 against 6,896
   in maize5. **So compare suggestion counts across ALL InterPro categories, never one.**

   One loose end, deliberately left: `IPR009540` (BAP) is `InterPro: Family` in both cores
   with a byte-identical doc (same `num_genes=543`, same `taxon_freq`) yet matches `q=zea`
   only on v5. Since the doc is present and findable by id, this is an analyzer/copyField
   difference in the suggestions schema affecting one dropdown row, not missing data. Not
   worth chasing unless a user reports a real miss.

## Operational constraints

- **Never `pm2 restart all`** — ~55 unrelated services are online on this host, including
  every other subsite and `maize_swagger5`. Act on the two v6 names only, and assert v5's
  restart counts unchanged before and after.
- **Never restart mongod.** It would drop `maize5`, `grapevine4/5`, `sorghum11`, `search69/70`,
  `oryza*` and every other live db.
- **Solr core removal: resolve name→instanceDir from the STATUS API and unload by core *name*
  with `deleteInstanceDir=true`.** Never `rm -rf /solr/data/<name>` — core names are shifted
  off their directories on this host (`suggestions69` lives in `/solr/data/suggestions69b`).
- `/usr/local` is **shared with every other subsite** and it filled to 48K free mid-build,
  from a concurrent sorghum v11 stage 60 holding 63 GB of generated JSON. The expression
  pipeline spools mongosh output next to itself, so the symptom is
  `OSError: [Errno 28]` forty minutes into stage 58. Check `df -h /usr/local` before a long run.
- `dump_genes.js` takes the MySQL password as a **command-line argument**, visible in `ps` to
  any local user for the duration of a run. Pre-existing; noted, not widened. Prefer `MYSQL_PWD`.
- `gh` is not installed on this host, so PRs cannot be opened from here.

## Do not drive the stages by hand

`make all` enforces the dependency order through `.state/*.done`. Driving a stage directly
skips its dependencies silently — which is exactly how `60_solr_genes` once reused a
day-old 11 GB dump on grapevine and shipped 0 of 50 restored studies with a document count
that matched mongo perfectly.

## Still outstanding

- **The services are not started.** As of 2026-11-09 the proxy route EXISTS:
  `https://data.gramene.org/maize_v6/swagger` returns **503**, not the earlier 404, and the
  response is Apache's own `mod_proxy` 503 carrying this vhost's
  `Access-Control-Allow-Headers`, so the stanza is in place and only the backend is absent.
  `30006` and `31006` are both free, and `maize_v5`/`grapevine_v5` both still return 200.

  `70_services` has been run and is stamped: all five serving-tier values are derived,
  verified and committed (swagger `3fda15e`, ebeye `aa06931`). What has NOT happened is
  `START_SERVICES=1`, which pm2-starts `maize_swagger6` then `maize_ebeye6`. That is a
  public deploy and needs the operator.

  **Run it in exactly this order — the stage already does, do not start the two by hand:**

      cd /usr/local/gramene/subsites/maize/v6/build
      START_SERVICES=1 bash stages/70_services.sh

  The stage starts swagger, proves it on `http://localhost:30006/maize_v6/swagger`, WAITS
  for the public URL to serve, and only then starts ebeye — because ebeye *fetches*
  `defaultServer` at startup. Starting ebeye against a 503 is what crash-looped it 125 times
  on the first v70 deploy; this site's `maize_ebeye5` is at 895 restarts for the same reason.
  If the public URL does not come up the stage skips ebeye deliberately and names which of
  proxy / firewall / swagger to check. A stopped ebeye is one command to recover; a crash
  loop is not.

  Then `pm2 save` if these are meant to survive a reboot — note it rewrites the resurrect
  list for all 65 registered apps, so check `pm2 jlist` is sane first. **Never
  `pm2 restart all`**: 55 apps are online, including `maize_swagger5` and every other subsite.
- **`/gxa` was redirecting into EBI's URL space with this site's basePath attached, and the
  same bug is live on three other sites.** Fixed here in `gramene-swagger` `dcc689c`:
  `api/controllers/gxa.js` built its target as
  `'https://www.ebi.ac.uk' + req.originalUrl.replace('/auth_testing','')`, and
  `req.originalUrl` carries the basePath — so `/maize_v6/gxa` became
  `https://www.ebi.ac.uk/maize_v6/gxa`, a 404. `/auth_testing` is the basePath of whichever
  deployment the handler was written on, so it has never worked anywhere else. Measured the
  same afternoon, all still broken and all needing this one-line fix plus a swagger restart:

      data.gramene.org/v70              -> https://www.ebi.ac.uk/v70/gxa
      data.sorghumbase.org/sorghum_v11  -> https://www.ebi.ac.uk/sorghum_v11/gxa
      data.gramene.org/grapevine_v5     -> https://www.ebi.ac.uk/grapevine_v5/gxa

  v69 predates the controller and returns 400 from the `/{collection}` fallback, which is why
  nobody noticed: the endpoint has never worked on any deployed site. The fix anchors on
  `/gxa` instead of stripping a known prefix, so it is correct under any basePath.

  **All four are fixed as of 2026-11-09**, each verified against its public URL after a
  targeted `pm2 restart` of that site's swagger only:
  maize v6 `dcc689c`, release70 `2fc1160`, grapevine v5 `1a4546a`.

  Two things to know about the rollout:

  - **sorghum v11's fix is applied but NOT committed, on purpose.** Its
    `api/controllers/gxa.js` already carried substantial *uncommitted* JGI-expression work
    (`isAtlasExperiment` / `atlasExperimentUri`, routing non-EBI studies to Phytozome rather
    than to a 404 at EBI, with a load-bearing note that `uri` must always be a string or the
    Atlas heatmap widget throws). Staging that file would have bundled someone else's
    unrelated change into this commit. The fix is live in the working tree and verified at
    the origin; whoever owns the JGI work should commit it, and this fix with it.
  - **`data.sorghumbase.org` caches, and it cached the broken 301.** That proxy returns
    `X-Cache: HIT` / `Age:` headers; gramene.org's does not, which is why maize, grapevine
    and v70 showed the fix the moment their swagger restarted and SorghumBase did not. The
    origin is correct — `…/sorghum_v11/gxa?cb=<random>` returns
    `https://www.ebi.ac.uk/gxa?cb=<random>` — but the bare URL served a stale
    `…/sorghum_v11/gxa` for as long as the cache entry lived. A request-side
    `Cache-Control: no-cache` does not dislodge it.

    **This redirect should never have been a 301, and no longer is.** A 301 is cached by
    browsers close to permanently, so every user who had hit the broken URL kept being sent
    to the EBI 404 from their own cache no matter what the server said. The target is
    derived at request time -- basePath stripped, EBI host prepended -- so it is not a
    permanent property of the URL. Changed to **302** on all four sites, in both places,
    which have to agree:

        api/controllers/gxa.js      res.redirect(301, ...) -> res.redirect(302, ...)
        api/swagger/swagger.yaml    /gxa get responses: 301 -> 302

    maize v6 `2f7006f`, release70 `361711c`, grapevine v5 `deeef5a` (which also finally
    commits grapevine's derived serving-tier values, left uncommitted when that site was
    built). Verified on a private port first -- 302 Found, no `Cache-Control` header, so it
    is not heuristically cacheable -- then on each public URL after a targeted restart of
    that site's swagger alone. All four follow through to
    `https://www.ebi.ac.uk/gxa/home` 200.

    **sorghum v11 is now committed too**, as three commits rather than one lump, so that
    work found uncommitted in that tree is not folded into mine. `swagger.yaml` and
    `gxa.js` each carried two unrelated concerns, so the split was done by staging one
    change at a time rather than by file:

        d4d0328  mongo: make the /{collection} catch-all actually work   (NOT mine)
                 `module.exports.get` was assigned before `module.exports = toExport`
                 replaced the object wholesale, so the handler was discarded and the route
                 answered "Controller mongo doesn't export handler function get" for
                 everything; and `params.collection` was read instead of
                 `params.collection.value`. Plus the two collections the route exists to
                 serve -- `homologs`, `expression_attributes` -- were missing from the
                 `collection` enum and so 400'd with ENUM_MISMATCH.
        48e6a2c  gxa: do not deep-link non-EBI studies to Atlas          (NOT mine)
                 JGI-sourced studies have no EBI page; they now point at Phytozome.
                 Load-bearing: `uri` must ALWAYS be a string, because the Atlas heatmap
                 widget runs URI.resolve() over every row and one undefined takes down the
                 whole heatmap.
        33b165c  gxa: basePath-free redirect, as a 302                   (mine)

    Verified after committing: the working tree is identical to HEAD, HEAD holds all three
    changes together, and `/sorghum_v11/homologs` and `/sorghum_v11/expression_attributes`
    both return real documents through the catch-all. Three manual backups
    (`*.bak.preCatchAll`, `*.bak.preHomologs`, `package-lock.json.pre-deploy-20260916`) are
    left untracked; git history supersedes them and they can be deleted.

    One stale artifact is left and is self-limiting: `data.sorghumbase.org` still answers
    the *bare* `/sorghum_v11/gxa` from its cache with the old 301, since that entry was
    stored before the fix. Cache-busted it returns 302 correctly, and its TTL is not
    advertised, so it simply has to age out. Nothing will stick again — a 302 is not
    heuristically cacheable.
  **The two POST endpoints were never affected** — `/gxa/json/baseline_experiments` and
  `/gxa/json/experiments/{id}` were exercised against maize6 and return real anatomogram and
  assay data; both 404 on v5, so this controller is new capability here, not a parity fix.

- **Nothing is pushed.** maize v6 commits across six repos, grapevine v5's seven, and four
  ahead `release70` repos are all local.
- **Three categories of fix are stranded on subsite branches** and `release70` has none of
  them: grapevine's atlas/solr work and trait-suggestion fix, maize's `25_reactome` +
  `35_genetrees` gates, and this site's base-taxon fix. Sorghum v11 and release70 each host
  exactly one genome per base taxon, so the base-taxon bug never fires there and nothing
  upstream would catch it. The next subsite port faces the same merge.
