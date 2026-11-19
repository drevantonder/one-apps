// WhatsApp: each account is a phone linked to one of your devices, as WhatsApp Desktop is linked. Opened from
// Accounts, as sign_in's page, with its number after a `#`, it's that account; with none, it links one: it shows the QR code to
// scan on the phone, and the code to type there for a number.
import { createMemo, createSignal, Errored, Loading, Match, onCleanup, refresh, Show, Switch } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, confirm, createListCollection, Empty, Field, Input, leave, List, Problem, Row, Screen, Section, Select, Skeleton, Status, Steps, toast } from "ui"
import "./sign-in.css"

/** A linked account, as `whatsapp_accounts` answers it. */
interface Account {
  account: string
  device: string
  ok: boolean
  state: "connecting" | "connected" | "disconnected" | "restarting" | "unreachable" | "unlinked" | "replaced"
  why: string
}

/** Where linking a phone is, as `whatsapp_pairing` answers it (link.ex's `@pairing`): the QR code to scan and one to
 *  type for a number while it's pairing. */
interface Pairing {
  state: "none" | "starting" | "pairing" | "linked" | "ran_out" | "failed"
  qr?: string
  code?: string
  account?: string
  why?: string
}

const ask = <T,>(tool: string, inputs = {}): Promise<T> => call(`whatsapp_${tool}`, inputs).then(JSON.parse)
const plain = (error: unknown) => (error as Error).message.replace(/^./, (c) => c.toUpperCase())

/// Linking a phone, in the state it's in: its steps while it starts, the QR code to scan while it's pairing (which
/// WhatsApp renews every 20 seconds), asked again whenever the server says it changed, and Try Again once the codes
/// ran out or it failed, and Done once it's linked.
function Linking(props: { device: string; phone: string; again: () => void }) {
  const [pairing, setPairing] = createSignal<Pairing>({ state: "starting" })
  const device = { device: props.device }
  const start = () => {
    setPairing({ state: "starting" })
    call("whatsapp_sign_in", { ...device, ...(props.phone ? { phone: props.phone } : {}) }).then(
      () => ask<Pairing>("pairing", device).then(setPairing),
      (error) => setPairing({ state: "failed", why: (error as Error).message }),
    )
  }
  start()
  onCleanup(
    changed(async () => {
      if (!["starting", "pairing"].includes(pairing().state)) return
      const now = await ask<Pairing>("pairing", device).catch((): undefined => undefined)
      // While sign_in is still starting it, the last link's outcome, or none, is still what's there.
      if (!now || (pairing().state === "starting" && now.state !== "pairing" && now.state !== "linked")) return
      setPairing(now)
    }),
  )
  const tryAgain = <Button variant="outline" onClick={start}>Try Again</Button>
  return (
    <Section heading="Link a Phone">
      <Switch>
        <Match when={pairing().state === "starting"}>
          <Steps steps={["Asking WhatsApp for a code", "Scanning it on the phone"]} at={0} />
        </Match>
        <Match when={pairing().state === "pairing"}>
          <p class="how">On the phone, open WhatsApp › Settings › Linked devices › Link a device, and scan this code.</p>
          <img class="qr" src={pairing().qr} alt="The QR code to scan" />
          <Show when={pairing().code}>
            <p class="how">Or tap Link with phone number instead, and type this code:</p>
            <p class="code">{pairing().code}</p>
          </Show>
          <p class="how">Recent chats take a few minutes to arrive.</p>
        </Match>
        <Match when={pairing().state === "linked"}>
          <Empty action={<Button onClick={leave}>Done</Button>}>{pairing().account} is linked. Recent chats take a few minutes to arrive.</Empty>
        </Match>
        <Match when={pairing().state === "ran_out"}>
          <Problem warn heading="The code ran out" text="The phone didn't scan it in time." action={tryAgain} />
        </Match>
        <Match when={pairing().state === "failed"}>
          <Problem heading="Couldn't link the phone" text={pairing().why} action={tryAgain} />
        </Match>
        <Match when={pairing().state === "none"}>
          <Problem warn heading="Linking stopped" text={`WhatsApp's link on ${props.device} started again.`} action={tryAgain} />
        </Match>
      </Switch>
    </Section>
  )
}

