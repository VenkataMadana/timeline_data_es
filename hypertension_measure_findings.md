# Hypertension Measure PC-001 — Elasticsearch Rules Engine: Findings & Required Changes

**Measure:** PC-001 Hypertension Management (CMS165 — Controlling High Blood Pressure)
**Patient:** Carol Lee Bailey (`7H49DQ0VG28`)
**Validated against:** `sample_json_data.json` (schema version 2.0, source: mradb_prod)
**Pipeline artifact:** `es_hypertension_pipeline.json`
**Date:** 2026-06-11

---

## 1. Summary

The measure definition (`hypertension_measure 1.json`) was written against a relational database schema (tables: `patient`, `mra1_encounter_icd_codes`, `mra1_encounter_bill_cpts`). The Elasticsearch document (`sample_json_data.json`) uses a nested JSON structure under `patient.*`. All four data elements require a path remapping, and one data element (**DE-3: BP Measurement CPT**) cannot be validated because procedure data is missing from the sample document.

Three of four rules pass for the sample patient. The HEDIS cross-check independently confirms the patient has an open "Controlling High BP" gap.

---

## 2. Data Element Mapping: Relational → JSON

| DE ID | Name | Original Table | Original Field | JSON Path | Status |
|-------|------|---------------|----------------|-----------|--------|
| de-1781178177381 | Age | `patient` | `patient_age` | `patient.demographics.age` | ✅ Mapped |
| de-1781178461754 | Problem/Diagnosis Code | `mra1_encounter_icd_codes` | `problem_code` | `patient.chronic_conditions[].icd_code` **OR** `patient.encounters[].diagnoses[].icd_code` | ✅ Mapped (two sources) |
| de-1781178618255 | Procedure Code (BP present) | `mra1_encounter_bill_cpts` | `procedure_code` | `patient.encounters[].procedures[].procedure_code` | ⚠️ Mapped, no data |
| de-1781178801758 | Procedure Code (exclusions absent) | `mra1_encounter_bill_cpts` | `procedure_code` | `patient.encounters[].procedures[].procedure_code` | ⚠️ Mapped, no data |

### Key structural differences

- **`patient` table → `patient.demographics`**: The relational `patient` table's `patient_age` column lives at `patient.demographics.age` in the JSON. The field is pre-computed; DOB is also available at `patient.demographics.dob` for server-side age calculation.
- **`mra1_encounter_icd_codes` → two JSON locations**: Diagnosis codes exist in both `patient.chronic_conditions[].icd_code` (consolidated problem list) and `patient.encounters[].diagnoses[].icd_code` (encounter-level). Both must be searched with a `should` / `minimum_should_match: 1` query. Nested queries are required since both are nested arrays.
- **`mra1_encounter_bill_cpts` → `patient.encounters[].procedures`**: Procedure codes are nested two levels deep under encounters. In the sample document, `procedures` is `null` for all 61 encounters — this field is not yet populated from the source system.

---

## 3. Validation Results — Sample Patient

### DE-1: Age (18–85)
- **Rule:** `patient.demographics.age` between 18 and 85
- **Patient value:** `79`
- **Result:** ✅ PASS

### DE-2: Hypertension ICD Code (contains any of I10, I11.x, I12.x, I13.x, I15.x, I16.x)
- **Rule:** `patient.chronic_conditions[].icd_code` OR `patient.encounters[].diagnoses[].icd_code` contains a hypertension code
- **Matched codes:**
  - `chronic_conditions`: **I10** (Essential hypertension, Active, last seen 2023-09-13)
  - `encounters.diagnoses`: **I10** (encounter ID 202303235614690365)
- **Result:** ✅ PASS

### DE-3: BP Measurement CPT Present (3077F or 3080F)
- **Rule:** `patient.encounters[].procedures[].procedure_code` contains 3077F or 3080F
- **Patient value:** `encounters[].procedures` is `null` for all 61 encounter records
- **Result:** ❌ BLOCKED — no procedure data

### DE-4: Exclusion CPT Codes Absent (G8950, G8952, G8783, G9745, M1278, M1279)
- **Rule:** `patient.encounters[].procedures[].procedure_code` does NOT contain any exclusion code
- **Patient value:** No procedure records → no exclusion codes present
- **Result:** ✅ PASS (vacuously — no data to match against)

### HEDIS Cross-Validation
- Patient has **2 open gaps** for "Controlling High BP" (measure year 2026, last screening 2022-12-15)
- This independently confirms the patient is a measure candidate — consistent with DE-1 and DE-2 passing.

