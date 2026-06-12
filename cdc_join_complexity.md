# CDC Join Complexity — `sp_get_patient_es_doc`

This document catalogs every field and node in `sp_get_patient_es_doc.sql` that requires a JOIN
to produce its value, and explains why each JOIN complicates CDC insert, update, and delete
operations. Fields that read directly from a table with an `origid` / `patientid` column are
**clean** for CDC and are not listed here.

---

## Quick Reference

| Node / Field | Indirect Table(s) | CDC Problem |
| --- | --- | --- |
| `care_team{}` | `dc_bene_alignment_rostr_m01` | No `origid` — joined via MBI cross-reference |
| `care_team.care_manager` | `personell` | No `origid` — resolved through `cds_patient_personell_assocs` |
| `rule_flags.awv_due` / `awv_last_date` | `mra1_encounter_bill_cpts` | No `origid` — joined via `encounter_nr → adt_encounter` |
| `rule_flags.sdoh_food_insecurity` | `encounter_risk_assesments` | No `origid` — joined via `encounter_nr → adt_encounter` |
| `chronic_conditions[]` | `adt_encounter_icd_codes`, `mra_hcc_coefficients` | 2-hop resolution + mass-impact on coefficient change |
| `hcc_capture{}` | `adt_encounter_icd_codes`, `mra_hcc_coefficients` | Same as chronic_conditions |
| `raf_profile{}` | `mra_raf_patient` × 3 subqueries | Cartesian `1=1` cross-join anti-pattern |
| `encounters[].diagnoses[]` | `mra_hcc_coefficients` | Coefficient change = mass patient re-index |
| `encounters[].procedures[]` (ADT branch) | `mra1_encounter_bill_cpts` | No `origid` — joined via `encounter_nr → adt_encounter` |
| ~~`encounters[].enc_medications[]`~~ | ~~`drfirst_patient_medications`~~ | **Clean** — `patientid` = origid; `dm.id` is stable PK |
| `labs[]` | `cpoe_result`, `cpoe_result_values`, `flowsheet_rows` | 3-hop resolution; `flowsheet_rows` is mass-impact |
| `sdoh.food_insecurity_flag` | `encounter_risk_assesments` | Same as `rule_flags.sdoh_food_insecurity` |

---

## Detailed Analysis

### 1. `patient.care_team{}` — outer block
**SP lines:** 92–118  
**Tables joined:** `dc_bene_alignment_rostr_m01 r` matched on `r.mm_curr_mbi_id = p.mra_clm_refer_m01`

```sql
FROM dc_bene_alignment_rostr_m01 r
WHERE r.mm_curr_mbi_id = p.mra_clm_refer_m01   -- cross-field join, not origid
  AND r.ALIGN_STATUS_CODE IN ('AL','D1Y')
ORDER BY r.mm_date DESC LIMIT 1
```

**CDC problem — INSERT/UPDATE/DELETE on `dc_bene_alignment_rostr_m01`:**  
The roster table has no `origid` column. It is keyed on `mm_curr_mbi_id` (Medicare Beneficiary
ID), which must be matched against `adt_patient.mra_clm_refer_m01`. When a roster row changes
the CDC handler cannot directly look up which patient is affected. It must:

1. Read `mm_curr_mbi_id` from the changed row.
2. Query `adt_patient WHERE mra_clm_refer_m01 = <mbi>` to resolve `origid`.
3. Re-run the SP for that `origid`.

A single roster update can match zero or one patient, but the resolution requires an extra DB
round-trip through `adt_patient` before the SP can be called.

---

### 2. `patient.care_team.care_manager` — scalar correlated subquery
**SP lines:** 104–108  
**Tables joined:** `cds_patient_personell_assocs cpa` → `personell per ON per.nr = cpa.personell_id`

```sql
(SELECT per.name
 FROM cds_patient_personell_assocs cpa
 JOIN personell per ON per.nr = cpa.personell_id
 WHERE cpa.origid = p_origid
 ORDER BY cpa.created_date DESC LIMIT 1)
```

