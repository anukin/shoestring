# normalized-claude-receiver-projection-prereg

Canonical trajectory material for one live run on the production-configured
node, redacted. Redaction is applied to the REASSEMBLED delta stream and then to
each whole detail line; every substitution is same-length, so ordinals and
counts are unchanged. Worktree paths become `$WORKSPACE`, other host paths
`$REDACTED_PATH`, UUIDs map 1:1 to the synthetic `01950000-0000-7000-8000-…`
(UUIDv7) and `55555555-0000-4000-9000-…` series, `pgid:` numbers become `x`.
Per-event provider session ids, source event ids, item ids and cwd are omitted.
Details are capped at 600 characters. The `x` runs are padding, not data.

## Run lifecycle and terminal events (8)

```
run.requested	run-requested:55555555-0000-4000-9000-000000000017
lease.proposed	lease-proposed:55555555-0000-4000-9000-000000000021
handoff.created	handoff:55555555-0000-4000-9000-000000000017
dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000017
run.starting	elf-starting:55555555-0000-4000-9000-000000000017
run.running	elf-running:55555555-0000-4000-9000-000000000017
checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000022
run.completed	elf-terminal:55555555-0000-4000-9000-000000000017
```

## Normalized events (13): ordinal, kind, detail

```
1	lifecycle	{"claude-headless:claude_code_version":"2.1.283","claude-headless:frame_type":"system","claude-headless:model":"claude-opus-5-5","claude-headless:permission_mode":"bypassPermissions","claude-headless:subtype":"init","claude-headless:tools":["Bash","mcp__claude_ai_Claude_Docs__batch","mcp__claude_ai_Claude_Docs__create","mcp__claude_ai_Claude_Docs__delete","mcp__claude_ai_Claude_Docs__export","mcp__claude_ai_Claude_Docs__guide","mcp__claude_ai_Claude_Docs__query","mcp__claude_ai_Claude_Docs__read","mcp__claude_ai_Claude_Docs__update"]}
2	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
3	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
4	command	{"claude-headless:boundary":"start","claude-headless:command":"git status --short; git log --oneline -3; git show --stat HEAD | cat; for c in \"gofmt -l .\" \"go test ./...\" \"go vet ./...\"; do echo \"\\$ $c\"; timeout 300 zsh -c \"$c\" < /dev/null; echo \"exit $?\"; done","claude-headless:description":"Check git state and rerun gofmt, tests, vet","claude-headless:message_id":"msg_000000000000000000000010","claude-headless:request_id":"req_000000000000000000000011","claude-headless:tool_name":"Bash","claude-headless:tool_use_id":"toolu_000000000000000000000012"}
5	lifecycle	{"claude-headless:five_hour_utilization":0.29,"claude-headless:frame_type":"rate_limit_event","claude-headless:rate_limit_status":"allowed","claude-headless:rate_limit_type":"five_hour","claude-headless:seven_day_utilization":0.48}
6	command	{"claude-headless:boundary":"end","claude-headless:interrupted":false,"claude-headless:is_error":false,"claude-headless:status":"completed","claude-headless:tool_result_text":"0fb8be4 Add move parser and table-driven tests\n4fb93ca Implement Tic-Tac-Toe game package with table-driven tests\n8f9512d Baseline: module, task and legacy material\ncommit 0fb8be4315738dc4076ee04b5133307311e02233\nAuthor: Live Eval <live-eval@example.invalid>\nDate:   Fri Sep 25 18:39:37 2026 -0700\n\n    Add move parser and table-driven tests\n\n main.go      | 29 +++++++++++++++++++++++++++++\n main_test.go | 55 +++
7	command	{"claude-headless:boundary":"start","claude-headless:command":"cat main.go main_test.go; git show HEAD --format=%B -s | cat","claude-headless:description":"Review committed parser, tests, and commit message","claude-headless:message_id":"msg_000000000000000000000013","claude-headless:request_id":"req_000000000000000000000014","claude-headless:tool_name":"Bash","claude-headless:tool_use_id":"toolu_000000000000000000000015"}
8	lifecycle	{"claude-headless:five_hour_utilization":0.3,"claude-headless:frame_type":"rate_limit_event","claude-headless:rate_limit_status":"allowed","claude-headless:rate_limit_type":"five_hour","claude-headless:seven_day_utilization":0.48}
9	command	{"claude-headless:boundary":"end","claude-headless:interrupted":false,"claude-headless:is_error":false,"claude-headless:status":"completed","claude-headless:tool_result_text":"package main\n\nimport (\n\t\"errors\"\n\t\"strconv\"\n\t\"strings\"\n)\n\n// parseMove converts two whitespace-separated coordinates to zero-based indices.\nfunc parseMove(line string) (row, col int, err error) {\n\tfields := strings.Fields(line)\n\tif len(fields) != 2 {\n\t\treturn 0, 0, errors.New(\"expected exactly two coordinates\")\n\t}\n\trow, err = strconv.Atoi(fields[0])\n\tif err != nil {\n\t\treturn 0, 0, err\
10	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
11	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
12	output	{"claude-headless:output_text":"I checked the worktree again and this session's work is complete, so I'm stopping here as the brief says. The one open problem is a `go vet` failure in `legacy/`, which is left for the next session.\n\n**State (VERIFIED, from this run):**\n- Branch `shoestring/run-6c5941bf-…` is at `0fb8be4` (\"Add move parser and table-driven tests\"), and the working tree is clean.\n- That commit adds only `main.go` and `main_test.go`. `parseMove` accepts exactly two whitespace-separated integers from 1 to 3 and ret"}
13	result	{"claude-headless:duration_ms":13852,"claude-headless:frame_type":"result","claude-headless:num_turns":3,"claude-headless:status":"completed","claude-headless:terminal":true,"claude-headless:terminal_reason":"completed","claude-headless:total_cost_usd":0.090668,"result":{"status":"completed"}}
```
