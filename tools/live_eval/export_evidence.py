#!/usr/bin/env python3
"""Export redacted canonical transcripts for committed live evidence.

Reads a disposable live-run state database (read-only) and writes one
markdown transcript per run in the format that
`test/shoestring/evidence/live_evidence_redaction_test.exs` checks:
a lifecycle block and a normalized-event block, each with a declared count.

Redaction is applied to the REASSEMBLED text, not field by field:

  1. the `codex-app-server:delta` fragments of a run are joined in ordinal
     order, substituted as one stream, and sliced back with the original
     per-fragment lengths (a path spelled across many deltas is caught);
  2. every rendered detail line is then substituted again as a whole.

Every substitution is SAME-LENGTH, so ordinals, counts and offsets are
unchanged. Identifiers map 1:1 and deterministically to declared synthetic
series. Per-event provider session ids, source event ids, item ids and cwd
are omitted rather than substituted.

Usage:
    export_evidence.py <state.db> <out_dir> <label>=<run_id> [...]
"""

import getpass
import json
import re
import sqlite3
import sys

UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# Absolute host paths (macOS home, temp shards, per-user state). `$WORKSPACE`
# is used for Shoestring-managed worktrees, `$REDACTED_PATH` for the rest.
PATH = re.compile(r"/(?:Users|private|var|home|Library|opt)/[^\s\"'`,;)\]}<>|\\]*")
PGID = re.compile(r"pgid:\d+")
# The operator's login name appears in captured `ls -l` output; it is a machine
# identifier, replaced same-length like everything else.
LOGIN = re.compile(r"\b%s\b" % re.escape(getpass.getuser()))
OMIT = {
    "codex-app-server:item_id",
    "codex-app-server:cwd",
    "claude-headless:session_id",
    "claude-headless:cwd",
}
DETAIL_CAP = 600

uuid_map = {}


def synthetic_uuid(real):
    key = real.lower()
    if key == "00000000-0000-4000-8000-000000000cb0":
        return real
    if key not in uuid_map:
        n = len(uuid_map) + 1
        if key[14] == "7":
            uuid_map[key] = "01950000-0000-7000-8000-%012d" % n
        else:
            uuid_map[key] = "55555555-0000-4000-9000-%012d" % n
    return uuid_map[key]


def pad(placeholder, length):
    return (placeholder + "x" * length)[:length]


def substitute(text):
    def path(m):
        s = m.group(0)
        return pad("$WORKSPACE" if "/worktrees/run-" in s else "$REDACTED_PATH", len(s))

    text = PATH.sub(path, text)
    text = UUID.sub(lambda m: synthetic_uuid(m.group(0)), text)
    text = PGID.sub(lambda m: pad("pgid:", len(m.group(0))), text)
    text = LOGIN.sub(lambda m: pad("$USER", len(m.group(0))), text)
    return text


def events(db, run_id):
    rows = db.execute(
        "select sequence, type, idempotency_key, payload from trajectory_events "
        "where json_extract(payload, '$.run_id') = ? order by sequence",
        (run_id,),
    ).fetchall()
    return [(seq, typ, key or "", json.loads(payload)) for seq, typ, key, payload in rows]


def render_run(db, label, run_id):
    evs = events(db, run_id)
    lifecycle = [(t, k) for _s, t, k, _p in evs if t != "harness.event_recorded"]
    normalized = sorted(
        (p for _s, t, _k, p in evs if t == "harness.event_recorded"), key=lambda p: p["ordinal"]
    )

    # 1. Reassembled delta stream, substituted as one string, sliced back.
    deltas = [p.get("extensions", {}).get("codex-app-server:delta") for p in normalized]
    lengths = [len(d) if isinstance(d, str) else 0 for d in deltas]
    joined = substitute("".join(d for d in deltas if isinstance(d, str)))
    assert len(joined) == sum(lengths), "same-length substitution violated"
    offset = 0
    for p, d, n in zip(normalized, deltas, lengths):
        if isinstance(d, str):
            p["extensions"]["codex-app-server:delta"] = joined[offset : offset + n]
            offset += n

    lines = []
    for p in normalized:
        detail = {k: v for k, v in (p.get("extensions") or {}).items() if k not in OMIT}
        if "result" in p:
            detail["result"] = p["result"]
        text = json.dumps(detail, ensure_ascii=False, separators=(",", ":"))
        # 2. Whole-line substitution, then the documented cap.
        text = substitute(text)[:DETAIL_CAP]
        lines.append("%d\t%s\t%s" % (p["ordinal"], p["kind"], text))

    life = ["%s\t%s" % (t, substitute(k)) for t, k in lifecycle]
    body = [
        "# %s" % label,
        "",
        "Canonical trajectory material for one live run on the production-configured",
        "node, redacted. Redaction is applied to the REASSEMBLED delta stream and then to",
        "each whole detail line; every substitution is same-length, so ordinals and",
        "counts are unchanged. Worktree paths become `$WORKSPACE`, other host paths",
        "`$REDACTED_PATH`, UUIDs map 1:1 to the synthetic `01950000-0000-7000-8000-…`",
        "(UUIDv7) and `55555555-0000-4000-9000-…` series, `pgid:` numbers become `x`.",
        "Per-event provider session ids, source event ids, item ids and cwd are omitted.",
        "Details are capped at %d characters. The `x` runs are padding, not data." % DETAIL_CAP,
        "",
        "## Run lifecycle and terminal events (%d)" % len(life),
        "",
        "```",
        *life,
        "```",
        "",
        "## Normalized events (%d): ordinal, kind, detail" % len(lines),
        "",
        "```",
        *lines,
        "```",
        "",
    ]
    return "\n".join(body)


def main(argv):
    db = sqlite3.connect("file:%s?mode=ro" % argv[1], uri=True)
    out_dir = argv[2]
    for spec in argv[3:]:
        label, run_id = spec.split("=", 1)
        with open("%s/%s.md" % (out_dir, label), "w") as fh:
            fh.write(render_run(db, label, run_id))
    json.dump({"synthetic_ids_assigned": len(uuid_map)}, sys.stdout)
    print()


if __name__ == "__main__":
    main(sys.argv)
