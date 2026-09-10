#!/usr/bin/env python3
"""Deterministic stand-in receiver for the milestone-05 semantic fixture eval.

Reads a handoff prompt file, performs exactly what the prompt instructs via
regex rules, and logs every action. There is no intelligence here on purpose:
the INTELLIGENCE under measurement is the prompt (composed per ablation arm
by the real Cobbler pipeline). Genuine file mechanics, zero model calls.

Usage: fixture_applier.py <workdir>
Reads <workdir>/prompt.txt, acts inside <workdir>, writes <workdir>/actions.log.

Rules (fixed, content-independent):
  1. Investigation: every `word.ext` token ending in .txt/.sh names a file
     to read (if present). prompt.txt itself is read as step 0 and excluded
     from the repeated-investigation count.
  2. Instruction: the first `write '<content>' into <file>` line performs
     exactly one write (content + newline).
  3. Verification: the first `run <file.sh>` line is executed (up to two
     attempts: an initial run plus one re-read/retry); the applier exits
     with the last check exit code (0 only when a check ran and passed,
     3 when no instruction was found).
"""

import os
import re
import subprocess
import sys


def main(workdir):
    prompt_path = os.path.join(workdir, "prompt.txt")
    log_path = os.path.join(workdir, "actions.log")

    with open(prompt_path, encoding="utf-8") as fh:
        prompt = fh.read()

    actions = []

    file_tokens = re.findall(r"[\w][\w.\-]*\.(?:txt|sh)", prompt)
    for token in dict.fromkeys(file_tokens):
        if token == "prompt.txt":
            continue
        path = os.path.join(workdir, token)
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                data = fh.read()
            actions.append("read %s %d" % (token, len(data)))

    wrote = None
    write_match = re.search(r"write '(.*)' into (\S+)", prompt)
    if write_match:
        content, target = write_match.group(1), write_match.group(2)
        with open(os.path.join(workdir, target), "w", encoding="utf-8") as fh:
            fh.write(content + "\n")
        actions.append("write %s %d" % (target, len(content) + 1))
        wrote = target

    check_match = re.search(r"run (\S+\.sh)", prompt)
    exit_code = 3
    if check_match:
        script = check_match.group(1)
        for attempt in (1, 2):
            proc = subprocess.run(
                ["./" + script], cwd=workdir, capture_output=True, text=True
            )
            actions.append("check %s exit=%d" % (script, proc.returncode))
            exit_code = proc.returncode
            if proc.returncode == 0:
                break

    with open(log_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(actions) + "\n")

    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
