# normalized-codex-cancel-final

Canonical trajectory material for one live run on the production-configured
node, redacted. Redaction is applied to the REASSEMBLED delta stream and then to
each whole detail line; every substitution is same-length, so ordinals and
counts are unchanged. Worktree paths become `$WORKSPACE`, other host paths
`$REDACTED_PATH`, UUIDs map 1:1 to the synthetic `01950000-0000-7000-8000-…`
(UUIDv7) and `55555555-0000-4000-9000-…` series, `pgid:` numbers become `x`.
Per-event provider session ids, source event ids, item ids and cwd are omitted.
Details are capped at 600 characters. The `x` runs are padding, not data.

## Run lifecycle and terminal events (9)

```
run.requested	run-requested:55555555-0000-4000-9000-000000000061
lease.proposed	lease-proposed:55555555-0000-4000-9000-000000000062
dispatch.requested	dispatch-requested:55555555-0000-4000-9000-000000000061
run.starting	elf-starting:55555555-0000-4000-9000-000000000061
run.running	elf-running:55555555-0000-4000-9000-000000000061
dispatch.effect_deferred	dispatch-effect-deferred:55555555-0000-4000-9000-000000000061
run.cancelling	elf-cancelling:55555555-0000-4000-9000-000000000061
checkpoint.created	checkpoint-created:55555555-0000-4000-9000-000000000063
run.cancelled	elf-terminal:55555555-0000-4000-9000-000000000061
```

## Normalized events (30): ordinal, kind, detail

```
1	lifecycle	{"codex-app-server:method":"thread/status/changed","codex-app-server:status":"active"}
2	lifecycle	{"codex-app-server:method":"turn/started","codex-app-server:status":"inProgress","codex-app-server:turn_id":"01950000-0000-7000-8000-000000000060"}
3	lifecycle	{"codex-app-server:item_type":"userMessage"}
4	lifecycle	{"codex-app-server:item_type":"userMessage"}
5	output	{"codex-app-server:phase":"commentary"}
6	output	{"codex-app-server:delta":"I","codex-app-server:method":"item/agentMessage/delta"}
7	output	{"codex-app-server:delta":"’ll","codex-app-server:method":"item/agentMessage/delta"}
8	output	{"codex-app-server:delta":" inspect","codex-app-server:method":"item/agentMessage/delta"}
9	output	{"codex-app-server:delta":" the","codex-app-server:method":"item/agentMessage/delta"}
10	output	{"codex-app-server:delta":" module","codex-app-server:method":"item/agentMessage/delta"}
11	output	{"codex-app-server:delta":",","codex-app-server:method":"item/agentMessage/delta"}
12	output	{"codex-app-server:delta":" write","codex-app-server:method":"item/agentMessage/delta"}
13	output	{"codex-app-server:delta":" the","codex-app-server:method":"item/agentMessage/delta"}
14	output	{"codex-app-server:delta":" design","codex-app-server:method":"item/agentMessage/delta"}
15	output	{"codex-app-server:delta":" note","codex-app-server:method":"item/agentMessage/delta"}
16	output	{"codex-app-server:delta":",","codex-app-server:method":"item/agentMessage/delta"}
17	output	{"codex-app-server:delta":" then","codex-app-server:method":"item/agentMessage/delta"}
18	output	{"codex-app-server:delta":" implement","codex-app-server:method":"item/agentMessage/delta"}
19	output	{"codex-app-server:delta":" the","codex-app-server:method":"item/agentMessage/delta"}
20	output	{"codex-app-server:delta":" engine","codex-app-server:method":"item/agentMessage/delta"}
21	output	{"codex-app-server:delta":" and","codex-app-server:method":"item/agentMessage/delta"}
22	output	{"codex-app-server:delta":" exhaustive","codex-app-server:method":"item/agentMessage/delta"}
23	output	{"codex-app-server:delta":" tests","codex-app-server:method":"item/agentMessage/delta"}
24	output	{"codex-app-server:delta":",","codex-app-server:method":"item/agentMessage/delta"}
25	output	{"codex-app-server:delta":" running","codex-app-server:method":"item/agentMessage/delta"}
26	output	{"codex-app-server:delta":" `","codex-app-server:method":"item/agentMessage/delta"}
27	output	{"codex-app-server:delta":"go","codex-app-server:method":"item/agentMessage/delta"}
28	output	{"codex-app-server:delta":" test","codex-app-server:method":"item/agentMessage/delta"}
29	output	{"codex-app-server:delta":" ./","codex-app-server:method":"item/agentMessage/delta"}
30	output	{"codex-app-server:delta":"...","codex-app-server:method":"item/agentMessage/delta"}
```
