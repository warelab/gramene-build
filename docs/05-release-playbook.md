# Release playbook

How to cut the next release (v12) from scratch. This is the path v11 took, with the mistakes removed.

Budget roughly a day of wall-clock: ~4 h of build plus verification, plus the manual infra steps.

---

## 1. Choose the source databases — before anything else

This is the step most worth slowing down on. Everything downstream inherits its mistakes, and the
symptoms surface hours later as plausible-looking wrong numbers.

```sql
-- on cabot
SHOW DATABASES LIKE '%_core_12_%';
SHOW DATABASES LIKE 'ensembl_compara_12%';
SHOW DATABASES LIKE '%_variation_%';
```

Rules learned the hard way:

* **A genome may have several core databases for the same release** (`…_core_12_108_1` *and*
  `…_core_12_108_2`). Pick the one that was **actually used in the compara run** — not the
  highest-numbered one. Verify by cross-checking gene stable ids against compara's `gene_member`
  table. A pattern-match that catches both variants silently adds phantom genomes.
* **Variation databases are opt-in per purpose.** v11 includes `oryza_sativa_variation_9_108_7` for
  its **QTLs only** — not for loss-of-function genotype extraction. Be explicit about why each
  variation db is in the set.
* Get the genome set reviewed by whoever ran compara before you build.

Write the result into `gramene-mongodb/ensembl_db_info.json` — cores, variations, compara, and the
`anchor` flags. Then update the expectations in `config.sh`:

```bash
export EXPECT_CORES=…      # 128 for v11
export EXPECT_ANCHORS=…    # 9
export EXPECT_VARIATIONS=… # 2
```

`00_preflight` enforces these, so a miscount fails in seconds instead of at ingest.

## 2. Set up the release tree

```bash
cp -r /usr/local/gramene/subsites/sorghum/v11 /usr/local/gramene/subsites/sorghum/v12
cd /usr/local/gramene/subsites/sorghum/v12
for r in build gramene-mongodb gramene-mongodb-config gramene-solr gramene-swagger gramene-ebeye; do
  git -C $r checkout -b sorghum_v12
done
```

Then, in order:

1. **`gramene-mongodb-config/collections.js`** — bump the version. This is the single source of
   truth; `config.sh` reads the db name and version from it, and everything else follows. Do not
   hardcode `sorghum12` anywhere.
2. **`build/config.sh`** — update `RELEASE_ROOT` and the `EXPECT_*` counts. Nothing else should need
   changing; if you are editing a path in a stage script, put it here instead.
3. **`build/stages/05_install.sh`** then `00_preflight` — confirm all 16 collections resolve.

## 3. Build

```bash
cd build
make all
```

Watch it with `make running` and `tail -f logs/<stage>.log`. See
[docs/02-build-runbook.md](02-build-runbook.md) for resuming and refreshing, and
[docs/04-troubleshooting.md](04-troubleshooting.md) if a stage stalls.

## 4. Regenerate the attribute tables (only if their sources changed)

* **MAKER** — only when new MAKER annotations arrive. `../gramene-solr/maker_pipeline/`, then point
  `MAKER_TABLE` at the new file. **Do not edit a previous release's table** — v10 serves its copy
  through a symlink.
* **VEP** — only when the variation database changes.
  `vep/dump_gene_level_VEP_table.pl --registry <reg.pm> -s <species>` → `vep/munge_vep.pl`, then
  point `VEP_TABLE` at it.
* **Grassius / grassius_homolog** — `grassius_homolog` is regenerated every build. For a fresh
  Grassius download, `make refresh-grassius` (it *merges* rather than replaces — the grassius.org
  download currently has less sorghum coverage than the curated file).

## 5. Verify before publishing

See [docs/02-build-runbook.md](02-build-runbook.md#verifying-a-finished-build). Compare against the
previous release rather than absolute numbers. In particular check:

* Solr genes count ≈ Mongo genes count, and both plausibly larger than the previous release
* every genome present in `maps` with a sane `num_genes` and the correct `taxon_id`
* attribute coverage (`capabilities:MAKER`, `capabilities:VEP`) did not drop
* the suggestions core's primary-id count equals the genes core
* a handful of real gene lookups through the API

## 6. Propagate user gene lists

User lists live in `userData1` and are keyed to Solr docs by a `saved_search` hash, so they must be
re-tagged into the new core:

```bash
cd ../gramene-solr
MONGO_URL='mongodb://localhost:27017/userData1,mongodb://localhost:27017/sorghum11' \
SOURCE='http://localhost:8983/solr/sorghum_genes11' \
TARGET='http://localhost:8983/solr/sorghum_genes12' \
node scripts/sync_saved_search.js --dry-run    # then for real
```

## 7. Services

```bash
make 70_services              # edits ports/basePath, verifies them, prints the infra checklist
START_SERVICES=1 make 70_services   # …and pm2-starts swagger + ebeye
```

Ports follow `10000 + version` (swagger) and `11000 + version` (ebeye). Check the target ports are
free across *all* releases on the host before starting — this host runs a dozen.

## 8. The manual infra steps

`70_services` prints these because the build cannot safely automate them:

1. **Apache reverse proxy** on gorgonzola (`conf/extra/httpd-ssl.conf`, under
   `data.sorghumbase.org`): `/sorghum_v12` → `squam:50012`, then
   `apachectl configtest && apachectl graceful`
2. **Firewall** — open 50012 and 51012
3. **Ensembl REST registry** — add the new cores/compara/variation to the shared registry and
   restart REST. Use `merge_reg_pm.pl` (see below); do not hand-edit the shared file.
4. **BLAST** — re-run `ensure_blast.pl` with the updated registry, then restart `gramene-blast`
   under pm2
5. **Gene-tree curation UI** (`gramene-genetree-vis`) — point `defaultServerSb` at the new swagger

### The Ensembl REST registry

The shared registry at `/usr/local/ensembl-87/ensembl-rest/reg.pm` serves **91 species across every
subsite**. A release adds its ~131 databases without disturbing the rest.

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
