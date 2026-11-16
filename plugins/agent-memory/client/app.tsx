// What agents remember, as they read it when they wake: recent memories word for word, older ones as summaries,
// oldest first. A summary opens into its two halves, down to the memories themselves. People read; only agents write.
import { createEffect, createMemo, createSignal, Errored, For, Loading, refresh, Show } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, Empty, Icon, leave, Problem, Screen, Skeleton } from "ui"
import "./app.css"

/// A tool of this plugin's, answered as the screen reads it.
/** A line of memory: one memory (`lo` to `hi` one apart), or a summary of several, and its day. */
interface Memory {
  lo: number
  hi: number
  date?: string
  text: string | null
}

const ask = <T,>(tool: string, inputs = {}): Promise<T> => call(`agent-memory_${tool}`, { ...inputs, format: "json" }).then(JSON.parse)

const single = (line: Memory) => line.hi - line.lo === 1
const name = (line: Memory) => (single(line) ? `#${line.lo}` : `#${line.lo}–${line.hi - 1}`)
const day = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" })

/// One line: a memory, or a summary that opens into its halves.
function Line(props: { line: Memory }) {
  const [halves, setHalves] = createSignal<Memory[]>()
  const toggle = async () => setHalves(halves() ? undefined : await ask<Memory[]>("zoom", { block: `${props.line.lo}-${props.line.hi - 1}` }).catch(() => undefined))
  const words = () => (
    <span class="words">
      <span class="about">
        {name(props.line)}
        {props.line.date && ` · ${day.format(new Date(`${props.line.date}T00:00:00`))}`}
        {!single(props.line) && ` · ${props.line.hi - props.line.lo} memories`}
      </span>
      <span class={{ text: true, unwritten: props.line.text === null }}>{props.line.text ?? "Not summarised yet"}</span>
    </span>
  )
  return (
    <div class="line">
      <Show when={!single(props.line)} fallback={words()}>
        <button type="button" class="open press ring" aria-expanded={halves() ? "true" : "false"} onClick={toggle}>
          <Icon name="caret-right" along />
          {words()}
        </button>
      </Show>
      <Show when={halves()}>{(halves) => <div class="halves"><Lines lines={halves()} /></div>}</Show>
    </div>
  )
}

function Lines(props: { lines: Memory[] }) {
  return <For each={props.lines} keyed={(line) => `${line.lo}-${line.hi}`}>{(line) => <Line line={line()} />}</For>
}

/// The newest memory is at the bottom: the screen stays there as it grows, unless it's been scrolled up.
let pinned = true
addEventListener("scroll", () => (pinned = innerHeight + scrollY >= document.body.scrollHeight - 40), { passive: true })

function Remembered(props: { memory: { count: number; lines: Memory[] } }) {
  createEffect(() => props.memory.count, () => {
    if (pinned) scrollTo(0, document.body.scrollHeight)
  })
  return (
    <Show when={props.memory.lines.length} fallback={<Empty>Nothing remembered yet</Empty>}>
      <div class="lines">
        <Lines lines={props.memory.lines} />
      </div>
    </Show>
  )
}

function App() {
  const memory = createMemo(() => ask<{ count: number; lines: Memory[] }>("wake"))
  changed(() => refresh(memory))
  return (
    <Screen heading="Agent Memory" back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't load the memory" text={(error() as Error).message} action={<Button variant="outline" onClick={reset}>Try again</Button>} />}>
        <Loading fallback={<Skeleton rows={3} />}>
          <Remembered memory={memory()} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />, document.body)
