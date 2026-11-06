# Documentation screenshots

The images in `docs/images/` are captured from a development service seeded
with synthetic data. Nothing in them comes from a real account, repository or
provider.

```sh
# Terminal 1: a new, empty directory outside your real state.
tools/screenshots/serve.sh "$(mktemp -d)/shots"

# Terminal 2, once http://localhost:4000/health answers:
node tools/screenshots/capture.js http://localhost:4000 docs/images
```

`serve.sh` prepares a throwaway state directory, runs `seed.exs` (a team,
two usage readings, a coordinator session with an EXPLORE and an IMPLEMENT
dispatch, and two lessons) and starts `mix phx.server`.

**Why the PATH is cut down.** In development `SHOESTRING_AUTOMATION=off` does
not stop the service's job queues, so it may pick up the seeded dispatches.
`serve.sh` runs with only Elixir, Erlang, `/usr/bin` and `/bin` on `PATH` and
refuses to start if `claude`, `codex` or `opencode` is still reachable, so a
seeded dispatch fails to start rather than reaching a provider. The seed also
opens no coordinator conversation: a running service would wake that
coordinator, which launches a provider CLI.

`capture.js` needs Playwright and Chromium. It loads each page at
1280×800, device scale 2, light colour scheme, and clicks nothing. Stop the
service with Ctrl-C and delete the directory afterwards.
