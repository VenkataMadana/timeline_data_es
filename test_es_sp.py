"""
test_es_sp.py — Validate and call sp_get_patient_es_doc, view the JSON output.

Usage:
    python test_es_sp.py                          # uses DEFAULT_PATIENT_ID from .env
    python test_es_sp.py <origid>                 # e.g. python test_es_sp.py 7H49DQ0VG28
    python test_es_sp.py <origid> --raw           # print raw JSON (no formatting)
    python test_es_sp.py <origid> --section NAME  # print one top-level section
    python test_es_sp.py <origid> --save          # save to <origid>_es_doc.json
    python test_es_sp.py --validate-sp            # DROP+CREATE the SP from the .sql file
    python test_es_sp.py <origid> --validate-doc  # call SP and check required fields
    python test_es_sp.py --validate-sp --validate-doc  # load SP then validate output
"""

import sys, json, os, pymysql
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

# -- connection ----------------------------------------------------------------
# All credentials come exclusively from .env — no hardcoded fallbacks.
def _db_config(read_only: bool = True) -> dict:
    for key in ("DB_HOST", "DB_USER", "DB_PASSWORD", "DB_NAME"):
        if not os.getenv(key):
            sys.exit(f"ERROR: {key} not set — check your .env file.")
    cfg = dict(
        host            = os.environ["DB_HOST"],
        port            = int(os.getenv("DB_PORT", 3306)),
        user            = os.environ["DB_USER"],
        password        = os.environ["DB_PASSWORD"],
        database        = os.environ["DB_NAME"],
        ssl             = {"ssl": True},   # TLS to RDS; no client cert required
        connect_timeout = 15,
        charset         = "utf8mb4",
    )
    return cfg


DEFAULT_PATIENT_ID = os.getenv("DEFAULT_PATIENT_ID", "7H49DQ0VG28")
SP_SQL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "sp_get_patient_es_doc.sql")

# Top-level patient keys the SP must emit (schema v2.0)
REQUIRED_PATIENT_KEYS = [
    "id", "origid", "demographics", "contact", "care_team", "enrollment",
    "rule_flags", "chronic_conditions", "raf_profile", "hcc_capture",
    "risk_scores", "uamcc", "hedis_measures", "encounters",
    "labs", "medications", "assessments", "alerts", "sdoh",
    "emr_appointments", "_meta",
]
# rule_flags booleans/scalars every rule engine reads
REQUIRED_RULE_FLAGS = [
    "raf_score", "readmit_30d", "readmit_90d", "open_inpatient",
    "awv_due", "awv_last_date", "pcp_visit_overdue",
    "hedis_gaps_open", "ccm_enrolled", "uamcc_eligible",
    "active_alerts", "care_plan_active", "last_updated",
]


# -- SP loader -----------------------------------------------------------------
def _parse_sp_file(sql_text: str):
    """Return (drop_stmt, create_stmt) from a DELIMITER $$ SQL file."""
    # DROP is before the DELIMITER $$ line; uses standard ; terminator
    drop_start = sql_text.upper().index("DROP PROCEDURE")
    drop_end   = sql_text.index(";", drop_start) + 1
    drop_stmt  = sql_text[drop_start:drop_end].strip()

    # CREATE PROCEDURE...END — everything up to (not including) the trailing $$
    cp_start   = sql_text.upper().index("CREATE PROCEDURE")
    end_marker = "END$$"
    cp_end     = sql_text.upper().rindex(end_marker, cp_start) + len("END")  # exclude $$
    create_stmt = sql_text[cp_start:cp_end].strip()

    return drop_stmt, create_stmt


def validate_sp() -> None:
    """DROP and CREATE sp_get_patient_es_doc from the local .sql file."""
    print(f"Reading {SP_SQL_FILE} …")
    try:
        with open(SP_SQL_FILE, encoding="utf-8") as f:
            sql_text = f.read()
    except FileNotFoundError:
        sys.exit(f"ERROR: {SP_SQL_FILE} not found.")

    try:
        drop_stmt, create_stmt = _parse_sp_file(sql_text)
    except (ValueError, AttributeError) as exc:
        sys.exit(f"ERROR parsing SQL file: {exc}")

    cfg = _db_config()
    print(f"Connecting to {cfg['host']} / {cfg['database']} …")
    conn = pymysql.connect(**cfg)
    cur  = conn.cursor()
    try:
        print("DROP PROCEDURE IF EXISTS sp_get_patient_es_doc …")
        cur.execute(drop_stmt)

        print("CREATE PROCEDURE sp_get_patient_es_doc …")
        cur.execute(create_stmt)
        conn.commit()
        print("SP compiled and loaded successfully.\n")
    except pymysql.MySQLError as exc:
        conn.rollback()
        sys.exit(f"ERROR loading SP: {exc}")
    finally:
        cur.close()
        conn.close()


