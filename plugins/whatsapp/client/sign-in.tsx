// WhatsApp: each account is a phone linked to one of your devices, as WhatsApp Desktop is linked. Opened from
// Accounts, as sign_in's page, with its number after a `#`, it's that account; with none, it links one: it shows the QR code to
// scan on the phone, and the code to type there for a number.
import { createMemo, createSignal, Errored, For, Loading, onCleanup, refresh, Show } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, confirm, createListCollection, Empty, Field, Input, leave, List, Problem, Row, Screen, Section, Select, Skeleton, toast } from "ui"
import "./sign-in.css"

/** A linked account, as `whatsapp_accounts` answers it. */
interface Account {
  account: string
  device: string
  ok: boolean
  why: string
}

/** The codes a phone links by, while it links: the QR code to scan, and one to type for a number. */
interface Codes {
  qr?: string
  code?: string
  error?: string
}

const ask = <T,>(tool: string, inputs = {}): Promise<T> => call(`whatsapp_${tool}`, inputs).then(JSON.parse)
const plain = (error: unknown) => (error as Error).message.replace(/^./, (c) => c.toUpperCase())

/// While a phone links: the QR code to scan, which WhatsApp renews every 20 seconds, asked again every 2. It's done
/// once there's no code any more: linked, or run out.
function Pairing(props: { device?: string; first: Codes; done: (linked: boolean) => void }) {
  const [codes, setCodes] = createSignal(props.first)
  const [why, setWhy] = createSignal<string>()
  const timer = setInterval(async () => {
    const now = await ask<Codes>("pairing", props.device ? { device: props.device } : {}).catch((error): Codes => ({ error: plain(error) }))
    if (now.error) setWhy(now.error)
    if (!now.qr) {
      clearInterval(timer)
      return props.done(!now.error)
    }
    setCodes(now)
  }, 2000)
  onCleanup(() => clearInterval(timer))
  return (
    <Section heading="Link a Phone">
      <p class="how">On the phone, open WhatsApp › Settings › Linked devices › Link a device, and scan this code.</p>
      <Show when={codes().qr}>
        <img class="qr" src={codes().qr} alt="The QR code to scan" />
      </Show>
      <Show when={codes().code}>
        <p class="how">Or tap Link with phone number instead, and type this code:</p>
        <p class="code">{codes().code}</p>
      </Show>
      <Show when={why()} fallback={<p class="how">Recent chats take a few minutes to arrive.</p>}>
        <Problem warn heading={why()} />
      </Show>
    </Section>
  )
}

function Link(props: { devices: string[]; again: () => void }) {
  const devices = createListCollection({ items: props.devices.map((d) => ({ value: d, label: d })) })
  const [linking, setLinking] = createSignal<{ device: string; first: Codes }>()
  const [busy, setBusy] = createSignal(false)
  const start = async (event: SubmitEvent & { currentTarget: HTMLFormElement }) => {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const device = (form.get("device") as string | null) || props.devices[0]
    const phone = String(form.get("phone") || "").trim()
    setBusy(true)
    try {
      await call("whatsapp_sign_in", { device, ...(phone ? { phone } : {}) })
      setLinking({ device, first: await ask<Codes>("pairing", { device }) })
    } catch (error) {
      toast(plain(error))
    } finally {
      setBusy(false)
    }
  }
  const done = (linked: boolean) => {
    setLinking()
    if (!linked) toast("The codes ran out before the phone linked.")
    props.again()
  }
  return (
    <Show when={!linking()} fallback={<Pairing {...linking()!} done={done} />}>
      <Section heading="Add Account">
        <form class="form" onSubmit={start}>
          <Show when={props.devices.length > 1}>
            <Field label="Link on">
              <Select.Root name="device" collection={devices} />
            </Field>
          </Show>
          <Field label="Phone number" hint="Optional: for a code to type on the phone, when this shows on the phone itself.">
            <Input name="phone" type="tel" autocomplete="tel" placeholder="+61 400 000 000" />
          </Field>
          <Button type="submit" loading={busy()}>Link Account</Button>
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
      <Show when={!props.account.ok}>
        <Problem warn heading="Not connected" text={`${props.account.why.replace(/^./, (c) => c.toUpperCase())}.`} />
      </Show>
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
