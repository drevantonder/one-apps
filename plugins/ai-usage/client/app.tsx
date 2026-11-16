// Each AI plan, metered: a provider's mark and name, then each of its accounts with a meter for each window and
// when it resets. Accounts fill the room: more columns where there's more of it.
import { createMemo, Errored, For, Loading, refresh, Show } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, Empty, leave, Problem, Screen, Skeleton } from "ui"
import claude from "./claude.svg"
import codex from "./codex.svg"
import opencodego from "./opencodego.svg"
import "./app.css"

// Each brand's own mark: a logo is inset on white, an icon is a whole tile already.
/** A window a plan is metered over: how much of it is used, when it resets, and whether the pace lasts to then. */
interface Window {
  used?: number | null
  countdown?: string
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
  stale?: string
  session?: Window
  weekly?: Window
  monthly?: Window
  models?: (Window & { name: string })[]
  extra?: { used: number; limit: number }
  alarm?: { text: string; tone?: string }
}

const marks: Record<string, { src: string; inset?: boolean }> = { claude: { src: claude, inset: true }, codex: { src: codex, inset: true }, opencodego: { src: opencodego } }

const on = (p: Plan) => (p.machines.length ? `on ${p.machines.join(", ")}` : "")

function Meter(props: { label: string; window?: Window }) {
  return (
    <Show when={props.window && props.window!.used != null}>
      <div class="meter">
        <span class="label">{props.label}</span>
        <div class={["bar", { full: props.window!.used! >= 100 || props.window!.will_last === false }]} role="meter" aria-label={props.label} aria-valuenow={props.window!.used!} aria-valuemin="0" aria-valuemax="100">
          <div style={{ width: `${Math.min(100, props.window!.used!)}%` }} />
        </div>
        <span class="used">{Math.round(props.window!.used!)}%</span>
        <span class="resets">{props.window!.countdown ? `resets ${props.window!.countdown}` : ""}</span>
      </div>
    </Show>
  )
}

function Account(props: { plan: Plan; several: boolean }) {
  const p = () => props.plan
  const [team, email] = (p().account || "").split(" · ")
  const state = () => (p().active && props.several ? "In use" : p().disabled ? "Not used" : "")
  return (
    <div class="account">
      <Show when={p().account}>
        <div>
          <div class="who">
            <span class="team">{team}</span>
            <span class="state">{state()}</span>
          </div>
          <div class="about">{[email, on(p())].filter(Boolean).join(" · ")}</div>
        </div>
      </Show>
      <Meter label="Session" window={p().session} />
      <Meter label="Weekly" window={p().weekly} />
      <Meter label="Monthly" window={p().monthly} />
      <For each={p().models} keyed={(m) => m.name}>{(m) => <Meter label={m().name} window={m()} />}</For>
      <Show when={p().extra}>
        <div class="extra">
          <span>Extra</span>
          <span>{`$${p().extra!.used} of $${p().extra!.limit}`}</span>
        </div>
      </Show>
      <Show when={p().alarm}>{(alarm) => <Problem warn={alarm().tone === "warn"} heading={alarm().text} />}</Show>
    </div>
  )
}

function Provider(props: { plans: Plan[] }) {
  const p = () => props.plans[0]
  const mark = () => marks[p().id]
  const sub = () => [p().plan, p().account ? "" : on(p()), `updated ${p().updated_ago}`].filter(Boolean).join(" · ")
  const stale = () => [...new Set(props.plans.map((r) => r.stale).filter(Boolean))]
  return (
    <section class="provider">
      <div class="heading">
        <img class={["mark", { inset: mark().inset }]} src={mark().src} alt="" />
        <div class="words">
          <h2>{p().title}</h2>
          <span class="about">{sub()}</span>
        </div>
      </div>
      <div class="accounts">
        <For each={props.plans} keyed={(r) => r.account || r.id}>{(r) => <Account plan={r()} several={props.plans.length > 1} />}</For>
      </div>
      <Show when={stale().length}>
        <Problem warn heading={`Can't read ${p().title} now`} text={stale().join("; ")} />
      </Show>
    </section>
  )
}

function Plans(props: { usage: { providers: Plan[]; problem?: string } }) {
  const ids = () => [...new Set(props.usage.providers.map((p) => p.id))]
  return (
    <Show when={!props.usage.problem} fallback={<Problem heading="Can't read your AI plans" text={props.usage.problem} />}>
      <Show when={props.usage.providers.length} fallback={<Empty>No AI sign-ins on your devices</Empty>}>
        <div class="providers">
          <For each={ids()}>{(id) => <Provider plans={props.usage.providers.filter((p) => p.id === id)} />}</For>
        </div>
      </Show>
    </Show>
  )
}

function App() {
  const usage = createMemo(() => call("ai-usage_status", { format: "json" }).then(JSON.parse))
  changed(() => refresh(usage))
  return (
    <Screen heading="AI Usage" back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't read your AI plans" text={(error() as Error).message} action={<Button variant="outline" onClick={reset}>Try again</Button>} />}>
        <Loading fallback={<Skeleton rows={4} />}>
          <Plans usage={usage()} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />, document.body)
