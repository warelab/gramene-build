#!/usr/bin/env python3
"""rescue_descriptions.py -- copy gene.description from the release-69 (e114) cores into the
release-70 (e116) cores, for genes that exist in both.

Why: the e116 cores ship with gene.description almost entirely empty. Across the 225 species with a
core in both releases, 2,323,799 genes lost a description that e114 had, and only one e116 core
(arabidopsis) is above 50% coverage. The gene sets are the same size in every pair, so this is an
unpopulated column rather than a re-annotation. See build/docs/07-upstream-defects.md defect 7.

Matching, both conditions required:
  * identical `species.production_name` in the two cores' meta tables -- read from meta, never
    inferred from the database name;
  * identical gene.stable_id, both rows is_current=1.

It never overwrites: a gene is touched only where the e116 description IS NULL or ''. So running it
after a future core reload that fixes the column is a no-op rather than a regression.

It writes nothing itself. It emits four SQL scripts to run as a writer, in order -- the same
generate-backup-and-revert-together pattern as gramene-mongodb/legoo/, and for the same reason:
these tables are MyISAM, so there are no transactions and no rollback, and a revert reconstructed
later from memory is not a revert.

  01_rescue_preflight.sql   read-only. Re-checks production_name and row counts; stop if any differ.
  02_rescue_backup.sql      saves the gene_id/stable_id/description of every row the load will touch.
  03_rescue_load.sql        the UPDATEs.
  99_rescue_revert.sql      exact rollback, driven by those backup tables.

The copy happens server-side as a cross-database join, so no description text passes through this
script or through the SQL files. That keeps the load small and exact regardless of how many million
rows it moves.

usage:
  . /usr/local/gramene/release70/build/config.sh
  python3 -I rescue_descriptions.py                       # report only
  python3 -I rescue_descriptions.py --emit [--out DIR]    # also write the SQL
  python3 -I rescue_descriptions.py --emit --species brassica_napus glycine_max
"""

import io
import os
import subprocess
import sys

NEW_PAT = '_core_70_116_'
OLD_PAT = '_core_69_114_'
BAK = 'rescue_desc_bak'


def mysql(sql, db=None):
    user = os.environ.get('MYSQL_USER')
    host = os.environ.get('MYSQL_HOST')
    if not user or not host:
        sys.exit('MYSQL_HOST/MYSQL_USER unset -- source build/config.sh first')
    cmd = ['mysql', '-h', host, '-u', user]
    pw = os.environ.get('MYSQL_PASS')
    if pw:
        cmd.append('-p' + pw)
    cmd += ['-N', '-s']
    if db:
        cmd += ['-D', db]
    cmd += ['-e', sql]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         universal_newlines=True)
    out, err = p.communicate()
    if p.returncode:
        sys.exit('mysql failed: ' + err.strip())
    return [l.split('\t') for l in out.splitlines()]


def production_names(db):
    """species_id -> production_name, from meta. Never inferred from the database name."""
    rows = mysql("SELECT IFNULL(species_id,1), meta_value FROM meta "
                 "WHERE meta_key='species.production_name'", db)
    return {r[0]: r[1] for r in rows if len(r) == 2}