**CDC problem — UPDATE on `personell`:**  
The `personell` table stores care manager names but has no `origid` column. If a care manager's
name changes (e.g., after a legal name change), the CDC event fires on `personell.nr`. To find
which patients are affected, the handler must:

1. Find the `personell.nr` that changed.
2. Query `cds_patient_personell_assocs WHERE personell_id = <nr>` to get the list of `origid`s.
3. Re-run the SP for each affected patient.

On large panels this can trigger a fan-out: one `personell` row change → N patient re-indexes.

**CDC problem — INSERT/DELETE on `cds_patient_personell_assocs`:**  
`cds_patient_personell_assocs` does have `origid`, so a new assignment or removal is
straightforward. However, the value returned also depends on `personell.name`, requiring the
JOIN at read time.

---

### 3. `rule_flags.awv_due` and `rule_flags.awv_last_date`
**SP lines:** 175–188  
**Tables joined:** `adt_encounter ae` INNER JOIN `mra1_encounter_bill_cpts cpt ON cpt.encounter_nr = ae.encounter_nr`

```sql
FROM adt_encounter ae
INNER JOIN mra1_encounter_bill_cpts cpt
  ON cpt.encounter_nr = ae.encounter_nr
WHERE ae.origid = p_origid
  AND cpt.bb_Code IN ('G0438','G0439')
```

**CDC problem — INSERT/UPDATE/DELETE on `mra1_encounter_bill_cpts`:**  
`mra1_encounter_bill_cpts` has no `origid` column. A new AWV billing code arrives as a new row
in this table with only `encounter_nr`. The CDC handler must:

1. Read `encounter_nr` from the changed row.
2. Query `adt_encounter WHERE encounter_nr = <nr>` to resolve `origid`.
3. Re-run the SP.

A delete of a CPT row (e.g., a billing correction) also requires this 2-hop resolution to
know which patient's `awv_due` flag must be recalculated.

---

### 4. `rule_flags.sdoh_food_insecurity`
**SP lines:** 214–219  
**Tables joined:** `encounter_risk_assesments era` INNER JOIN `adt_encounter ae ON ae.encounter_nr = era.encounter_nr`

```sql
FROM encounter_risk_assesments era
INNER JOIN adt_encounter ae ON ae.encounter_nr = era.encounter_nr
WHERE ae.origid = p_origid
  AND era.sub_type = 'SDOH'
  AND era.result_code_desc LIKE '%food%'
```

**CDC problem — INSERT/UPDATE/DELETE on `encounter_risk_assesments`:**  
`encounter_risk_assesments` has no `origid` column. It is keyed on `encounter_nr`. Every CDC
event on this table requires:

1. Read `encounter_nr` from the changed row.
2. Query `adt_encounter WHERE encounter_nr = <nr>` to resolve `origid`.
3. Re-run the SP.

An update that adds or removes a food-insecurity screening result can silently flip the
`sdoh_food_insecurity` flag in `rule_flags` — which rule engines read as a fast filter — without
any direct signal on the patient record.

---

### 5. `patient.chronic_conditions[]`
**SP lines:** 276–338  
**Tables joined (4-way):**

```
adt_encounter_icd_codes ai  INNER JOIN  adt_encounter ae         (resolve origid)
                             INNER JOIN  adt_encounter_icd_codes  (self-join for SNOMED/ccm_track)
                             LEFT  JOIN  mra_hcc_coefficients hc  (enrich with HCC number/score)
                             LEFT  JOIN  mra_uamcc_details ud      (enrich with condition_category)
```

**CDC problem — INSERT/UPDATE/DELETE on `adt_encounter_icd_codes`:**  
This table has no `origid`. Adding, removing, or changing a diagnosis code fires an event keyed
on `encounter_nr`. The handler must resolve `encounter_nr → adt_encounter.origid` before calling
the SP. The self-join (to aggregate SNOMED and ccm_track across all occurrences of the same
code) means the entire `chronic_conditions` block must be rebuilt — a single new ICD row can
change first/last onset dates, encounter counts, and recapture flags for that code.

