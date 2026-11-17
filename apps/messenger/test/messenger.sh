#!/usr/bin/env bash
# Tests Messenger on two servers of a network on this machine, against a fake messenger.com (`messenger.js`) with
# the parts the browser reads on the real one: signing in, in a window the person finishes, which is kept;
# listing chats, reading one (and marking it unread again), searching, and sending (to the fake); the other server
# reading from the same session, the session outlasting a restart, with the keys in IndexedDB its encrypted chats
# need, the session never on a disk or in the bucket unencrypted, and signing out.
#
#     ONE_APP=~/the-one-app mise exec -C ~/the-one-app -- "$PWD/apps/messenger/test/messenger.sh"
#
# ONE_APP is a checkout of The One App with its client built (`cargo build --release`). The machine needs Bun and
# Playwright's Chromium. The sign-in window opens headless here, as nobody is at the screen: the fake is told the
# person signed in.
source "${ONE_APP:?a checkout of The One App}/core/server/test/servers.sh"
app=$(cd "$(dirname "$0")/.." && pwd)

ask() {
  local server=$1
  shift
  ONE_HOME=$folder/only-$server "$one" "$@" 2>&1 | sed -e "s/${key[a]:-none}/a/g" -e "s/${key[b]:-none}/b/g"
}
# Waits for a line a log has yet to say, while `"$@"` runs.
after() {
  local log=$1 pattern=$2 lines
  shift 2
  lines=$(wc -l <"$log")
  "$@"
  timeout 120 grep -q -m1 -e "$pattern" <(tail -f -n +$((lines + 1)) "$log") || { echo "$log never said: $pattern"; exit 1; }
}

# The fake messenger.com, and the app pointed at it, its sign-in window headless.
: >"$folder/messenger.log"
bun "$app/test/messenger.js" >>"$folder/messenger.log" 2>&1 &
group[messenger]=$!
read -r port < <(tail -f -n +1 "$folder/messenger.log" | head -1)
fake=http://127.0.0.1:$port
mkdir -p "$folder/messenger/server/browser"
cp -r "$app"/{SKILL.md,client} "$folder/messenger/"
cp "$app"/server/*.ex "$folder/messenger/server/"
cp "$app"/server/browser/{main.js,package.json,bun.lock} "$folder/messenger/server/browser/"
sed -i -e "s|https://www.messenger.com/|$fake/|" -e "s/launch(false)/launch(true)/" "$folder/messenger/server/browser/main.js"
approve() { curl -s -X POST "$fake/approve" && echo; }

say "Two servers, each its own machine by name, and Messenger deployed for the owner"
options="--name a" start a
options="--name b" start b
deployed=$(ask a deploy --name messenger --files-from "$folder/messenger" || true)
echo "$deployed" | head -c 600 && echo
[[ $deployed == *"\"version\""* ]]

say "The owner's key is made on their phone, which chooses both servers to open their Vault"
mkdir -p "$folder/phone"
printf '[%s,%s]' "$(sed -e 's/^\[//' -e 's/\]$//' "$folder/only-a/servers")" "$(sed -e 's/^\[//' -e 's/\]$//' "$folder/only-b/servers")" >"$folder/phone/servers"
phone() { ONE_HOME=$folder/phone "$one" "$@" 2>&1; }
phone encryption approve | head -c 200 && echo
phone vault grant --servers "[\"${key[a]}\",\"${key[b]}\"]"

say "Messenger's browser on both"
ask a install_service --app messenger --service Messenger.Browser --server "${key[a]}" >/dev/null
ask a install_service --app messenger --service Messenger.Browser --server "${key[b]}" >/dev/null
ask a messenger devices
ask a messenger chats || true

say "Signing in: a window opens on a, the person signs in there, and it's kept"
ask a messenger sign_in --account Personal --device a
echo "the person signs in, in the window:"
after "$folder/a.log" "Messenger: Personal is signed in" approve
ask a messenger accounts
phone vault list | grep -o '"name":"Messenger[^"]*"'

say "Chats are listed, read and searched, through a"
ask a messenger chats
ask a messenger chats --unread true
ask a messenger read --chat kim
grep -o "fake Messenger: marked .*" "$folder/messenger.log"
ask a messenger search --query lunch

say "Sending, to the fake: to a chat, to someone with none, and refused when it's unclear who"
ask a messenger send --chat Kim --text "See you at 12:30"
ask a messenger send --chat "Jo Lin" --text "Hi Jo, it's Sam"
ask a messenger send --chat Lee --text "never sent" || true
grep -o "fake Messenger: sent to .*" "$folder/messenger.log"

say "b reads from the same session, which it opens itself"
ask b messenger chats

say "The session outlasts a's restart, with the keys its encrypted chats need"
stop a
options="--name a" start a
ask a messenger read --chat Family


say "The session is never on a disk or in the bucket unencrypted"
echo "files of the network holding the keys the fake put in IndexedDB: $({ grep -r -a -l -F "made-up-keys" "$folder" --exclude=messenger.js || true; } | wc -l)"
echo "the browsers' own folders holding them: $({ grep -r -a -l -F "made-up-keys" /tmp/playwright* 2>/dev/null || true; } | wc -l)"
for blob in $(find "$bucket" -path "*messenger/sessions/*" -type f); do
  echo "the bucket's ${blob#"$bucket"/}: $(wc -c <"$blob") bytes, starts like JSON: $([[ $(head -c1 "$blob") == "{" ]] && echo yes || echo no)"
done
[[ $({ grep -r -a -l -F "made-up-keys" "$folder" --exclude=messenger.js || true; } | wc -l) == 0 ]]

say "Signing out deletes the session here"
ask b messenger sign_out --account Personal
ask a messenger accounts
phone vault list | grep -c '"name":"Messenger' || true
echo "session blobs left in the bucket: $(find "$bucket" -path "*messenger/sessions/*" -type f | wc -l)"
echo
echo "Messenger is proven."
