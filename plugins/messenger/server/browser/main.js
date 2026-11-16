// Messenger's browser: reads and sends Messenger in messenger.com, for its plugin's service (`Messenger.Browser`),
// which started this program and speaks to it in lines of JSON. Messenger has no API for personal accounts, and
// its chats are end-to-end encrypted, so its own site in a browser is the way in.
//
// Each line in is a command, `{"id": 1, "do": "chats", "account": "Personal", ...}`, answered by a line with the
// same id and `ok` or `error`. An account's browser is a context of its own, opened from its session, `state`:
// Playwright's storage state, its cookies, local storage and IndexedDB, where Messenger keeps the keys to its
// encrypted chats. Nothing of it is written to disk. A context left alone for 5 minutes closes, and its session,
// as it is then, goes out as the event `session` for the service to keep encrypted. Signing in opens a window the
// person signs in in, and its session goes out once the chat list shows. It ends when its input closes.
import { chromium } from "playwright-core"

const HOME = "https://www.messenger.com/"
const IDLE = 5 * 60_000
const MENU = "More options for "

const emit = (line) => process.stdout.write(JSON.stringify(line) + "\n")
const sleep = (ms) => new Promise((done) => setTimeout(done, ms))

/// What's the caller's to change, or the person's to do: nothing broke.
class Refusal extends Error {}
class SignedOut extends Error {
  code = "signed_out"
  constructor() {
    super("Messenger isn't signed in on this account: messenger_sign_in signs it in again")
  }
}

// The browser, shared by every account's context, started when first needed: Playwright's Chromium, or else the
// machine's Chrome.
let browser
async function launch(headless) {
  try {
    return await chromium.launch({ headless })
  } catch {
    return await chromium.launch({ headless, channel: "chrome" })
  }
}

/// Each account's open context and page, and when it was last used.
const open = new Map()

async function page(account, state) {
  let held = open.get(account)
  if (!held) {
    if (!state) throw Object.assign(new Error("no session"), { code: "no_session" })
    browser ??= await launch(true)
    const context = await browser.newContext({ storageState: JSON.parse(state), viewport: { width: 1280, height: 900 } })
    held = { context, page: await context.newPage(), dirty: true }
    open.set(account, held)
  }
  held.used = Date.now()
  return held
}

async function close(account) {
  const held = open.get(account)
  if (!held) return
  open.delete(account)
  const state = await held.context.storageState({ indexedDB: true })
  await held.context.close()
  emit({ event: "session", account, data: JSON.stringify(state) })
}

setInterval(() => {
  for (const [account, held] of open) if (Date.now() - held.used > IDLE) close(account).catch(() => {})
}, 30_000)

// What the page shows, read from its DOM by the roles and names Messenger gives its parts, which is what a screen
// reader reads: the chat list's rows each have a "More options for <name>" button; a conversation's messages are
// "Enter, Message sent <time> by <sender>: <text>"; the search box is "Search Messenger".
const reads = {
  signedOut: () =>
    !!document.querySelector('input[type="password"], [name="pass"]') || location.pathname.startsWith("/login"),
  chats: (MENU) =>
    [...document.querySelectorAll('[role="row"]')].flatMap((row, index) => {
      const menu = row.querySelector(`[aria-label^="${MENU}"]`)
      if (!menu) return []
      const name = menu.getAttribute("aria-label").slice(MENU.length)
      const abbr = row.querySelector("abbr")
      const time = abbr ? abbr.getAttribute("aria-label") || abbr.textContent.trim() : ""
      const texts = []
      const walk = document.createTreeWalker(row, NodeFilter.SHOW_TEXT)
      while (walk.nextNode()) {
        const text = walk.currentNode.textContent.trim()
        if (text && !walk.currentNode.parentElement.closest("abbr, [aria-hidden='true']")) texts.push(text)
      }
      const unread = texts.includes("Unread message:")
      const shown = texts.filter((t) => t !== "Unread message:" && t !== "Active now" && !/^Active \d.* ago$/.test(t) && t !== "·")
      const last = shown[0] === name ? shown.slice(1) : shown
      return [{ name, time, unread, last: last.join(" "), index }]
    }),
  messages: () =>
    [...document.querySelectorAll('[aria-label^="Enter, Message sent "]')].map((m) => m.getAttribute("aria-label")),
  matches: (MENU) =>
    [...document.querySelectorAll('[role="row"]')].flatMap((row) => {
      if (row.querySelector(`[aria-label^="${MENU}"]`)) return []
      const texts = [...row.querySelectorAll("span, div")].filter((e) => !e.children.length).map((e) => e.textContent.trim()).filter(Boolean)
      if (!texts.length) return []
      const abbr = row.querySelector("abbr")
      return [{ chat: texts[0], rest: texts.slice(1).filter((t) => t !== abbr?.textContent.trim()).join(" "), time: abbr ? abbr.getAttribute("aria-label") || abbr.textContent.trim() : "" }]
    }),
}