function Link(props: { devices: string[]; again: () => void }) {
  const devices = createListCollection({ items: props.devices.map((d) => ({ value: d, label: d })) })
  const [linking, setLinking] = createSignal<{ device: string; phone: string }>()
  const start = (event: SubmitEvent & { currentTarget: HTMLFormElement }) => {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setLinking({ device: (form.get("device") as string | null) || props.devices[0], phone: String(form.get("phone") || "").trim() })
  }
  return (
    <Show when={!linking()} fallback={<Linking {...linking()!} again={props.again} />}>
      <Section heading="Add Account">
        <form class="form" onSubmit={start}>
          <Show when={props.devices.length > 1}>
            <Field label="Link on">
              <Select.Root name="device" collection={devices} />
            </Field>
          </Show>
          <Field label="Phone number" hint="Optional: for a code to type on the phone, when this shows on the phone itself.">
            <Input name="phone" inputMode="tel" autoComplete="tel" placeholder="+61 400 000 000" />
          </Field>
          <Button type="submit">Link Account</Button>
        </form>
      </Section>
    </Show>
  )
}

/// One account, opened from Accounts: what's wrong with it, if anything, where it's linked, and Sign Out.
function AccountView(props: { account: Account }) {
  const signOut = async () => {
    const sure = await confirm({
      heading: `Sign out of ${props.account.account}?`,
      text: "It's unlinked from the phone, and its messages kept here are deleted. Linking again needs the phone.",
      action: "Sign Out",
      destructive: true,
    })
    if (!sure) return
    try {
      await call("whatsapp_sign_out", { account: props.account.account })
      leave()
    } catch (error) {
      toast(plain(error))
    }
  }
  return (
    <>
      <Switch>
        <Match when={props.account.state === "connecting"}>
          <Status heading="Connecting…" />
        </Match>
        <Match when={props.account.state === "restarting"}>
          <Status heading="Starting again…" text={`Its link on ${props.account.device} stopped.`} />
        </Match>
        <Match when={props.account.state === "disconnected"}>
          <Status heading="Reconnecting…" />
        </Match>
        <Match when={props.account.state !== "connected"}>
          <Problem warn heading="Not connected" text={`${props.account.why.replace(/^./, (c) => c.toUpperCase())}.`} />
        </Match>
      </Switch>
      <Section heading="Linked On">
        <List>
          <Row heading={props.account.device} />
        </List>
      </Section>
      <div class="out">
        <Button variant="ghost" class="sign-out" onClick={signOut}>Sign Out</Button>
      </div>
    </>
  )
}

/// The account after the page's `#`, if it was opened for one; else linking another.
const named = decodeURIComponent(location.hash.slice(1))

function WhatsApp(props: { state: { accounts: Account[]; devices: string[] }; again: () => void }) {
  const account = () => props.state.accounts.find((a) => a.account === named)
  return (
    <Show when={!named} fallback={<Show when={account()} fallback={<Empty>This account isn't linked any more.</Empty>}><AccountView account={account()!} /></Show>}>
      <Show
        when={props.state.devices.length}
        fallback={<Problem warn heading="WhatsApp isn't on any of your devices yet" text="Ask your agent to install it on a computer of yours that stays on." />}
      >
        <div class="whatsapp">
          <Link devices={props.state.devices} again={props.again} />
        </div>
      </Show>
    </Show>
  )
}

function Page() {
  const state = createMemo(async () => {
    const [{ accounts }, { devices }] = await Promise.all([ask<{ accounts: Account[] }>("accounts"), ask<{ devices: string[] }>("devices")])
    return { accounts, devices }
  })
  changed(() => refresh(state))
  return (
    <Screen heading={named || "WhatsApp"} back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't reach WhatsApp" text={(error() as Error).message} action={<Button variant="outline" onClick={reset}>Try again</Button>} />}>
        <Loading fallback={<Skeleton rows={3} />}>
          <WhatsApp state={state()} again={() => refresh(state)} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <Page />, document.body)
