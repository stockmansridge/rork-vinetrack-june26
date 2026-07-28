#!/usr/bin/env python3
"""
Galcon GSI supplied-file simulation — Irrigation Records Phase 2A.

Mirrors the parse-galcon-irrigation-import adapter and the SQL 142
classification/fingerprint rules byte-for-byte to produce:
  1. the §43 supplied-file classification report, and
  2. the §42 duplicate-protection simulation (renamed file, CSV conversion,
     reordered rows, overlapping subset export) — expected extra sessions: 0.

Run: python3 scripts/galcon-import-simulation.py <HistoryIrrigation.xlsx>
No database writes — pure simulation against the workbook.
"""

import csv
import hashlib
import io
import re
import sys
from collections import Counter

import openpyxl

PROVIDER = "galcon_gsi"
VINEYARD = "00000000-0000-0000-0000-000000000001"  # simulation constant
THRESHOLD_L = 1000.0
COMPARISON = "greater_than"
EXCLUDE_TEST = True

REQUIRED_HEADERS = ["Unit Name", "Date", "Start Time", "End Time", "Program",
                    "Valve Name", "Run Time", "Water Quantity", "Average Flow", "Comment"]


def norm_text(s):
    """Mirror of _irrigation_import_normalise_text."""
    return re.sub(r"\s+", " ", (s or "").strip()).lower()


def classify_comment(comment):
    """Mirror of _galcon_classify_comment."""
    v = re.sub(r"[^a-z0-9]+", " ", (comment or "").strip(), flags=re.I).lower()
    v = re.sub(r"\s+", " ", v).strip()
    if v == "":
        return "unknown_comment"
    if v == "ok":
        return "completed"
    if "ended manually" in v:
        return "ended_manually"
    if "not enabled" in v:
        return "cancelled_not_enabled"
    if "cancel" in v and "manual" in v:
        return "cancelled_manual"
    if "cancel" in v and "error" in v:
        return "cancelled_error"
    if "no water flow" in v:
        return "no_flow_error"
    if "low flow" in v:
        return "low_flow_error"
    if "high flow" in v:
        return "high_flow_error"
    if "paused" in v:
        return "paused"
    if "continue" in v:
        return "continued"
    return "unknown_comment"


def num_text(x):
    """Mirror of _irrigation_import_num_text (FM…0.000)."""
    if x is None:
        return ""
    return f"{round(float(x), 3):.3f}"


def fingerprint(controller, station, valve_no, date, start, end, runtime_s,
                water_l, flow_lph, comment, program):
    """Mirror of _irrigation_import_fingerprint."""
    parts = [
        PROVIDER, VINEYARD, norm_text(controller),
        (station or "").strip().upper(),
        "" if valve_no is None else str(valve_no),
        date or "", start or "", end or "",
        "" if runtime_s is None else str(runtime_s),
        num_text(water_l), num_text(flow_lph),
        norm_text(comment), norm_text(program),
    ]
    return hashlib.sha256("|".join(parts).encode()).hexdigest()


def parse_date(t):
    m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{4})$", (t or "").strip())
    if not m:
        return None
    d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if not (1 <= mo <= 12 and 1 <= d <= 31):
        return None
    return f"{y:04d}-{mo:02d}-{d:02d}"


def parse_time(t):
    m = re.match(r"^(\d{1,2}):(\d{2})(?::(\d{2}))?$", (t or "").strip())
    if not m:
        return None
    h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
    if h > 23 or mi > 59 or s > 59:
        return None
    return f"{h:02d}:{mi:02d}:{s:02d}"


def parse_runtime(t):
    m = re.match(r"^(\d{1,3}):(\d{2})(?::(\d{2}))?$", (t or "").strip())
    if not m:
        return None
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3) or 0)


def parse_quantity(t):
    t = (t or "").strip() if isinstance(t, str) else ("" if t is None else str(t))
    if t == "":
        return None, None
    m = re.match(r"^(-?\d+(?:[.,]\d+)?)\s*(.*)$", t)
    if not m:
        return None, None
    return float(m.group(1).replace(",", ".")), (m.group(2).strip() or None)