/// A message's label: `Enter, Message sent <time> by <sender>[: <text>]`, its time the shortest that fits.
function message(label) {
  const rest = label.slice("Enter, Message sent ".length)
  for (let i = rest.indexOf(" by "); i >= 0; i = rest.indexOf(" by ", i + 1)) {
    if (i === 0) continue
    const after = rest.slice(i + 4)
    const k = after.indexOf(":")
    if (k < 0 && after) return { time: rest.slice(0, i), sender: after, text: "(attachment)" }
    if (k > 0 && after.slice(k).startsWith(": ")) return { time: rest.slice(0, i), sender: after.slice(0, k), text: after.slice(k + 2).trim() || "(attachment)" }
  }
  return null
}

function pick(chats, want) {
  const w = want.trim().toLowerCase()
  const exact = chats.find((c) => c.name.toLowerCase() === w)
  if (exact) return exact
  const partial = chats.filter((c) => c.name.toLowerCase().includes(w))
  if (partial.length === 1) return partial[0]
  const names = (cs) => cs.map((c) => c.name).join("; ")
  if (!partial.length) return null
  throw new Refusal(`${JSON.stringify(want)} matches several chats: ${names(partial)}. Give more of the name`)
}

/// Waits for what `read` reads to be there, as a page loads: what it read, once it's anything, or the last read.
async function until(page, read, arg, tries = 40) {
  let got
  for (let n = 0; n < tries; n++) {
    if (await page.evaluate(reads.signedOut)) throw new SignedOut()
    got = await page.evaluate(read, arg)
    if (got.length) return got
    await sleep(250)
  }
  return got
}

/// The chat list, loading it unless it's showing.
async function list(held) {
  const { page } = held
  if (held.dirty || !page.url().startsWith(HOME) || new URL(page.url()).pathname !== "/") {
    await page.goto(HOME)
    held.dirty = false
  }
  const chats = await until(page, reads.chats, MENU)
  if (!chats.length) throw new Error("Messenger's chat list didn't show")
  return chats
}

async function openChat(held, chats, c) {
  held.dirty = true
  await held.page.locator('[role="row"]').nth(c.index).getByRole("link").first().click()
}

