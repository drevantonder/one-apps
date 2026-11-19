// Device Activity: each device with its memory, CPU, GPU and disk, and the containers it hosts below. The devices
// fill the room: more columns where there's more of it. Asked again every 5 seconds while it can be seen.
import { createMemo, Errored, For, Loading, onCleanup, refresh, Show } from "solid-js"
import { Button, call, changed, type Element, Empty, List, Problem, render, Row, Screen, Skeleton, styles, Text, tokens, View, visible } from "ui"
import { sizes } from "./sizes.ts"

const look = styles({
  // The devices fill the room: one column on a phone, more where there's more of it.
  devices: { display: "grid", gridTemplateColumns: { fill: sizes.device }, gap: tokens.grid[4], alignItems: "flex-start" },
  device: { gap: tokens.grid[2], minWidth: 0 },
  title: { flexDirection: "row", alignItems: "baseline", justifyContent: "space-between", gap: tokens.grid[2] },
  name: { flexShrink: 1, font: tokens.type.large, fontWeight: tokens.weight.semibold, lineClamp: 1 },
  quiet: { font: tokens.type.small, color: tokens.colour.secondaryLabel },
  // Its stats two across where there's room.
  stats: { display: "grid", gridTemplateColumns: { fill: sizes.stat }, gap: tokens.grid[2] },
  stat: { gap: tokens.grid[1.5] },
  figures: { flexDirection: "row", justifyContent: "space-between", gap: tokens.grid[2] },
  figure: { font: tokens.type.small },
  bar: { height: tokens.grid[1.5], borderRadius: tokens.radius.full, backgroundColor: tokens.colour.quinaryLabel, overflow: "hidden" },
  filled: (width: `${number}%`) => ({ width, height: "100%", borderRadius: tokens.radius.full, backgroundColor: tokens.colour.secondaryLabel }),
  // Nearly full, which needs someone.
  full: { backgroundColor: tokens.colour.orange },
  spark: { flexDirection: "row", alignItems: "flex-end", gap: tokens.length.hairline, height: tokens.grid[6] },
  sparkBar: (height: `${number}%`) => ({ flexGrow: 1, flexBasis: 0, height, minHeight: tokens.length.hairline, backgroundColor: tokens.colour.secondaryLabel }),
})

/** Space in bytes: how much is used of how much. */
interface Space {
  used: number
  total: number
}

/** A device, as `server-load_now` answers it: its memory, CPU and GPU every 5 seconds, disk and containers. */
interface Device {
  server: string
  name: string
  os: string
  problem?: string
  seen?: number
  memory?: Space
  cpu: number[]
  gpu: number[]
  disk?: Space
  containers: { name: string; kind?: string; memory?: Space }[]
}

const GB = 1e9
const GiB = 2 ** 30
// Bytes as GB: memory counts them in 2^30s, as macOS and Activity Monitor do, disks in 10^9s.
const size = (b: number, g = GB) => (b >= 10 * g ? `${Math.round(b / g)} GB` : b >= g ? `${(b / g).toFixed(1)} GB` : `${Math.round(b / (g / 1000))} MB`)
const share = (space?: Space) => (space?.total ? space.used / space.total : null)
const OS: Record<string, string> = { linux: "Linux", macos: "macOS" }
const ago = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
/// How long ago `at` was, in the largest unit that's whole: "Seen 2 minutes ago".
function seen(at: number) {
  const minutes = Math.round((at - Date.now()) / 60_000)
  if (minutes > -60) return `Seen ${ago.format(Math.min(minutes, -1), "minute")}`
  if (minutes > -48 * 60) return `Seen ${ago.format(Math.round(minutes / 60), "hour")}`
  return `Seen ${ago.format(Math.round(minutes / (24 * 60)), "day")}`
}

/// A bar of how full something is: grey, and the warning colour once it's nearly full.
function Bar(props: { share: number; label: string }) {
  return (
    <View role="progressbar" aria-valuenow={Math.round(props.share * 100)} aria-valuemin={0} aria-valuemax={100} aria-label={props.label} style={look.bar}>
      <View style={[look.filled(`${props.share * 100}%`), props.share >= 0.85 && look.full]} />
    </View>
  )
}

/// How busy something was every 5 seconds over two minutes, oldest first, a bar to each.
function Spark(props: { values: number[]; label: string }) {
  return (
    <View role="img" aria-label={props.label} style={look.spark}>
      <For each={props.values}>{(value) => <View style={look.sparkBar(`${Math.min(100, value)}%`)} />}</For>
    </View>
  )
}

function Stat(props: { label: string; value: string; children?: Element }) {
  return (
    <View style={look.stat}>
      <View style={look.figures}>
        <Text style={look.quiet}>{props.label}</Text>
        <Text style={look.figure}>{props.value}</Text>
      </View>
      {props.children}
    </View>
  )
}

function DeviceView(props: { device: Device }) {
  const d = () => props.device
  return (
    <View role="region" aria-label={d().name} style={look.device}>
      <View style={look.title}>
        <Text role="heading" aria-level={2} style={look.name}>
          {d().name}
        </Text>
        <Show when={!d().problem} fallback={<Show when={d().seen}>{(at) => <Text style={look.quiet}>{seen(at())}</Text>}</Show>}>
          <Text style={look.quiet}>Online · {OS[d().os] ?? d().os}</Text>
        </Show>
      </View>
      <Show when={!d().problem}>
        <View style={look.stats}>
          <Show when={d().memory}>
            {(memory) => (
              <Stat label="Memory" value={`${size(memory().used, GiB)} of ${size(memory().total, GiB)}`}>
                <Bar share={share(memory())!} label="Memory" />
              </Stat>
            )}
          </Show>
          <Show when={d().cpu.length}>
            <Stat label="CPU" value={`${d().cpu.at(-1)}%`}>
              <Spark values={d().cpu} label="CPU over two minutes" />
            </Stat>
          </Show>
          <Show when={d().gpu.length}>
            <Stat label="GPU" value={`${d().gpu.at(-1)}%`}>
              <Spark values={d().gpu} label="GPU over two minutes" />
            </Stat>
          </Show>
          <Show when={d().disk}>
            {(disk) => (
              <Stat label="Disk" value={`${size(disk().total - disk().used)} free`}>
                <Bar share={share(disk())!} label="Disk" />
              </Stat>
            )}
          </Show>
        </View>
        <Show when={d().containers.length}>
          <List>
            <For each={d().containers} keyed={(c) => c.name}>
              {(c) => <Row heading={c().name} text={c().kind === "podman" ? "Podman" : "Container"} end={c().memory ? size(c().memory!.used, GiB) : undefined} />}
            </For>
          </List>
        </Show>
      </Show>
    </View>
  )
}

function App() {
  const devices = createMemo(() => call("server-load_now").then((text): Device[] => JSON.parse(text).devices))
  changed(() => refresh(devices))
  // Asked again every 5 seconds while it can be seen.
  const every = setInterval(() => visible() && refresh(devices), 5000)
  onCleanup(() => clearInterval(every))
  return (
    <Screen heading="Device Activity">
      <Errored fallback={(error, reset) => <Problem heading="Couldn't measure your devices" text={error() as Error} action={<Button variant="outline" onPress={reset}>Try Again</Button>} />}>
        <Loading fallback={<Skeleton rows={3} />}>
          <Show when={devices().length} fallback={<Empty>No device is measured yet</Empty>}>
            <View style={look.devices}>
              <For each={devices()} keyed={(d) => d.server}>
                {(d) => <DeviceView device={d()} />}
              </For>
            </View>
          </Show>
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />)
