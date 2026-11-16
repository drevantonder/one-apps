// Messenger: each account is a sign-in to messenger.com, held by a browser on one of your devices. Opened from the
// Accounts folder with its name after a `#`, it's that account; with none, it signs one in, which opens a window on
// that device's screen, where you sign in yourself.
import { createMemo, createSignal, Errored, For, Loading, refresh, Show } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, confirm, createListCollection, Empty, Field, Input, leave, Problem, Screen, Section, Select, Skeleton, toast } from "ui"
import "./app.css"

const ask = (tool, inputs = {}) => call(`messenger_${tool}`, inputs).then(JSON.parse)
const plain = (error) => error.message.replace(/^./, (c) => c.toUpperCase())

function SignIn(props) {
  const devices = createListCollection({ items: props.devices.map((d) => ({ value: d, label: d })) })
  const [busy, setBusy] = createSignal(false)
  const [opened, setOpened] = createSignal()
  const start = async (event) => {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const device = form.get("device") || props.devices[0]
    const account = String(form.get("account") || "").trim() || "Personal"
    setBusy(true)
    try {
      await call("messenger_sign_in", { account, device })
      setOpened({ account, device })
    } catch (error) {
      toast(plain(error))
    } finally {
      setBusy(false)
    }
  }
  return (
    <Section heading="Add Account">
      <Show
        when={!opened()}
        fallback={<p class="how">{`A window opened on ${opened().device}. Sign in to Messenger there as ${opened().account}, and tick Keep me signed in. It's added here once your chats show.`}</p>}
      >
        <form class="form" onSubmit={start}>
          <Field label="Name" hint="To tell your accounts apart, like Personal or Work.">
            <Input name="account" placeholder="Personal" autocapitalize="words" autocorrect="off" />
          </Field>
          <Show when={props.devices.length > 1}>
            <Field label="Sign in on" hint="A window opens on its screen.">
              <Select.Root name="device" collection={devices} />
            </Field>
          </Show>
          <Button type="submit" loading={busy()}>Sign In to Messenger</Button>
        </form>
      </Show>
    </Section>
  )
}

/// One account, opened from the Accounts folder: whether it needs signing in again, and Sign Out.
function Account(props) {
  const signOut = async () => {
    const sure = await confirm({
      heading: `Stop reading ${props.account.account}?`,
      text: "Its session is deleted here. Messenger isn't told: sign that browser out in Facebook's settings to end it there too.",
      action: "Sign Out",
      destructive: true,
    })
    if (!sure) return
    try {
      await call("messenger_sign_out", { account: props.account.account })
      leave()
    } catch (error) {
      toast(plain(error))
    }
  }
  const signIn = async () => {
    try {
      await call("messenger_sign_in", { account: props.account.account, device: props.devices[0] })
      toast(`A window opened on ${props.devices[0]}. Sign in to Messenger there.`)
    } catch (error) {
      toast(plain(error))
    }
  }
  return (
    <>
      <Show when={!props.account.ok}>
        <Problem
          warn
          heading="Needs signing in again"
          text="Messenger signed it out."
          action={<Show when={props.devices.length}><Button variant="outline" onClick={signIn}>Sign In</Button></Show>}
        />
      </Show>
      <div class="out">
        <Button variant="ghost" class="sign-out" onClick={signOut}>Sign Out</Button>
      </div>
    </>
  )
}

/// The account after the page's `#`, if it was opened for one; else signing another in.
const named = decodeURIComponent(location.hash.slice(1))

function Messenger(props) {
  const account = () => props.state.accounts.find((a) => a.account === named)
  return (
    <Show when={!named} fallback={<Show when={account()} fallback={<Empty>This account isn't signed in any more.</Empty>}><Account account={account()} devices={props.state.devices} /></Show>}>
      <Show
        when={props.state.devices.length}
        fallback={<Problem warn heading="Messenger isn't on any of your devices yet" text="Ask your agent to install its browser on a computer of yours." />}
      >
        <div class="messenger">
          <SignIn devices={props.state.devices} />
        </div>
      </Show>
    </Show>
  )
}

function App() {
  const state = createMemo(async () => {
    const [accounts, devices] = await Promise.all([ask("accounts"), ask("devices")])
    return { accounts, devices }
  })
  changed(() => refresh(state))
  return (
    <Screen heading={named || "Messenger"} back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't reach Messenger" text={error().message} action={<Button variant="outline" onClick={reset}>Try again</Button>} />}>
        <Loading fallback={<Skeleton rows={3} />}>
          <Messenger state={state()} again={() => refresh(state)} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <App />, document.body)