const commands = {
  async chats({ account, state, unread }) {
    const held = await page(account, state)
    const chats = (await list(held)).filter((c) => !unread || c.unread)
    return { chats: chats.map((c) => ({ chat: c.name, unread: c.unread, time: c.time, last: c.last })) }
  },

  async read({ account, state, chat }) {
    if (!chat?.trim()) throw new Refusal("which chat?")
    const held = await page(account, state)
    const chats = await list(held)
    const c = pick(chats, chat)
    if (!c) throw new Refusal(`no recent chat called ${JSON.stringify(chat)}; recent chats: ${chats.map((c) => c.name).join("; ")}`)
    await openChat(held, chats, c)
    const messages = (await until(held.page, reads.messages)).map(message).filter(Boolean)
    const read = { chat: c.name, messages }
    // Opening a chat marks it read: one that was unread is marked unread again.
    if (c.unread) {
      try {
        await list(held)
        // Its menu's button shows only under a pointer, so it's pressed as an event, as a screen reader does.
        await held.page.getByRole("button", { name: MENU + c.name, exact: true }).dispatchEvent("click")
        await held.page.getByRole("menuitem", { name: "Mark as unread" }).dispatchEvent("click")
        read.unread_again = true
      } catch (error) {
        read.unread_again = false
        read.why = `Couldn't mark it unread again: ${error.message.split("\n")[0]}`
      }
      held.dirty = true
    }
    if (!messages.length) throw new Error(`no messages showed in ${c.name}${read.why ? `. ${read.why}` : ""}`)
    return read
  },

  async search({ account, state, query }) {
    if (!query?.trim()) throw new Refusal("what to search for?")
    const held = await page(account, state)
    await list(held)
    held.dirty = true
    await held.page.getByRole("combobox", { name: "Search Messenger" }).fill(query)
    await held.page.getByRole("link", { name: `Search messages for ${query}` }).click()
    const found = await until(held.page, reads.matches, MENU, 20)
    return {
      matches: found.map((m) => {
        const count = m.rest.match(/^(\d+) matched messages?$/)
        return count ? { chat: m.chat, count: Number(count[1]) } : { chat: m.chat, count: 1, time: m.time, text: m.rest }
      }),
    }
  },

  /// Sends to a recent chat, or else to the one person Messenger suggests whose name is exactly `chat`. Anything
  /// less certain is refused, so a message never goes to the wrong person.
  async send({ account, state, chat, text }) {
    if (!chat?.trim() || !text?.trim()) throw new Refusal("chat and text are required")
    const held = await page(account, state)
    const chats = await list(held)
    const c = pick(chats, chat)
    let name
    if (c) {
      await openChat(held, chats, c)
      name = c.name
    } else {
      held.dirty = true
      await held.page.getByRole("combobox", { name: "Search Messenger" }).fill(chat)
      await sleep(500)
      const people = held.page.getByRole("link", { name: chat.trim(), exact: true })
      const n = await people.count()
      if (n === 0) throw new Refusal(`no chat or person called exactly ${JSON.stringify(chat)}: messenger_chats lists recent chats; anyone else by the name Messenger shows for them`)
      if (n > 1) throw new Refusal(`several people are called ${JSON.stringify(chat)}`)
      await people.click()
      name = chat.trim()
    }
    const box = held.page.getByRole("textbox", { name: /^Write to/ }).last()
    await box.click()
    await box.pressSequentially(text)
    await box.press("Enter")
    // It's sent once the chat list says so.
    const words = (s) => s.split(/\s+/).filter(Boolean).join(" ")
    for (let n = 0; n < 20; n++) {
      held.dirty = true
      const now = pick(await list(held), name)
      if (now && words(now.last) === `You: ${words(text)}`) return { to: now.name }
      await sleep(500)
    }
    throw new Error(`typed the message to ${name}, but it didn't show as sent`)
  },

  /// A window the person signs in to Messenger in. Its session goes out once the chat list shows; the window closes.
  async sign_in({ account }) {
    const headed = await launch(false)
    const context = await headed.newContext()
    const signing = await context.newPage()
    await signing.goto(HOME)
    ;(async () => {
      const end = Date.now() + 15 * 60_000
      while (Date.now() < end) {
        await sleep(1000)
        const chats = await signing.evaluate(reads.chats, MENU).catch(() => [])
        if (chats.length) {
          const state = await context.storageState({ indexedDB: true })
          await headed.close()
          await close(account)
          emit({ event: "signed_in", account, data: JSON.stringify(state) })
          return
        }
      }
      await headed.close()
      emit({ event: "not_signed_in", account })
    })().catch((error) => emit({ event: "not_signed_in", account, why: error.message }))
    return "The window is open."
  },

  /// Closes an account's context, its session going out as it closes.
  async close({ account }) {
    await close(account)
    return "closed"
  },
}

const queues = new Map()
let lines = ""
process.stdin.setEncoding("utf8")
process.stdin.on("data", (part) => {
  lines += part
  let at
  while ((at = lines.indexOf("\n")) >= 0) {
    const command = JSON.parse(lines.slice(0, at))
    lines = lines.slice(at + 1)
    const run = commands[command.do] ?? (() => Promise.reject(new Error(`no command ${command.do}`)))
    // An account's commands run one after another: they share its page.
    const queued = (queues.get(command.account) ?? Promise.resolve()).then(() => run(command))
    queues.set(command.account, queued.catch(() => {}))
    queued.then(
      (ok) => emit({ id: command.id, ok }),
      (error) => emit({ id: command.id, error: error.message.split("\n")[0], code: error.code ?? (error instanceof Refusal ? "refused" : undefined) }),
    )
  }
})
// Its service is gone, and nothing it says now is heard.
process.stdin.on("end", async () => {
  await browser?.close()
  process.exit(0)
})
