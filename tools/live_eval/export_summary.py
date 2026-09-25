#!/usr/bin/env python3
"""Export the redacted run summary for committed live evidence.

Reads `<state dir>/live-results.jsonl` (what `prod_rerun.exs` records) and the
state database (read-only), and writes one JSON summary whose identifiers use
the SAME synthetic series and mapping as the transcripts
`export_evidence.py` writes: the transcripts are rendered first, in the given
order, in this process, so every UUID maps exactly as it does there.

Per-phase `event_types` lists are reduced to their non-normalized types plus
a normalized count. Absolute host paths become `$WORKSPACE` / `$REDACTED_PATH`
(same-length, as in the transcripts).

Usage:
    export_summary.py <state dir> <out.json> <label>=<run_id> [...]
"""

import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_evidence as ev  # noqa: E402


def scrub(value):
    if isinstance(value, dict):
        return {k: scrub(v) for k, v in value.items()}
    if isinstance(value, list):
        return [scrub(v) for v in value]
    if isinstance(value, str):
        return ev.substitute(value)
    return value


def reduce_phase(entry):
    entry = dict(entry)
    types = entry.pop("event_types", None)
    if types is not None:
        entry["lifecycle_types"] = [t for t in types if t != "harness.event_recorded"]
        entry["normalized_event_rows"] = sum(1 for t in types if t == "harness.event_recorded")
    return entry


def main(argv):
    state_dir, out = argv[1], argv[2]
    db = sqlite3.connect("file:%s?mode=ro" % os.path.join(state_dir, "shoestring.db"), uri=True)
    for spec in argv[3:]:
        label, run_id = spec.split("=", 1)
        ev.render_run(db, label, run_id)

    with open(os.path.join(state_dir, "live-results.jsonl")) as fh:
        phases = [reduce_phase(json.loads(line)) for line in fh if line.strip()]

    with open(out, "w") as fh:
        json.dump(scrub({"phases": phases}), fh, indent=1, sort_keys=True)
        fh.write("\n")


if __name__ == "__main__":
    main(sys.argv)
