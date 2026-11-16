#!/usr/bin/env bash
# Tests WhatsApp on two servers of a network on this machine, against a fake WhatsApp at the edge of whatsmeow
# (`fake_client.go`, which takes `server/bridge/client.go`'s place, with whatsmeow's own store and parsing underneath):
# linking a phone by QR code, its chats arriving and being listed, read and searched, a message arriving, sending
# (to the fake), the link carrying on from its session after its server restarts, the other server taking it over
# while the first is down, the session never on a disk or in the bucket unencrypted, and signing out.
#
#     ONE_APP=~/the-one-app mise exec -C ~/the-one-app -- "$PWD/plugins/whatsapp/test/whatsapp.sh"
#
# ONE_APP is a checkout of The One App with its client built (`cargo build --release`). The machine needs Go. With
# SHOTS=<folder>, it takes pictures of the screen there too.
source "${ONE_APP:?a checkout of The One App}/core/server/test/servers.sh"
plugin=$(cd "$(dirname "$0")/.." && pwd)

ask() {
  local server=$1
  shift
  ONE_HOME=$folder/only-$server "$one" "$@" 2>&1 | sed -e "s/${key[a]:-none}/a/g" -e "s/${key[b]:-none}/b/g"
}
# Waits for a line a server's log has yet to say, while `"$@"` runs.
after() {
  local log=$folder/$1.log pattern=$2 lines
  shift 2
  lines=$(wc -l <"$log")
  "$@"
  timeout 120 grep -q -m1 -e "$pattern" <(tail -f -n +$((lines + 1)) "$log") || { echo "$log never said: $pattern"; exit 1; }
}
# The link's program on a server, which the fake answers to: SIGUSR1 is the phone scanning, SIGUSR2 a message.
link() { pgrep -f "$folder/$1/services/.*/whatsapp-link$"; }

# The plugin as it's deployed, with the fake in the place of whatsmeow's client.
mkdir "$folder/whatsapp"
cp -r "$plugin"/{SKILL.md,server,client} "$folder/whatsapp/"
cp "$plugin/test/fake_client.go" "$folder/whatsapp/server/bridge/client.go"

say "Two servers, each its own machine by name, and WhatsApp deployed for the owner"
options="--name a" start a
options="--name b" start b
deployed=$(ask a deploy --name whatsapp --files-from "$folder/whatsapp" || true)
echo "$deployed" | head -c 600 && echo
[[ $deployed == *"\"version\""* ]]

say "The owner's key is made on their phone, which chooses both servers to open their Vault"
mkdir -p "$folder/phone"
printf '[%s,%s]' "$(sed -e 's/^\[//' -e 's/\]$//' "$folder/only-a/servers")" "$(sed -e 's/^\[//' -e 's/\]$//' "$folder/only-b/servers")" >"$folder/phone/servers"
phone() { ONE_HOME=$folder/phone "$one" "$@" 2>&1 | sed -e "s/${key[a]}/a/g" -e "s/${key[b]}/b/g"; }
phone encryption approve | head -c 200 && echo
phone vault grant --servers "[\"${key[a]}\",\"${key[b]}\"]"

say "WhatsApp's service on both: each builds the link's program with Go"
ask a whatsapp devices || true
ask a install_service --plugin whatsapp --service WhatsApp.Link --server "${key[a]}" >/dev/null
ask a install_service --plugin whatsapp --service WhatsApp.Link --server "${key[b]}" >/dev/null
ask a whatsapp devices
ask a whatsapp accounts

say "Linking a phone on a: a QR code to scan, and the code to type for a number"
ask a whatsapp sign_in --device a --phone "+61 400 000 001"
ask a whatsapp pairing --device a | cut -c1-120
echo "the phone scans it:"
after a "WhatsApp: linked +61400000001" kill -USR1 "$(link a)"
ask a whatsapp accounts
ask a whatsapp status
phone vault list | grep -o '"name":"WhatsApp[^"]*"'

say "Its chats arrived, as history, and are listed, read and searched"
ask a whatsapp chats
ask a whatsapp chats --unread true
ask b whatsapp read --chat kim
ask b whatsapp read --chat Family
ask b whatsapp search --query lunch
ask b whatsapp search --query lunch --chat "+61 400 000 003"
ask b whatsapp read --chat Lee || true

