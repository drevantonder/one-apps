// WhatsApp: each account is a phone linked to one of your devices, as WhatsApp Desktop is linked. Its screens are
// `whatsapp_sign_in`, whose form (its arguments filled in: the device, the number) links one: it shows the QR code to
// scan on the phone, and the code to type there for a number, and `whatsapp_account { account }`, which Accounts opens.
import { createProjection, createSignal, Errored, Loading, Match, onCleanup, refresh, Show, Switch } from "solid-js"
import { Button, call, changed, confirm, Empty, Field, Image, Input, leave, List, Problem, render, Row, Screen, Section, Select, Spinner, Status, Steps, styles, Text, toast, tokens, toolInput, View } from "ui"
import { own } from "./own.ts"

const look = styles({
  whatsapp: { gap: tokens.grid[6], maxWidth: tokens.length.readable },
  pairing: { gap: tokens.grid[2], alignItems: "flex-start" },
  how: { font: tokens.type.small, color: tokens.colour.secondaryLabel },
  // A QR code is black on white, whatever the scheme, so a phone's camera reads it.
  qr: { width: own.qr, height: own.qr, marginBlock: tokens.grid[2], borderRadius: tokens.radius.medium, backgroundColor: own.paper },
  code: { fontFamily: tokens.font.mono, font: tokens.type.title },
  form: { gap: tokens.grid[4], alignItems: "flex-start" },
  field: { alignSelf: "stretch" },
  // Sign Out is the account's last thing, centred under it.
})

/** A linked account, as `whatsapp_account` answers it. */
interface Account {
  account: string
  device: string
  ok: boolean
  state: "connecting" | "connected" | "disconnected" | "restarting" | "unreachable" | "unlinked" | "replaced"
  why: string
  since?: number
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
// A time arrives as an instant and is said in this device's own time zone and language.
const since = (at: number) => new Date(at).toLocaleString(undefined, { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" })
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
  const tryAgain = <Button variant="outline" onPress={start}>Try Again</Button>
  return (
    <Section heading="Link a Phone">
      <Switch>
        <Match when={pairing().state === "starting"}>
          <Steps steps={["Asking WhatsApp for a code", "Scanning it on the phone"]} at={0} />
        </Match>
        <Match when={pairing().state === "pairing"}>
          <View style={look.pairing}>
            <Text style={look.how}>On the phone, open WhatsApp › Settings › Linked devices › Link a device, and scan this code.</Text>
            <Show when={pairing().qr}>{(qr) => <Image src={qr()} alt="The QR code to scan" style={look.qr} />}</Show>
            <Show when={pairing().code}>
              <Text style={look.how}>Or tap Link with phone number instead, and type this code:</Text>
              <Text style={look.code}>{pairing().code}</Text>
            </Show>
            <Text style={look.how}>Recent chats take a few minutes to arrive.</Text>
          </View>
        </Match>
        <Match when={pairing().state === "linked"}>
          <Empty action={<Button onPress={leave}>Done</Button>}>{pairing().account} is linked. Recent chats take a few minutes to arrive.</Empty>
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
  const devices = props.devices.map((d) => ({ value: d, label: d }))
  const [linking, setLinking] = createSignal<{ device: string; phone: string }>()
  // Filled in from the arguments it was opened with, as a `mailto:` link fills an email: nothing links until it's pressed.
  const given = toolInput("whatsapp_sign_in").arguments
  const [device, setDevice] = createSignal(props.devices.find((d) => d === given.device) ?? props.devices[0])
  const [phone, setPhone] = createSignal(typeof given.phone === "string" ? given.phone : "")
  const start = () => setLinking({ device: device(), phone: phone().trim() })
  return (
    <Show when={!linking()} fallback={<Linking {...linking()!} again={props.again} />}>
      <Section heading="Add Account">
        <View style={look.form}>
          <Show when={props.devices.length > 1}>
            <View style={look.field}>
              <Field label="Link on">
                <Select.Root items={devices} value={device()} onValueChange={setDevice} />
              </Field>
            </View>
          </Show>
          <View style={look.field}>
            <Field label="Phone number" hint="Optional: for a code to type on the phone, when this shows on the phone itself.">
              <Input value={phone()} onChangeText={setPhone} onSubmitEditing={start} inputMode="tel" autoComplete="tel" placeholder="+61 400 000 000" />
            </Field>
          </View>
          <Button onPress={start}>Link Account</Button>
        </View>
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
          <Problem warn heading="Not connected" text={`${props.account.why.replace(/^./, (c) => c.toUpperCase())}.${props.account.since ? ` Since ${since(props.account.since)}.` : ""}`} />
        </Match>
      </Switch>
      <Section heading="Linked On">
        <List>
          <Row heading={props.account.device} />
        </List>
      </Section>
      <List>
        <Row heading="Sign Out" destructive onPress={signOut} />
      </List>
    </>
  )
}

/// The account the screen is of, if it's `whatsapp_account`'s; else linking another.
const named = () => {
  const { name, arguments: inputs } = toolInput("whatsapp_sign_in")
  return name === "whatsapp_account" ? String(inputs.account ?? "") : ""
}

function WhatsApp(props: { state: { account?: Account | null; devices: string[] }; again: () => void }) {
  return (
    <Show when={!named()} fallback={<Show when={props.state.account} fallback={<Empty>This account isn't linked any more.</Empty>}>{(account) => <AccountView account={account()} />}</Show>}>
      <Show
        when={props.state.devices.length}
        fallback={<Problem warn heading="WhatsApp isn't on any of your devices yet" text="Ask your agent to install it on a computer of yours that stays on." />}
      >
        <View style={look.whatsapp}>
          <Link devices={props.state.devices} again={props.again} />
        </View>
      </Show>
    </Show>
  )
}

function Page() {
  const state = createProjection(async () => {
    const [{ account }, { devices }] = await Promise.all([named() ? ask<{ account: Account | null }>("account", { account: named() }) : { account: undefined }, ask<{ devices: string[] }>("devices")])
    return { account, devices }
  })
  changed(() => refresh(state))
  return (
    <Screen heading={named() || "WhatsApp"} back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't reach WhatsApp" text={error() as Error} action={<Button variant="outline" onPress={reset}>Try Again</Button>} />}>
        <Loading fallback={<Spinner delay />}>
          <WhatsApp state={state} again={() => refresh(state)} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <Page />)