### Overall Measure Match
| Condition | Result |
|-----------|--------|
| DE-1 age eligible | ✅ |
| DE-2 hypertension diagnosis present | ✅ |
| DE-3 BP measurement CPT present | ❌ No data |
| DE-4 exclusion CPT absent | ✅ |
| **PC-001 candidate (partial)** | **⚠️ Likely YES — blocked on DE-3** |

---

## 4. Required Changes

### 4.1 Measure Definition — Table/Field Name Remapping (Required)

Update `dataElements` in `hypertension_measure 1.json` to replace relational table references with JSON paths:

```json
// DE-1: Age
"table": "patient.demographics",
"selectedField": "age"

// DE-2: Problem/Diagnosis Code
"table": "patient.chronic_conditions OR patient.encounters[].diagnoses",
"selectedField": "icd_code"

// DE-3 and DE-4: Procedure Code
"table": "patient.encounters[].procedures",
"selectedField": "procedure_code"
```

### 4.2 Diagnosis Code Source Strategy (Required)

The measure currently references a single table (`mra1_encounter_icd_codes`). In the JSON model, diagnoses exist in two places with different freshness:

| Source | Path | Use Case |
|--------|------|----------|
| Chronic conditions (problem list) | `patient.chronic_conditions[].icd_code` | Historical/longitudinal — preferred for measure lookback |
| Encounter diagnoses | `patient.encounters[].diagnoses[].icd_code` | Encounter-specific — use for recent activity checks |

**Recommendation:** Search both sources using `bool.should` (as implemented in `es_hypertension_pipeline.json`).

### 4.3 Procedure Data Population (Critical — Blocks DE-3)

`patient.encounters[].procedures` is `null` for all encounters in the sample. This prevents evaluating DE-3 (BP measurement codes 3077F/3080F) entirely.

**Required actions:**
1. Confirm whether the ETL pipeline (`sp_get_patient_es_doc.sql`) populates `encounters[].procedures` from `mra1_encounter_bill_cpts`.
2. If the field is intentionally omitted, add a dedicated top-level array `patient.bill_cpts[]` mapped from claims data.
3. Until resolved, DE-3 cannot gate measure eligibility — patients will be flagged based on DE-1, DE-2, and DE-4 only.

### 4.4 Elasticsearch Index Mapping (Required)

Use nested field types for all array objects to support nested queries. Flat `object` mapping will cause incorrect query results for multi-value arrays. The required mappings are defined in `es_hypertension_pipeline.json` under `index_settings.mappings`.

### 4.5 Duplicate HEDIS Gap Records (Minor)

`patient.hedis_measures` contains **two identical entries** for "Controlling High BP" (both `frows_nr` 328565 and 578094, same `last_screening_date`). De-duplicate at ingest or accept in downstream aggregations.

---

## 5. Elasticsearch Pipeline Components Delivered

**File:** `es_hypertension_pipeline.json`

| Component | Key |
|-----------|-----|
| Index mapping | `index_settings` |
| DE-1 age range query | `queries.de_1_age_between_18_85` |
| DE-2 hypertension ICD query (both sources) | `queries.de_2_hypertension_icd_code` |
| DE-3 BP CPT present query | `queries.de_3_bp_measurement_cpt_present` |
| DE-4 exclusion CPT absent query | `queries.de_4_bp_exclusion_cpt_absent` |
| Combined measure query | `queries.full_measure_combined` |
| HEDIS gap cross-validation | `queries.validation_hedis_gap_check` |
| Ingest pipeline (Painless script) | `ingest_pipeline` |

The ingest pipeline script sets `measure_flags.pc001_candidate = true` when DE-1, DE-2, and DE-4 pass. It sets `measure_flags.pc001_bp_measurement_present = false` as a placeholder until DE-3 data is available.

---

## 6. Next Steps

1. **Populate procedure data** — trace `sp_get_patient_es_doc.sql` to confirm why `encounters[].procedures` is null and fix the ETL.
2. **Apply index mappings** — create or update the `patients` index with the nested mappings before indexing documents.
3. **Index the sample document** — run `POST /patients/_doc/7H49DQ0VG28` with the ingest pipeline to verify `measure_flags` are set correctly.
4. **Re-run DE-3 validation** once procedure data is available to complete the full rule evaluation.
5. **Extend to population** — once validated on the sample patient, run the combined measure query against all patients in the index to build the CMS165 worklist.
