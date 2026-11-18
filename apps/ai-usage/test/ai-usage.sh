#!/usr/bin/env bash
# Tests AI Usage on two servers of a network on this machine, against fake providers (`providers.js`) and sign-ins
# made up for it: each machine reads the plans signed in on it, the app merges them by account and keeps the
# readings, a reading under 5 minutes old is answered without asking again, the readings outlast both servers, the
# newest of each account is found through the index, and no token reaches an answer, a log or the bucket.
#
#     ONE_APP=~/the-one-app mise exec -C ~/the-one-app -- "$PWD/apps/ai-usage/test/ai-usage.sh"
#
# With SHOTS=<folder>, it takes pictures of the screen there too.
#
# ONE_APP is a checkout of the One App with its client built (`cargo build --release`). The servers read the sign-ins
# in the test's folder, by the variables Claude Code, Codex and OpenCode honour, never this machine's own.
source "${ONE_APP:?a checkout of the One App}/core/server/test/servers.sh"
app=$(cd "$(dirname "$0")/.." && pwd)
# What went wrong, from the server's side, before the folder goes.
set -E
trap 'tail -60 "$folder"/a.log 2>/dev/null' ERR

random() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
marker=ai-usage-test-$(random 6)
ask() {
  local server=$1
  shift
  ONE_HOME=$folder/only-$server "$one" "$@" 2>&1 | tee -a "$folder/said" | sed -e "s/${key[a]:-none}/a/g" -e "s/${key[b]:-none}/b/g"
}

# The fake providers, and the app pointed at them: only its three addresses differ.
: >"$folder/providers.port"
(cd "$ONE_APP/core/edge" && MARKER=$marker exec bun "$app/test/providers.js") >>"$folder/providers.port" 2>"$folder/providers.log" &
group[providers]=$!
read -r port < <(tail -f -n +1 "$folder/providers.port" | head -1)
fake=http://127.0.0.1:$port
mkdir "$folder/ai-usage"
cp -r "$app"/{SKILL.md,server,client} "$folder/ai-usage/"
sed -i -e "s|https://api.anthropic.com|$fake|" -e "s|https://chatgpt.com|$fake|" -e "s|https://opencode.ai|$fake|" "$folder/ai-usage/server/reader.ex"
seen() { curl -s "$fake/seen"; }

# Sign-ins as the tools keep them: two Claude accounts in claude-swap and one that ran out, Codex's and OpenCode's.
signins=$folder/signins
export XDG_DATA_HOME=$signins/data CLAUDE_CONFIG_DIR=$signins/claude CODEX_HOME=$signins/codex
mkdir -p "$XDG_DATA_HOME/claude-swap/credentials" "$XDG_DATA_HOME/opencode" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
creds() { printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s}}' "$1" "$2" | base64 -w0; }
later=$((($(date +%s) + 86400) * 1000))
creds "$marker-claude-1" $later >"$XDG_DATA_HOME/claude-swap/credentials/.creds-1-sam@example.com.enc"
creds "$marker-claude-2" $later >"$XDG_DATA_HOME/claude-swap/credentials/.creds-2-sam@work.example.enc"
creds "$marker-claude-3" 1000 >"$XDG_DATA_HOME/claude-swap/credentials/.creds-3-old@example.com.enc"
cat >"$XDG_DATA_HOME/claude-swap/sequence.json" <<EOF
{"activeAccountNumber":1,"sequence":[1,2,3],"accounts":{
  "1":{"email":"sam@example.com","uuid":"u-sam","organizationUuid":"o-sam","organizationName":"sam@example.com's Organization"},
  "2":{"email":"sam@work.example","uuid":"u-sam-work","organizationUuid":"o-example","organizationName":"Example Co"},
  "3":{"email":"old@example.com","uuid":"u-old","organizationUuid":"o-old","organizationName":"Old Co","disabled":true}}}