**CDC problem — UPDATE on `mra_hcc_coefficients`:**  
This is a reference/lookup table (HCC version 28 mappings). If CMS updates a coefficient file
or activates a new date range, the change is not patient-specific — it affects every patient
who carries any of the updated diagnosis codes. There is no `origid` in this table and no way
to scope the re-index to a subset of patients. A coefficient file update requires a full
patient re-index pass.

---

### 6. `patient.hcc_capture{}`
**SP lines:** 376–420  
**Tables joined:**

```
-- outer eligible / captured counts:
mra_hcc_coefficients hc  INNER JOIN  (adt_encounter_icd_codes ai  INNER JOIN  adt_encounter ae)

-- gap_hccs subquery:
mra_hcc_coefficients hc2  INNER JOIN  (adt_encounter_icd_codes ai3  INNER JOIN  adt_encounter ae3)
  + NOT EXISTS subquery:   adt_encounter_icd_codes ai4  INNER JOIN  adt_encounter ae4
```

**CDC problem:**  
Same two problems as `chronic_conditions`:
1. `adt_encounter_icd_codes` changes require `encounter_nr → adt_encounter → origid` resolution.
2. `mra_hcc_coefficients` changes are mass-impact — no origid in the table.

In addition, the `gap_hccs` field uses a NOT EXISTS anti-join that checks whether each HCC code
was seen *this calendar year*. A CDC event that arrives on December 31st can flip a code from
"gap" to "captured" and then back to "gap" on January 1st — purely because `YEAR(CURDATE())`
changes, with no source table change at all. This time-sensitivity means `hcc_capture` must
also be refreshed on a nightly schedule, independent of any CDC event.

---

### 7. `patient.raf_profile{}`
**SP lines:** 341–373  
**Pattern:** Three independent subqueries each with `LIMIT 1`, cross-joined on `1=1`

```sql
FROM (SELECT 1) _base
LEFT JOIN (SELECT total_score, initial_score, MONTH
           FROM mra_raf_patient WHERE origid = ... AND TYPE = 'pmra' ...) pmra ON 1=1
LEFT JOIN (SELECT total_score, initial_score, MONTH
           FROM mra_raf_patient WHERE origid = ... AND TYPE = 'prmra' ...) prmra ON 1=1
LEFT JOIN (SELECT total_score, initial_score, MONTH
           FROM mra_raf_patient WHERE origid = ... AND TYPE = 'rmra'  ...) rmra ON 1=1
```

**CDC problem — cardinality risk:**  
`mra_raf_patient` does have `origid`, so the source table is CDC-friendly. The complication is
structural: the Cartesian `1=1` join pattern materializes three independent subqueries and
cross-joins them. If any subquery ever returns more than one row (e.g., the `LIMIT 1`
assumption fails due to a data defect), the resulting cross product multiplies rows and
produces corrupted `raf_profile` output without raising an error. CDC tests should verify the
row count before indexing.

Additionally, because each RAF type (pmra / prmra / rmra) is fetched in a separate subquery,
a CDC INSERT on `mra_raf_patient` for one type does not automatically refresh the values for
the other two types — the SP must be re-run in full to keep all three consistent.

---

### 8. `patient.encounters[].diagnoses[]` — both branches
**SP lines (Branch A / ADT):** 626–653  
**SP lines (Branch B / mra1):** 860–887  
**Tables joined:**

```sql
FROM adt_encounter_icd_codes aic
LEFT JOIN mra_hcc_coefficients hcd
  ON hcd.diagnosis_code = aic.diagnosis_code
 AND hcd.active_date <= NOW() AND hcd.inactive_date >= NOW()
WHERE aic.encounter_nr = ae.encounter_nr     -- correlated to outer encounter row
```

**CDC problem — INSERT/DELETE on `adt_encounter_icd_codes`:**  
Adding or removing a diagnosis code for an encounter fires an event keyed on `encounter_nr`.
Resolving to `origid` requires joining `adt_encounter`. This is a 2-hop: `encounter_nr →
adt_encounter → origid`.