say "A message arrives"
after a "a message arrived from Kim" kill -USR2 "$(link a)"
ask a whatsapp accounts >/dev/null
ask b whatsapp chats --limit 1

say "Sending, to the fake: to a chat, to a number with no chat, and refused when it's unclear who"
after a "fake WhatsApp: sent to 61400000002@s.whatsapp.net: See you at 12:30" ask b whatsapp send --chat Kim --text "See you at 12:30"
after a "fake WhatsApp: sent to 61400000009@s.whatsapp.net: Hi, it's Sam" ask b whatsapp send --chat "+61 400 000 009" --text "Hi, it's Sam"
ask b whatsapp send --chat Lee --text "never sent" || true
ask b whatsapp send --chat "0400 000 001" --text "never sent" || true
grep -o "fake WhatsApp: sent to .*" "$folder/a.log"
ask b whatsapp read --chat Kim --limit 2

say "The link carries on from its session after its server restarts"
stop a
after a "fake WhatsApp: connected as +61400000001" eval 'options="--name a" start a'
ask a whatsapp status
after a "fake WhatsApp: sent to 61400000002@s.whatsapp.net: Back again" ask a whatsapp send --chat Kim --text "Back again"

say "With a down, b takes the link over, from the same session, and a doesn't start it again when it's back"
stop a
after b "fake WhatsApp: connected as +61400000001" ask b whatsapp move --to b
ask b whatsapp accounts
after b "fake WhatsApp: sent to 61400000002@s.whatsapp.net: From b now" ask b whatsapp send --chat Kim --text "From b now"
back=$(wc -l <"$folder/a.log")
options="--name a" start a
ask a whatsapp status
echo "times a connected the link since it came back: $(tail -n +$((back + 1)) "$folder/a.log" | grep -c "connected as" || true)"
ask b whatsapp read --chat Kim --limit 3

if [[ -n ${SHOTS:-} ]]; then
  say "Pictures of its screen, on a phone and a desktop, light and dark, into $SHOTS"
  cat >"$folder/steps.js" <<'EOF'
export default async ({ app, shot }) => {
  const frame = await app("WhatsApp")
  await frame.locator(".ui-row").first().waitFor({ timeout: 15000 })
  await shot("whatsapp")
  await frame.getByRole("button", { name: "Link Account" }).click()
  await frame.locator("img.qr").waitFor({ timeout: 15000 })
  await shot("whatsapp-linking")
}
EOF
  mkdir -p "$SHOTS"
  (cd "$ONE_APP/core/edge" && ONE_HOME=$folder/only-b bun "$ONE_APP/clients/app/test/window.js" "$SHOTS" "$folder/steps.js")
fi

say "The session is never on a disk or in the bucket unencrypted"
python3 -I - "$folder" <<'EOF'
import gzip, os, sqlite3, sys
sessions, databases, gz = [], [], []
for here, _, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(here, name)
        with open(path, "rb") as f:
            head = f.read(16)
        if "sessions" in path and "whatsapp" in path:
            sessions.append((path, os.path.getsize(path), head))
        if head.startswith(b"SQLite format 3"):
            try:
                tables = {t for (t,) in sqlite3.connect(f"file:{path}?mode=ro", uri=True).execute("select name from sqlite_master")}
            except sqlite3.Error:
                continue
            databases.append((path, any(t.startswith("whatsmeow_") for t in tables)))
        if head.startswith(b"\x1f\x8b"):
            gz.append(path)
print(f"  SQLite databases on disk: {len(databases)}, of which hold whatsmeow's tables: {sum(1 for _, w in databases if w)}")
print(f"  gzip files: {len(gz)}")
for path, size, head in sessions:
    print(f"  the bucket's {path.split('/users/')[-1]}: {size} bytes, neither SQLite nor gzip: {not head.startswith(b'SQLite') and not head.startswith(bytes([0x1f, 0x8b]))}")
assert not any(w for _, w in databases) and not gz and sessions
EOF

say "Signing out unlinks it from the phone, and deletes what was kept for it"
after b "fake WhatsApp: unlinked +61400000001" ask b whatsapp sign_out
ask a whatsapp accounts
ask a whatsapp chats || true
phone vault list | grep -c '"name":"WhatsApp' || true
echo "session blobs left in the bucket: $(find "$bucket" -path "*whatsapp/sessions/*" -type f | wc -l)"
echo
echo "WhatsApp is proven."
