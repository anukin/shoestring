# Worker instruction discovery

VERIFIED offline on macOS with Codex CLI 0.166.0, Claude Code 2.1.316 and
opencode 2.0.31. These checks used throwaway homes and repositories with
synthetic instruction sentinels. An OS sandbox denied external networking.
Codex and Claude sent one request each to a scripted localhost API; no
provider inference or subscription allowance was used. Only sentinel
presence was retained, never complete requests or model reasoning.

| Worker launch | Global instructions in request | Repository instructions in request |
| --- | --- | --- |
| Codex app-server, workspace-write, approval never | Yes: `CODEX_HOME/AGENTS.md` | Yes: `AGENTS.md` |
| Claude with Shoestring's safe/restricted launch and empty setting sources | No: `.claude/CLAUDE.md` | No: `CLAUDE.md` |
| Claude positive control with normal settings discovery | Yes | Yes |

The Codex check used an ephemeral thread with a synthetic `CODEX_HOME`;
production workers inherit the configured home. The Claude positive control
removed `--safe-mode`, `--restricted` and `--setting-sources ""`; the other
worker flags and scripted API were retained. This establishes the effect
of that flag set together, not of any one flag independently. Worker
requirements must be in the dispatch brief when implicit discovery is off.

The [official AGENTS.md guide](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
describes Codex's global and repository discovery. The table records the
installed versions' observed requests, not a guarantee of model compliance
or of behavior in future CLI versions. The user's actual private global
instruction files were not inspected or modified for these probes.

VERIFIED: opencode ACP read a synthetic custom primary agent from
`XDG_CONFIG_HOME/opencode/opencode.json` while `HOME` pointed to an empty
run directory. `initialize` and `session/new` succeeded and the session's
agent options included the marker. No prompt was sent. This matches the
worker environment's separate HOME and XDG configuration paths.

Earlier diagnostic attempts are retained as limitations: `opencode debug
config` timed out in 1 of 2 runs with default model fetching; ACP could not
create a session when all outbound connections, including its own loopback
server, were denied. The completed ACP check disabled model fetching and
updates, allowed loopback only, and used synthetic configuration. Neither
the user's actual opencode configuration nor live provider access was
verified.
