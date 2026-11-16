// A fake messenger.com, for Messenger's test: pages with the parts, roles and names the browser reads on the real
// one (a chat list whose rows have "More options for <name>", messages labelled "Enter, Message sent <time> by
// <sender>: <text>", the "Search Messenger" box, a "Write to <name>" box), a login the person finishes, and keys
// in IndexedDB that its encrypted chats need, as Messenger keeps them. A browser that has the cookie but not the
// keys is asked for its PIN, and shows no chats.
//
// POST /approve is the person finishing signing in, in the window that's waiting. What's sent is written to its
// log, which the test reads. It prints its port once it's listening.
const people = { 1: "Kim Lee", 2: "Family", 3: "Lee Park", 4: "Jo Lin" }
const chats = {
  1: { at: 3, unread: true, messages: [["11:02 AM", "Kim Lee", "Are we still on for lunch on Friday?"], ["11:10 AM", "You", "Yes, 12:30 at the usual place"], ["11:31 AM", "Kim Lee", "Great, I'll book the table for four"]] },
  2: { at: 2, unread: false, messages: [["Yesterday 6:15 PM", "Lee Park", "Who's bringing dessert on Sunday?"], ["Yesterday 6:40 PM", "You", "I'll bring the pavlova"]] },
  3: { at: 1, unread: false, messages: [["Mon 9:00 AM", "Lee Park", "The lunch booking is confirmed for twelve thirty"]] },
}
const sessions = new Set()
let waiting = null
let approved = false

const page = (title, body, script = "") => new Response(
  `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title></head><body>${body}<script>${script}</script></body></html>`,
  { headers: { "content-type": "text/html" } },
)
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;")
const signedIn = (request) => sessions.has((request.headers.get("cookie") || "").match(/session=([^;]+)/)?.[1])
const last = (id) => chats[id].messages.at(-1)
// The keys are checked before anything of a chat shows, as an encrypted chat can't be read without them.
const keys = `
  const keys = () => new Promise((done) => {
    const opened = indexedDB.open("secure", 1)
    opened.onupgradeneeded = () => opened.result.createObjectStore("keys")
    opened.onsuccess = () => {
      const got = opened.result.transaction("keys").objectStore("keys").get("chat-keys")
      got.onsuccess = () => done(got.result)
    }
  })`

function list() {
  const order = Object.keys(chats).filter((id) => chats[id].messages.length).sort((a, b) => chats[b].at - chats[a].at)
  const rows = order.map((id) => {
    const [time, who, text] = last(id)
    return `<div role="row"><a role="link" href="/t/${id}"><span>${esc(people[id])}</span>${chats[id].unread ? "<span>Unread message:</span>" : ""}<span>${esc(who === "You" ? `You: ${text}` : text)}</span><abbr aria-label="${esc(time)}">${esc(time)}</abbr></a><div role="button" aria-label="More options for ${esc(people[id])}" onclick="menu(${id})"></div></div>`
  })
  return page(
    "Messenger",
    `<input role="combobox" aria-label="Search Messenger" oninput="suggest(this.value)"><div id="suggestions"></div><main id="chats" hidden><div role="navigation" aria-label="Chats">${rows.join("")}</div></main><p id="pin" hidden>Enter your PIN to restore your chat history</p><div id="menu"></div>`,
    `${keys}
    keys().then((k) => { document.getElementById(k ? "chats" : "pin").hidden = false; if (!k) document.getElementById("chats").remove() })
    function suggest(q) {
      const names = ${JSON.stringify(Object.values(people))}.filter((n) => n.toLowerCase().includes(q.toLowerCase()))
      document.getElementById("suggestions").innerHTML = names.map((n) => '<a role="link" href="/to/' + encodeURIComponent(n) + '">' + n + '</a>').join("") +
        '<a role="link" href="/search?q=' + encodeURIComponent(q) + '">Search messages for ' + q + '</a>'
    }
    function menu(id) {
      document.getElementById("menu").innerHTML = '<div role="menu"><div role="menuitem" onclick="fetch(\\'/unread/' + id + '\\', { method: \\'POST\\' })">Mark as unread</div></div>'
    }`,
  )
}

