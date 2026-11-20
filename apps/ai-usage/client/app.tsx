// Each AI plan, metered: a provider's mark and name, then each of its accounts with a meter for each window and
// when it resets. Accounts fill the room: more columns where there's more of it.
import { createMemo, createSignal, Errored, For, Loading, onCleanup, refresh, Show } from "solid-js"
import { Button, call, changed, Empty, Image, Problem, render, Screen, Skeleton, styles, Text, tokens, View, visible } from "ui"
import { sizes } from "./sizes.ts"
import claude from "./claude.svg?inline"
import codex from "./codex.svg?inline"
import opencodego from "./opencodego.svg?inline"

const look = styles({
  providers: { gap: tokens.grid[8] },
  provider: { gap: tokens.grid[4], minWidth: 0 },
  heading: { flexDirection: "row", alignItems: "center", gap: tokens.grid[3] },
  mark: { width: sizes.mark, height: sizes.mark, borderRadius: tokens.radius.small, flexShrink: 0 },
  // A logo is inset on white; an icon is a whole tile already.
  inset: { backgroundColor: sizes.paper, padding: tokens.grid[1], boxShadow: tokens.shadow.field },
  words: { flexShrink: 1, minWidth: 0 },
  title: { fontWeight: tokens.weight.semibold, lineClamp: 1 },
  quiet: { font: tokens.type.small, color: tokens.colour.secondaryLabel },
  oneLine: { lineClamp: 1 },
  // The accounts fill the room: one column on a phone, more where there's more of it.
  accounts: { display: "grid", gridTemplateColumns: { fill: sizes.account }, gap: tokens.grid[6], alignItems: "flex-start" },
  account: { gap: tokens.grid[2], minWidth: 0 },
  // A reading that couldn't update is shown as it was, greyed.
  outdated: { opacity: 0.5 },
  who: { flexDirection: "row", alignItems: "baseline", justifyContent: "space-between", gap: tokens.grid[2] },
  team: { flexShrink: 1, fontWeight: tokens.weight.semibold, lineClamp: 1 },
  meter: { gap: tokens.grid[0.5] },
  row: { flexDirection: "row", alignItems: "center", gap: tokens.grid[3] },
  label: { width: sizes.label, flexShrink: 0, font: tokens.type.small, color: tokens.colour.secondaryLabel, lineClamp: 1 },
  bar: { flexGrow: 1, height: tokens.grid[1.5], borderRadius: tokens.radius.full, backgroundColor: tokens.colour.quinaryLabel, overflow: "hidden" },
  filled: (width: `${number}%`) => ({ width, height: "100%", borderRadius: tokens.radius.full, backgroundColor: tokens.colour.secondaryLabel }),
  full: { backgroundColor: tokens.colour.orange },
  used: { width: sizes.used, flexShrink: 0, font: tokens.type.small, textAlign: "end" },
  under: { width: sizes.label, flexShrink: 0 },
  resets: { font: tokens.type.small, color: tokens.colour.secondaryLabel },
  extra: { flexDirection: "row", justifyContent: "space-between", gap: tokens.grid[3] },
})

/** A window a plan is metered over: how much of it is used, when it resets, and whether the pace lasts to then. */
interface Window {
  used?: number | null
  resets_at?: number | null
  will_last?: boolean
}

/** A plan of one account, as `ai-usage_status` answers it. */
interface Plan {
  id: string
  title: string
  plan?: string
  account?: string
  machines: string[]
  active?: boolean
  disabled?: boolean
  updated_ago: string
  outdated?: boolean
  note?: string
  session?: Window
  weekly?: Window
  monthly?: Window
  models?: (Window & { name: string })[]
  extra?: { used: number; limit: number }
  alarm?: { text: string; tone?: string; resets_at?: number | null }
}

// Times arrive as instants and are said here, in this device's own time zone and language, as its clock is.
const clock = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })
const weekday = new Intl.DateTimeFormat(undefined, { weekday: "short" })
const date = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" })
const [now, setNow] = createSignal(Date.now())

/// When something resets, from now: "in 45 min", "in 2h 5m", "in 5d 1h", or its date past two weeks.
function countdown(at: number) {
  const minutes = Math.max(0, Math.round((at - now()) / 60_000))
  const hours = Math.floor(minutes / 60)
  if (minutes < 1) return "now"
  if (minutes < 120) return `in ${minutes} min`
  if (hours < 48) return `in ${hours}h ${minutes % 60}m`
  if (hours < 14 * 24) return `in ${Math.floor(hours / 24)}d ${hours % 24}h`
  return `on ${date.format(at)}`
}

/// The moment something resets, as a person says it: "today at 9:19 PM", "Thu at 5:59 AM", "Dec 10 at 9:28 PM".
function when(at: number) {
  const left = at - now()
  if (left <= 0) return "now"
  if (left < 2 * 3_600_000) return countdown(at)
  if (new Date(at).toDateString() === new Date(now()).toDateString()) return `today at ${clock.format(at)}`
  if (left < 7 * 86_400_000) return `${weekday.format(at)} at ${clock.format(at)}`
  return `${date.format(at)} at ${clock.format(at)}`
}