# -- document validator --------------------------------------------------------
def validate_doc(doc: dict) -> list:
    errors = []
    p = doc.get("patient")
    if p is None:
        return ["top-level 'patient' key is missing from the document"]

    for key in REQUIRED_PATIENT_KEYS:
        if key not in p:
            errors.append(f"patient.{key} missing")

    rf = p.get("rule_flags") or {}
    for flag in REQUIRED_RULE_FLAGS:
        if flag not in rf:
            errors.append(f"rule_flags.{flag} missing")

    meta = p.get("_meta") or {}
    if meta.get("schema_version") != "2.0":
        errors.append(
            f"_meta.schema_version expected '2.0', got {meta.get('schema_version')!r}"
        )

    return errors


# -- summary printer -----------------------------------------------------------
def _arr_summary(val):
    if val is None:
        return "null"
    if isinstance(val, list):
        return f"[{len(val)} item{'s' if len(val) != 1 else ''}]"
    return str(val)


def print_summary(doc: dict):
    p = doc.get("patient", {})

    print("-" * 70)
    print("  ES DOCUMENT SUMMARY")
    print(f"  patient.id  : {p.get('id')}")
    print(f"  origid      : {p.get('origid')}")
    print("-" * 70)

    dem = p.get("demographics") or {}
    print("\n-- demographics")
    print(f"   name : {dem.get('last_name')}, {dem.get('first_name')} {dem.get('middle_name') or ''}")
    print(f"   dob  : {dem.get('dob')}  age={dem.get('age')}  sex={dem.get('sex')}")
    print(f"   race : {dem.get('race')}  lang={dem.get('language')}")

    enr = p.get("enrollment") or {}
    print("\n-- enrollment")
    print(f"   status     : {enr.get('status')}")
    print(f"   ccm_enabled: {enr.get('ccm_enabled')}  level={enr.get('ccm_level')}")
    print(f"   consent    : {enr.get('consent_on_file')}")

    ct = p.get("care_team") or {}
    print("\n-- care_team")
    print(f"   dce_provider : {ct.get('dce_provider')}")
    print(f"   care_manager : {ct.get('care_manager')}")
    print(f"   last_pcp     : {ct.get('last_pcp_visit')}  next={ct.get('next_pcp_visit')}")

    rf = p.get("rule_flags") or {}
    print("\n-- rule_flags")
    print(f"   raf_score          : {rf.get('raf_score')}")
    print(f"   readmit_30d        : {rf.get('readmit_30d')}")
    print(f"   open_inpatient     : {rf.get('open_inpatient')}")
    print(f"   awv_due            : {rf.get('awv_due')}  last={rf.get('awv_last_date')}")
    print(f"   hedis_gaps_open    : {rf.get('hedis_gaps_open')}")
    print(f"   hedis_gap_measures : {rf.get('hedis_gap_measures')}")
    print(f"   uamcc_eligible     : {rf.get('uamcc_eligible')}  conditions={rf.get('uamcc_conditions')}")
    print(f"   active_alerts      : {rf.get('active_alerts')}")
    print(f"   care_plan_active   : {rf.get('care_plan_active')}")
    print(f"   pcp_visit_overdue  : {rf.get('pcp_visit_overdue')}")

    sections = [
        ("encounters",         p.get("encounters")),
        ("labs",               p.get("labs")),
        ("medications",        p.get("medications")),
        ("assessments",        p.get("assessments")),
        ("alerts",             p.get("alerts")),
        ("hedis_measures",     p.get("hedis_measures")),
        ("emr_appointments",   p.get("emr_appointments")),
        ("chronic_conditions", p.get("chronic_conditions")),
    ]
    print("\n-- array counts")
    for label, val in sections:
        n = len(val) if isinstance(val, list) else ("null" if val is None else "?")
        print(f"   {label:<22s}: {n}")

    raf = p.get("raf_profile")
    print(f"\n-- raf_profile  : {'present' if raf else 'null (no RAF data this year)'}")
    if raf:
        for k in ("pmra", "prmra", "rmra"):
            s = raf.get(k) or {}
            print(f"   {k}: score={s.get('detail_score')}  initial={s.get('initial_score')}  month={s.get('month')}")

    hcc = p.get("hcc_capture") or {}
    print("\n-- hcc_capture")
    print(f"   eligible={hcc.get('eligible_hccs')}  captured={hcc.get('captured_hccs')}  pct={hcc.get('capture_pct')}%")
    gap = hcc.get("gap_hccs")
    if isinstance(gap, list) and gap:
        print(f"   gap_hccs: {', '.join(str(x) for x in gap[:10])}{'...' if len(gap) > 10 else ''}")

    uamcc = p.get("uamcc") or {}
    summ  = uamcc.get("summary") or {}
    print("\n-- uamcc")
    print(f"   program_eligible: {summ.get('program_eligible')}  condition_count={summ.get('condition_count')}")
    print(f"   conditions: {summ.get('conditions')}")

    sdoh = p.get("sdoh") or {}
    print("\n-- sdoh")
    print(f"   food_insecurity  : {sdoh.get('food_insecurity_flag')}")
    print(f"   transport_barrier: {sdoh.get('transport_barrier_flag')}")
    print(f"   meal_plans       : {_arr_summary(sdoh.get('meal_plans'))}")
    print(f"   reward_programs  : {_arr_summary(sdoh.get('reward_programs'))}")

    encs = p.get("encounters") or []
    print(f"\n-- encounters  (showing first 3 of {len(encs)})")
    for enc in encs[:3]:
        dates = enc.get("dates") or {}
        print(f"   [{enc.get('encounter_nr')}]  {dates.get('admission_date')}  "
              f"type={enc.get('encounter_type')}  status={enc.get('encounter_status')}  "
              f"dx={len(enc.get('diagnoses') or [])}  cpt={len(enc.get('procedures') or [])}")

    meta = p.get("_meta") or {}
    print("\n-- _meta")
    print(f"   schema_version : {meta.get('schema_version')}")
    print(f"   created_at     : {meta.get('created_at')}")
    print("-" * 70)


