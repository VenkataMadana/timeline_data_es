# CLAUDE.md — Patient Value Care · Elasticsearch Rules Engine

## Project Purpose

Convert patient records from a MySQL relational database (`mradb_prod`) into a single nested JSON document per patient, index them into Elasticsearch, and run measure/quality rules as analytical search pipelines. The system supports two loading modes:

---

## Development Workflow

The canonical authoring sequence for any new section of the document is:

```
1. HTML mapping file  (table_to_json_mapping.html)
   └─ defines: MySQL table → JSON path, MySQL column → JSON key,
               data type, transformation, CDC key column, purpose

2. Excel review       (optional — same columns as HTML, for stakeholder review)

3. Stored procedure   (sp_get_patient_es_doc.sql pattern)
   OR Python script   — translates the mapping into executable INSERT/UPDATE logic

4. Validate           — run against sample_json_data.json, confirm ES queries return expected results
```

**When adding a new data source or JSON section:**
- Add rows to `table_to_json_mapping.html` first using the existing table/column structure (JSON Path, Source Table, Source Column, MySQL Type, CDC Key, Transformation, Value-Care Purpose).
- Once the mapping is agreed, implement it in the SP (initial load) and the relevant CDC stored procedure listed in `routing-config.json`.
- If a Python script is used instead of a stored procedure, it must implement the same `ReplaceOne` strategy: call `sp_get_patient_es_doc` (or an equivalent query), then `PUT /patients/_doc/{origid}`.

---

- **Initial load** — full patient document built by `sp_get_patient_es_doc.sql`, indexed once per patient
- **Incremental/CDC** — table-level change events route through `routing-config.json` to targeted stored procedures that rebuild only the changed sub-section of the document, then replace the ES document

The primary use case is a **clinical rules engine**: a measure definition (e.g., `hypertension_measure 1.json`) declares data elements with comparison operators; the pipeline translates those into ES queries and flags matching patients for worklist routing.

---

## Repository Layout

| File | Role |
|------|------|
| `sp_get_patient_es_doc.sql` | MySQL stored procedure — builds the full patient JSON for initial load. One document per `origid`. Sets `_meta.trigger_source = 'initial_load'`. |
| `patient_value_care_schema.json` | Canonical schema v2.0 — authoritative field list, types, and CDC notes. Source of truth for ES mappings. |
| `sample_json_data.json` | Real patient document (Carol Bailey, `7H49DQ0VG28`) used for testing. |
| `routing-config.json` | CDC routing table — maps each MySQL source table to the stored procedure(s) that must re-run when that table changes. |
| `hypertension_measure 1.json` | Example measure definition (PC-001 CMS165). Declares data elements, comparison operators, triggers, and worklist routing. |
| `es_hypertension_pipeline.json` | Elasticsearch pipeline artifact — index mappings, per-rule queries, combined measure query, Painless ingest script. |
| `hypertension_measure_findings.md` | Findings document — relational-to-JSON field mapping, validation results, required changes. |
| `mradb_Schema.sql` | Source MySQL DDL — reference for source table structure. |
| `table_to_json_mapping.html` | Visual mapping of MySQL tables → JSON paths. |

---

## Document Architecture

### ES Document Identity

```
ES index   : patients
ES _id     : patient.id  (= origid = CDC primary key)
CDC key    : patient.id / patient.origid
account_id : universal cross-section correlation key (joins across sub-arrays)
```

### Top-Level Patient Structure

