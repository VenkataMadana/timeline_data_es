-- =============================================================================
-- sp_get_patient_es_doc  (schema version 2.0)
-- Builds the full patient_value_care JSON document for Elasticsearch initial load.
--
-- Input : p_origid  VARCHAR(64) — patient origid (CDC primary key / ES doc _id)
-- Output: single resultset, one column `es_doc` (LONGTEXT JSON)
--
-- Design:
--   • One document per patient, full history
--   • account_id = universal cross-section correlation key
--   • Encounters are the spine — diagnoses, procedures, enc_medications,
--     audit, and claim embedded
--   • Labs and patient medications are top-level arrays (independent of encounter)
--   • rule_flags{} pre-computed — rule engines read this first without traversing
--   • CDC strategy: ES ReplaceOne on {patient.id} = p_origid
--
-- Source tables (mradb_prod):
--   adt_patient, adt_encounter, mra1_encounter (UNION ALL for encounter spine),
--   adt_encounter_icd_codes, adt_encounter_procedure,
--   mra1_encounter_bill_cpts, mra_hcc_coefficients, mra_raf_patient,
--   mra_uamcc_details, mra_scorecard_alerts, drfirst_patient_medications,
--   encounter_risk_assesments, in_home_patient_program, mra_chart_queue,
--   reminder_events, transportation_benefit, sdoh_meal_plan,
--   chronic_disease_reward_program, care_plan, care_plan_patient,
--   mra_assessments_and_screenings, cpoe_result, cpoe_result_values,
--   flowsheet_rows, adt_appointment, qip_uamcc_lambda
--
-- Encounter spine strategy:
--   adt_encounter  → source_system = 'adt'  (ADT/EMR events; full clinical detail)
--   mra1_encounter → source_system = 'mra1' (CCLF claim events; all enc_proc_type values)
--   UNION ALL keyed on encounter_nr — each row carries its source_system tag.
--   CCLF-specific claim fields (alignedStatus, TFU flags, ACR, UAMCC, etc.) are
--   embedded in a nested cclf{} object so ADT rows carry NULL there cleanly.
-- =============================================================================

DROP PROCEDURE IF EXISTS `sp_get_patient_es_doc`;

DELIMITER $$

