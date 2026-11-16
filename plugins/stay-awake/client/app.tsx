// Each Mac with Stay Awake, and a switch for it: on, it stays awake while it's plugged in, even with its lid shut.
import { createMemo, Errored, For, Loading, refresh, Show } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, Empty, leave, List, Problem, Row, Screen, Skeleton, Switch, toast } from "ui"

/** A Mac with Stay Awake, as `stay-awake_macs` answers it. */
interface Mac {
  name: string
  on?: boolean
  plugged_in?: boolean
  problem?: string
  seen?: number
}

const ago = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
/// How long ago `at` was, in the largest unit that's whole: "Seen 2 minutes ago".
function seen(at: number) {
  const minutes = Math.round((at - Date.now()) / 60_000)
  if (minutes > -60) return `Seen ${ago.format(Math.min(minutes, -1), "minute")}`
  if (minutes > -48 * 60) return `Seen ${ago.format(Math.round(minutes / 60), "hour")}`
  return `Seen ${ago.format(Math.round(minutes / (24 * 60)), "day")}`
}

/// A Mac's grey line. One that's off says when it was last seen, and one never seen says nothing.
function says(mac: Mac) {
  if (mac.problem) return mac.seen ? seen(mac.seen) : undefined
  if (!mac.on) return "Sleeps as usual"
  return mac.plugged_in ? "Awake while plugged in" : "On battery, so it sleeps as usual"
}

function Macs(props: { macs: Mac[]; again: () => void }) {
  const set = async (mac: Mac, on: boolean) => {
    try {
      await call("stay-awake_set", { device: mac.name, on })
    } catch (error) {
      toast((error as Error).message)
    }
    props.again()
  }
  return (
    <Show when={props.macs.length} fallback={<Empty>No Mac has Stay Awake yet</Empty>}>
      <List>
        <For each={props.macs} keyed={(mac) => mac.name}>
          {(mac) => (
            <Row
              heading={mac().name}
              text={says(mac())}
              end={
                <Switch
                  aria-label={`Keep ${mac().name} awake`}
                  checked={!mac().problem && mac().on}
                  disabled={!!mac().problem}
                  onChange={(event) => set(mac(), event.currentTarget.checked)}
                />
              }
            />
          )}
        </For>
      </List>
    </Show>
  )
}

function App() {
  const macs = createMemo(() => call("stay-awake_macs").then((text): Mac[] => JSON.parse(text)))
  changed(() => refresh(macs))
  return (
    <Screen heading="Stay Awake" back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't reach your Macs" text={(error() as Error).message} action={<Button variant="outline" onClick={reset}>Try again</Button>} />}>
        <Loading fallback={<Skeleton rows={2} />}>
          <Macs macs={macs()} again={() => refresh(macs)} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />, document.body)
