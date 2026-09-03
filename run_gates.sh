#!/bin/bash
cd /Users/anukin/projects/shoestring/.worktrees/iter3-codex-monitor
mix compile --warnings-as-errors; echo "exit=$?"
mix test; echo "exit=$?"
mix format --check-formatted; echo "exit=$?"
mix precommit; echo "exit=$?"