**CDC problem — UPDATE on `mra_hcc_coefficients`:**  
Same mass-impact issue as `chronic_conditions`. The HCC number and score embedded in each
encounter diagnosis object (`hcc_number`, `hcc_score`, `hcc_included`) will silently stale if
coefficients are updated without a full patient re-index.

---

### 9. `patient.encounters[].procedures[]` (ADT branch only)
**SP lines:** 656–668  
**Source table:** `mra1_encounter_bill_cpts` — correlated to the ADT encounter by `encounter_nr`

```sql
FROM mra1_encounter_bill_cpts cpt
WHERE cpt.encounter_nr = ae.encounter_nr   -- ae is from adt_encounter
```

**CDC problem — INSERT/UPDATE/DELETE on `mra1_encounter_bill_cpts`:**  
`mra1_encounter_bill_cpts` has no `origid`. The CDC handler must:

1. Read `encounter_nr` from the changed CPT row.
2. Query `adt_encounter WHERE encounter_nr = <nr>` to resolve `origid`.
3. Re-run the SP.

This is the same 2-hop as the AWV flag, but it surfaces inside the encounter array rather than
`rule_flags`. Because the billing code data crosses systems (CCLF claim data embedded in an
ADT encounter context), a billing correction in the CCLF feed updates `mra1_encounter_bill_cpts`
and must trigger an ES document replacement via the ADT encounter's patient.

---

### 10. `patient.encounters[].enc_medications[]` — both branches — CLEAN

**SP lines (Branch A / ADT):** 671–692  
**SP lines (Branch B / mra1):** 904–926

```sql
FROM drfirst_patient_medications dm
WHERE dm.patientid = p_origid          -- origid is directly available
  AND dm.admission = 'yes'
  AND DATE(dm.start_date) = DATE(ae.encounter_date)   -- internal grouping only
```

**`drfirst_patient_medications` has both `id` (PK) and `patientid` (= origid).**  
The date-match is an internal SP aggregation detail — it groups admission meds under their
encounter for display, but it does not affect CDC resolution:

| CDC event | Resolution |
| --- | --- |
| INSERT | new row's `patientid` = origid → call SP immediately |
| UPDATE | same row, `patientid` unchanged → call SP with origid |
| DELETE | before-image's `patientid` = origid → call SP with origid |

`dm.id` is already emitted as the JSON `id` field for each medication item, so each item in
`enc_medications[]` has a stable, unique key. **No join resolution required for any CDC
operation on this table.**

---

### 11. `patient.labs[]`
**SP lines:** 948–975  
**Tables joined (3 hops):**

```sql
FROM cpoe_result cr
INNER JOIN adt_encounter ae ON ae.encounter_nr = cr.encounter_nr   -- hop 1: resolve origid
LEFT  JOIN cpoe_result_values crv ON crv.result_id = cr.result_id  -- hop 2: result values
LEFT  JOIN flowsheet_rows fr ON fr.frows_nr = crv.item_id          -- hop 3: test name
WHERE ae.origid = p_origid
```

**CDC problem — INSERT/UPDATE on `cpoe_result`:**  
`cpoe_result` has no `origid`. Resolution requires `encounter_nr → adt_encounter → origid`
(2-hop).

**CDC problem — INSERT/UPDATE on `cpoe_result_values`:**  
`cpoe_result_values` has no `origid` and no `encounter_nr`. Resolution requires
`result_id → cpoe_result → encounter_nr → adt_encounter → origid` (3-hop). Each hop is a
separate DB round-trip before the CDC handler knows which patient document to replace.

**CDC problem — UPDATE on `flowsheet_rows`:**  
`flowsheet_rows` is a reference/definition table that maps `frows_nr` to `frows_name` (the
human-readable test name). It has no `origid`. If a test name is renamed or corrected, every
patient who has a lab result referencing that `frows_nr` must be re-indexed. There is no way
to scope the re-index to a subset of patients — it is a mass-impact update identical to the
`mra_hcc_coefficients` problem.

---