// Each brand's own mark, as a `data:` address.
const marks: Record<string, { src: string; inset?: boolean }> = { claude: { src: claude, inset: true }, codex: { src: codex, inset: true }, opencodego: { src: opencodego } }

const on = (p: Plan) => (p.machines.length ? `on ${p.machines.join(", ")}` : "")

function Meter(props: { label: string; window?: Window }) {
  return (
    <Show when={props.window?.used != null && props.window}>
      {(window) => (
        <View style={look.meter}>
          <View style={look.row}>
            <Text style={look.label}>{props.label}</Text>
            <View role="progressbar" aria-label={props.label} aria-valuenow={window().used!} aria-valuemin={0} aria-valuemax={100} style={look.bar}>
              <View style={[look.filled(`${Math.min(100, window().used!)}%`), (window().used! >= 100 || window().will_last === false) && look.full]} />
            </View>
            <Text style={look.used}>{`${Math.round(window().used!)}%`}</Text>
          </View>
          <Show when={window().resets_at}>
            <View style={look.row}>
              <View style={look.under} />
              <Text style={look.resets}>resets {countdown(window().resets_at!)}</Text>
            </View>
          </Show>
        </View>
      )}
    </Show>
  )
}

function Account(props: { plan: Plan; several: boolean }) {
  const p = () => props.plan
  const [team, email] = (p().account || "").split(" · ")
  const state = () => (p().disabled ? "Not used" : p().active && props.several ? "In use" : "")
  // What's off about this reading: why it couldn't update, and how old the one shown is.
  const note = () => [p().note, p().outdated && `updated ${p().updated_ago}`].filter(Boolean).join(" · ")
  return (
    <View style={look.account}>
      <Show when={p().account}>
        <View>
          <View style={look.who}>
            <Text style={look.team}>{team}</Text>
            <Text style={look.quiet}>{state()}</Text>
          </View>
          <Text style={[look.quiet, look.oneLine]}>{[email, on(p())].filter(Boolean).join(" · ")}</Text>
        </View>
      </Show>
      <View style={[look.account, p().outdated && look.outdated]}>
        <Meter label="Session" window={p().session} />
        <Meter label="Weekly" window={p().weekly} />
        <Meter label="Monthly" window={p().monthly} />
        <For each={p().models} keyed={(m) => m.name}>{(m) => <Meter label={m().name} window={m()} />}</For>
        <Show when={p().extra}>
          {(extra) => (
            <View style={look.extra}>
              <Text style={look.quiet}>Extra</Text>
              <Text style={look.quiet}>{`$${extra().used} of $${extra().limit}`}</Text>
            </View>
          )}
        </Show>
      </View>
      <Show when={note()}>
        <Text style={look.quiet}>{note()}</Text>
      </Show>
      <Show when={!p().outdated && p().alarm}>{(alarm) => <Problem warn={alarm().tone === "warn"} heading={alarm().resets_at ? `${alarm().text}, resets ${when(alarm().resets_at!)}` : alarm().text} />}</Show>
    </View>
  )
}

function Provider(props: { plans: Plan[] }) {
  const p = () => props.plans[0]
  const mark = () => marks[p().id]
  const sub = () => [p().plan, p().account ? "" : on(p()), `updated ${p().updated_ago}`].filter(Boolean).join(" · ")
  return (
    <View role="region" aria-label={p().title} style={look.provider}>
      <View style={look.heading}>
        <Show when={mark()}>{(mark) => <Image src={mark().src} alt="" style={[look.mark, mark().inset && look.inset]} />}</Show>
        <View style={look.words}>
          <Text role="heading" aria-level={2} style={look.title}>
            {p().title}
          </Text>
          <Text style={[look.quiet, look.oneLine]}>{sub()}</Text>
        </View>
      </View>
      <View style={look.accounts}>
        <For each={props.plans} keyed={(r) => r.account || r.id}>{(r) => <Account plan={r()} several={props.plans.length > 1} />}</For>
      </View>
    </View>
  )
}

function Plans(props: { usage: { providers: Plan[]; problem?: string } }) {
  const ids = () => [...new Set(props.usage.providers.map((p) => p.id))]
  return (
    <Show when={!props.usage.problem} fallback={<Problem heading="Can't read your AI plans" text={props.usage.problem} />}>
      <Show when={props.usage.providers.length} fallback={<Empty>No AI sign-ins on your devices</Empty>}>
        <View style={look.providers}>
          <For each={ids()}>{(id) => <Provider plans={props.usage.providers.filter((p) => p.id === id)} />}</For>
        </View>
      </Show>
    </Show>
  )
}

function App() {
  const usage = createMemo(() => call("ai-usage_status").then(JSON.parse))
  changed(() => {
    setNow(Date.now())
    refresh(usage)
  })
  // The times are said from now, so they're said again each minute while they can be seen.
  const every = setInterval(() => visible() && setNow(Date.now()), 60_000)
  onCleanup(() => clearInterval(every))
  return (
    <Screen heading="AI Usage">
      <Errored fallback={(error, reset) => <Problem heading="Couldn't read your AI plans" text={error() as Error} action={<Button variant="outline" onPress={reset}>Try Again</Button>} />}>
        <Loading fallback={<Skeleton rows={4} />}>
          <Plans usage={usage()} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />)