EOF
# Claude Code is signed in to the first: that one is in use.
printf '{"oauthAccount":{"accountUuid":"u-sam","organizationUuid":"o-sam"}}' >"$CLAUDE_CONFIG_DIR/.claude.json"
claims=$(printf '{"email":"sam@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
printf '{"tokens":{"access_token":"%s-codex","account_id":"acct-1","id_token":"e30.%s.sig"}}' "$marker" "$claims" >"$CODEX_HOME/auth.json"
printf '{"opencode":{"key":"%s-opencode"}}' "$marker" >"$XDG_DATA_HOME/opencode/auth.json"

say "Two servers, each its own machine by name, and AI Usage deployed for the owner"
options="--name a" start a
options="--name b" start b
ask a deploy --name ai-usage --files-from "$folder/ai-usage" | head -c 1500; echo
ask a services | grep -o '"needs":"[^"]*"' | grep -i "claude"
echo "before any machine reads plans:"
ask a ai-usage status

say "Its service on both: each reads the plans signed in on it, and they're merged by account"
ask a install_service --app ai-usage --service AIUsage.Reader --server "${key[a]}" >/dev/null
ask a install_service --app ai-usage --service AIUsage.Reader --server "${key[b]}" >/dev/null
ask a ai-usage status
echo "the fake providers were read: $(seen)"
ask b ai-usage status --format json | head -c 700 && echo " ..."

say "A reading under 5 minutes old is answered without asking again, through either server"
before=$(seen)
ask b ai-usage status --provider codex
[[ $(seen) == "$before" ]] && echo "the providers were read nothing more: $(seen)"

say "The readings outlast both servers"
stop a && stop b
options="--name a" start a
ask a ai-usage status --provider claude
[[ $(seen) == "$before" ]] && echo "answered from the readings kept, with the providers read nothing more: $(seen)"

if [[ -n ${SHOTS:-} ]]; then
  say "Pictures of its screen, on a phone and a desktop, light and dark, into $SHOTS"
  cat >"$folder/steps.js" <<'EOF'
export default async ({ app, shot }) => {
  const frame = await app("AI Usage")
  await frame.locator(".provider").first().waitFor({ timeout: 10000 }).catch(async (error) => {
    await shot("ai-usage-failed")
    console.error(await frame.locator("body").innerHTML())
    throw error
  })
  await shot("ai-usage")
}
EOF
  mkdir -p "$SHOTS"
  (cd "$ONE_APP/core/edge" && ONE_HOME=$folder/only-a bun "$ONE_APP/clients/app/test/window.js" "$SHOTS" "$folder/steps.js")
  ls "$SHOTS" | grep ai-usage
fi

say "Each account's newest reading is found through the index"
copy=$(find "$folder/a" -path "*ai-usage*" -name copy.sqlite | head -1)
python3 -I - "$copy" <<'EOF'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
plan = db.execute("""explain query plan
  select r.* from (select account, max(at) as newest from readings where provider = ? and at <= ? group by account) l
  cross join readings r on r.provider = ? and r.account = l.account and r.at = l.newest""", ("claude", 9e12, "claude")).fetchall()
print("  rows kept:", db.execute("select count(*) from readings").fetchone()[0])
for row in plan:
    print("  " + row[-1])
assert any(row[-1].startswith("SEARCH r USING INDEX readings_newest (provider=? AND account=? AND at=?)") for row in plan), "a walk over every reading"
EOF

say "No token reached an answer, a log or the bucket"
echo "what every call answered: $(wc -l <"$folder/output") lines, of which $({ grep -c -F -e "$marker" "$folder/output" || true; }) hold a token's marker"
echo "the servers' logs: $(cat "$folder"/a.log "$folder"/b.log | wc -l) lines, of which $({ cat "$folder"/a.log "$folder"/b.log | grep -c -a -F -e "$marker" || true; }) hold it"
echo "the bucket's files: $(find "$bucket" -type f | wc -l), of which $({ grep -r -a -l -F -e "$marker" "$bucket" || true; } | wc -l) hold it"
[[ $({ grep -c -F -e "$marker" "$folder/said" || true; }) == 0 && $({ grep -r -a -l -F -e "$marker" "$bucket" || true; } | wc -l) == 0 ]]
echo
echo "AI Usage passes."