def main():
    emit = '--emit' in sys.argv
    outdir = 'sql_rescue'
    if '--out' in sys.argv:
        outdir = sys.argv[sys.argv.index('--out') + 1]
    want = []
    if '--species' in sys.argv:
        want = [a for a in sys.argv[sys.argv.index('--species') + 1:] if not a.startswith('-')]

    dbs = [r[0] for r in mysql('SHOW DATABASES') if r and r[0]]
    new_cores = sorted(d for d in dbs if NEW_PAT in d)
    old_cores = sorted(d for d in dbs if OLD_PAT in d)
    print('e116 cores: %d    e114 cores: %d' % (len(new_cores), len(old_cores)))

    # production_name -> core, for the old release. A name appearing in two old cores is ambiguous
    # and is skipped rather than guessed at.
    old_by_name, ambiguous = {}, set()
    for db in old_cores:
        for pn in production_names(db).values():
            if pn in old_by_name:
                ambiguous.add(pn)
            old_by_name[pn] = db
    for pn in ambiguous:
        old_by_name.pop(pn, None)
    if ambiguous:
        print('skipping %d production_name(s) present in more than one e114 core: %s'
              % (len(ambiguous), ', '.join(sorted(ambiguous))))

    pairs, unpaired = [], []
    for db in new_cores:
        for pn in production_names(db).values():
            if want and pn not in want:
                continue
            old = old_by_name.get(pn)
            if old:
                pairs.append((pn, old, db))
            else:
                unpaired.append((pn, db))
    print('paired by production_name: %d    no e114 counterpart: %d\n' % (len(pairs), len(unpaired)))

    rescue_sql = (
        "  FROM `%s`.gene n\n"
        "  JOIN `%s`.gene o ON o.stable_id = n.stable_id\n"
        " WHERE n.is_current = 1 AND o.is_current = 1\n"
        "   AND (n.description IS NULL OR n.description = '')\n"
        "   AND o.description IS NOT NULL AND o.description <> ''")

    print('%-40s %10s %10s' % ('production_name', 'rescuable', 'e116 now'))
    print('-' * 62)
    todo, total = [], 0
    for pn, old, new in pairs:
        n = int(mysql('SELECT COUNT(*)\n' + (rescue_sql % (new, old)))[0][0])
        have = int(mysql("SELECT COUNT(*) FROM `%s`.gene WHERE is_current=1 "
                         "AND description IS NOT NULL AND description<>''" % new)[0][0])
        if n:
            todo.append((pn, old, new, n))
            total += n
        print('%-40s %10d %10d' % (pn, n, have))
    print('-' * 62)
    print('%-40s %10d' % ('TOTAL rescuable', total))
    if unpaired:
        print('\nno e114 core, nothing to rescue (%d): %s%s'
              % (len(unpaired), ', '.join(pn for pn, _ in unpaired[:6]),
                 ' ...' if len(unpaired) > 6 else ''))
    if not emit:
        print('\n(report only -- re-run with --emit to write the SQL)')
        return
    if not todo:
        print('\nnothing to emit')
        return

    os.makedirs(outdir, exist_ok=True)
    hdr = ("-- Generated by build/rescue_descriptions.py -- do not edit.\n"
           "-- gene.description rescued from the e114 cores into the e116 cores.\n"
           "-- Matched on species.production_name AND gene.stable_id, both rows is_current=1.\n"
           "-- Only rows whose e116 description IS NULL or '' are touched; nothing is overwritten.\n"
           "-- These tables are MyISAM: no transactions, no rollback. Run 02 before 03, or\n"
           "-- 99_rescue_revert.sql cannot restore exactly.\n\n")

    w = io.open(os.path.join(outdir, '01_rescue_preflight.sql'), 'w', encoding='utf-8')
    w.write(hdr + '-- Read-only. Every row must read OK. A count below its generated value means\n'
                  '-- the cores changed since generation; regenerate rather than running 03.\n\n')
    for pn, old, new, n in todo:
        w.write("SELECT '%s' AS production_name,\n" % pn)
        w.write("  (SELECT meta_value FROM `%s`.meta WHERE meta_key='species.production_name' LIMIT 1) AS e114_name,\n" % old)
        w.write("  (SELECT meta_value FROM `%s`.meta WHERE meta_key='species.production_name' LIMIT 1) AS e116_name,\n" % new)
        w.write("  (SELECT COUNT(*)\n%s) AS rescuable_now,\n" % (rescue_sql % (new, old)))
        w.write("  %d AS rescuable_at_generation;\n\n" % n)
    w.close()

    w = io.open(os.path.join(outdir, '02_rescue_backup.sql'), 'w', encoding='utf-8')
    w.write(hdr + '-- Saves what the load will overwrite. Refuses to clobber an existing backup,\n'
                  '-- because a second backup taken after a load restores the load, not the original.\n\n')
    for pn, old, new, n in todo:
        w.write("SELECT IF((SELECT COUNT(*) FROM information_schema.TABLES\n"
                "            WHERE TABLE_SCHEMA='%s' AND TABLE_NAME='%s')=0,\n"
                "          'ok: no previous backup for %s',\n"
                "          'ABORT: %s.%s already exists -- revert or drop it first') AS backup_guard;\n"
                % (new, BAK, pn, new, BAK))
        w.write("CREATE TABLE `%s`.`%s` (\n"
                "  gene_id INT UNSIGNED NOT NULL PRIMARY KEY,\n"
                "  stable_id VARCHAR(128) NOT NULL,\n"
                "  description TEXT\n"
                ") ENGINE=MyISAM;\n" % (new, BAK))
        w.write("INSERT INTO `%s`.`%s` (gene_id, stable_id, description)\n"
                "SELECT n.gene_id, n.stable_id, n.description\n%s;\n\n" % (new, BAK, rescue_sql % (new, old)))
    w.close()

    w = io.open(os.path.join(outdir, '03_rescue_load.sql'), 'w', encoding='utf-8')
    w.write(hdr + '-- The copy is a cross-database join: the text never leaves the server.\n\n')
    for pn, old, new, n in todo:
        w.write("SELECT IF((SELECT COUNT(*) FROM information_schema.TABLES\n"
                "            WHERE TABLE_SCHEMA='%s' AND TABLE_NAME='%s')=1,\n"
                "          'ok: backup present for %s',\n"
                "          'ABORT: run 02_rescue_backup.sql first') AS load_guard;\n" % (new, BAK, pn))
        w.write("UPDATE `%s`.gene n\n"
                "  JOIN `%s`.gene o ON o.stable_id = n.stable_id\n"
                "   SET n.description = o.description\n"
                " WHERE n.is_current = 1 AND o.is_current = 1\n"
                "   AND (n.description IS NULL OR n.description = '')\n"
                "   AND o.description IS NOT NULL AND o.description <> '';\n" % (new, old))
        w.write("SELECT '%s' AS production_name, ROW_COUNT() AS updated, %d AS expected;\n\n" % (pn, n))
    w.close()

    w = io.open(os.path.join(outdir, '99_rescue_revert.sql'), 'w', encoding='utf-8')
    w.write(hdr + '-- Exact rollback. Needs the %s tables from 02_rescue_backup.sql.\n\n' % BAK)
    for pn, old, new, n in todo:
        w.write("UPDATE `%s`.gene n\n"
                "  JOIN `%s`.`%s` b ON b.gene_id = n.gene_id\n"
                "   SET n.description = b.description;\n" % (new, new, BAK))
        w.write("SELECT '%s' AS production_name, ROW_COUNT() AS reverted;\n" % pn)
        w.write("DROP TABLE `%s`.`%s`;\n\n" % (new, BAK))
    w.close()

    print('\nwrote 4 scripts to %s/ covering %d species and %d genes:' % (outdir, len(todo), total))
    print('  mysql -h $MYSQL_HOST -u <writer> -p < %s/01_rescue_preflight.sql   # read-only, must pass' % outdir)
    print('  mysql -h $MYSQL_HOST -u <writer> -p < %s/02_rescue_backup.sql' % outdir)
    print('  mysql -h $MYSQL_HOST -u <writer> -p < %s/03_rescue_load.sql' % outdir)
    print('\nThe build\'s %s account is read-only; this needs a writer.' % os.environ.get('MYSQL_USER', '<user>'))
    print('Afterwards the search index only picks it up on a re-dump: delete the affected')
    print('search/tmp/<species>.json.gz and re-run 40_genes_dump, then 50_genes_decorate.')


if __name__ == '__main__':
    main()
