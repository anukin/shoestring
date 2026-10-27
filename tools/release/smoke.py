#!/usr/bin/env python3
"""Local relocated-release smoke, system-tools-only PATH, synthetic state, no providers."""
import argparse
import json
import os
import pathlib
import selectors
import socket
import subprocess
import time
import urllib.request


def smoke(release, state):
    if not __debug__:
        raise RuntimeError("Verification requires Python assertions enabled")
    release = release.resolve(strict=True)
    state.mkdir(parents=True, exist_ok=False)
    guard = state / "cli-guard"
    guard.mkdir()
    for provider in ("claude", "codex", "opencode", "ollama", "mix", "elixir", "erl", "cargo",
                     "rustc"):
        shim = guard / provider
        shim.write_text('#!/bin/sh\necho unexpected >> "$SHOESTRING_GUARD_LOG"\nexit 99\n')
        shim.chmod(0o755)
    env = {key: os.environ[key] for key in ("HOME", "USER", "LANG", "TMPDIR") if key in os.environ}
    env.update({"PATH": f"{guard}:/usr/bin:/bin", "SHOESTRING_STATE_DIR": str(state),
                "SHOESTRING_AUTOMATION": "off", "SHOESTRING_GUARD_LOG": str(state / "unexpected.log"),
                "ERL_CRASH_DUMP": str(state / "crash.dump")})
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        env["PORT"] = str(listener.getsockname()[1])
    command = str(release / "bin/shoestringctl")

    def run(*args):
        result = subprocess.run([command, *args], env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        assert result.returncode == 0, f"Release {args[0]} failed (see local smoke logs)"
        return result.stdout.decode()

    def refused(*args):
        """A work command's refusal: exit 1, one line on stderr, nothing on stdout."""
        result = subprocess.run([command, *args], env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        lines = result.stderr.decode().splitlines()
        assert result.returncode == 1 and result.stdout == b"" and len(lines) == 1, \
            f"Release {args[0]} did not refuse in one line"
        return lines[0]

    assert refused("goals", "list").startswith("No Shoestring database in the state directory.")
    assert not (state / "shoestring.db").exists(), "A work command created state"
    before = json.loads(run("doctor"))
    assert before["database"] == "needs_init"
    assert before["endpoint_secret"] == "missing_or_invalid"
    run("init")
    secret = (state / ".endpoint-secret").read_bytes()
    assert len(secret) == 88 and (state / ".endpoint-secret").stat().st_mode & 0o777 == 0o600
    run("init")
    assert (state / ".endpoint-secret").read_bytes() == secret
    doctor = json.loads(run("doctor"))
    assert doctor["database"] == "ok" and doctor["helper"] == "compatible"
    assert doctor["endpoint_secret"] == "private"
    assert doctor["agents"]["claude"]["readiness"] in ("not_checked", "binary_missing")
    goal = json.loads(run("goals", "create", "--title", "Smoke goal", "--json"))
    assert [item["id"] for item in json.loads(run("goals", "list", "--json"))] == [goal["id"]]
    assert json.loads(run("agents", "list", "--json")) == []
    assert "shoestring do" in run("do", "--help")
    # Iteration 14: the coordinator commands and their instructions ship in the
    # release, and what needs a person refuses without a terminal.
    for name in ("setup", "chat", "grant", "grants", "dispatch", "wait", "runs", "advice",
                 "capacity"):
        assert f"shoestring {name}" in run(name, "--help"), f"Release {name} --help"
    assert len(list(release.glob("lib/shoestring-*/priv/coordinator/instructions.md"))) == 1
    assert refused("grant", "--models", "codex:gpt-6-luna").startswith(
        "A grant is a person's decision")
    assert refused("chat").startswith("A grant is a person's decision")
    assert refused("setup").startswith("setup asks questions.")
    assert json.loads(run("advice", "--json")) == []
    assert json.loads(run("grants", "list", "--json")) == []
    assert json.loads(run("runs", "list", "--session", "smoke", "--json")) == []
    assert json.loads(run("chat", "list", "--json")) == []
    assert "providers" in json.loads(run("capacity", "--json"))
    preview = json.loads(run("diagnostics-preview"))
    export = state / "diagnostics.json"
    run("diagnostics-export", str(export), preview["confirmation_sha256"])
    assert export.stat().st_mode & 0o777 == 0o600

    log = state / "server.log"
    with log.open("wb") as output:
        process = subprocess.Popen([command, "start"], env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 60
            pending = b""
            ready = False
            while not ready and time.monotonic() < deadline:
                for key, _ in selector.select(timeout=max(0, deadline - time.monotonic())):
                    chunk = os.read(key.fd, 65536)
                    assert chunk, "Release exited before endpoint readiness"
                    output.write(chunk)
                    output.flush()
                    pending += chunk
                    ready = b"Access ShoestringWeb.Endpoint at" in pending
                    assert len(pending) <= 1_048_576, "Startup log bound exceeded"
            selector.close()
            assert ready, "Endpoint startup timed out"
            duplicate = subprocess.run([command, "init"], env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            assert duplicate.returncode != 0 and b"State is owned" in duplicate.stderr
            with urllib.request.urlopen(f"http://127.0.0.1:{env['PORT']}/health", timeout=10) as response:
                assert response.status == 200
            with urllib.request.urlopen(f"http://127.0.0.1:{env['PORT']}/", timeout=10) as response:
                assert response.status == 200
        finally:
            process.terminate()
            process.wait(timeout=30)
    assert refused("follow", goal["id"]).startswith("The Shoestring service is not running.")
    assert not (state / "unexpected.log").exists(), "A provider or system toolchain was invoked"
    print(json.dumps({"initialized": True, "secret_private_and_persistent": True,
                      "helper": doctor["helper"], "database": doctor["database"],
                      "health_http": 200, "ui_http": 200, "diagnostic_export": "confirmed_private",
                      "work_commands": "goals_agents_refusals",
                      "coordinator_commands": "help_lists_refusals_instructions",
                      "provider_or_toolchain_launches": 0, "clean_machine": "not_verified"}, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=pathlib.Path)
    parser.add_argument("state", type=pathlib.Path)
    args = parser.parse_args()
    smoke(args.release, args.state)