```
patient
├── id / origid / account_id / mbi
├── demographics          ← age, dob, sex, race, language
├── contact               ← address, phone, email, emergency_contact
├── care_team             ← dce_provider, dce_group, care_manager, market
├── enrollment            ← ccm_enabled, ccm_level, consent_on_file
├── rule_flags{}          ← PRE-COMPUTED summary — rule engines read this FIRST
├── chronic_conditions[]  ← icd_code, hcc_number, status, last_seen_date
├── encounters[]          ← spine — all clinical events; each embeds:
│   ├── diagnoses[]       ← icd_code (from adt_encounter_icd_codes)
│   ├── procedures[]      ← billing_code (from mra1_encounter_bill_cpts)
│   ├── risk_screenings[]
│   ├── enc_medications[]
│   ├── transport{}
│   ├── home_program{}
│   ├── care_plans[]
│   ├── communications[]
│   └── documents[]
├── medications[]         ← patient-level (drfirst), not encounter-linked
├── labs[]                ← cpoe_result / cpoe_result_values
├── alerts[]              ← mra_scorecard_alerts
├── assessments[]
├── hedis_measures[]      ← measure_name, status, gap_open, last_screening_date
├── raf_profile{}
├── risk_scores{}
├── hcc_capture{}
├── uamcc{}
├── sdoh{}
├── emr_appointments[]
└── _meta{}               ← schema_version, trigger_source, created_at
```

**Rule of thumb:** Sub-arrays that have an `encounter_nr` in MySQL are embedded inside `encounters[]`. Sub-arrays without one (`medications`, `labs`, `assessments`, `alerts`, `hedis_measures`, `raf_profile`, `risk_scores`, `uamcc`, `sdoh`, `emr_appointments`) live at the patient top-level.

### `rule_flags{}` — Critical Performance Pattern

`rule_flags` is a flat key-value object pre-computed at write time by `sp_get_patient_es_doc.sql`. Rule engines **always read `rule_flags` first** — this avoids nested query traversal for common filters:

```json
"rule_flags": {
  "risk_tier":            "High",
  "raf_score":            1.412,
  "readmit_30d":          false,
  "hedis_gaps_open":      2,
  "awv_due":              true,
  "ccm_enrolled":         true,
  "sdoh_food_insecurity": true,
  ...
  "last_updated":         "2025-06-04T00:00:00Z"
}
```

When adding a new measure, determine whether its primary filter can be expressed as a `rule_flags` boolean — if yes, add it here and update both the SP and the CDC procedure.

---

## Measure Definition → ES Pipeline Translation

A measure file (`hypertension_measure 1.json` pattern) declares `dataElements[]`. Each element has:

| Measure Field | ES Translation |
|---------------|----------------|
| `table` | Relational name → JSON path (see mapping below) |
| `selectedField` | Leaf key within that JSON path |
| `comparisonOperator` | `between` → `range`, `contains` → `terms`, `not_contains` → `bool.must_not.terms` |
| `valueMode: latest` | Add `sort` + `size: 1` on the nested query, or rely on encounter order |
| `allowNull: 0` / `nullHandling: exclude` | Add `exists` filter on the field |

### Source Table → JSON Path Mapping

| MySQL Table | JSON Path | ES Field Type |
|-------------|-----------|---------------|
| `adt_patient` | `patient.demographics.*` | flat keyword/integer |
| `adt_encounter_icd_codes` | `patient.encounters[].diagnoses[].icd_code` | nested keyword |
| `chronic_disease_*` (problem list) | `patient.chronic_conditions[].icd_code` | nested keyword |
| `mra1_encounter_bill_cpts` | `patient.encounters[].procedures[].billing_code` | nested keyword |
| `mra_scorecard_alerts` | `patient.alerts[]` | nested |
| `mra_raf_patient` | `patient.raf_profile` / `patient.rule_flags.raf_score` | float |
| `qip_uamcc_lambda` / `mra_uamcc_details` | `patient.uamcc` | object/nested |
| `mra_assessments_and_screenings` | `patient.assessments[]` | nested |
| `cpoe_result` / `cpoe_result_values` | `patient.labs[]` | nested |
| `drfirst_patient_medications` | `patient.medications[]` | nested |
| `care_plan` / `care_plan_patient` | `patient.encounters[].care_plans[]` | nested |
| `adt_appointment` | `patient.emr_appointments[]` | nested |

**Diagnosis codes exist in two locations** — always search both with `bool.should`:
1. `patient.chronic_conditions[].icd_code` — longitudinal problem list
2. `patient.encounters[].diagnoses[].icd_code` — encounter-specific

**Procedure codes field name** — in the JSON document the field is `billing_code` (not `procedure_code`). The measure definition uses `procedure_code` as the logical name; map it to `patient.encounters[].procedures[].billing_code` in ES.

---

