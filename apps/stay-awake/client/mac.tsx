// Stay Awake, on a Mac's page in Settings: a switch that keeps it online with its lid shut while it's plugged in.
import { createMemo, Errored, Loading, refresh, Show } from "solid-js"
import { call, changed, List, Problem, Row, Skeleton, Switch, toast } from "ui"

/** A Mac with Stay Awake, as `stay-awake_macs` answers it. */
interface Mac {
  name: string
  server: string
  on?: boolean
  plugged_in?: boolean
  problem?: string
}

export default function StayAwake(props: { server?: string }) {
  const mac = createMemo(() => call("stay-awake_macs").then((text) => (JSON.parse(text).macs as Mac[]).find((mac) => mac.server === props.server)))
  changed(() => refresh(mac))
  const set = async (on: boolean) => {
    try {
      await call("stay-awake_set", { device: mac()!.name, on })
    } catch (error) {
      toast(error as Error)
    }
    refresh(mac)
  }
  return (
    <Errored fallback={(error) => <Problem heading="Can't ask the Mac" text={error() as Error} />}>
      <Loading fallback={<Skeleton rows={1} />}>
        <Show when={mac()}>
          {(mac) => (
            <List>
              <Row
                heading="Stay Online with the Lid Shut"
                text={mac().problem ?? (mac().on && !mac().plugged_in ? "On battery, so it sleeps as usual." : "While it's plugged in.")}
                end={<Switch aria-label="Stay Online with the Lid Shut" value={!mac().problem && !!mac().on} disabled={!!mac().problem} onValueChange={set} />}
              />
            </List>
          )}
        </Show>
      </Loading>
    </Errored>
  )
}