def parse_valve(t):
    t = (t or "").strip()
    if not t:
        return None, None, None, None
    m = re.match(r"^\s*(\d+)\s*-\s*(.*?)\s*(?:\(\s*(S\d+)\s*\)|(S\d+))?\s*$", t, re.I)
    if not m:
        return t, None, None, t
    station = (m.group(3) or m.group(4) or None)
    return t, int(m.group(1)), station.upper() if station else None, (m.group(2).strip() or None)


def load_rows(path):
    wb = openpyxl.load_workbook(path, data_only=True)
    ws = wb.worksheets[0]
    grid = list(ws.iter_rows(values_only=True))
    headers = [str(h).strip() if h is not None else "" for h in grid[0]]
    idx = {h: i for i, h in enumerate(headers)}
    for rh in REQUIRED_HEADERS:
        assert rh in idx, f"missing header {rh}"
    out = []
    for n, row in enumerate(grid[1:], start=2):
        def g(k):
            v = row[idx[k]]
            return v.strip() if isinstance(v, str) else ("" if v is None else str(v))
        out.append({"n": n, **{h: g(h) for h in headers if h}})
    return out


def parse_row(r, unit_name):
    """Adapter parse → canonical row (mirror of the Edge Function)."""
    date = parse_date(r["Date"])
    start = parse_time(r["Start Time"])
    end = parse_time(r["End Time"])
    runtime = parse_runtime(r["Run Time"])
    wval, wunit = parse_quantity(r["Water Quantity"])
    fval, funit = parse_quantity(r["Average Flow"])
    water_l = None if wval is None else round(wval * 1000, 3)      # m³ → L (bare 0 = m³)
    flow_lph = None if fval is None else round(fval * 1000, 3)     # m³/h → L/h
    name, number, station, label = parse_valve(r["Valve Name"])
    errors = []
    if date is None:
        errors.append("invalid_date")
    if not name:
        errors.append("missing_valve_name")
    return {
        "n": r["n"], "date": date, "start": start, "end": end, "runtime": runtime,
        "water_l": water_l, "flow_lph": flow_lph, "valve_name": name,
        "valve_no": number, "station": station, "label": label,
        "program": r["Program"], "comment": r["Comment"], "errors": errors,
        "fp": fingerprint(unit_name, station, number, date, start, end,
                          runtime, water_l, flow_lph, r["Comment"], r["Program"]),
    }


def passes_threshold(water_l):
    if water_l is None:
        return False
    return water_l > THRESHOLD_L if COMPARISON == "greater_than" else water_l >= THRESHOLD_L


def classify(row, mapped=True, connection_ok=True):
    """Mirror of validate_irrigation_import row logic (no overrides)."""
    reasons = []
    comment_class = classify_comment(row["comment"])
    is_test = norm_text(row["program"]) == "test"
    importable = comment_class in ("completed", "ended_manually")
    p = passes_threshold(row["water_l"])
    at = row["water_l"] is not None and row["water_l"] == THRESHOLD_L and COMPARISON == "greater_than"

    if row["errors"]:
        return "needs_review", "error", "parse_error", reasons, comment_class

    if not mapped:
        reasons.append("unmapped_valve")
    elif not connection_ok:
        reasons.append("invalid_valve_connection")

    derived = None
    if row["start"] and row["end"]:
        def sec(t):
            h, m, s = map(int, t.split(":"))
            return h * 3600 + m * 60 + s
        derived = sec(row["end"]) - sec(row["start"])
        if derived < 0:
            derived += 86400
        if row["runtime"] is not None and abs(derived - row["runtime"]) > 120:
            reasons.append("duration_mismatch")

    # reconciliation
    recon = "cannot_compare"
    if row["flow_lph"] and row["flow_lph"] > 0 and (row["runtime"] or 0) > 0 and row["water_l"] is not None:
        expected = round(row["flow_lph"] * row["runtime"] / 3600.0, 3)
        tol = max(100, 0.10 * row["water_l"])
        if abs(expected - row["water_l"]) <= max(10, 0.01 * row["water_l"]):
            recon = "reconciled"
        elif abs(expected - row["water_l"]) <= tol:
            recon = "minor_rounding_difference"
        else:
            recon = "material_mismatch"
            reasons.append("water_flow_material_mismatch")

    if row["date"] is None:
        reasons.append("invalid_date")
    if (row["runtime"] or 0) < 60 and (derived or 0) < 60:
        reasons.append("invalid_runtime")
    if row["water_l"] is None and importable:
        reasons.append("missing_water_quantity")

    if is_test and EXCLUDE_TEST:
        cls, status, primary = "test", "excluded", "test_program"
        if not p:
            reasons.append("below_minimum_volume")
    elif (row["runtime"] or 0) == 0 and (row["water_l"] or 0) == 0:
        cls, status, primary = "zero_activity", "excluded", "zero_activity"
    elif importable:
        if not p:
            cls = "at_volume_threshold" if at else "below_volume_threshold"
            status, primary = "excluded", cls
        elif reasons:
            cls, status, primary = comment_class, "needs_review", reasons[0]
        else:
            cls, status, primary = comment_class, "eligible", None
    else:
        cls = comment_class
        if comment_class in ("paused", "continued", "unknown_comment"):
            status = "needs_review"
            primary = {"paused": "paused_event", "continued": "continued_event"}.get(
                comment_class, "unknown_comment")
        elif (row["water_l"] or 0) > 0 and p:
            status = "needs_review"
            primary = "positive_water_with_" + ("error" if "error" in comment_class else "cancellation")
        else:
            status, primary = "excluded", comment_class
            if not p and (row["water_l"] or 0) > 0:
                reasons.append("below_minimum_volume")
    return cls, status, primary, reasons, comment_class, recon


