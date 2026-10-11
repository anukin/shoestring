"""Verify only shipped reference steps in new temporary fixture repositories.

Never reads model proposals, uses the network, or starts Shoestring. Leaves
owned temporary repositories and exact command logs available for inspection.
"""

import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2] / "priv" / "planner_eval"
CASES = {
    "greeting": ["greeting"],
    "receipt": ["total", "receipt"],
    "catalog": ["catalog"],
}


def gate(repository, paths, log):
    command = ["mix", "test", *paths]
    with log.open("w") as output:
        result = subprocess.run(
            command,
            cwd=repository,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=60,
            check=False,
        )
    text = log.read_text()
    counts = re.search(r"(\d+) tests?, (\d+) failures?", text)
    if counts is None:
        raise RuntimeError(f"Missing test summary: {log}")
    return {
        "command": command,
        "exit_code": result.returncode,
        "tests": int(counts[1]),
        "failures": int(counts[2]),
    }, text


def main():
    owned = Path(tempfile.mkdtemp(prefix="shoestring-planner-reference-"))
    report = {
        "source": "shipped_reference_steps",
        "model_quality": "UNVERIFIED",
        "evidence_directory": str(owned),
        "cases": [],
    }
    for case_id, steps in CASES.items():
        repository = owned / case_id
        shutil.copytree(ROOT / "repository", repository)
        plan = json.loads((ROOT / "cases" / case_id / "reference.json").read_text())
        goal_paths = plan["goal"]["acceptance"]["gates"][0]["test_paths"]
        baseline, text = gate(repository, goal_paths, owned / f"{case_id}-baseline.log")
        expected = 2 if case_id == "receipt" else 1
        if not (
            baseline["exit_code"] == 2
            and baseline["tests"] == expected
            and baseline["failures"] == expected
            and text.count("Assertion with == failed") == expected
        ):
            raise RuntimeError(f"Baseline did not fail on behavior: {case_id}: {baseline}")
        entry = {"case_id": case_id, "baseline": baseline, "steps": []}
        for step, task in zip(steps, plan["tasks"], strict=True):
            if step != task["id"]:
                raise RuntimeError("Reference step and task identity mismatch")
            shutil.copyfile(ROOT / "reference_steps" / f"{step}.ex", repository / "lib/pantry.ex")
            paths = task["gates"][0]["test_paths"]
            result, _ = gate(repository, paths, owned / f"{case_id}-{step}.log")
            if result["exit_code"] != 0 or result["failures"] != 0:
                raise RuntimeError(f"Reference step failed: {case_id}/{step}: {result}")
            entry["steps"].append({"task_id": step, **result})
        report["cases"].append(entry)
    (owned / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
