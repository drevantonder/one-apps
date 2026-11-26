// What agents remember, as they read it when they wake: recent memories word for word, older ones as summaries,
// newest first, so the latest is in sight. A summary opens into its two halves, down to the memories themselves.
// People read; only agents write.
import { createProjection, createSignal, Errored, For, Loading, refresh, Show } from "solid-js"
import { Button, call, changed, Empty, Icon, Pressable, Problem, render, Screen, Spinner, styles, Text, tokens, toolInput, View } from "ui"

const look = styles({
  lines: { gap: tokens.grid[4], maxWidth: tokens.length.readable },
  halves: { gap: tokens.grid[4], paddingStart: tokens.grid[4] },
  line: { gap: tokens.grid[4] },
  open: { flexDirection: "row", alignItems: "flex-start", gap: tokens.grid[2], borderRadius: tokens.radius.small },
  caret: { marginTop: tokens.grid[0.5], color: tokens.colour.secondaryLabel, rotate: 0, transitionProperty: ["rotate"], transition: tokens.motion.quick },
  turned: { rotate: 90 },
  words: { flexShrink: 1, gap: tokens.grid[0.5], minWidth: 0 },
  about: { font: tokens.type.small, color: tokens.colour.secondaryLabel },
  unwritten: { color: tokens.colour.secondaryLabel },
})

/** A line of memory: one memory (`lo` to `hi` one apart), or a summary of several, and its day. */
interface Memory {
  lo: number
  hi: number
  date?: string
  text: string | null
}

const ask = <T,>(tool: string, inputs = {}): Promise<T> => call(`agent-memory_${tool}`, inputs).then(JSON.parse)

const single = (line: Memory) => line.hi - line.lo === 1
const name = (line: Memory) => (single(line) ? `#${line.lo}` : `#${line.lo}–${line.hi - 1}`)
const day = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" })

/// One line: a memory, or a summary that opens into its halves.
function Line(props: { line: Memory }) {
  const [halves, setHalves] = createSignal<Memory[]>()
  const toggle = async () => setHalves(halves() ? undefined : (await ask<{ halves: Memory[] }>("zoom", { block: `${props.line.lo}-${props.line.hi - 1}` })).halves)
  const words = () => (
    <View style={look.words}>
      <Text style={look.about}>
        {name(props.line)}
        {props.line.date && ` · ${day.format(new Date(`${props.line.date}T00:00:00`))}`}
        {!single(props.line) && ` · ${props.line.hi - props.line.lo} memories`}
      </Text>
      <Text style={props.line.text === null && look.unwritten}>{props.line.text ?? "Not summarised yet"}</Text>
    </View>
  )
  return (
    <View style={look.line}>
      <Show when={!single(props.line)} fallback={words()}>
        <Pressable role="button" aria-expanded={halves() ? "true" : "false"} onPress={toggle} style={look.open}>
          <View style={[look.caret, !!halves() && look.turned]}>
            <Icon name="caret-right" along />
          </View>
          {words()}
        </Pressable>
      </Show>
      <Show when={halves()}>
        {(halves) => (
          <View style={look.halves}>
            <Lines lines={halves()} />
          </View>
        )}
      </Show>
    </View>
  )
}

function Lines(props: { lines: Memory[] }) {
  return <For each={props.lines} keyed={(line) => `${line.lo}-${line.hi}`}>{(line) => <Line line={line()} />}</For>
}

function App() {
  // Its one screen is `wake`'s, whichever part an assistant read: every memory, as the screen shows it.
  const memory = createProjection(() => (toolInput("agent-memory_wake"), ask<{ count: number; memory: Memory[] }>("wake", { format: "json" })))
  changed(() => refresh(memory))
  return (
    <Screen heading="Agent Memory">
      <Errored fallback={(error, reset) => <Problem heading="Couldn't load the memory" text={error() as Error} action={<Button variant="outline" onPress={reset}>Try Again</Button>} />}>
        <Loading fallback={<Spinner delay />}>
          <Show when={memory.memory.length} fallback={<Empty>Nothing remembered yet</Empty>}>
            <View style={look.lines}>
              <Lines lines={[...memory.memory].reverse()} />
            </View>
          </Show>
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />)
