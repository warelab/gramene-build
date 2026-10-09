-- ---------------------------------------------------------------------------
-- Restore TraesALC* stable ids in the Triticum aestivum cv. Alchemy core
--
--   database: triticum_aestivum_alchemy_core_70_116_1   (on colden)
--
-- WHY
-- The r70 core labels every gene/transcript/translation/exon TraesCS*, which is
-- the REFERENCE wheat (IWGSC) stable-id namespace. The r69 core for the same
-- assembly uses TraesALC*. Evidence that this is a prefix regression and not a
-- real annotation difference:
--
--   * same assembly (GCA951799155v1 / GCA_951799155.1), same genebuild
--     (2024-08, GCA951799155v1.0), same gene count (106,786)
--   * joining the two cores on REPLACE(stable_id,'TraesALC','TraesCS') matches
--     106,786 of 106,786 genes, with identical seq_region/start/end/strand
--   * ensembl_compara_plants_69_114 and _70_116 both contain ZERO alchemy
--     genome_dbs and ZERO TraesALC* members, while all 107,545 TraesCS*
--     gene_members belong to genome_db 2102 = triticum_aestivum (IWGSC)
--
-- IMPACT OF LEAVING IT
-- Gramene keys gene documents on the stable id, so the two wheat genomes
-- collide on 103,039 ids. This already shipped: in search69, alchemy owns the
-- TraesCS* ids and reference wheat retains only 17,705 of its 120,744 genes.
--
-- SCOPE
-- The prefix occurs ONLY in the four stable_id columns below. Verified empty /
-- unaffected: stable_id_event, gene_archive, mapping_session,
-- seq_region_synonym, xref.display_label, xref.dbprimary_acc,
-- gene_attrib, transcript_attrib, translation_attrib, protein_align_feature.
--
-- SAFETY
--   * anchored on LEFT(stable_id,7)='TraesCS', so it cannot touch anything else
--     and is idempotent -- re-running is a no-op because TraesALC* does not match
--   * stable_id_idx is NON-unique on all four tables and there are 0 existing
--     TraesALC* rows, so no constraint can be violated
--   * SUBSTRING is used rather than REPLACE so only the leading prefix is
--     rewritten, even if a body were ever to contain the literal 'TraesCS'
--
-- BACK UP FIRST (outside this script):
--   mysqldump -h colden -u <writer> -p \
--     triticum_aestivum_alchemy_core_70_116_1 gene transcript translation exon \
--     | gzip > alchemy_70_116_1.stable_ids.pre-TraesALC.sql.gz
-- ---------------------------------------------------------------------------

USE triticum_aestivum_alchemy_core_70_116_1;

-- --- 1. pre-flight: expect 106786 / 131360 / 112053 / 518640, and 0 "other" ---
SELECT 'gene'        AS tbl, COUNT(*) AS total,
       SUM(LEFT(stable_id,7) = 'TraesCS')  AS to_rename,
       SUM(LEFT(stable_id,8) = 'TraesALC') AS already_done,
       SUM(LEFT(stable_id,7) <> 'TraesCS' AND LEFT(stable_id,8) <> 'TraesALC') AS other
  FROM gene
UNION ALL SELECT 'transcript',  COUNT(*), SUM(LEFT(stable_id,7)='TraesCS'), SUM(LEFT(stable_id,8)='TraesALC'),
       SUM(LEFT(stable_id,7)<>'TraesCS' AND LEFT(stable_id,8)<>'TraesALC') FROM transcript
UNION ALL SELECT 'translation', COUNT(*), SUM(LEFT(stable_id,7)='TraesCS'), SUM(LEFT(stable_id,8)='TraesALC'),
       SUM(LEFT(stable_id,7)<>'TraesCS' AND LEFT(stable_id,8)<>'TraesALC') FROM translation
UNION ALL SELECT 'exon',        COUNT(*), SUM(LEFT(stable_id,7)='TraesCS'), SUM(LEFT(stable_id,8)='TraesALC'),
       SUM(LEFT(stable_id,7)<>'TraesCS' AND LEFT(stable_id,8)<>'TraesALC') FROM exon;

-- STOP if "other" is non-zero anywhere, or if to_rename is 0 everywhere
-- (already applied). Otherwise continue.

-- --- 2. the rename ---------------------------------------------------------
START TRANSACTION;

UPDATE gene
   SET stable_id = CONCAT('TraesALC', SUBSTRING(stable_id, 8))
 WHERE LEFT(stable_id, 7) = 'TraesCS';          -- expect 106786 rows

UPDATE transcript
   SET stable_id = CONCAT('TraesALC', SUBSTRING(stable_id, 8))
 WHERE LEFT(stable_id, 7) = 'TraesCS';          -- expect 131360 rows

UPDATE translation
   SET stable_id = CONCAT('TraesALC', SUBSTRING(stable_id, 8))
 WHERE LEFT(stable_id, 7) = 'TraesCS';          -- expect 112053 rows

UPDATE exon
   SET stable_id = CONCAT('TraesALC', SUBSTRING(stable_id, 8))
 WHERE LEFT(stable_id, 7) = 'TraesCS';          -- expect 518640 rows

-- --- 3. verify BEFORE committing -------------------------------------------
-- (a) nothing left on the old prefix, everything on the new one
SELECT 'gene' AS tbl, SUM(LEFT(stable_id,7)='TraesCS') AS still_old,
                      SUM(LEFT(stable_id,8)='TraesALC') AS now_new FROM gene
UNION ALL SELECT 'transcript',  SUM(LEFT(stable_id,7)='TraesCS'), SUM(LEFT(stable_id,8)='TraesALC') FROM transcript
UNION ALL SELECT 'translation', SUM(LEFT(stable_id,7)='TraesCS'), SUM(LEFT(stable_id,8)='TraesALC') FROM translation
UNION ALL SELECT 'exon',        SUM(LEFT(stable_id,7)='TraesCS'), SUM(LEFT(stable_id,8)='TraesALC') FROM exon;
-- expect still_old = 0 and now_new = 106786 / 131360 / 112053 / 518640

-- (b) the strongest check: every gene now matches the r69 core by stable id
--     AND by position. Expect all three counts equal 106786.
SELECT (SELECT COUNT(*) FROM gene)                                   AS r70_genes,
       (SELECT COUNT(*) FROM triticum_aestivum_alchemy_core_69_114_1.gene) AS r69_genes,
       (SELECT COUNT(*)
          FROM gene n
          JOIN triticum_aestivum_alchemy_core_69_114_1.gene o
            ON o.stable_id = n.stable_id
          JOIN seq_region nsr ON n.seq_region_id = nsr.seq_region_id
          JOIN triticum_aestivum_alchemy_core_69_114_1.seq_region osr
            ON o.seq_region_id = osr.seq_region_id
         WHERE nsr.name            = osr.name
           AND n.seq_region_start  = o.seq_region_start
           AND n.seq_region_end    = o.seq_region_end
           AND n.seq_region_strand = o.seq_region_strand)            AS matched_id_and_position;

-- (c) and confirm no overlap remains with the reference wheat namespace
SELECT COUNT(*) AS collides_with_reference
  FROM gene n
  JOIN triticum_aestivum_core_70_116_4.gene r ON r.stable_id = n.stable_id;
-- expect 0

-- --- 4. commit (or ROLLBACK if any check above disagrees) ------------------
COMMIT;
-- ROLLBACK;
