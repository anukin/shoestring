# normalized-claude-receiver-attempt2-floor

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
run.requested	run-requested:55555555-0000-4000-9000-000000000009
lease.proposed	lease-proposed:55555555-0000-4000-9000-000000000011
handoff.created	handoff:55555555-0000-4000-9000-000000000009
dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000009
run.starting	elf-starting:55555555-0000-4000-9000-000000000009
run.running	elf-running:55555555-0000-4000-9000-000000000009
checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000012
run.completed	elf-terminal:55555555-0000-4000-9000-000000000009
```

## Normalized events (17): ordinal, kind, detail

```
1	lifecycle	{"claude-headless:claude_code_version":"2.1.283","claude-headless:frame_type":"system","claude-headless:model":"claude-opus-5-5","claude-headless:permission_mode":"bypassPermissions","claude-headless:subtype":"init","claude-headless:tools":["Bash","mcp__claude_ai_Claude_Docs__batch","mcp__claude_ai_Claude_Docs__create","mcp__claude_ai_Claude_Docs__delete","mcp__claude_ai_Claude_Docs__export","mcp__claude_ai_Claude_Docs__guide","mcp__claude_ai_Claude_Docs__query","mcp__claude_ai_Claude_Docs__read","mcp__claude_ai_Claude_Docs__update"]}
2	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
3	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
4	command	{"claude-headless:boundary":"start","claude-headless:command":"git status --short; git log --oneline -5; ls; git show --stat HEAD | cat; cat TASK.md","claude-headless:description":"Inspect worktree state and task","claude-headless:message_id":"msg_000000000000000000000001","claude-headless:request_id":"req_000000000000000000000002","claude-headless:tool_name":"Bash","claude-headless:tool_use_id":"toolu_000000000000000000000003"}
5	lifecycle	{"claude-headless:five_hour_utilization":0.24,"claude-headless:frame_type":"rate_limit_event","claude-headless:rate_limit_status":"allowed","claude-headless:rate_limit_type":"five_hour","claude-headless:seven_day_utilization":0.47}
6	command	{"claude-headless:boundary":"end","claude-headless:interrupted":false,"claude-headless:is_error":false,"claude-headless:status":"completed","claude-headless:tool_result_text":"b2fe39d Add move parser and table-driven tests\n4fb93ca Implement Tic-Tac-Toe game package with table-driven tests\n8f9512d Baseline: module, task and legacy material\ndocs\ngame\ngo.mod\nlegacy\nmain_test.go\nmain.go\nTASK.md\ncommit b2fe39d51c7a6f76384f44b5b481714fee1aa544\nAuthor: Live Eval <live-eval@example.invalid>\nDate:   Fri Sep 25 18:27:13 2026 -0700\n\n    Add move parser and table-driven tests\n\n main.go    
7	output	{"claude-headless:output_text":"Step 1 appears committed already. Verifying its content and rerunning the gates."}
8	command	{"claude-headless:boundary":"start","claude-headless:command":"cat main.go main_test.go; echo \"--- gofmt\"; gofmt -l . ; echo \"rc=$?\"; echo \"--- test\"; go test ./... < /dev/null; echo \"rc=$?\"; echo \"--- vet\"; go vet ./... < /dev/null; echo \"rc=$?\"","claude-headless:description":"Review main.go and run gofmt, tests, vet","claude-headless:message_id":"msg_000000000000000000000004","claude-headless:request_id":"req_000000000000000000000005","claude-headless:tool_name":"Bash","claude-headless:tool_use_id":"toolu_000000000000000000000006"}
9	command	{"claude-headless:boundary":"end","claude-headless:interrupted":false,"claude-headless:is_error":false,"claude-headless:status":"completed","claude-headless:tool_result_text":"package main\n\nimport (\n\t\"errors\"\n\t\"strconv\"\n\t\"strings\"\n)\n\nfunc parseMove(line string) (row, col int, err error) {\n\tfields := strings.Fields(line)\n\tif len(fields) != 2 {\n\t\treturn 0, 0, errors.New(\"expected two coordinates\")\n\t}\n\trow, err = strconv.Atoi(fields[0])\n\tif err != nil {\n\t\treturn 0, 0, err\n\t}\n\tcol, err = strconv.Atoi(fields[1])\n\tif err != nil {\n\t\treturn 0, 0, err\n\t}\n\
10	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
11	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
12	lifecycle	{"claude-headless:frame_type":"system","claude-headless:subtype":"thinking_tokens"}
13	command	{"claude-headless:boundary":"start","claude-headless:command":"git remote -v; git status -sb | head -1","claude-headless:description":"Check remotes and branch tracking","claude-headless:message_id":"msg_000000000000000000000007","claude-headless:request_id":"req_000000000000000000000008","claude-headless:tool_name":"Bash","claude-headless:tool_use_id":"toolu_000000000000000000000009"}
14	command	{"claude-headless:boundary":"end","claude-headless:interrupted":false,"claude-headless:is_error":false,"claude-headless:status":"completed","claude-headless:tool_result_text":"## shoestring/run-55555555-0000-4000-9000-000000000006","claude-headless:tool_stdout":"## shoestring/run-55555555-0000-4000-9000-000000000006","claude-headless:tool_use_id":"toolu_000000000000000000000009"}
15	output	{"claude-headless:output_text":"This session's work was already done and committed; I reran the checks, and all pass except `go vet`, which fails on legacy code I was told to leave alone. Nothing new needed committing, so I made no changes.\n\n**Worktree state:** the branch `shoestring/run-34670f38-…` has no uncommitted changes. HEAD is `b2fe39d Add move parser and table-driven tests`, which adds only `main.go` and `main_test.go`.\n\n**Step 1 (reviewed in the code):**\n- `parseMove` in `main.go` splits the line on whitespace and re"}
16	lifecycle	{"claude-headless:five_hour_utilization":0.25,"claude-headless:frame_type":"rate_limit_event","claude-headless:rate_limit_status":"allowed","claude-headless:rate_limit_type":"five_hour","claude-headless:seven_day_utilization":0.47}
17	result	{"claude-headless:duration_ms":18127,"claude-headless:frame_type":"result","claude-headless:num_turns":4,"claude-headless:status":"completed","claude-headless:terminal":true,"claude-headless:terminal_reason":"completed","claude-headless:total_cost_usd":0.1186412,"result":{"status":"completed"}}
```
