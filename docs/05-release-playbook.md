# Release playbook

How to cut the next main release (v71) from this one. This is the path v70 took, with the mistakes
removed.

Budget **several days** of wall-clock, not the subsite's one day: the build alone runs well over a
day at 16.1M genes (`45_homologs` measured 1 h 40 m, and the decorate and Solr load scale by ~3x
from the subsite's figures), plus verification and the manual infra steps.

v70 was a *port* — the staged pipeline came from the SorghumBase v11 subsite and had to be
propagated onto main-release config. **v71 does not repeat that.** Branch from `release70` /
`main_v70` and the pipeline comes with you. If you ever do need to pull subsite work across again,
note what bit v70: `gramene-mongodb-config` must be hand-edited rather than cherry-picked (the
branches disagree on `dbName`/`dbVersion`), and the commit that regenerates `ensembl_db_info.json`
must be skipped or it destroys the core configuration.

---

## 1. Choose the source databases — before anything else

This is the step most worth slowing down on. Everything downstream inherits its mistakes, and the
symptoms surface hours later as plausible-looking wrong numbers.

```sql
-- on colden
SHOW DATABASES LIKE '%_core_71_%';
SHOW DATABASES LIKE 'ensembl_compara_plants_71%';
SHOW DATABASES LIKE '%_variation_71_%';
```

Rules learned the hard way:

* **A genome may have several core databases for the same release** (`…_core_71_116_1` *and*
  `…_core_71_116_2`). Pick the one that was **actually used in the compara run** — not the
  highest-numbered one. Verify by cross-checking gene stable ids against compara's `gene_member`
  table. A pattern-match that catches both variants silently adds phantom genomes.
* **Variation databases are opt-in per purpose.** v70 carries 24 of them for **QTLs only** — not
  for loss-of-function genotype extraction, which is a subsite feature. Be explicit about why each
  variation db is in the set.
* Get the genome set reviewed by whoever ran compara before you build.

Write the result into `gramene-mongodb/ensembl_db_info.json` — cores, variations, compara, and the
`anchor` flags. Then update the expectations in `config.sh`:

```bash
export EXPECT_CORES=…      # 267 for v70
export EXPECT_ANCHORS=…    # 0 for a main release -- anchors are a SorghumBase concept
export EXPECT_VARIATIONS=… # 24
```

`00_preflight` enforces these, so a miscount fails in seconds instead of at ingest. Leave
`EXPECT_ANCHORS=0` unless the main release starts designating anchor genomes; it is a real
expectation here, not an unfilled blank.

⚠️ **Do not let anything regenerate `ensembl_db_info.json` after you have curated it.** It is the
record of the choices made in this step, and one of the ETL repos carries a script that rebuilds it
from a database pattern — which is exactly the pattern-match this section warns about.

## 2. Set up the release tree

```bash
cp -r /usr/local/gramene/release70 /usr/local/gramene/release71
cd /usr/local/gramene/release71
for r in build gramene-mongodb gramene-solr gramene-swagger gramene-ebeye; do
  git -C $r checkout -b release71
done
git -C gramene-mongodb-config checkout -b main_v71
```

Then, in order:

1. **`gramene-mongodb-config/collections.js`** — bump `dbVersion` to `71`. This is the single source
   of truth; `config.sh` reads the db name and version from it, and everything else follows. Do not
   hardcode `search71` anywhere.
2. **`build/config.sh`** — update the `EXPECT_*` counts and `COMPARA_DB`. `RELEASE_ROOT` and the
   per-stage paths derive from the script's own location, so nothing else should need changing; if
   you are editing a path in a stage script, put it in `config.sh` instead.
3. **`build/stages/05_install.sh`** then `00_preflight` — confirm every collection resolves, and
   that `node_modules/gramene-mongodb-config` is a **symlink** in all four consumer repos (the
   stage only reports on two; npm replacing that symlink with a copy is a live failure mode).
4. **Carry `reactome/Ensembl2PlantReactomeReactions_Zmy_ver5.txt` forward.** The `cp -r` does this
   for you, but if you check the repos out fresh instead, note that this file is not published
   upstream and maize pathways depend on it.

## 3. Build

```bash
cd build
make all
```

**Before the decorate**, cap mongod's cache or the box swaps — see
[the resource notes](../README.md#resource-notes-for-this-host). Also check `/solr` headroom: the
genes core projects to ~60 GB, and freeing space by deleting old cores requires resolving core
name → `instanceDir` first, because on this host they do not match.

Two stages depend on external HTTP and will simply sit there if the service is down:
`25_reactome` (Plant Reactome's ContentService — Gramene-operated, so ask for a restart) and
`55_atlas` (EBI GXA). A hang with no output is as likely to be an unresponsive dependency as a bug.

Watch it with `make running` and `tail -f logs/<stage>.log`. See
[docs/02-build-runbook.md](02-build-runbook.md) for resuming and refreshing, and
[docs/04-troubleshooting.md](04-troubleshooting.md) if a stage stalls.

## 4. Regenerate the attribute tables (only if their sources changed)

* **MAKER and VEP are not used in a main release.** `MAKER_TABLE` and `VEP_TABLE` stay empty and
  stage 60 warns and skips them. Leave them alone unless the main release takes on those
  capabilities.
* **Grassius / grassius_homolog** — `grassius_homolog` is regenerated every build and is the layer
  that actually covers maize. `28_grassius_source` can refresh `grassius.tsv` from grassius.org but
  is deliberately outside `make all`: GRASSIUS publishes v3/v4 maize ids while this release's maize
  is v5, so coverage from source is near zero for maize. The checked-in file is what the build
  reads.

## 5. Verify before publishing

See [docs/02-build-runbook.md](02-build-runbook.md#verifying-a-finished-build). Compare against the
previous release rather than absolute numbers. In particular check:

* Solr genes count ≈ Mongo genes count ≈ `sum(maps.num_genes)`, and plausibly larger than the
  previous release (v70: 16,127,051 against v69's 11,773,843)
* every genome present in `maps` with a sane `num_genes` and the correct `taxon_id`; no genome more
  than 1% short of its `maps.num_genes`
* attribute coverage (`grassius_homolog__attr_ss`, `capabilities:expression`) did not drop
* maize pathways are present — `capabilities:pathways AND system_name:zea_mays` should be ~1,518,
  not 0. This is the check that catches a missing ZMY supplement, and it is worth running because
  v11 shipped with it at 0.
* no rsID suggestion category leaked in from a subsite branch
* the suggestions core's primary-id count equals the genes core
* a handful of real gene lookups through the API

## 6. Propagate user gene lists

User lists live in `userData1` and are keyed to Solr docs by a `saved_search` hash, so they must be
re-tagged into the new core:

```bash
make restore-saved-search DRY=1     # then without DRY
```

It derives the cores from `config.sh` (`PREV_LIVE_GENES_CORE` → `SOLR_GENES_CORE`) and reads
`userData1` alone. Set `PREV_LIVE_GENES_CORE` if the live core is not `genes<version-1>`.

Check the reported numbers against `genelists` rather than assuming: a hash with no surviving
metadata row is correctly skipped, so "0 restored" can be the right answer. v70 restored 0 of 14
for exactly that reason.

## 7. Services

```bash
make 70_services              # edits ports/basePath, verifies them, prints the infra checklist
START_SERVICES=1 make 70_services   # …and pm2-starts swagger + ebeye
```

Ports follow `10000 + version` (swagger) and `11000 + version` (ebeye), and `basePath` is a bare
`/v<version>` — the `<species>_v<N>` form and the 50000+ block belong to the subsites. Check the
target ports are free across *all* releases on the host before starting; there are 59 pm2 processes
here.

## 8. The manual infra steps

`70_services` prints these because the build cannot safely automate them:

1. **Apache reverse proxy** on gorgonzola (`conf/extra/httpd-ssl.conf`, under
   `data.gramene.org`): `/v71` → `squam:10071`, then
   `apachectl configtest && apachectl graceful`
2. **Firewall** — open 10071 and 11071
3. **Ensembl REST registry** — add the new cores/compara/variation to the shared registry and
   restart REST. Use `merge_reg_pm.pl` (see below); do not hand-edit the shared file.
4. **BLAST** — re-run `ensure_blast.pl` with the updated registry, then restart `gramene-blast`
   under pm2
5. **Gene-tree curation UI** (`gramene-genetree-vis`) — point `defaultServerSb` at the new swagger

### The Ensembl REST registry

The shared registry at `/usr/local/ensembl-87/ensembl-rest/reg.pm` serves **91 species across every
subsite**. A main release adds its several hundred databases (v70: 267 cores + compara + 24
variation) without disturbing the rest.

Note that this local registry is **not** what the build uses for maps QC — that is
`https://rest.ensembl.org`, because the local one resolves none of a main release's genomes. The
registry still matters for the genome browser and BLAST.

Generate the release's own registry, then merge:

```bash
node make_reg_pm.js > reg.pm                      # from ensembl_db_info.json
PERL5LIB=$(ls -d /usr/local/ensembl-115/*/modules | tr '\n' ':') \
  perl merge_reg_pm.pl <shared-reg.pm> reg.pm > merged.pm 2> conflicts.txt
```

`merge_reg_pm.pl` **loads** each registry with Perl rather than parsing it as text — necessary
because real registries build adaptors in loops (`for my $core (@core_10_108_2) { … }`), which no
text parser handles. Later files win on `(species, group)`; conflicts are reported on stderr with
file:line. Read `conflicts.txt` before installing, then `perl -c merged.pm`.

## 9. Keep the previous release alive

The old release stays live until the new one is verified in production. Do not drop its Mongo db or
Solr cores, do not stop its pm2 processes, and do not edit files under its directory — some are
shared by symlink.

Two specific hazards when reclaiming space on this host:

* **Resolve Solr core name → `instanceDir` before deleting anything.** They do not match here, and
  the directory named after the live core may well be a disposable copy. Unload by **name** with
  `deleteInstanceDir=true` and re-query the live core between deletions.
* **Capping mongod's WiredTiger cache is safe while the old release serves** — it is a runtime
  change needing no restart, and r69 kept answering in under 15 ms through a 125 GB → 64 GB cap.
  Restarting mongod is not the same thing, and drops every release at once.