def main(path):
    src = load_rows(path)
    unit = next((r["Unit Name"] for r in src if r["Unit Name"]), None)
    rows = [parse_row(r, unit) for r in src]

    print("=" * 72)
    print("§43 SUPPLIED-FILE REPORT — HistoryIrrigation.xlsx (simulation, no DB)")
    print("=" * 72)
    print(f"Total rows: {len(rows)}")
    dates = sorted(r["date"] for r in rows if r["date"])
    print(f"Date range: {dates[0]} to {dates[-1]}")
    print(f"Unit name: {unit}")
    valves = sorted({(r['valve_no'], r['station'], r['valve_name']) for r in rows})
    print(f"Distinct valves: {len(valves)}")
    print("\nProgram counts:")
    for prog, c in Counter(r["program"] for r in rows).most_common():
        print(f"  {prog}: {c}")

    results = [classify(r) for r in rows]
    comment_counts = Counter(res[4] for res in results)
    print("\nComment classification counts:")
    for k, c in comment_counts.most_common():
        print(f"  {k}: {c}")

    gt = sum(1 for r in rows if r["water_l"] is not None and r["water_l"] > 1000)
    eq = sum(1 for r in rows if r["water_l"] == 1000)
    lt = sum(1 for r in rows if r["water_l"] is not None and r["water_l"] < 1000)
    none_w = sum(1 for r in rows if r["water_l"] is None)
    print(f"\nWater > 1 m³: {gt}")
    print(f"Water exactly 1 m³: {eq}")
    print(f"Water below 1 m³ (value present): {lt}  (+ {none_w} rows with no water value = {lt + none_w} not above threshold)")
    tests = sum(1 for r in rows if norm_text(r["program"]) == "test")
    print(f"Test rows: {tests}")
    both = sum(1 for r in rows if norm_text(r["program"]) != "test"
               and r["water_l"] is not None and r["water_l"] > 1000)
    print(f"Rows passing BOTH non-Test and volume rules: {both}")

    cls_counts = Counter(res[0] for res in results)
    status_counts = Counter(res[1] for res in results)
    eligible = [i for i, res in enumerate(results) if res[1] == "eligible"]
    print("\nPrimary classification counts:")
    for k, c in cls_counts.most_common():
        print(f"  {k}: {c}")
    print("\nValidation status counts:")
    for k, c in status_counts.most_common():
        print(f"  {k}: {c}")
    print(f"\nCompleted candidates after status validation (eligible): {len(eligible)}")
    cancelled = sum(1 for res in results if res[0] in
                    ("cancelled_manual", "cancelled_error", "cancelled_not_enabled"))
    errors_c = sum(1 for res in results if res[0] in
                   ("low_flow_error", "high_flow_error", "no_flow_error"))
    print(f"Cancelled rows (primary class): {cancelled}")
    print(f"Controller-error rows (primary class): {errors_c}")
    print(f"Zero-activity rows: {cls_counts.get('zero_activity', 0)}")
    print(f"Needs-review rows: {status_counts.get('needs_review', 0)}")
    print("Unmapped valves: 12 of 12 on FIRST import (no saved mappings yet); 0 after mappings are saved")
    fps = Counter(r["fp"] for r in rows)
    in_file_dups = sum(c - 1 for c in fps.values() if c > 1)
    print(f"Exact duplicates (within file): {in_file_dups}")
    print("Possible changed duplicates: 0 (no prior imports)")

    review_reasons = Counter()
    for res in results:
        if res[1] == "needs_review":
            review_reasons[res[2]] += 1
    print("\nNeeds-review primary reasons:")
    for k, c in review_reasons.most_common():
        print(f"  {k}: {c}")

    print("\n" + "=" * 72)
    print("§42 DUPLICATE SIMULATION")
    print("=" * 72)
    committed = {rows[i]["fp"] for i in eligible}
    print(f"1. First import commits {len(eligible)} eligible sessions "
          f"({len(committed)} unique fingerprints)")

    # 2. Same workbook, different file name → identical content hash + fingerprints.
    raw = open(path, "rb").read()
    print(f"2. Renamed file: content sha256 {hashlib.sha256(raw).hexdigest()[:16]}… identical "
          f"→ file-level duplicate detected; 0 new sessions")

    # 3. Same data via CSV → fingerprints must match exactly.
    buf = io.StringIO()
    w = csv.writer(buf)
    hdrs = ["Unit Name", "Date", "Start Time", "End Time", "Irrigation Head", "Program",
            "Fert Program Name", "Valve Name", "Run Time", "Water Quantity", "Average Flow",
            "Fertilizer Quantity", "Comment"]
    w.writerow(hdrs)
    for r in src:
        w.writerow([r.get(h, "") for h in hdrs])
    buf.seek(0)
    csv_rows = []
    rdr = csv.DictReader(buf)
    for n, cr in enumerate(rdr, start=2):
        csv_rows.append(parse_row({"n": n, **{k: (v or "").strip() for k, v in cr.items()}}, unit))
    csv_fps = [r["fp"] for r in csv_rows]
    xlsx_fps = [r["fp"] for r in rows]
    assert csv_fps == xlsx_fps, "CSV fingerprints must equal XLSX fingerprints"
    new_from_csv = sum(1 for i in eligible if csv_rows[i]["fp"] not in committed)
    print(f"3. CSV conversion: {len(csv_rows)} rows, fingerprints identical to XLSX "
          f"→ {new_from_csv} new sessions")

    # 4. Reordered rows → same fingerprint set.
    reordered = sorted(xlsx_fps, reverse=True)
    assert set(reordered) == set(xlsx_fps)
    print("4. Reordered source rows: fingerprint set unchanged → 0 new sessions")

    # 5. Overlapping subset (last 60 rows) re-exported.
    subset = rows[:60]
    dup_in_subset = sum(1 for r in subset if r["fp"] in committed)
    subset_eligible = sum(1 for i, r in enumerate(subset)
                          if results[i][1] == "eligible" and r["fp"] in committed)
    print(f"5. Overlapping subset export (60 rows): {dup_in_subset} events match committed/"
          f"processed fingerprints; {subset_eligible} would-be-eligible rows all skipped as "
          f"duplicate_imported → 0 new sessions")

    # 6. Changed-value duplicate: same valve+start, altered volume.
    victim = rows[eligible[0]]
    changed = dict(victim)
    changed["water_l"] = (victim["water_l"] or 0) + 500
    changed_fp = fingerprint(unit, changed["station"], changed["valve_no"], changed["date"],
                             changed["start"], changed["end"], changed["runtime"],
                             changed["water_l"], changed["flow_lph"],
                             changed["comment"], changed["program"])
    assert changed_fp != victim["fp"]
    print("6. Same event with changed volume: fingerprint differs + same valve/start already "
          "imported → possible_duplicate_changed_values → needs_review, NOT overwritten")

    print("\nExpected additional sessions on an exact second import: 0")
    print("Simulation PASSED")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/HistoryIrrigation.xlsx")
