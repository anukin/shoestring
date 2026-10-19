#!/usr/bin/env python3
"""A shared, fail-closed call ceiling for explicitly authorized live probes.

Initialize before adding the generated bin directory to PATH:
  python3 tools/live_eval/provider_budget.py init DIR --planner 4 --worker 12 --reviewer 16
Then set SHOESTRING_LIVE_BUDGET_DIR=DIR and prepend DIR/bin to PATH.
Provider paths are discovered at initialization; prompts and provider output
never enter the ledger. Failed launches consume their reserved call too.
"""

import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("call limits must be nonnegative")
    return number


def initialize(args):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    for role in ("planner", "worker", "reviewer"):
        parser.add_argument("--" + role, type=nonnegative, required=True)
    parser.add_argument("--fail-first-review-delivery", choices=("claude", "codex"))
    options = parser.parse_args(args)
    root = options.directory.resolve()
    executables = {name: shutil.which(name) for name in ("claude", "codex")}
    if any(path is None or Path(path).resolve() == Path(__file__).resolve()
           for path in executables.values()):
        raise ValueError("initialize with real provider executables on PATH")
    root.mkdir(parents=True, exist_ok=True)
    ledger = {
        "limits": {role: getattr(options, role) for role in ("planner", "worker", "reviewer")},
        "used": {role: 0 for role in ("planner", "worker", "reviewer")},
        "calls": [],
        "executables": executables,
        "faults": [],
    }
    if options.fail_first_review_delivery:
        ledger["faults"].append({"provider": options.fail_first_review_delivery,
                                 "role": "reviewer", "remaining": 1})
    # Never reset a previous budget, even when initialization is repeated.
    with (root / "ledger.json").open("x") as output:
        json.dump(ledger, output, indent=2)
        output.flush()
        os.fsync(output.fileno())
    (root / "bin").mkdir(exist_ok=True)
    for name in executables:
        (root / "bin" / name).symlink_to(Path(__file__).resolve())
    print(json.dumps({"limits": ledger["limits"], "used": ledger["used"]}))


def classify(provider, args):
    if args in (["--version"], ["-v"]):
        return None
    if provider == "claude" and "--output-format" in args:
        output_format = args[args.index("--output-format") + 1]
        if output_format == "stream-json":
            return "worker"
        if output_format == "json" and "--json-schema" in args:
            schema = json.loads(args[args.index("--json-schema") + 1])
            properties = schema.get("properties", {})
            if "findings" in properties:
                return "reviewer"
            if "tasks" in properties:
                return "planner"
    if provider == "codex" and "exec" in args:
        return "reviewer"
    if provider == "codex" and "app-server" in args:
        # Conservatively charge model-free capacity monitor launches too.
        return "worker"
    raise ValueError("unclassified provider call")


def invoke(provider, args):
    role = classify(provider, args)
    root = Path(os.environ["SHOESTRING_LIVE_BUDGET_DIR"]).resolve()
    discard = False
    with (root / "ledger.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ledger = json.loads((root / "ledger.json").read_text())
        if role:
            if ledger["used"][role] >= ledger["limits"][role]:
                print("LIVE CALL BUDGET EXHAUSTED: " + role, file=sys.stderr)
                return 125
            ledger["used"][role] += 1
            call = {"role": role, "provider": provider, "ordinal": ledger["used"][role],
                    "at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
            ledger["calls"].append(call)
            for fault in ledger.get("faults", []):
                if fault["provider"] == provider and fault["role"] == role and fault["remaining"] > 0:
                    fault["remaining"] -= 1
                    discard = True
                    call["injected_delivery_failure"] = True
                    break
            temporary = root / "ledger.next.json"
            with temporary.open("w") as output:
                json.dump(ledger, output, indent=2)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, root / "ledger.json")
        executable = ledger["executables"][provider]
    if discard:
        subprocess.run([executable, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=240, check=False)
        print("Injected review delivery failure after a charged provider invocation", file=sys.stderr)
        return 71
    os.execv(executable, [executable, *args])


def main():
    provider = Path(sys.argv[0]).name
    if provider in ("claude", "codex"):
        return invoke(provider, sys.argv[1:])
    if len(sys.argv) > 1 and sys.argv[1] == "init":
        initialize(sys.argv[2:])
        return 0
    raise ValueError("expected init or a generated provider wrapper")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, IndexError, subprocess.TimeoutExpired):
        print("Live budget guard refused the operation; no unclassified call was launched.",
              file=sys.stderr)
        sys.exit(2)
