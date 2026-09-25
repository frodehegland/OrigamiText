#!/usr/bin/env python3
"""Validate a publication's records against the Origami JSON schemas.

Point it at an unpacked EPUB directory, or at individual record files.
This is the §1.8 / §18 check that draft 3 could only ask for in prose.

    /tmp/jsonenv/bin/python validate-records.py /path/to/unpacked-epub
    /tmp/jsonenv/bin/python validate-records.py visual-meta.json origami.json
"""

import json
import pathlib
import sys

from jsonschema import Draft202012Validator

HERE = pathlib.Path(__file__).parent
SCHEMAS = {
    "visual-meta": json.loads((HERE / "visual-meta-1.1.schema.json").read_text()),
    "origami-text": json.loads((HERE / "origami-interaction-1.0.schema.json").read_text()),
}


def classify(record):
    """Which schema applies, taken from the record's own self-identification
    (§8.1, §9.1) rather than from its filename."""
    for key, schema in (("visual-meta", "visual-meta"), ("origami", "origami-text")):
        head = record.get(key)
        if isinstance(head, dict):
            stated = head.get("format")
            if stated in SCHEMAS:
                return stated
            return schema
    return None


def check(path):
    try:
        record = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        print(f"FAIL {path}: not JSON — {error}")
        return 1

    # A JSON Schema is not a record. Pointed at a directory that holds
    # the schemas themselves, skip them rather than reporting them as
    # non-conforming records.
    if isinstance(record, dict) and "$schema" in record:
        print(f"–    {path.name}: a JSON Schema, not a record — skipped")
        return 0

    kind = classify(record)
    if kind is None:
        print(f"FAIL {path}: no self-identification — a record must say what "
              f"it is, what version it is, and what it describes (§8.1, §9.1)")
        return 1

    errors = sorted(Draft202012Validator(SCHEMAS[kind]).iter_errors(record),
                    key=lambda e: list(e.path))
    if not errors:
        print(f"ok   {path.name}: valid against {kind}")
        return 0

    print(f"FAIL {path.name}: {len(errors)} error(s) against {kind}")
    for error in errors:
        where = "/".join(str(p) for p in error.path) or "(root)"
        print(f"       {where}: {error.message}")
    return 1


def main(argv):
    targets = []
    for argument in argv or ["."]:
        path = pathlib.Path(argument)
        if path.is_dir():
            targets += sorted(p for p in path.rglob("*.json")
                              if p.name not in {"package.json"})
        else:
            targets.append(path)

    if not targets:
        print("no JSON records found")
        return 1

    failures = sum(check(path) for path in targets)
    print()
    if failures:
        print(f"{failures} record(s) did not conform")
    else:
        print("every record checked conforms")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
