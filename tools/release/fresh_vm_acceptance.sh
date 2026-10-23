#!/bin/zsh
# Fresh-machine acceptance for the Shoestring release. Prints PASS/FAIL lines.
# Run inside a clean macOS VM (no Homebrew or language toolchains) with the
# archive, SHA256SUMS and generated shoestring.rb copied to ~/pkg. Installs
# Homebrew from the network; exits with the number of failed checks.
to() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
D="$HOME/Library/Application Support/Shoestring"
ARCHIVE=$HOME/pkg/shoestring-0.2.0-aarch64-apple-darwin.tar.gz

echo "== environment"; sw_vers -productVersion
check "no homebrew or toolchains" '! command -v brew >/dev/null && ! command -v elixir >/dev/null && ! command -v erl >/dev/null && ! command -v cargo >/dev/null && ! command -v node >/dev/null'
check "checksum" '(cd ~/pkg && shasum -a 256 -c SHA256SUMS >/dev/null)'

echo "== phase A: archive without OpenSSL 3"
mkdir -p ~/direct && tar -xzf $ARCHIVE -C ~/direct
for a in doctor init version start; do
  out=$(to 60 ~/direct/bin/shoestringctl $a 2>&1); st=$?
  check "no-openssl $a refuses with instruction" '[ $st -eq 1 ] && [ "$out" = "OpenSSL 3 is a required runtime dependency and was not found at /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib. Install it with Homebrew: brew install openssl@3" ]'
done
check "no state written" '[ ! -e "$D" ]'

echo "== phase B: Homebrew"
NONINTERACTIVE=1 to 580 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" > ~/brew-install.log 2>&1
check "homebrew installed" '[ -x /opt/homebrew/bin/brew ]'
eval "$(/opt/homebrew/bin/brew shellenv zsh)"; export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1
to 120 brew tap-new --no-git local/shoestring >/dev/null 2>&1
T=$(brew --repository)/Library/Taps/local/homebrew-shoestring/Formula; mkdir -p $T
sed "s#url \".*\"#url \"file://$ARCHIVE\"#" ~/pkg/shoestring.rb > $T/shoestring.rb
to 580 brew install local/shoestring/shoestring > ~/brew-shoestring.log 2>&1
check "formula installs" '[ $? -eq 0 ] && command -v shoestring >/dev/null'
check "no language toolchain pulled in" '! command -v elixir >/dev/null && ! command -v erl >/dev/null && ! command -v cargo >/dev/null && ! command -v rustc >/dev/null && ! command -v node >/dev/null'
check "version" '[ "$(to 60 shoestring version)" = "shoestring 0.2.0" ]'
to 120 shoestring doctor > ~/d1.json 2>&1
check "doctor before init" 'grep -q "\"database\": \"needs_init\"" ~/d1.json && grep -q "\"helper\": \"compatible\"" ~/d1.json && grep -q "\"git\": \"present\"" ~/d1.json && grep -q "\"python3\": \"present\"" ~/d1.json'

echo "== init"
python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1",4000)); s.listen(); time.sleep(30)' & L=$!; sleep 1
out=$(to 120 shoestring init 2>&1); st=$?
check "init refuses a busy port in one line" '[ $st -ne 0 ] && [ "$(print -r -- "$out" | grep -c .)" -eq 1 ] && print -r -- "$out" | grep -q "^Initialization refused: configured endpoint port is unavailable"'
kill $L 2>/dev/null; wait $L 2>/dev/null
to 300 shoestring init > ~/init.log 2>&1
check "init" '[ $? -eq 0 ]'
check "init again is idempotent" 'to 300 shoestring init 2>&1 | grep -q "Migrations already up"'
to 120 shoestring doctor > ~/d2.json 2>&1
check "doctor after init" 'grep -q "\"database\": \"ok\"" ~/d2.json && grep -q "\"endpoint_secret\": \"private\"" ~/d2.json'
check "state directory private" '[ "$(stat -f %Lp "$D")" = 700 ] && [ "$(stat -f %Lp "$D/.endpoint-secret")" = 600 ]'

echo "== diagnostics"
to 120 shoestring diagnostics-preview > ~/preview.json 2>&1
check "preview" '[ $? -eq 0 ] && grep -q "\"confirmation_sha256\"" ~/preview.json'
out=$(to 120 shoestring diagnostics-export ~/diag-bad.json $(printf '0%.0s' {1..64}) 2>&1); st=$?
check "wrong hash refused in one line, nothing written" '[ $st -eq 1 ] && [ "$out" = "Operation refused: diagnostic_confirmation_mismatch" ] && [ ! -e ~/diag-bad.json ]'
SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["confirmation_sha256"])' ~/preview.json)
to 120 shoestring diagnostics-export ~/diag.json $SHA > /dev/null 2>&1
check "export" '[ $? -eq 0 ] && [ "$(stat -f %Lp ~/diag.json)" = 600 ] && ! grep -q "/Users/admin" ~/diag.json'

echo "== start"
nohup shoestring start > ~/start.log 2>&1 < /dev/null & PID=$!
for i in $(seq 1 60); do code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4000/health); [ "$code" = 200 ] && break; sleep 1; done
check "health 200 (${i}s)" '[ "$code" = 200 ] && curl -s http://127.0.0.1:4000/health | grep -q "\"ready\":true"'
check "ui 200" '[ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4000/)" = 200 ]'
out=$(to 60 shoestring start 2>&1); st=$?
check "second start refused in one line" '[ $st -ne 0 ] && [ "$out" = "State is owned by a running Shoestring process. Stop it explicitly before upgrading or starting another instance." ]'
kill -TERM $PID; for i in $(seq 1 30); do kill -0 $PID 2>/dev/null || break; sleep 1; done; wait $PID; st=$?
check "SIGTERM stop (${i}s)" '[ $st -eq 0 ] && ! kill -0 $PID 2>/dev/null'
check "no errors logged while running" '! grep -q "\[error\]" ~/start.log'

echo "== reinstall over existing state"
before=$(shasum -a 256 "$D/shoestring.db" | cut -c1-16)
to 300 brew reinstall local/shoestring/shoestring > /dev/null 2>&1
check "reinstall" '[ $? -eq 0 ]'
nohup shoestring start > ~/start2.log 2>&1 < /dev/null & PID=$!
for i in $(seq 1 60); do code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4000/health); [ "$code" = 200 ] && break; sleep 1; done
check "restart on existing state healthy" '[ "$code" = 200 ]'
kill -TERM $PID; wait $PID; check "second stop" '[ $? -eq 0 ]'
check "no backup needed when schema current" '[ ! -d "$D/backups" ] || [ -z "$(ls -A "$D/backups")" ]'

echo "== brew test and uninstall"
to 300 brew test local/shoestring/shoestring > /dev/null 2>&1
check "brew test" '[ $? -eq 0 ]'
before=$(shasum -a 256 "$D/shoestring.db" | cut -c1-16)
to 120 brew uninstall shoestring > /dev/null 2>&1
check "uninstall removes binary" '! command -v shoestring >/dev/null'
check "uninstall keeps state" '[ "$(shasum -a 256 "$D/shoestring.db" | cut -c1-16)" = "$before" ] && [ -f "$D/.endpoint-secret" ]'

echo "== result: $fails failure(s)"
exit $fails
