# Patient Value Care — Elasticsearch Rules Engine

Converts patient records from MySQL (`mradb_prod`) into a single nested JSON document per patient, indexes them into Elasticsearch, and runs measure/quality rules as analytical search pipelines.

---

## Repository layout

| File | Purpose |
|------|---------|
| `sp_get_patient_es_doc.sql` | MySQL stored procedure — builds the full patient JSON document |
| `patient_value_care_schema.json` | Canonical schema v2.0 — authoritative field list |
| `sample_json_data.json` | Reference output for patient `7H49DQ0VG28` (Carol Bailey) |
| `routing-config.json` | CDC routing — maps MySQL tables to stored procedures |
| `table_to_json_mapping.html` | Visual mapping of MySQL columns → JSON paths |
| `test_es_sp.py` | CLI tool: load SP, call it, view output, validate structure |
| `hypertension_measure 1.json` | Example measure definition (PC-001 CMS165) |
| `es_hypertension_pipeline.json` | Elasticsearch pipeline artifact for hypertension measure |

---

## Prerequisites

**Python packages**

```bash
pip install pymysql python-dotenv
```

**`.env` file** — copy from `.env.example` or create manually at the project root:

```ini
DB_HOST=mrauatdevdb.ccwlsodxtwq3.us-west-2.rds.amazonaws.com
DB_PORT=3306
DB_NAME=mradb_prod
DB_USER=admin
DB_PASSWORD=<your-password>

DEFAULT_PATIENT_ID=7H49DQ0VG28   # origid used when no ID is passed on the command line
```

---

## Step 1 — Load the stored procedure

Run this once after any change to `sp_get_patient_es_doc.sql`. It drops the existing SP and recreates it from the local file.

```bash
python test_es_sp.py --validate-sp
```

Expected output:

```
Reading D:\...\sp_get_patient_es_doc.sql …
Connecting to mrauatdevdb… / mradb_prod …
DROP PROCEDURE IF EXISTS sp_get_patient_es_doc …
CREATE PROCEDURE sp_get_patient_es_doc …
SP compiled and loaded successfully.
```

If the CREATE fails, MySQL will print the exact line number and error. Fix the SQL, then re-run.

---

## Step 2 — Get the sample JSON

### Summary view (default)

```bash
python test_es_sp.py
```

Prints a human-readable summary of every section for `DEFAULT_PATIENT_ID`:

```
----------------------------------------------------------------------
  ES DOCUMENT SUMMARY
  patient.id  : 7H49DQ0VG28
  origid      : 7H49DQ0VG28
----------------------------------------------------------------------
-- demographics
   name : Bailey, Carol
   dob  : 1944-03-09  age=81  sex=Female
...
-- array counts
   encounters            : 42
   labs                  : 7
   medications           : 12
   ...
```

### Specific patient

```bash
python test_es_sp.py <origid>
```

### Save to file

```bash
python test_es_sp.py --save
# writes 7H49DQ0VG28_es_doc.json to the current directory

python test_es_sp.py <origid> --save
# writes <origid>_es_doc.json
```

### Print one section as JSON

```bash
python test_es_sp.py --section encounters
python test_es_sp.py --section rule_flags
python test_es_sp.py --section chronic_conditions
python test_es_sp.py --section labs
python test_es_sp.py --section medications
python test_es_sp.py --section hedis_measures
python test_es_sp.py --section sdoh
python test_es_sp.py --section _meta
```

### Print the raw JSON string

```bash
python test_es_sp.py --raw
```

---

## Step 3 — Validate the JSON structure

`--validate-doc` checks that every required top-level key and every `rule_flags` field is present in the returned document. It exits with code 1 and lists failures if anything is missing.

```bash
python test_es_sp.py --validate-doc
```

Expected output on success:

```
Connecting to mrauatdevdb… / mradb_prod …
Calling sp_get_patient_es_doc('7H49DQ0VG28') …
Document received in 128.05s  (2,463.1 KB)

VALIDATION PASSED — all 21 patient keys and 13 rule_flags present.
```

Example failure output:

```
VALIDATION FAILED — 2 error(s):
  FAIL patient.hedis_measures missing
  FAIL rule_flags.uamcc_eligible missing
```

### What is validated

**21 required `patient.*` keys**