### 12. `patient.sdoh.food_insecurity_flag`
**SP lines:** 1071–1078

This is identical in structure to `rule_flags.sdoh_food_insecurity` (item 4 above). It queries
`encounter_risk_assesments` joined to `adt_encounter` and has the same 2-hop CDC resolution
problem. Both fields must be refreshed together when `encounter_risk_assesments` changes.

---

## Summary: CDC Resolution Patterns

The table below classifies each indirect join by the strategy needed to resolve `origid` at
CDC time.

| Strategy | Fields Affected | Resolution Steps |
| --- | --- | --- |
| **1-hop via `encounter_nr`** | `rule_flags.awv_due`, `rule_flags.awv_last_date`, `encounters[].procedures[]`, `rule_flags.sdoh_food_insecurity`, `sdoh.food_insecurity_flag` | `changed_table.encounter_nr → adt_encounter → origid` |
| **1-hop via MBI cross-reference** | `care_team{}` (all fields) | `dc_bene_alignment_rostr_m01.mm_curr_mbi_id → adt_patient.mra_clm_refer_m01 → origid` |
| **1-hop via personell fan-out** | `care_team.care_manager` | `personell.nr → cds_patient_personell_assocs → origid (many rows possible)` |
| **2-hop via result chain** | `labs[]` (on `cpoe_result_values` change) | `cpoe_result_values.result_id → cpoe_result.encounter_nr → adt_encounter → origid` |
| **Date-match (no FK)** | `encounters[].enc_medications[]` | `origid` is available but encounter assignment depends on date equality — partial update impossible |
| **Mass-impact (no origid, no scoping)** | `chronic_conditions[]`, `hcc_capture{}`, `encounters[].diagnoses[]`, `labs[]` (on `flowsheet_rows` change) | All patients with matching diagnosis/result codes must be re-indexed |

---

## Nodes with NO Join Complexity (Clean CDC)

These nodes read directly from tables with an `origid` / `patientid` column and require no
join resolution. A CDC event on these tables can call the SP immediately with the known origid.

| Node | Source Table | CDC Key |
| --- | --- | --- |
| `demographics`, `contact`, `enrollment` | `adt_patient` | `origid` |
| `rule_flags.readmit_*`, `open_inpatient`, `last_admission_date` | `adt_encounter` | `origid` |
| `rule_flags.raf_score` | `mra_raf_patient` | `origid` |
| `rule_flags.hedis_gaps_open`, `active_alerts` | `mra_scorecard_alerts` | `origid` |
| `rule_flags.ccm_enrolled`, `pcp_visit_overdue` | `adt_patient` | `origid` |
| `rule_flags.sdoh_transport_barrier`, `sdoh.transport_barrier_flag` | `transportation_benefit` | `orig_id` |
| `rule_flags.sdoh_meal_plan_active`, `sdoh.meal_plans[]` | `sdoh_meal_plan` | `origid` |
| `rule_flags.care_plan_active` | `care_plan_patient` | `origid` |
| `rule_flags.uamcc_eligible` | `mra_uamcc_details` | `origid` |
| `uamcc{}` | `mra_uamcc_details` | `origid` |
| `medication_adherence{}` | `drfirst_patient_medications` | `patientid` |
| `hedis_measures[]` | `mra_scorecard_alerts` | `origid` |
| `medications[]` | `drfirst_patient_medications` | `patientid` |
| `assessments[]` | `mra_assessments_and_screenings` | `origid` |
| `alerts[]` | `mra_scorecard_alerts` | `origid` |
| `sdoh.reward_programs[]` | `chronic_disease_reward_program` | `origid` |
| `sdoh.transport_benefits[]` | `transportation_benefit` | `orig_id` |
| `emr_appointments[]` | `adt_appointment` | `origid` |
| `encounters[]` (ADT spine) | `adt_encounter` | `origid` |
| `encounters[]` (mra1 spine) | `mra1_encounter` | `patient_id` |
| `raf_profile{}` | `mra_raf_patient` | `origid` (3× subqueries, `1=1` join risk — see §7) |
