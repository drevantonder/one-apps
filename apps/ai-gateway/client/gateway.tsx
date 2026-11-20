// AI Gateway, as its page in Settings draws it: which model each job uses, which a person can change, and where models
// run, by machine or by hosted endpoint, with the endpoints' keys, said by name and never by value.
import { createMemo, Errored, For, Loading, refresh, Show } from "solid-js"
import { call, changed, Empty, List, Problem, Row, Section, Select, Skeleton, toast } from "ui"

/** A model a place has, as `ai-gateway_models` answers it. */
interface Model {
  id: string
  name: string
}

/** Where models run, as `ai-gateway_models` answers it: a machine, or a hosted endpoint whose key is set. */
interface Place {
  name: string
  kind: "machine" | "hosted"
  up: boolean
  seen?: number
  problem?: string
  models: Model[]
}

/** The models a job tries, in order, and whose list that is. */
interface Job {
  job: string
  models: string[]
  whose: "yours" | "everyone's"
}

// Chat and vision are the jobs there always are; others show once one is set.
const JOBS = ["chat", "vision"]
const title = (job: string) => job.replace(/(^|-)([a-z])/g, (_, dash, letter) => `${dash ? " " : ""}${letter.toUpperCase()}`)

const state = createMemo(() => call("ai-gateway_models").then((text): { places: Place[]; jobs: Job[] } => JSON.parse(text)))
changed(() => refresh(state))

async function choose(job: string, model: string) {
  try {
    await call("ai-gateway_set", { job, models: model ? [model] : [] })
  } catch (error) {
    toast(error as Error)
  }
  refresh(state)
}

const count = (place: Place) => `${place.models.length} ${place.models.length === 1 ? "model" : "models"}`
// What a place says of itself: a machine's models, or that it's off; a hosted endpoint's key is set, or the endpoint isn't answering.
const about = (place: Place) => (place.kind === "hosted" ? `Key set · ${place.up ? count(place) : (place.problem ?? "Not answering")}` : place.up ? count(place) : (place.problem ?? (place.seen ? "Off" : "Not answering")))

function Jobs(props: { places: Place[]; jobs: Job[] }) {
  const named = () => [...new Set([...JOBS, ...props.jobs.map((one) => one.job)])]
  const models = () => props.places.flatMap((place) => place.models.map((model) => ({ value: model.id, label: place.kind === "hosted" ? model.id : `${model.name} on ${place.name}` })))
  const items = (job?: Job) => [{ value: "", label: "Automatic" }, ...models(), ...(job?.models ?? []).filter((id) => !models().some((model) => model.value === id)).map((id) => ({ value: id, label: id }))]
  return (
    <List>
      <For each={named()}>
        {(name) => {
          const job = () => props.jobs.find((one) => one.job === name)
          const rest = () => job()?.models.slice(1) ?? []
          return (
            <Row
              heading={title(name)}
              text={job() ? [rest().length ? `Then ${rest().join(", ")}` : "", job()!.whose === "everyone's" ? "Set for everyone" : ""].filter(Boolean).join(" · ") || undefined : "A model on your machines answers"}
              end={<Select.Root aria-label={title(name)} items={items(job())} value={job()?.models[0] ?? ""} onValueChange={(model) => choose(name, model)} />}
            />
          )
        }}
      </For>
    </List>
  )
}

export default function Gateway() {
  return (
    <Errored fallback={(error) => <Problem heading="Can't show AI Gateway" text={error() as Error} />}>
      <Loading fallback={<Skeleton rows={3} />}>
        <Section heading="Which Model Does a Job">
          <Jobs places={state().places} jobs={state().jobs} />
        </Section>
        <Section heading="Where Models Run, and Keys">
          <Show when={state().places.length} fallback={<Empty>No model yet: a machine running Ollama, or an AI key from the Vault.</Empty>}>
            <List each={state().places} keyed={(place) => `${place.kind} ${place.name}`}>
              {(place) => <Row heading={place().name} text={about(place())} />}
            </List>
          </Show>
        </Section>
      </Loading>
    </Errored>
  )
}