# -- main ----------------------------------------------------------------------
def main():
    args = sys.argv[1:]
    origid          = DEFAULT_PATIENT_ID
    raw             = False
    section         = None
    save            = False
    do_validate_sp  = False
    do_validate_doc = False

    i = 0
    while i < len(args):
        if args[i] == "--raw":
            raw = True
        elif args[i] == "--save":
            save = True
        elif args[i] == "--validate-sp":
            do_validate_sp = True
        elif args[i] == "--validate-doc":
            do_validate_doc = True
        elif args[i] == "--section" and i + 1 < len(args):
            section = args[i + 1]
            i += 1
        elif not args[i].startswith("--"):
            origid = args[i]
        i += 1

    if do_validate_sp:
        validate_sp()

    cfg = _db_config()
    print(f"Connecting to {cfg['host']} / {cfg['database']} …")
    conn = pymysql.connect(**cfg)
    cur  = conn.cursor()
    cur.execute("SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")

    print(f"Calling sp_get_patient_es_doc('{origid}') …")
    t0 = datetime.now()
    cur.execute("CALL sp_get_patient_es_doc(%s)", (origid,))
    row = cur.fetchone()
    elapsed = (datetime.now() - t0).total_seconds()
    cur.close()
    conn.close()

    if not row or not row[0]:
        print(f"No document returned — patient '{origid}' not found.")
        sys.exit(1)

    doc = json.loads(row[0])
    size_kb = len(row[0]) / 1024
    print(f"Document received in {elapsed:.2f}s  ({size_kb:,.1f} KB)\n")

    if raw:
        print(row[0])
        return

    if section:
        val = doc.get("patient", {}).get(section)
        if val is None:
            print(f"Section '{section}' not found or null.")
        else:
            print(json.dumps(val, indent=2, default=str))
        return

    if save:
        fname = f"{origid}_es_doc.json"
        with open(fname, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2, default=str)
        print(f"Saved to {fname}")

    if do_validate_doc:
        errors = validate_doc(doc)
        if errors:
            print(f"VALIDATION FAILED — {len(errors)} error(s):")
            for e in errors:
                print(f"  FAIL {e}")
            sys.exit(1)
        else:
            print(f"VALIDATION PASSED — all {len(REQUIRED_PATIENT_KEYS)} patient keys "
                  f"and {len(REQUIRED_RULE_FLAGS)} rule_flags present.")
        return

    print_summary(doc)


if __name__ == "__main__":
    main()