```
id, origid, demographics, contact, care_team, enrollment,
rule_flags, chronic_conditions, raf_profile, hcc_capture,
risk_scores, uamcc, hedis_measures, encounters,
labs, medications, assessments, alerts, sdoh,
emr_appointments, _meta
```

**13 required `rule_flags.*` fields**

```
raf_score, readmit_30d, readmit_90d, open_inpatient,
awv_due, awv_last_date, pcp_visit_overdue,
hedis_gaps_open, ccm_enrolled, uamcc_eligible,
active_alerts, care_plan_active, last_updated
```

**Schema version**

`_meta.schema_version` must equal `"2.0"`.

---

## Step 4 — Load SP and validate in one command

```bash
python test_es_sp.py --validate-sp --validate-doc
```

This is the full end-to-end check: drops and recreates the SP, calls it for `DEFAULT_PATIENT_ID`, and validates the document structure. Use this after any SQL change to confirm the SP both compiles and returns a correct document.

---

## Command reference

| Command | What it does |
|---------|-------------|
| `python test_es_sp.py` | Summary for `DEFAULT_PATIENT_ID` |
| `python test_es_sp.py <origid>` | Summary for a specific patient |
| `python test_es_sp.py --validate-sp` | DROP + CREATE SP from the local `.sql` file |
| `python test_es_sp.py --validate-doc` | Call SP and assert all required fields are present |
| `python test_es_sp.py --validate-sp --validate-doc` | Full end-to-end check |
| `python test_es_sp.py --save` | Save raw document to `<origid>_es_doc.json` |
| `python test_es_sp.py --section <name>` | Pretty-print one top-level section as JSON |
| `python test_es_sp.py --raw` | Print the raw JSON string from the SP |

Options can be combined, e.g.:

```bash
python test_es_sp.py 7H49DQ0VG28 --save --validate-doc
python test_es_sp.py --validate-sp --section encounters
```

---

## Document structure quick reference

```
patient
├── id / origid                   ← ES _id; CDC primary key
├── demographics                  ← age, dob, sex, race, language
├── contact                       ← address, phone, email, emergency_contact
├── care_team                     ← dce_provider, care_manager, market
├── enrollment                    ← ccm_enabled, ccm_level, consent_on_file
├── rule_flags{}                  ← pre-computed scalars/booleans; rule engines read this first
├── chronic_conditions[]          ← icd_code, hcc_number, status, last_seen_date
├── encounters[]                  ← clinical spine (ADT + CCLF UNION ALL)
│   ├── provider{}
│   ├── admission{}
│   ├── discharge{}
│   ├── diagnoses[]               ← icd_code (adt_encounter_icd_codes)
│   ├── procedures[]              ← billing_code (mra1_encounter_bill_cpts)
│   ├── enc_medications[]
│   ├── audit{}
│   ├── claim{}
│   └── cclf{}                    ← CCLF-specific fields (null on ADT rows)
├── medications[]                 ← patient-level DrFirst list
├── labs[]                        ← cpoe_result / cpoe_result_values
├── alerts[]                      ← mra_scorecard_alerts
├── assessments[]
├── hedis_measures[]
├── raf_profile{}
├── hcc_capture{}
├── risk_scores{}
├── uamcc{}
├── medication_adherence{}
├── sdoh{}                        ← food_insecurity, transport_barrier, meal_plans
├── emr_appointments[]
└── _meta{}                       ← schema_version: "2.0", trigger_source, created_at
```

See `patient_value_care_schema.json` for the full field list and `table_to_json_mapping.html` for the MySQL → JSON path mapping.

---

## Known data notes

- **`encounters[].procedures`** may be null for patients with no CPT billing data in `mra1_encounter_bill_cpts`.
- **`raf_profile`** is null when no RAF data exists for the current calendar year.
- **`hedis_measures`** may contain duplicate entries for the same measure name — de-duplicate by `(measure_name, measure_year, frows_nr)` before aggregating.
- **Procedure codes** in the JSON document are stored as `billing_code`, not `procedure_code`. Elasticsearch queries and measure definitions must use `billing_code`.
- The SP call for a full patient with many encounters can take 2–5 minutes. This is expected for initial load; CDC updates rebuild only the changed sub-section.