CREATE PROCEDURE `sp_get_patient_es_doc`(IN p_origid VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci)
sp_get_patient_es_doc: BEGIN

  -- ── 1. Main document ──────────────────────────────────────────────────────
  SELECT JSON_OBJECT(
    'patient', JSON_OBJECT(

      -- ─ identity ──────────────────────────────────────────────────────────
      'id',         p.origid,
      'origid',     p.origid,

      -- ─ demographics ──────────────────────────────────────────────────────
      'demographics', JSON_OBJECT(
        'last_name',          p.lastname,
        'first_name',         p.firstname,
        'middle_name',        p.middlename,
        'dob',                DATE_FORMAT(p.birthdate, '%Y-%m-%d'),
        'age',                TIMESTAMPDIFF(YEAR, p.birthdate, CURDATE()),
        'sex',                CASE p.sex WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE p.sex END,
        'sex_at_birth',       p.sex_at_birth,
        'race',               p.race,
        'ethnicity',          p.ethnicgroup,
        'language',           p.language,
        'civil_status',       p.civil_status,
        'blood_group',        p.blood_group,
        'dnr_status',         p.dnr_status,
        'nursing_home_alert', IF(p.nursing_home_alert = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
      ),

      -- ─ contact ───────────────────────────────────────────────────────────
      'contact', JSON_OBJECT(
        'phone_primary',   CONCAT(COALESCE(p.phone_1_code,''), COALESCE(p.phone_1_nr,'')),
        'phone_secondary', p.phone_2_nr,
        'cellphone',       p.cellphone_2_nr,
        'email',           p.email,
        'no_email',        IF(p.no_email = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'address', JSON_OBJECT(
          'street',   p.addr_str,
          'city',     p.addr_citytown_name,
          'state',    p.addr_state,
          'zip',      p.addr_zip,
          'country',  COALESCE(p.addr_country, 'US'),
          'verified', IF(p.addr_is_valid = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
        ),
        'emergency_contact', JSON_OBJECT(
          'name',     p.contact_person,
          'relation', p.contact_relation,
          'phone',    p.contact_person_phone
        )
      ),

      -- ─ care_team — sourced from dc_bene_alignment_rostr_m01 (latest row) ──
      'care_team', (
        SELECT JSON_OBJECT(
          'market_id',           r.market_id,
          'market_name',         r.market_names,
          'group_name',          r.dce_group_name,
          'sub_group_name',      r.dce_sub_group_name,
          'subgroup_id',         r.dce_sub_group_nr,
          'facility_nr',         r.dce_group_nr,
          'facility_name',       r.dce_group_name,
          'dce_provider',        r.dce_provider_name,
          'dce_provider_npi',    r.prov_npi_nr,
          'care_manager',        (SELECT per.name
                                   FROM cds_patient_personell_assocs cpa
                                   JOIN personell per ON per.nr = cpa.personell_id
                                   WHERE cpa.origid = p_origid
                                   ORDER BY cpa.created_date DESC LIMIT 1),
          'last_pcp_visit',      DATE_FORMAT(r.Last_PCP_Visit_Date, '%Y-%m-%d'),
          'next_pcp_visit',      DATE_FORMAT(p.Next_Office_Visit, '%Y-%m-%d'),
          'days_since_pcp_visit',DATEDIFF(CURDATE(), r.Last_PCP_Visit_Date)
        )
        FROM dc_bene_alignment_rostr_m01 r
        WHERE r.mm_curr_mbi_id = p.mra_clm_refer_m01
          AND r.ALIGN_STATUS_CODE IN ('AL','D1Y')
        ORDER BY r.mm_date DESC
        LIMIT 1
      ),

      -- ─ enrollment ────────────────────────────────────────────────────────
      'enrollment', JSON_OBJECT(
        'status',            p.status,
        'align_status_code', p.ALIG_STATUS_CODE,
        'ccm_enabled',       IF(p.is_ccm_enabled = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'ccm_level',         p.ccm_level,
        'ccm_active_date',   DATE_FORMAT(p.ccm_activedate, '%Y-%m-%d'),
        'ccm_inactive_date', DATE_FORMAT(p.ccm_inactivedate, '%Y-%m-%d'),
        'consent_on_file',   IF(p.consent_onfile = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'dr_first_status',   p.dr_first_status,
        'high_utilizer',     IF(p.is_alert_inc_alerts = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'long_term_care',    IF(p.long_term_care = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'inactive_date',     DATE_FORMAT(p.inactive_date, '%Y-%m-%d'),
        'inactive_reason',   p.inactive_reason
      ),

      -- ─ rule_flags{} — pre-computed at query time ─────────────────────────
      'rule_flags', JSON_OBJECT(

        -- raf / hcc
        'raf_score',          (SELECT ROUND(r.total_score, 4)
                               FROM mra_raf_patient r
                               WHERE r.origid = p_origid COLLATE utf8mb4_unicode_ci AND r.TYPE = 'prmra'
                               ORDER BY r.YEAR DESC, r.MONTH DESC LIMIT 1),

        -- readmit (based on most recent inpatient discharge)
        'readmit_30d',        (SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                               FROM adt_encounter ae
                               WHERE ae.origid = p_origid
                                 AND ae.m_redmit_flag = 1
                                 AND ae.discharge_date >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)),
        'readmit_90d',        (SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                               FROM adt_encounter ae
                               WHERE ae.origid = p_origid
                                 AND ae.m_redmit_flag = 1
                                 AND ae.discharge_date >= DATE_SUB(CURDATE(), INTERVAL 90 DAY)),
        'last_admission_date',(SELECT DATE_FORMAT(ae.encounter_date, '%Y-%m-%d')
                               FROM adt_encounter ae
                               WHERE ae.origid = p_origid
                                 AND ae.encounter_class_nr IN (1,2,3,4)
                               ORDER BY ae.encounter_date DESC LIMIT 1),
        'last_discharge_date',(SELECT DATE_FORMAT(ae.discharge_date, '%Y-%m-%d')
                               FROM adt_encounter ae
                               WHERE ae.origid = p_origid
                                 AND ae.encounter_class_nr IN (1,2,3,4)
                                 AND ae.discharge_date IS NOT NULL
                               ORDER BY ae.discharge_date DESC LIMIT 1),
        'open_inpatient',     (SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                               FROM adt_encounter ae
                               WHERE ae.origid = p_origid
                                 AND ae.encounter_class_nr IN (1,2,3,4)
                                 AND ae.discharge_date IS NULL
                                 AND ae.encounter_status != 'closed'),

        -- AWV
        'awv_due',            (SELECT IF(MAX(ae.encounter_date) IS NULL
                                         OR DATEDIFF(CURDATE(), MAX(ae.encounter_date)) > 365,
                                         CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                               FROM adt_encounter ae
                               INNER JOIN mra1_encounter_bill_cpts cpt
                                 ON cpt.encounter_nr = ae.encounter_nr
                               WHERE ae.origid = p_origid
                                 AND cpt.bb_Code IN ('G0438','G0439')),
        'awv_last_date',      (SELECT DATE_FORMAT(MAX(ae.encounter_date), '%Y-%m-%d')
                               FROM adt_encounter ae
                               INNER JOIN mra1_encounter_bill_cpts cpt
                                 ON cpt.encounter_nr = ae.encounter_nr
                               WHERE ae.origid = p_origid
                                 AND cpt.bb_Code IN ('G0438','G0439')),

        -- PCP
        'pcp_visit_overdue',  IF(p.Last_PCP_Visit_Date IS NULL
                                  OR DATEDIFF(CURDATE(), p.Last_PCP_Visit_Date) > 365,
                                  CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'pcp_days_since_visit',DATEDIFF(CURDATE(), p.Last_PCP_Visit_Date),

        -- HEDIS open gaps
        'hedis_gaps_open',    (SELECT COUNT(*) FROM mra_scorecard_alerts msa
                               WHERE msa.origid = p_origid
                                 AND msa.type = 'Hedis/Quality'
                                 AND msa.resolved_date IS NULL),
        'hedis_gap_measures', (SELECT JSON_ARRAYAGG(ref_description)
                               FROM (SELECT DISTINCT ref_description
                                     FROM mra_scorecard_alerts
                                     WHERE origid = p_origid
                                       AND type = 'Hedis/Quality'
                                       AND resolved_date IS NULL) _hgm),

        -- CCM
        'ccm_enrolled',       IF(p.is_ccm_enabled = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'ccm_consent_on_file',IF(p.consent_onfile = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
        'ccm_level',          p.ccm_level,

        -- SDOH flags
        'sdoh_food_insecurity',(SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                                FROM encounter_risk_assesments era
                                INNER JOIN adt_encounter ae ON ae.encounter_nr = era.encounter_nr
                                WHERE ae.origid = p_origid
                                  AND era.sub_type = 'SDOH'
                                  AND era.result_code_desc LIKE '%food%'),
        'sdoh_transport_barrier',(SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                                   FROM transportation_benefit tb
                                   WHERE tb.orig_id = p_origid),
        'sdoh_meal_plan_active',(SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                                  FROM sdoh_meal_plan smp
                                  WHERE smp.origid = p_origid
                                    AND smp.order_status = 'ordered'
                                    AND (smp.end_date IS NULL OR smp.end_date >= NOW())),

        -- care plan
        'care_plan_active',   (SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                               FROM care_plan_patient cpp
                               WHERE cpp.origid = p_origid
                                 AND cpp.plan_status = 1
                                 AND (cpp.plan_inactive_datetime IS NULL
                                      OR cpp.plan_inactive_datetime >= NOW())),
        'care_plan_overdue_reassessment',
                              (SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                               FROM care_plan_patient cpp
                               WHERE cpp.origid = p_origid
                                 AND cpp.plan_status = 1
                                 AND cpp.reassessment IS NOT NULL
                                 AND DATE_ADD(
                                       COALESCE(cpp.updated_date, cpp.plan_start_date),
                                       INTERVAL CAST(cpp.reassessment AS UNSIGNED) DAY
                                     ) < CURDATE()),

        -- UAMCC
        'uamcc_eligible',     (SELECT IF(COUNT(DISTINCT ud.condition_category) >= 2,
                                          CAST(TRUE AS JSON), CAST(FALSE AS JSON))
                               FROM mra_uamcc_details ud
                               WHERE ud.origid = p_origid
                                 AND ud.is_most_recent_per_category = 1),
        'uamcc_conditions',   (SELECT JSON_ARRAYAGG(condition_category)
                               FROM (SELECT DISTINCT condition_category
                                     FROM mra_uamcc_details
                                     WHERE origid = p_origid
                                       AND is_most_recent_per_category = 1) _uc),
        'uamcc_condition_count',(SELECT COUNT(DISTINCT ud.condition_category)
                                  FROM mra_uamcc_details ud
                                  WHERE ud.origid = p_origid
                                    AND ud.is_most_recent_per_category = 1),

        -- alerts
        'active_alerts',      (SELECT COUNT(*) FROM mra_scorecard_alerts msa
                               WHERE msa.origid = p_origid
                                 AND msa.resolved_date IS NULL),
        'unresolved_alert_types',(SELECT JSON_ARRAYAGG(type)
                                   FROM (SELECT DISTINCT type
                                         FROM mra_scorecard_alerts
                                         WHERE origid = p_origid
                                           AND resolved_date IS NULL) _uat),
        'last_updated',       DATE_FORMAT(NOW(), '%Y-%m-%dT%H:%i:%sZ')
      ),

      -- ─ chronic_conditions[] ──────────────────────────────────────────────
      'chronic_conditions', (
        SELECT JSON_ARRAYAGG(
          JSON_OBJECT(
            'id',                 cc.diagnosis_code,
            'icd_code',           cc.diagnosis_code,
            'icd_desc',           hc.description,
            'hcc_number',         hc.hcc,
            'hcc_score',          hc.community_nondual_aged,
            'condition_category', ud.condition_category,
            'is_comorbid',        IF(cc.is_comorbid = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
            'problem_type',       cc.problem_type,
            'status',             COALESCE(cc.status, 'Active'),
            'first_onset_date',   DATE_FORMAT(cc.first_date, '%Y-%m-%d'),
            'last_seen_date',     DATE_FORMAT(cc.last_date, '%Y-%m-%d'),
            'days_since_last_seen',DATEDIFF(CURDATE(), cc.last_date),
            'encounter_count',    cc.enc_count,
            'snomed_cid',         aic.SNOMED_CID,
            'snomed_fsn',         aic.SNOMED_FSN,
            'agreement_status',   'Agree',
            'ccm_tracked',        IF(aic.ccm_track = 1, CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
            'recapture_needed',   IF(hc.hcc IS NOT NULL
                                     AND cc.year_seen < YEAR(CURDATE()),
                                     CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
            'source',             aic.source
          )
        )
        FROM (
          SELECT
            ai.diagnosis_code,
            MAX(ai.is_comorbid)     AS is_comorbid,
            MAX(ai.problem_type)    AS problem_type,
            MAX(ai.status)          AS STATUS,
            MIN(ae.encounter_date)  AS first_date,
            MAX(ae.encounter_date)  AS last_date,
            YEAR(MAX(ae.encounter_date)) AS year_seen,
            COUNT(DISTINCT ai.encounter_nr) AS enc_count
          FROM adt_encounter_icd_codes ai
          INNER JOIN adt_encounter ae ON ae.encounter_nr = ai.encounter_nr
          WHERE ae.origid = p_origid
          GROUP BY ai.diagnosis_code
        ) cc
        INNER JOIN (
          SELECT diagnosis_code,
                 MAX(is_comorbid)  AS is_comorbid,
                 MAX(problem_type) AS problem_type,
                 MAX(STATUS)       AS STATUS,
                 MAX(SNOMED_CID)   AS SNOMED_CID,
                 MAX(SNOMED_FSN)   AS SNOMED_FSN,
                 MAX(ccm_track)    AS ccm_track,
                 MAX(SOURCE)       AS SOURCE
          FROM adt_encounter_icd_codes
          WHERE encounter_nr IN (
            SELECT encounter_nr FROM adt_encounter WHERE origid = p_origid
          )
          GROUP BY diagnosis_code
        ) aic ON aic.diagnosis_code = cc.diagnosis_code
        LEFT JOIN mra_hcc_coefficients hc
          ON hc.diagnosis_code = cc.diagnosis_code
         AND hc.active_date <= NOW() AND hc.inactive_date >= NOW()
        LEFT JOIN mra_uamcc_details ud
          ON ud.diagnosis_code = cc.diagnosis_code
         AND ud.origid = p_origid
      ),

      -- ─ raf_profile{} ─────────────────────────────────────────────────────
      'raf_profile', (
        SELECT JSON_OBJECT(
          'id',         CONCAT(p_origid, '_', YEAR(CURDATE())),
          'year',       YEAR(CURDATE()),
          'pmra',       JSON_OBJECT(
            'detail_score',  pmra.total_score,
            'initial_score', pmra.initial_score,
            'month',         pmra.MONTH
          ),
          'prmra',      JSON_OBJECT(
            'detail_score',  prmra.total_score,
            'initial_score', prmra.initial_score,
            'month',         prmra.MONTH
          ),
          'rmra',       JSON_OBJECT(
            'detail_score',  rmra.total_score,
            'initial_score', rmra.initial_score,
            'month',         rmra.MONTH
          ),
          'raf_version',28,
          'score_trend','Stable'
        )
        FROM (SELECT 1) _base
        LEFT JOIN (SELECT total_score, initial_score, MONTH FROM mra_raf_patient
                   WHERE origid = p_origid COLLATE utf8mb4_unicode_ci AND TYPE = 'pmra' AND YEAR = YEAR(CURDATE())
                   ORDER BY MONTH DESC LIMIT 1) pmra ON 1=1
        LEFT JOIN (SELECT total_score, initial_score, MONTH FROM mra_raf_patient
                   WHERE origid = p_origid COLLATE utf8mb4_unicode_ci AND TYPE = 'prmra' AND YEAR = YEAR(CURDATE())
                   ORDER BY MONTH DESC LIMIT 1) prmra ON 1=1
        LEFT JOIN (SELECT total_score, initial_score, MONTH FROM mra_raf_patient
                   WHERE origid = p_origid COLLATE utf8mb4_unicode_ci AND TYPE = 'rmra' AND YEAR = YEAR(CURDATE())
                   ORDER BY MONTH DESC LIMIT 1) rmra ON 1=1
      ),

      -- ─ hcc_capture{} ─────────────────────────────────────────────────────
      'hcc_capture', (
        SELECT JSON_OBJECT(
          'id',              CONCAT(p_origid, '_', YEAR(CURDATE()), '_v28'),
          'year',            YEAR(CURDATE()),
          'hcc_version',     28,
          'eligible_hccs',   COUNT(DISTINCT hc.hcc),
          'captured_hccs',   SUM(CASE WHEN cy_seen.cnt > 0 THEN 1 ELSE 0 END),
          'capture_pct',     ROUND(
                               100.0 * SUM(CASE WHEN cy_seen.cnt > 0 THEN 1 ELSE 0 END)
                               / NULLIF(COUNT(DISTINCT hc.hcc), 0), 1),
          'gap_hccs',        (SELECT JSON_ARRAYAGG(CONCAT('HCC-', hc2.hcc_nr))
                               FROM mra_hcc_coefficients hc2
                               INNER JOIN (SELECT DISTINCT ai3.diagnosis_code
                                           FROM adt_encounter_icd_codes ai3
                                           INNER JOIN adt_encounter ae3 ON ae3.encounter_nr = ai3.encounter_nr
                                           WHERE ae3.origid = p_origid) pt2
                                 ON pt2.diagnosis_code = hc2.diagnosis_code
                                AND hc2.active_date <= NOW() AND hc2.inactive_date >= NOW()
                               WHERE NOT EXISTS (
                                 SELECT 1 FROM adt_encounter_icd_codes ai4
                                 INNER JOIN adt_encounter ae4 ON ae4.encounter_nr = ai4.encounter_nr
                                 WHERE ae4.origid = p_origid
                                   AND YEAR(ae4.encounter_date) = YEAR(CURDATE())
                                   AND ai4.diagnosis_code = hc2.diagnosis_code
                               )),
          'gap_revenue_at_risk', 0.00
        )
        FROM (
          SELECT DISTINCT ai.diagnosis_code
          FROM adt_encounter_icd_codes ai
          INNER JOIN adt_encounter ae ON ae.encounter_nr = ai.encounter_nr
          WHERE ae.origid = p_origid
        ) pt_codes
        INNER JOIN mra_hcc_coefficients hc
          ON hc.diagnosis_code = pt_codes.diagnosis_code
         AND hc.active_date <= NOW() AND hc.inactive_date >= NOW()
        LEFT JOIN (
          SELECT ai2.diagnosis_code, COUNT(*) AS cnt
          FROM adt_encounter_icd_codes ai2
          INNER JOIN adt_encounter ae2 ON ae2.encounter_nr = ai2.encounter_nr
          WHERE ae2.origid = p_origid
            AND YEAR(ae2.encounter_date) = YEAR(CURDATE())
          GROUP BY ai2.diagnosis_code
        ) cy_seen ON cy_seen.diagnosis_code = pt_codes.diagnosis_code
      ),

      -- ─ risk_scores{} ─────────────────────────────────────────────────────
      'risk_scores', (
        SELECT JSON_OBJECT(
          'id',   CONCAT(p_origid, '_', YEAR(CURDATE())),
          'year', YEAR(CURDATE()),
          'uha',  JSON_ARRAY(),
          'chf',  JSON_ARRAY(),
          'roster_scores', JSON_OBJECT(
            'avg_adi_score', NULL,
            'cdi_score',     NULL,
            'equity_score',  NULL
          )
        )
      ),

      -- ─ uamcc{} ───────────────────────────────────────────────────────────
      'uamcc', JSON_OBJECT(
        'summary', (
          SELECT JSON_OBJECT(
            'id',              CONCAT(p_origid, '_', YEAR(CURDATE())),
            'year',            YEAR(CURDATE()),
            'conditions',      (SELECT JSON_ARRAYAGG(condition_category)
                                FROM (SELECT DISTINCT condition_category
                                      FROM mra_uamcc_details
                                      WHERE origid = p_origid
                                        AND is_most_recent_per_category = 1) _sc),
            'icd_prefixes',    (SELECT JSON_ARRAYAGG(pfx)
                                FROM (SELECT DISTINCT LEFT(diagnosis_code, 3) AS pfx
                                      FROM mra_uamcc_details
                                      WHERE origid = p_origid
                                        AND is_most_recent_per_category = 1) _sp),
            'condition_count', COUNT(DISTINCT ud.condition_category),
            'program_eligible',IF(COUNT(DISTINCT ud.condition_category) >= 2,
                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON))
          )
          FROM mra_uamcc_details ud
          WHERE ud.origid = p_origid AND ud.is_most_recent_per_category = 1
        ),
        'details', (
          SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
              'id',                 ud.nr,
              'service_date',       DATE_FORMAT(ud.service_date, '%Y-%m-%d'),
              'condition_category', ud.condition_category,
              'icd_code',           ud.diagnosis_code,
              'icd_desc',           ud.diagnosis_desc,
              'provider_npi',       ud.prov_npi_nr,
              'provider_name',      ud.prov_name,
              'provider_taxonomy',  ud.prov_taxonomy,
              'facility_name',      ud.facility_name,
              'claim_source',       ud.claim_source,
              'claim_type',         ud.claim_type,
              'version',            ud.version
            )
          )
          FROM mra_uamcc_details ud
          WHERE ud.origid = p_origid AND ud.is_most_recent_per_category = 1
          ORDER BY ud.service_date DESC
        )
      ),

      -- ─ medication_adherence{} ────────────────────────────────────────────
      'medication_adherence', (
        SELECT JSON_OBJECT(
          'id',               CONCAT(p_origid, '_', YEAR(CURDATE())),
          'year',             YEAR(CURDATE()),
          'covered_days',     COALESCE(SUM(
                                DATEDIFF(LEAST(COALESCE(stop_date, NOW()), NOW()), start_date)
                              ), 0),
          'rx_adherence_pct', ROUND(
                                100.0 * COALESCE(SUM(
                                  DATEDIFF(LEAST(COALESCE(stop_date, NOW()), NOW()), start_date)
                                ), 0) / NULLIF(DATEDIFF(NOW(), MIN(start_date)), 0), 2),
          'adherence_flag',   CASE
                                WHEN ROUND(100.0 * COALESCE(SUM(
                                  DATEDIFF(LEAST(COALESCE(stop_date,NOW()),NOW()), start_date)
                                ), 0) / NULLIF(DATEDIFF(NOW(), MIN(start_date)), 0), 2) >= 80
                                THEN 'Adequate' ELSE 'Inadequate' END,
          'star_rating_impact','On Track'
        )
        FROM drfirst_patient_medications
        WHERE patientid = p_origid
          AND delete_status = 'n'
          AND start_date IS NOT NULL
      ),

      -- ─ hedis_measures[] ──────────────────────────────────────────────────
      'hedis_measures', (
        SELECT JSON_ARRAYAGG(
          JSON_OBJECT(
            'id',                  CONCAT(COALESCE(msa.ref_detail,''), '_', YEAR(CURDATE())),
            'frows_nr',            msa.ref_id,
            'measure_year',        YEAR(CURDATE()),
            'measure_name',        msa.ref_description,
            'last_screening_date', DATE_FORMAT(msa.ref_date, '%Y-%m-%d'),
            'status',              IF(msa.resolved_date IS NOT NULL, 'Compliant', 'Gap'),
            'gap_open',            IF(msa.resolved_date IS NULL, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
          )
        )
        FROM mra_scorecard_alerts msa
        WHERE msa.origid = p_origid
          AND msa.type = 'Hedis/Quality'
        ORDER BY msa.added_date DESC
      ),

      -- ─ encounters[] — SPINE (UNION ALL: adt_encounter + mra1_encounter) ────
      --
      -- Both source tables contribute rows keyed on encounter_nr.
      -- adt_encounter  → source_system = 'adt'  (ADT/EMR events; full clinical)
      -- mra1_encounter → source_system = 'mra1' (CCLF claims; all enc_proc_type)
      --
      -- Common fields (dates, facility, provider, diagnoses, procedures, meds)
      -- are populated from whichever source has the row.  CCLF-specific claim
      -- analytics (TFU flags, ACR, UAMCC numerators, alignment status, etc.) are
      -- nested under cclf{} so ADT-only rows carry null there cleanly.
      --
      -- enc_proc_type on mra1_encounter maps to encounters[].setting:
      --   Acute Hospital | Emergency | HHA | Hospice | Long Term Care Hospital |
      --   Observation | Part B | Part C | Part D | Part DME | Psychiatric |
      --   Rehabilitation | SNF
      'encounters', (
        SELECT JSON_ARRAYAGG(enc_obj ORDER BY enc_date DESC)
        FROM (

          -- ── Branch A: ADT / EMR encounters ─────────────────────────────────
          SELECT
            ae.encounter_date          AS enc_date,
            ae.encounter_nr            AS enc_nr,
            JSON_OBJECT(
              'id',               ae.encounter_nr,
              'encounter_nr',     ae.encounter_nr,
              'source_system',    'adt',
              'encounter_type',   ae.mos_type,
              'enc_class_nr',     ae.encounter_class_nr,
              'encounter_status', ae.encounter_status,
              'setting',          ae.mos_type,

              'dates', JSON_OBJECT(
                'admission_date',      DATE_FORMAT(ae.encounter_date, '%Y-%m-%d'),
                'discharge_date',      DATE_FORMAT(ae.discharge_date, '%Y-%m-%d'),
                'length_of_stay_days', DATEDIFF(COALESCE(ae.discharge_date, CURDATE()),
                                                ae.encounter_date),
                'next_pcp_visit',      DATE_FORMAT(ae.next_pcp_visit_date, '%Y-%m-%d'),
                'hcc_followup_date',   DATE_FORMAT(ae.hcc_followup, '%Y-%m-%d'),
                'cm_followup_date',    DATE_FORMAT(ae.cm_followup, '%Y-%m-%d'),
                'tcm_7day_deadline',   DATE_FORMAT(DATE_ADD(ae.discharge_date, INTERVAL 7 DAY), '%Y-%m-%d'),
                'tcm_14day_deadline',  DATE_FORMAT(DATE_ADD(ae.discharge_date, INTERVAL 14 DAY), '%Y-%m-%d')
              ),

              'facility', JSON_OBJECT(
                'name',        ae.hospital_name,
                'npi',         ae.hospital_npi,
                'taxonomy',    ae.hos_taxonomy01,
                'hospital_nr', ae.hospital_nr,
                'oscar_num',   ae.PRVDR_OSCAR_NUM
              ),

              'provider', JSON_OBJECT(
                'attending_name',     ae.dce_provider_name,
                'attending_npi',      ae.ATNDG_PRVDR_NPI_NUM,
                'attending_taxonomy', ae.taxonomy
              ),

              'admission', JSON_OBJECT(
                'point_of_origin',    ae.mh_admission_source,
                'purpose',            ae.referrer_diagnosis,
                'admit_type_cd',      ae.mh_patient_class,
                'confirmed_mra',      IF(ae.appt_confirmed_mra IS NOT NULL,
                                         CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'high_utilizer',      IF(ae.high_utilizer = 1,
                                         CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'referrer_diagnosis', ae.referrer_diagnosis
              ),

              'discharge', JSON_OBJECT(
                'disposition',       ae.m_discharge_to,
                'discharge_to_code', ae.BENE_PTNT_STUS_CD,
                'readmit_30d',       IF(ae.m_redmit_flag = 1,
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'readmit_er_30d',    IF(ae.readmit_er_status = 1,
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'readmit_rate_pct',  ae.readmit_rate_percentile,
                'tfu_enabled',       IF(ae.tfu_enabled = 1,
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'followup_days',     ae.followup_days,
                'acr_numerator',     ae.acr_numerator,
                'tcm_numerator',     ae.tcm_num,
                'tcm_completed',     IF(ae.tcm_num = 1,
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON))
              ),

              'claim', JSON_OBJECT(
                'clm_uniq_id',       ae.CUR_CLM_UNIQ_ID,
                'clm_efctv_dt',      DATE_FORMAT(ae.CLM_EFCTV_DT, '%Y-%m-%d'),
                'rndrg_prvdr_npi',   ae.ATNDG_PRVDR_NPI_NUM,
                'patient_status_cd', ae.BENE_PTNT_STUS_CD,
                'prvdr_spclty_cd',   ae.CLM_PRVDR_SPCLTY_CD
              ),

              -- cclf{} is null for ADT rows — CCLF fields only on mra1 branch
              'cclf', NULL,

              -- diagnoses embedded in encounter
              'diagnoses', (
                SELECT JSON_ARRAYAGG(obj)
                FROM (
                  SELECT JSON_OBJECT(
                    'id',               aic.id,
                    'icd_code',         aic.diagnosis_code,
                    'icd_desc',         aic.diagnosis_desc,
                    'onset_date',       DATE_FORMAT(aic.onset_date, '%Y-%m-%d'),
                    'problem_type',     aic.problem_type,
                    'icd_order',        aic.icd_order,
                    'status',           COALESCE(aic.status, 'Active'),
                    'hcc_number',       hcd.hcc,
                    'hcc_score',        hcd.community_nondual_aged,
                    'hcc_included',     IF(hcd.hcc IS NOT NULL,
                                           CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                    'is_comorbid',      IF(aic.is_comorbid = 1,
                                           CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                    'agreement_status', 'Agree',
                    'source',           COALESCE(aic.source, ae.mos_type)
                  ) AS obj
                  FROM adt_encounter_icd_codes aic
                  LEFT JOIN mra_hcc_coefficients hcd
                    ON hcd.diagnosis_code = aic.diagnosis_code
                   AND hcd.active_date <= NOW() AND hcd.inactive_date >= NOW()
                  WHERE aic.encounter_nr = ae.encounter_nr
                  ORDER BY aic.icd_order
                ) _diag
              ),

              -- billing CPT procedures embedded in encounter
              'procedures', (
                SELECT JSON_ARRAYAGG(
                  JSON_OBJECT(
                    'id',             CONCAT(cpt.bb_Code, '_', DATE_FORMAT(ae.encounter_date, '%Y-%m-%d')),
                    'billing_code',   cpt.bb_Code,
                    'cpt_modifier',   cpt.bb_modifier,
                    'procedure_date', DATE_FORMAT(ae.encounter_date, '%Y-%m-%d'),
                    'revenue_code',   cpt.CLM_LINE_PROD_REV_CTR_CD
                  )
                )
                FROM mra1_encounter_bill_cpts cpt
                WHERE cpt.encounter_nr = ae.encounter_nr
              ),

              -- encounter medications (admission meds)
              'enc_medications', (
                SELECT JSON_ARRAYAGG(
                  JSON_OBJECT(
                    'id',               dm.id,
                    'ndc_id',           dm.NDCID,
                    'rxnorm_id',        dm.RxnormID,
                    'medication_name',  dm.medications,
                    'dose',             dm.dose,
                    'dose_unit',        dm.dose_unit,
                    'route',            dm.rout,
                    'schedule',         dm.schedule,
                    'start_date',       DATE_FORMAT(dm.start_date, '%Y-%m-%d'),
                    'stop_date',        DATE_FORMAT(dm.stop_date, '%Y-%m-%d'),
                    'prescribed_doctor',dm.prescribed_doctor,
                    'delete_status',    dm.delete_status
                  )
                )
                FROM drfirst_patient_medications dm
                WHERE dm.patientid = p_origid
                  AND dm.admission = 'yes'
                  AND DATE(dm.start_date) = DATE(ae.encounter_date)
              ),

              -- audit fields
              'audit', JSON_OBJECT(
                'care_status',   ae.care_status,
                'audit_status',  ae.audit_status,
                'mos',           ae.mos,
                'mos_type',      ae.mos_type,
                'tfu_numerator', ae.tfu_numerator,
                'mif_exclusion', IF(ae.mif_exclusion = 1,
                                     CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'census_status', ae.census_status
              )
            ) AS enc_obj

          FROM adt_encounter ae
          WHERE ae.origid = p_origid

          UNION ALL

          -- ── Branch B: CCLF / mra1_encounter (all enc_proc_type values) ─────
          -- All 12 enc_proc_type settings are captured by removing the WHERE
          -- filter and tagging source_system = 'mra1'.  CCLF-specific analytics
          -- live in cclf{} so they are available for TFU/ACR/UAMCC rule queries
          -- without polluting the shared encounter fields.
          SELECT
            me.enc_admit_date          AS enc_date,
            me.encounter_nr            AS enc_nr,
            JSON_OBJECT(
              'id',               me.encounter_nr,
              'encounter_nr',     me.encounter_nr,
              'source_system',    'mra1',
              'encounter_type',   me.enc_proc_type,
              'enc_class_nr',     NULL,
              'encounter_status', NULL,
              'setting',          me.enc_proc_type,

              'dates', JSON_OBJECT(
                'admission_date',      DATE_FORMAT(me.enc_admit_date, '%Y-%m-%d'),
                'discharge_date',      DATE_FORMAT(me.enc_disch_date, '%Y-%m-%d'),
                'length_of_stay_days', DATEDIFF(COALESCE(me.enc_disch_date, CURDATE()),
                                                me.enc_admit_date),
                'next_pcp_visit',      NULL,
                'hcc_followup_date',   NULL,
                'cm_followup_date',    NULL,
                'tcm_7day_deadline',   DATE_FORMAT(DATE_ADD(me.enc_disch_date, INTERVAL 7 DAY), '%Y-%m-%d'),
                'tcm_14day_deadline',  DATE_FORMAT(DATE_ADD(me.enc_disch_date, INTERVAL 14 DAY), '%Y-%m-%d')
              ),

              'facility', JSON_OBJECT(
                'name',        me.hospital_name,
                'npi',         NULL,
                'taxonomy',    me.hos_taxonomy01,
                'hospital_nr', me.hospital_nr,
                'oscar_num',   NULL
              ),

              'provider', JSON_OBJECT(
                'attending_name',     me.m_provider_name,
                'attending_npi',      me.m_provider_npi,
                'attending_taxonomy', me.m_prov_spclty_txt
              ),

              'admission', JSON_OBJECT(
                'point_of_origin',    NULL,
                'purpose',            NULL,
                'admit_type_cd',      NULL,
                'confirmed_mra',      CAST(FALSE AS JSON),
                'high_utilizer',      CAST(FALSE AS JSON),
                'referrer_diagnosis', NULL
              ),

              'discharge', JSON_OBJECT(
                'disposition',       me.e_discharge_text,
                'discharge_to_code', me.e_discharge_type,
                'readmit_30d',       IF(me.is_readmit = 1,
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'readmit_er_30d',    CAST(FALSE AS JSON),
                'readmit_rate_pct',  NULL,
                'tfu_enabled',       IF(me.m_flwup_flag = 1,
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'followup_days',     NULL,
                'acr_numerator',     me.acr_numer,
                'tcm_numerator',     me.tfu_numer,
                'tcm_completed',     IF(me.tfu_numer = 1,
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON))
              ),

              'claim', JSON_OBJECT(
                'clm_uniq_id',       NULL,
                'clm_efctv_dt',      NULL,
                'rndrg_prvdr_npi',   me.m_provider_npi,
                'patient_status_cd', NULL,
                'prvdr_spclty_cd',   me.m_prov_spclty_txt
              ),

              -- cclf{} holds all CCLF-specific analytics fields from mra1_encounter
              'cclf', JSON_OBJECT(
                'admitTime',                    me.enc_admit_time,
                'dischargeTime',                me.enc_disch_time,
                'groupType',                    me.dce_group_type,
                'subGroupType',                 me.dce_sub_group_type,
                'marketId',                     me.market_nr,
                'marketName',                   me.market_name,
                'facilityId',                   me.pt_facility_nr,
                'facilitySubId',                me.pt_facility_sub_nr,
                'providerId',                   me.pt_provider_num,
                'facilityName',                 me.pt_facility_name,
                'facilitySubName',              me.pt_facility_sub_name,
                'primaryPhysician',             me.pt_sp_dr_1,
                'alignedStatus',                me.pt_aligned_status,
                'secondaryAlignedStatus',       me.pt_aligned2status,
                'mh1CalculatedAmount',          me.mh1_cal_amount,
                'mc1CalculatedAmount',          me.mc1_cal_amount,
                'isReferenceAdmitDate',         IF(me.is_enc_ref_admitdate = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isReadmission',                IF(me.is_readmit = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isC2Readmission',              IF(me.is_c2_readmit = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isTransferredEncounter',       IF(me.is_enc_transfer = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isSnfRecord',                  IF(me.is_snf_rec = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isSnfAdmitDateReference',      IF(me.is_snf_admitdate_ref = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isEmergencyRoomVisit',         IF(me.is_er_visit = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isPrimaryCareVisit',           IF(me.is_visit_pcp = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isOfficeVisitRecord',          IF(me.is_offvisit_rec = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isOfficeVisitSecondaryRecord', IF(me.is_offvisit2rec = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'followUpFlag',                 IF(me.m_flwup_flag = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'is72HourFollowUp',             IF(me.is_72_hr_flwup = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'is7DayFollowUp',               IF(me.is_flwup_7_days = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'is14DayFollowUp',              IF(me.is_flwup_14_days = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isGlobal14DayFollowUp',        IF(me.is_gflwup_14_days = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'followUp72HourDate',           DATE_FORMAT(me.m72hr_flwup_date, '%Y-%m-%d'),
                'emergencyRoomFollowUp',        IF(me.tfu_pb_er = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'observationFollowUp',          IF(me.tfu_pb_obs = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'isBcdaMatch',                  IF(me.is_bcda_match = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'calculatedBedDays',            me.m_cal_bed_days,
                'placeOfService',               me.m_pos_txt,
                'providerSpecialty',            me.m_prov_spclty_txt,
                'followUpDate',                 DATE_FORMAT(me.tfu_followup_date, '%Y-%m-%d'),
                'tfuDenominator',               IF(me.tfu_denom = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'tfuNumerator',                 IF(me.tfu_numer = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'acrNumerator',                 IF(me.acr_numer = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'acrDenominator',               IF(me.acr_denom = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                'uamccNumerator',               IF(me.uamcc_numerator = 1,
                                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON))
              ),

              -- diagnoses: mra1_encounter_icd_codes when available, else empty array
              'diagnoses', (
                SELECT JSON_ARRAYAGG(obj)
                FROM (
                  SELECT JSON_OBJECT(
                    'id',               aic.id,
                    'icd_code',         aic.diagnosis_code,
                    'icd_desc',         aic.diagnosis_desc,
                    'onset_date',       DATE_FORMAT(aic.onset_date, '%Y-%m-%d'),
                    'problem_type',     aic.problem_type,
                    'icd_order',        aic.icd_order,
                    'status',           COALESCE(aic.status, 'Active'),
                    'hcc_number',       hcd.hcc,
                    'hcc_score',        hcd.community_nondual_aged,
                    'hcc_included',     IF(hcd.hcc IS NOT NULL,
                                           CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                    'is_comorbid',      IF(aic.is_comorbid = 1,
                                           CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
                    'agreement_status', COALESCE(aic.agreement_status, 'Agree'),
                    'source',           COALESCE(aic.source, 'mra1')
                  ) AS obj
                  FROM adt_encounter_icd_codes aic
                  LEFT JOIN mra_hcc_coefficients hcd
                    ON hcd.diagnosis_code = aic.diagnosis_code
                   AND hcd.active_date <= NOW() AND hcd.inactive_date >= NOW()
                  WHERE aic.encounter_nr = me.encounter_nr
                  ORDER BY aic.icd_order
                ) _diag
              ),

              -- billing CPT procedures — same join, encounter_nr is the key
              'procedures', (
                SELECT JSON_ARRAYAGG(
                  JSON_OBJECT(
                    'id',             CONCAT(cpt.bb_Code, '_', DATE_FORMAT(me.enc_admit_date, '%Y-%m-%d')),
                    'billing_code',   cpt.bb_Code,
                    'cpt_modifier',   cpt.bb_modifier,
                    'procedure_date', DATE_FORMAT(me.enc_admit_date, '%Y-%m-%d'),
                    'revenue_code',   cpt.CLM_LINE_PROD_REV_CTR_CD
                  )
                )
                FROM mra1_encounter_bill_cpts cpt
                WHERE cpt.encounter_nr = me.encounter_nr
              ),

              -- enc_medications: match on admit date since mra1 has no encounter_date
              'enc_medications', (
                SELECT JSON_ARRAYAGG(
                  JSON_OBJECT(
                    'id',               dm.id,
                    'ndc_id',           dm.NDCID,
                    'rxnorm_id',        dm.RxnormID,
                    'medication_name',  dm.medications,
                    'dose',             dm.dose,
                    'dose_unit',        dm.dose_unit,
                    'route',            dm.rout,
                    'schedule',         dm.schedule,
                    'start_date',       DATE_FORMAT(dm.start_date, '%Y-%m-%d'),
                    'stop_date',        DATE_FORMAT(dm.stop_date, '%Y-%m-%d'),
                    'prescribed_doctor',dm.prescribed_doctor,
                    'delete_status',    dm.delete_status
                  )
                )
                FROM drfirst_patient_medications dm
                WHERE dm.patientid = p_origid
                  AND dm.admission = 'yes'
                  AND DATE(dm.start_date) = me.enc_admit_date
              ),

              -- audit: mra1 rows have no audit workflow fields — carry nulls
              'audit', JSON_OBJECT(
                'care_status',   NULL,
                'audit_status',  NULL,
                'mos',           me.enc_proc_type,
                'mos_type',      me.enc_proc_type,
                'tfu_numerator', me.tfu_numer,
                'mif_exclusion', CAST(FALSE AS JSON),
                'census_status', NULL
              )
            ) AS enc_obj

          FROM mra1_encounter me
          WHERE me.patient_id = p_origid

        ) enc_rows
      ),

      -- ─ labs[] — patient-level, top-level array ───────────────────────────
      'labs', (
        SELECT JSON_ARRAYAGG(obj)
        FROM (
          SELECT JSON_OBJECT(
            'id',              cr.result_id,
            'encounter_nr',    cr.encounter_nr,
            'result_date',     DATE_FORMAT(cr.result_date, '%Y-%m-%d'),
            'item_id',         crv.item_id,
            'test_name',       fr.frows_name,
            'result_value',    crv.notes,
            'result_unit',     crv.unit,
            'alert_flag',      crv.notes_abnormality_flag,
            'abnormal',        IF(crv.notes_abnormality_flag IN ('H','L','HH','LL','A','AA'),
                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
            'result_status',   cr.result_status,
            'ordered_by',      cr.result_created_by,
            'specimen_type',   cr.specimen_type,
            'collection_date', DATE_FORMAT(cr.specimen_collection_date, '%Y-%m-%d')
          ) AS obj
          FROM cpoe_result cr
          INNER JOIN adt_encounter ae ON ae.encounter_nr = cr.encounter_nr
          LEFT JOIN cpoe_result_values crv ON crv.result_id = cr.result_id
          LEFT JOIN flowsheet_rows fr ON fr.frows_nr = crv.item_id
          WHERE ae.origid = p_origid
          ORDER BY cr.result_date DESC
        ) _labs
      ),

      -- ─ medications[] — patient-level active list (DrFirst) ───────────────
      'medications', (
        SELECT JSON_ARRAYAGG(obj)
        FROM (
          SELECT JSON_OBJECT(
            'id',                 CONCAT(dm.NDCID, '_', DATE_FORMAT(dm.start_date, '%Y-%m-%d')),
            'ndc_id',             dm.NDCID,
            'rxnorm_id',          dm.RxnormID,
            'medication_name',    dm.medications,
            'generic_name',       dm.generic_name,
            'schedule',           dm.schedule,
            'dose',               dm.dose,
            'dose_unit',          dm.dose_unit,
            'route',              dm.rout,
            'start_date',         DATE_FORMAT(dm.start_date, '%Y-%m-%d'),
            'fill_date',          DATE_FORMAT(dm.fill_date, '%Y-%m-%d'),
            'stop_date',          DATE_FORMAT(dm.stop_date, '%Y-%m-%d'),
            'active',             IF(dm.stop_date IS NULL OR dm.stop_date >= NOW(),
                                      CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
            'quantity',           dm.quantity,
            'quantity_unit',      dm.quantity_unit,
            'refills',            dm.refills,
            'prescribed_doctor',  dm.prescribed_doctor,
            'source',             COALESCE(dm.source, 'DrFirst'),
            'delete_status',      dm.delete_status,
            'reconciled_status',  dm.reconciled_status
          ) AS obj
          FROM drfirst_patient_medications dm
          WHERE dm.patientid = p_origid
            AND dm.delete_status = 'n'
          ORDER BY dm.start_date DESC
        ) _meds
      ),

      -- ─ assessments[] ─────────────────────────────────────────────────────
      'assessments', (
        SELECT JSON_ARRAYAGG(obj)
        FROM (
          SELECT JSON_OBJECT(
            'id',             mas.nr,
            'tool',           mas.assessment_tools,
            'date_completed', DATE_FORMAT(mas.date_completed, '%Y-%m-%d'),
            'acuity',         mas.acuity,
            'score',          mas.score,
            'completed_by',   mas.completed_by,
            'notes',          mas.notes
          ) AS obj
          FROM mra_assessments_and_screenings mas
          WHERE mas.origid = p_origid COLLATE utf8mb4_unicode_ci
          ORDER BY mas.date_completed DESC
        ) _assessments
      ),

      -- ─ alerts[] ──────────────────────────────────────────────────────────
      'alerts', (
        SELECT JSON_ARRAYAGG(obj)
        FROM (
          SELECT JSON_OBJECT(
            'id',              msa.nr,
            'alert_type',      msa.type,
            'ref_description', msa.ref_description,
            'ref_detail',      msa.ref_detail,
            'ref_id',          msa.ref_id,
            'added_date',      DATE_FORMAT(msa.added_date, '%Y-%m-%d'),
            'acked_date',      DATE_FORMAT(msa.ack_date, '%Y-%m-%d'),
            'ack_by',          msa.ack_by,
            'ack_notes',       msa.ack_notes,
            'resolved_date',   DATE_FORMAT(msa.resolved_date, '%Y-%m-%d'),
            'resolved_by',     msa.resolved_by,
            'status_code',     msa.current_status,
            'status_desc',     CASE msa.current_status
                                 WHEN 0 THEN 'New'
                                 WHEN 1 THEN 'Red'
                                 WHEN 2 THEN 'Yellow'
                                 WHEN 3 THEN 'Acknowledged'
                                 WHEN 4 THEN 'Resolved'
                                 ELSE 'Unknown' END,
            'open',            IF(msa.resolved_date IS NULL,
                                   CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
            'version_no',      msa.version_no
          ) AS obj
          FROM mra_scorecard_alerts msa
          WHERE msa.origid = p_origid
          ORDER BY msa.added_date DESC
        ) _alerts
      ),

      -- ─ sdoh{} ────────────────────────────────────────────────────────────
      'sdoh', JSON_OBJECT(
        'food_insecurity_flag', (
          SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
          FROM encounter_risk_assesments era
          INNER JOIN adt_encounter ae ON ae.encounter_nr = era.encounter_nr
          WHERE ae.origid = p_origid
            AND era.sub_type = 'SDOH'
            AND era.result_code_desc LIKE '%food%'
        ),
        'transport_barrier_flag', (
          SELECT IF(COUNT(*) > 0, CAST(TRUE AS JSON), CAST(FALSE AS JSON))
          FROM transportation_benefit tb WHERE tb.orig_id = p_origid
        ),
        'housing_instability', CAST(FALSE AS JSON),

        'meal_plans', (
          SELECT JSON_ARRAYAGG(obj)
          FROM (
            SELECT JSON_OBJECT(
              'id',                 smp.nr,
              'meal_type',          smp.meal_type,
              'product_sku',        smp.product_sku,
              'order_id',           smp.order_id,
              'order_status',       smp.order_status,
              'eligibility_status', smp.eligibility_status,
              'start_date',         DATE_FORMAT(smp.start_date, '%Y-%m-%d'),
              'end_date',           DATE_FORMAT(smp.end_date, '%Y-%m-%d'),
              'created_date',       DATE_FORMAT(smp.created_date, '%Y-%m-%d'),
              'ship_frequency_id',  smp.ship_frequency_id,
              'assigned_cm',        smp.assigned_cm,
              'source',             smp.source
            ) AS obj
            FROM sdoh_meal_plan smp
            WHERE smp.origid = p_origid
            ORDER BY smp.created_date DESC
          ) _meal_plans
        ),

        'reward_programs', (
          SELECT JSON_ARRAYAGG(obj)
          FROM (
            SELECT JSON_OBJECT(
              'id',                 cdrp.nr,
              'program',            cdrp.program,
              'chronic_disease',    cdrp.chronic_disease,
              'criteria',           cdrp.criteria,
              'status',             cdrp.status,
              'date',               DATE_FORMAT(cdrp.date, '%Y-%m-%d'),
              'gift_card_number',   cdrp.gift_card_number_issued,
              'gift_card_received', IF(cdrp.gift_card_received = 'yes',
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON)),
              'address_verified',   IF(cdrp.address_verified = 'yes',
                                        CAST(TRUE AS JSON), CAST(FALSE AS JSON))
            ) AS obj
            FROM chronic_disease_reward_program cdrp
            WHERE cdrp.origid = p_origid
            ORDER BY cdrp.date DESC
          ) _rewards
        )
      ),

      -- ─ emr_appointments[] ────────────────────────────────────────────────
      'emr_appointments', (
        SELECT JSON_ARRAYAGG(obj)
        FROM (
          SELECT JSON_OBJECT(
            'id',                aa.nr,
            'appointment_id',    CAST(aa.nr AS CHAR),
            'encounter_date',    DATE_FORMAT(aa.date, '%Y-%m-%d'),
            'appointment_start', DATE_FORMAT(aa.date, CONCAT('%Y-%m-%d', 'T', '%H:%i:%s')),
            'encounter_type',    aa.encounter_class_nr,
            'visit_name',        aa.purpose,
            'provider_name',     aa.to_personell_name,
            'patient_status',    aa.appt_status,
            'type',              'appointment',
            'completed',         IF(aa.appt_status IN ('Checked Out','Completed','checked_out'),
                                     CAST(TRUE AS JSON), CAST(FALSE AS JSON))
          ) AS obj
          FROM adt_appointment aa
          WHERE aa.origid = p_origid
          ORDER BY aa.date DESC
        ) _appts
      ),

      -- ─ _meta{} ───────────────────────────────────────────────────────────
      '_meta', JSON_OBJECT(
        'created_at',       DATE_FORMAT(NOW(), '%Y-%m-%dT%H:%i:%sZ'),
        'last_modified_at', DATE_FORMAT(NOW(), '%Y-%m-%dT%H:%i:%sZ'),
        'source_db',        'mradb_prod',
        'schema_version',   '2.0',
        'trigger_source',   'initial_load'
      )

    ) -- end patient{}
  ) AS es_doc

  FROM adt_patient p
  WHERE p.origid = p_origid
  LIMIT 1;

END$$

DELIMITER ;


