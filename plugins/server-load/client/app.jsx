// Device Activity: each device with its memory, CPU, GPU and disk, and the containers it hosts below. The devices
// fill the room: more columns where there's more of it. Asked again every 5 seconds while it can be seen.
import { createMemo, Errored, For, Loading, onSettled, refresh, Show } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, Empty, leave, List, Problem, Row, Screen, Skeleton } from "ui"
import "./app.css"

const GB = 1e9
const GiB = 2 ** 30
// Bytes as GB: memory counts them in 2^30s, as macOS and Activity Monitor do, disks in 10^9s.
const size = (b, g = GB) => (b >= 10 * g ? `${Math.round(b / g)} GB` : b >= g ? `${(b / g).toFixed(1)} GB` : `${Math.round(b / (g / 1000))} MB`)
const share = (space) => (space?.total ? space.used / space.total : null)
const OS = { linux: "Linux", macos: "macOS" }
const ago = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
/// How long ago `at` was, in the largest unit that's whole: "Seen 2 minutes ago".
function seen(at) {
  const minutes = Math.round((at - Date.now()) / 60_000)
  if (minutes > -60) return `Seen ${ago.format(Math.min(minutes, -1), "minute")}`
  if (minutes > -48 * 60) return `Seen ${ago.format(Math.round(minutes / 60), "hour")}`
  return `Seen ${ago.format(Math.round(minutes / (24 * 60)), "day")}`
}

/// A bar of how full something is: grey, and the warning colour once it's nearly full, which needs someone.
function Bar(props) {
  return (
    <div class={["bar", { full: props.share >= 0.85 }]} role="meter" aria-valuenow={Math.round(props.share * 100)} aria-valuemin="0" aria-valuemax="100" aria-label={props.label}>
      <div style={{ "inline-size": `${props.share * 100}%` }} />
    </div>
  )
}

/// How busy something was every 5 seconds over two minutes, oldest first, as a line.
function Line(props) {
  const points = () => props.values.map((value, i) => `${(i * 100) / Math.max(props.values.length - 1, 1)},${100 - value}`).join(" ")
  return (
    <svg class="line" viewBox="0 0 100 100" preserveAspectRatio="none" role="img" aria-label={props.label}>
      <polyline points={points()} vector-effect="non-scaling-stroke" />
    </svg>
  )
}

function Stat(props) {
  return (
    <div class="stat">
      <div class="figures">
        <span class="label">{props.label}</span>
        <span>{props.value}</span>
      </div>
      {props.children}
    </div>
  )
}

function Device(props) {
  const d = () => props.device
  return (
    <section class="device">
      <div class="title">
        <h2>{d().name}</h2>
        <Show when={!d().problem} fallback={<Show when={d().seen}><span class="about">{seen(d().seen)}</span></Show>}>
          <span class="about">Online · {OS[d().os] ?? d().os}</span>
        </Show>
      </div>
      <Show when={!d().problem}>
        <div class="stats">
          <Show when={d().memory}>
            <Stat label="Memory" value={`${size(d().memory.used, GiB)} of ${size(d().memory.total, GiB)}`}>
              <Bar share={share(d().memory)} label="Memory" />
            </Stat>
          </Show>
          <Show when={d().cpu.length}>
            <Stat label="CPU" value={`${d().cpu.at(-1)}%`}>
              <Line values={d().cpu} label="CPU over two minutes" />
            </Stat>
          </Show>
          <Show when={d().gpu.length}>
            <Stat label="GPU" value={`${d().gpu.at(-1)}%`}>
              <Line values={d().gpu} label="GPU over two minutes" />
            </Stat>
          </Show>
          <Show when={d().disk}>
            <Stat label="Disk" value={`${size(d().disk.total - d().disk.used)} free`}>
              <Bar share={share(d().disk)} label="Disk" />
            </Stat>
          </Show>
        </div>
        <Show when={d().containers.length}>
          <List>
            <For each={d().containers} keyed={(c) => c.name}>
              {(c) => <Row heading={c().name} text={c().kind === "podman" ? "Podman" : "Container"} end={c().memory ? size(c().memory.used, GiB) : undefined} />}
            </For>
          </List>
        </Show>
      </Show>
    </section>
  )
}

function App() {
  const devices = createMemo(() => call("server-load_now", { format: "json" }).then(JSON.parse))
  changed(() => refresh(devices))
  onSettled(() => {
    const again = () => document.visibilityState === "visible" && refresh(devices)
    const every = setInterval(again, 5000)
    document.addEventListener("visibilitychange", again)
    return () => (clearInterval(every), document.removeEventListener("visibilitychange", again))
  })
  return (
    <Screen heading="Device Activity" back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't measure your devices" text={error().message} action={<Button variant="outline" onClick={reset}>Try again</Button>} />}>
        <Loading fallback={<Skeleton rows={3} />}>
          <Show when={devices().length} fallback={<Empty>No device is measured yet</Empty>}>
            <div class="devices">
              <For each={devices()} keyed={(d) => d.server}>
                {(d) => <Device device={d()} />}
              </For>
            </div>
          </Show>
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />, document.body)