function conversation(id) {
  chats[id].unread = false
  const said = chats[id].messages.map(([time, who, text]) => `<div role="button" aria-label="${esc(`Enter, Message sent ${time} by ${who}: ${text}`)}"><span>${esc(text)}</span></div>`)
  return page(
    people[id],
    `<a role="link" href="/">Chats</a><div id="said" hidden>${said.join("")}</div><div role="textbox" contenteditable="true" aria-label="Write to ${esc(people[id])}" onkeydown="send(event)"></div>`,
    `${keys}
    keys().then((k) => { if (k) document.getElementById("said").hidden = false })
    async function send(event) {
      if (event.key !== "Enter") return
      event.preventDefault()
      await fetch("/send/${id}", { method: "POST", body: event.target.textContent })
      event.target.textContent = ""
    }`,
  )
}

function search(q) {
  const rows = Object.keys(chats).flatMap((id) => {
    const found = chats[id].messages.filter(([, , text]) => text.toLowerCase().includes(q.toLowerCase()))
    if (!found.length) return []
    const [time, , text] = found.at(-1)
    return [`<div role="row"><span>${esc(people[id])}</span><span>${found.length > 1 ? `${found.length} matched messages` : esc(text)}</span><abbr aria-label="${esc(time)}">${esc(time)}</abbr></div>`]
  })
  return page("Search", rows.join(""))
}

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(request) {
    const url = new URL(request.url)
    const path = url.pathname
    if (path === "/approve" && request.method === "POST") {
      approved = !!waiting
      return new Response(approved ? "approved" : "nobody is signing in")
    }
    if (path === "/login/") {
      waiting = crypto.randomUUID()
      approved = false
      return page(
        "Log in to Messenger",
        `<form><input name="email" aria-label="Email"><input type="password" name="pass" aria-label="Password"><button>Log In</button></form>`,
        `${keys}
        setInterval(async () => {
          if (await (await fetch("/approved")).text() !== "yes") return
          const opened = indexedDB.open("secure", 1)
          opened.onupgradeneeded = () => opened.result.createObjectStore("keys")
          opened.onsuccess = () => {
            const put = opened.result.transaction("keys", "readwrite").objectStore("keys").put("made-up-keys", "chat-keys")
            put.onsuccess = () => (location.href = "/login/done")
          }
        }, 500)`,
      )
    }
    if (path === "/approved") return new Response(approved ? "yes" : "no")
    if (path === "/login/done" && approved) {
      const session = crypto.randomUUID()
      sessions.add(session)
      approved = false
      waiting = null
      return new Response(null, { status: 302, headers: { location: "/", "set-cookie": `session=${session}; Path=/; HttpOnly; Max-Age=31536000` } })
    }
    if (!signedIn(request)) return new Response(null, { status: 302, headers: { location: "/login/" } })
    if (path === "/") return list()
    const id = path.match(/^\/t\/(\d+)$/)?.[1]
    if (id && chats[id]) return conversation(id)
    const to = path.match(/^\/to\/(.+)$/)?.[1]
    if (to) {
      const id = Object.keys(people).find((k) => people[k] === decodeURIComponent(to))
      chats[id] ??= { at: 0, unread: false, messages: [] }
      return new Response(null, { status: 302, headers: { location: `/t/${id}` } })
    }
    if (path === "/search") return search(url.searchParams.get("q") || "")
    const sent = path.match(/^\/send\/(\d+)$/)?.[1]
    if (sent && request.method === "POST") {
      const text = await request.text()
      chats[sent].messages.push(["Just now", "You", text])
      chats[sent].at = Date.now()
      console.log(`fake Messenger: sent to ${people[sent]}: ${text}`)
      return new Response("sent")
    }
    const unread = path.match(/^\/unread\/(\d+)$/)?.[1]
    if (unread) {
      chats[unread].unread = true
      console.log(`fake Messenger: marked ${people[unread]} unread`)
      return new Response("ok")
    }
    return new Response("not here", { status: 404 })
  },
})
console.log(server.port)
