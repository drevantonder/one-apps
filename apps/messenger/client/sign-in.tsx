// Messenger: each account is a sign-in to messenger.com, held by a browser on one of your devices. Opened from
// Accounts, as sign_in's page, with its name after a `#`, it's that account; with none, it signs one in, which opens a window on
// that device's screen, where you sign in yourself.
import { createMemo, createSignal, Errored, Loading, Match, onCleanup, refresh, Show, Switch } from "solid-js"
import { render } from "@solidjs/web"
import { Button, call, changed, confirm, createListCollection, Empty, Field, Input, leave, Problem, Screen, Section, Select, Skeleton, Steps, toast } from "ui"
import "./sign-in.css"

/** A signed-in account, as `messenger_accounts` answers it. */
interface Account {
  account: string
  ok: boolean
}

const ask = <T,>(tool: string, inputs = {}): Promise<T> => call(`messenger_${tool}`, inputs).then(JSON.parse)
const plain = (error: unknown) => (error as Error).message.replace(/^./, (c) => c.toUpperCase())

/** Where signing an account in is, as `messenger_signing_in` answers it (browser.ex's `@signing`). */
interface Signing {
  state: "none" | "opening" | "waiting" | "signed_in" | "closed" | "timed_out" | "failed"
  why?: string
}

/// Signing `account` in on `device`, in the state it's in: its steps while the window opens and waits for its person,
/// asked again whenever the server says it changed, and Try Again once the window was closed, the time ran out or it
/// failed, and Done once it's signed in.
function SigningIn(props: { account: string; device: string }) {
  const [signing, setSigning] = createSignal<Signing>({ state: "opening" })
  const which = { account: props.account, device: props.device }
  const start = () => {
    setSigning({ state: "opening" })
    call("messenger_sign_in", which).then(
      () => ask<Signing>("signing_in", which).then(setSigning),
      (error) => setSigning({ state: "failed", why: (error as Error).message }),
    )
  }
  start()
  onCleanup(
    changed(async () => {
      if (!["opening", "waiting"].includes(signing().state)) return
      const now = await ask<Signing>("signing_in", which).catch((): undefined => undefined)
      if (!now || (signing().state === "opening" && now.state !== "waiting" && now.state !== "signed_in")) return
      setSigning(now)
    }),
  )
  const tryAgain = <Button variant="outline" onClick={start}>Try Again</Button>
  return (
    <Switch>
      <Match when={signing().state === "opening" || signing().state === "waiting"}>
        <Steps
          steps={[`Opening a window on ${props.device}`, `Signing in as ${props.account}`]}
          at={signing().state === "opening" ? 0 : 1}
          text={signing().state === "waiting" ? "Sign in to Messenger in that window, and tick Keep me signed in." : undefined}
        />
      </Match>
      <Match when={signing().state === "signed_in"}>
        <Empty action={<Button onClick={leave}>Done</Button>}>{props.account} is signed in.</Empty>
      </Match>
      <Match when={signing().state === "closed"}>
        <Problem warn heading="The window was closed" text="It closed before Messenger was signed in." action={tryAgain} />
      </Match>
      <Match when={signing().state === "timed_out"}>
        <Problem warn heading="Signing in took too long" text="The window closed after 15 minutes." action={tryAgain} />
      </Match>
      <Match when={signing().state === "failed"}>
        <Problem heading="Couldn't open the window" text={signing().why} action={tryAgain} />
      </Match>
      <Match when={signing().state === "none"}>
        <Problem warn heading="Signing in stopped" text={`Messenger's browser on ${props.device} started again.`} action={tryAgain} />
      </Match>
    </Switch>
  )
}

function SignIn(props: { devices: string[] }) {
  const devices = createListCollection({ items: props.devices.map((d) => ({ value: d, label: d })) })
  const [signing, setSigning] = createSignal<{ account: string; device: string }>()
  const start = (event: SubmitEvent & { currentTarget: HTMLFormElement }) => {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    setSigning({ account: String(form.get("account") || "").trim() || "Personal", device: (form.get("device") as string | null) || props.devices[0] })
  }
  return (
    <Section heading="Add Account">
      <Show when={!signing()} fallback={<SigningIn {...signing()!} />}>
        <form class="form" onSubmit={start}>
          <Field label="Name" hint="To tell your accounts apart, like Personal or Work.">
            <Input name="account" placeholder="Personal" autoCapitalize="words" autoCorrect={false} />
          </Field>
          <Show when={props.devices.length > 1}>
            <Field label="Sign in on" hint="A window opens on its screen.">
              <Select.Root name="device" collection={devices} />
            </Field>
          </Show>
          <Button type="submit">Sign In to Messenger</Button>
        </form>
      </Show>
    </Section>
  )
}

/// One account, opened from Accounts: whether it needs signing in again, and Sign Out.
function AccountView(props: { account: Account; devices: string[] }) {
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
  const [signing, setSigning] = createSignal(false)
  return (
    <>
      <Show when={!props.account.ok}>
        <Show
          when={signing()}
          fallback={
            <Problem
              warn
              heading="Needs signing in again"
              text="Messenger signed it out."
              action={<Show when={props.devices.length}><Button variant="outline" onClick={() => setSigning(true)}>Sign In</Button></Show>}
            />
          }
        >
          <SigningIn account={props.account.account} device={props.devices[0]} />
        </Show>
      </Show>
      <div class="out">
        <Button variant="ghost" class="sign-out" onClick={signOut}>Sign Out</Button>
      </div>
    </>
  )
}

/// The account after the page's `#`, if it was opened for one; else signing another in.
const named = decodeURIComponent(location.hash.slice(1))

function Messenger(props: { state: { accounts: Account[]; devices: string[] }; again: () => void }) {
  const account = () => props.state.accounts.find((a) => a.account === named)
  return (
    <Show when={!named} fallback={<Show when={account()} fallback={<Empty>This account isn't signed in any more.</Empty>}><AccountView account={account()!} devices={props.state.devices} /></Show>}>
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

function Page() {
  const state = createMemo(async () => {
    const [{ accounts }, { devices }] = await Promise.all([ask<{ accounts: Account[] }>("accounts"), ask<{ devices: string[] }>("devices")])
    return { accounts, devices }
  })
  changed(() => refresh(state))
  return (
    <Screen heading={named || "Messenger"} back onBack={leave}>
      <Errored fallback={(error, reset) => <Problem heading="Couldn't reach Messenger" text={(error() as Error).message} action={<Button variant="outline" onClick={reset}>Try again</Button>} />}>
        <Loading fallback={<Skeleton rows={3} />}>
          <Messenger state={state()} again={() => refresh(state)} />
        </Loading>
      </Errored>
    </Screen>
  )
}

render(() => <Page />, document.body)