## Elasticsearch Index Configuration

### Mappings — Critical Rules

1. All arrays of objects **must** use `"type": "nested"` — never `object`. Flat `object` mapping produces incorrect nested query results.
2. Date fields must be `"type": "date"` with `"format": "yyyy-MM-dd||strict_date_optional_time"`.
3. ICD and CPT codes are `"type": "keyword"` — never `text` (exact match required, no analysis).
4. `rule_flags` fields are flat — they live at the top level, not nested.

### Key Nested Paths

```
patient.chronic_conditions         (nested)
patient.encounters                 (nested)
patient.encounters.diagnoses       (nested)
patient.encounters.procedures      (nested)
patient.encounters.risk_screenings (nested)
patient.encounters.enc_medications (nested)
patient.alerts                     (nested)
patient.medications                (nested)
patient.labs                       (nested)
patient.assessments                (nested)
patient.hedis_measures             (nested)
patient.emr_appointments           (nested)
```

### Index Pattern

```
Index name  : patients
Document ID : patient.id  (origid)
Refresh     : 1s (default) — adjust for bulk initial load
Shards      : size to ~30GB per shard; start with 3 primary for production
```

---

## Loading Strategies

### Initial Load

1. Call `sp_get_patient_es_doc(p_origid)` per patient — returns a single `es_doc` JSON column.
2. `_meta.trigger_source` is set to `'initial_load'` by the SP.
3. Index via `PUT /patients/_doc/{origid}` (full replace).
4. Use the Elasticsearch bulk API for batch loads (`_bulk` endpoint, `index` action).
5. Run the ingest pipeline `hypertension_measure_pc001` on index to compute `measure_flags`.

### Incremental / CDC

`routing-config.json` maps each MySQL table to the stored procedure(s) that must re-run on change:

```
table changed → look up routing-config.json → run listed SP(s) → SP returns partial JSON → ES ReplaceOne on patient.id
```

CDC strategy is **full document replace** (`ReplaceOne` / `PUT /patients/_doc/{id}`), not partial update. The SP rebuilds the entire patient document each time. This avoids merge conflicts and keeps the document consistent.

`_meta.trigger_source` should be set to the triggering table name by CDC procedures (not `'initial_load'`).

**Tables with indirect patient resolution** (no direct `patient_id_col`) use a `join` block in `routing-config.json` — the CDC consumer must resolve `origid` via the join before calling the SP.

---

## Python Script Pattern (Alternative to SP)

When using Python instead of a stored procedure for insert/update:

```python
# Initial load — single patient
import mysql.connector
from elasticsearch import Elasticsearch

def load_patient(origid: str, mysql_conn, es_client):
    cursor = mysql_conn.cursor(dictionary=True)
    cursor.callproc("sp_get_patient_es_doc", [origid])
    for result in cursor.stored_results():
        row = result.fetchone()
        if row:
            doc = json.loads(row["es_doc"])
            es_client.index(
                index="patients",
                id=origid,
                document=doc,
                pipeline="hypertension_measure_pc001"
            )

# CDC incremental — triggered by routing-config.json
def handle_cdc_event(table_name: str, origid: str, mysql_conn, es_client):
    # Look up which SPs to call from routing-config.json
    with open("routing-config.json") as f:
        routing = json.load(f)
    if table_name not in routing:
        return
    # For each mapped SP, rebuild and replace the document
    load_patient(origid, mysql_conn, es_client)

# Bulk initial load
def bulk_load(origids: list[str], mysql_conn, es_client, batch_size=500):
    actions = []
    for origid in origids:
        cursor = mysql_conn.cursor(dictionary=True)
        cursor.callproc("sp_get_patient_es_doc", [origid])
        for result in cursor.stored_results():
            row = result.fetchone()
            if row:
                actions.append({"_index": "patients", "_id": origid,
                                 "_source": json.loads(row["es_doc"])})
        if len(actions) >= batch_size:
            helpers.bulk(es_client, actions)
            actions.clear()
    if actions:
        helpers.bulk(es_client, actions)
```

Key points:
- Always use `PUT /patients/_doc/{origid}` (full replace), never `POST` without an ID.
- Pass the ingest pipeline name on every index call so `measure_flags` are computed.
- For CDC events on tables with a `join` block in `routing-config.json`, resolve `origid` via the join before calling the SP.
- Set `_meta.trigger_source` to the source table name (not `'initial_load'`) on CDC events — update the SP parameter or set it in Python after parsing the JSON.

---

## Rules Engine Query Patterns

### Pattern 1 — Simple scalar filter (e.g., age range)
```json
{ "range": { "patient.demographics.age": { "gte": 18, "lte": 85 } } }
```

### Pattern 2 — Nested code match (e.g., ICD diagnosis)
```json
{
  "bool": {
    "should": [
      { "nested": { "path": "patient.chronic_conditions",
          "query": { "terms": { "patient.chronic_conditions.icd_code": ["I10","I11.0"] } } } },
      { "nested": { "path": "patient.encounters",
          "query": { "nested": { "path": "patient.encounters.diagnoses",
              "query": { "terms": { "patient.encounters.diagnoses.icd_code": ["I10","I11.0"] } } } } } }
    ],
    "minimum_should_match": 1
  }
}
```

### Pattern 3 — Exclusion (not_contains operator)
```json
{
  "bool": {
    "must_not": [
      { "nested": { "path": "patient.encounters",
          "query": { "nested": { "path": "patient.encounters.procedures",
              "query": { "terms": { "patient.encounters.procedures.billing_code": ["G8950","G8952"] } } } } } }
    ]
  }
}
```

### Pattern 4 — rule_flags shortcut (fastest — no nested traversal)
```json
{ "term": { "patient.rule_flags.hedis_gaps_open": { "gt": 0 } } }
```

### Pattern 5 — HEDIS gap cross-validation
```json
{ "nested": { "path": "patient.hedis_measures",
    "query": { "bool": { "must": [
      { "term": { "patient.hedis_measures.measure_name": "Controlling High BP" } },
      { "term": { "patient.hedis_measures.gap_open": true } }
    ] } } } }
```

---

## Known Data Gaps

| Gap | Impact | Resolution |
|-----|--------|------------|
| `encounters[].procedures` is null in sample data | DE-3 (BP CPT check) cannot be evaluated | Confirm `sp_get_patient_es_doc.sql` line 631 populates this from `mra1_encounter_bill_cpts`; verify data exists in source table for this patient |
| `hedis_measures` has duplicate entries for same measure | Double-counting in aggregations | De-duplicate by `(measure_name, measure_year, frows_nr)` at ingest or use `cardinality` aggregation |
| `billing_code` in JSON vs `procedure_code` in measure definitions | Measure files use wrong field name | The SP (line 636) outputs `billing_code`; the JSON schema uses `billing_code`; measure `dataElements` must use `billing_code` as `selectedField`, not `procedure_code`. Update the HTML mapping to reflect this. |

---

## Adding a New Measure

1. Create a measure JSON file following the `hypertension_measure 1.json` schema.
2. For each `dataElement`, map `table` + `selectedField` to a JSON path using the table mapping above.
3. Translate `comparisonOperator` to an ES query using the patterns in the Rules Engine section.
4. Determine if the measure's primary filter belongs in `rule_flags` — if high-frequency, add it there.
5. Add the measure's ingest pipeline processor to set `measure_flags.{measure_id}_candidate`.
6. Add the combined query to the measure's pipeline JSON file.
7. Validate against `sample_json_data.json` before deploying.

---

## Key Conventions

- **Document replace, not partial update** — always rebuild and replace the full document on CDC events.
- **`origid` is the canonical patient key** — use it as the ES `_id`, the CDC key, and the SP input parameter.
- **`account_id` is the correlation key** — use it to join across sub-arrays when sub-array items lack `origid`.
- **ICD/CPT codes are `keyword` type** — never analyze them; always use `term`/`terms` queries.
- **Nested paths need nested queries** — never use a `term` query directly on a field inside a `nested` object.
- **`rule_flags` is the fast lane** — pre-compute any boolean/scalar a rule engine will filter on frequently.
- **Schema version is `2.0`** — set in `_meta.schema_version`; increment if the document structure changes.
