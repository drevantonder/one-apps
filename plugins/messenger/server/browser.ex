defmodule Messenger.Browser do
  @moduledoc """
  Holds Messenger's browser on its machine: the program `server/browser/`, run with Bun, which reads and sends in
  messenger.com through Playwright. An account's browser opens from its session, which the plugin keeps encrypted
  (`Messenger.session/2`) and hands over the first time an account is asked for; what the program sends back as
  that session changes, and once someone signs in, goes back to the plugin (`Messenger.store_session/4`). Any machine
  that runs this can read any of its person's accounts.

  Signing an account in is in one state at a time, which changes only as `@signing` says: `opening` (the window
  starting), `waiting` (the window open, for its person to sign in), then `signed_in`, `closed` (they closed the
  window first), `timed_out` (15 minutes passed) or `failed`, with why. It's kept once it's over, for the screen to
  say so, until the account is signed in again.
  """
  use GenServer
  @behaviour OneCore.Service
  require Logger

  # Signing an account in, by the state it's in and what happens, as the moduledoc says. What isn't here leaves it as
  # it is.
  @signing %{
    {"opening", "opened"} => "waiting",
    {"opening", "failed"} => "failed",
    {"opening", "signed_in"} => "signed_in",
    {"waiting", "signed_in"} => "signed_in",
    {"waiting", "closed"} => "closed",
    {"waiting", "timed_out"} => "timed_out",
    {"waiting", "failed"} => "failed",
    {"opening", "closed"} => "closed",
    {"opening", "timed_out"} => "timed_out"
  }

  @impl OneCore.Service
  def called, do: "Messenger's browser"

  @impl OneCore.Service
  def needs do
    "Bun, and a Chromium for Playwright (`bunx playwright install chromium`) or Google Chrome. Signing in opens " <>
      "a window on the machine, so its person signs in at its screen. It reaches www.messenger.com."
  end

  @doc """
  Runs one of the program's commands on `account` for `who`: `%{"ok" => answer}`, or `%{"error" => why, "code" =>
  code}`, `signed_out` when Messenger has signed it out.
  """
  def run(service, who, account, command), do: GenServer.call(service, {:run, who, account, command}, 180_000)

  @doc "Opens a window on this machine for `who` to sign in to Messenger as `account`."
  def sign_in(service, who, account), do: GenServer.call(service, {:sign_in, who, account}, 60_000)

  @doc "Where signing `account` in here for `who` is: its `state`, and `why` it failed. `none` when it wasn't started here since this service started."
  def signing_in(service, who, account), do: GenServer.call(service, {:signing_in, who, account})

  @doc "Closes `account`'s browser here, if it's open, its session kept first."
  def close(service, account), do: GenServer.call(service, {:close, account}, 60_000)

  @impl GenServer
  def init(_) do
    bun = System.find_executable("bun") || raise "This machine has no Bun to run Messenger's browser with"

    {:ok, %{bun: bun, port: nil, buffer: "", waiting: %{}, request_id: 0, open: MapSet.new(), whos: %{}, signing: %{}},
     {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    folder = OneCore.Service.folder(self(), "server/browser")

    if not File.dir?(Path.join(folder, "node_modules")) do
      {output, status} = System.cmd(state.bun, ["install"], cd: folder, stderr_to_stdout: true)
      if status != 0, do: raise("Messenger's browser didn't install:\n" <> output)
    end

    port =
      Port.open({:spawn_executable, state.bun}, [:binary, :exit_status, line: 1_048_576, args: ["main.js"], cd: folder])

    # A sign-in under way in the browser this one replaces is over: a screen showing it asks again.
    for who <- OneCore.Service.acts_for(), do: tell(who)
    {:noreply, %{state | port: port}}
  end

  @impl GenServer
  def handle_call({:run, who, account, command}, from, state) do
    command = Map.put(command, "account", account)

    command =
      if MapSet.member?(state.open, account),
        do: command,
        else: Map.put(command, "state", OneCore.Service.plugin(self(), who, :session, [account]))

    state = put_in(state.whos[account], who)
    {:noreply, ask(state, command, {from, account, :opens})}
  end

  def handle_call({:sign_in, who, account}, from, state) do
    state = put_in(state.whos[account], who)
    state = put_in(state.signing[account], %{who: who, state: "opening", why: nil})
    tell(who)
    {:noreply, ask(state, %{"do" => "sign_in", "account" => account}, {from, account, :signs_in})}
  end

  def handle_call({:signing_in, who, account}, _from, state) do
    case state.signing[account] do
      %{who: ^who} = signing -> {:reply, Map.take(signing, [:state, :why]), state}
      _ -> {:reply, %{state: "none"}, state}
    end
  end

  def handle_call({:close, account}, from, state) do
    {:noreply, ask(state, %{"do" => "close", "account" => account}, {from, account, nil})}
  end

  defp ask(state, command, from) do
    id = state.request_id + 1
    Port.command(state.port, JSON.encode!(Map.put(command, "id", id)) <> "\n")
    %{state | request_id: id, waiting: Map.put(state.waiting, id, from)}
  end

  @impl GenServer
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> part}}

  def handle_info({port, {:data, {:eol, part}}}, %{port: port} = state) do
    line = state.buffer <> part
    {:noreply, handle_event(%{state | buffer: ""}, JSON.decode!(line))}
  end

  # The program stopped by itself, so the service does too, and its server starts both again.
  def handle_info({port, {:exit_status, status}}, %{port: port}),
    do: raise("Messenger's browser stopped, with status #{status}")

  defp handle_event(state, %{"id" => id} = response) do
    {{from, account, effect}, waiting} = Map.pop(state.waiting, id)
    GenServer.reply(from, Map.take(response, ["ok", "error", "code"]))

    # An account's browser is open once a command ran on it, and not once Messenger signed it out.
    open =
      cond do
        response["code"] in ["signed_out", "no_session"] -> MapSet.delete(state.open, account)
        effect == :opens -> MapSet.put(state.open, account)
        true -> state.open
      end

    state = %{state | waiting: waiting, open: open}

    cond do
      effect != :signs_in -> state
      response["error"] -> step(state, account, "failed", response["error"])
      true -> step(state, account, "opened")
    end
  end

  defp handle_event(state, %{"event" => "session", "account" => account, "data" => data}) do
    keep(state, account, data, false)
    %{state | open: MapSet.delete(state.open, account)}
  end

  defp handle_event(state, %{"event" => "signed_in", "account" => account, "data" => data}) do
    keep(state, account, data, true)
    Logger.info("Messenger: #{account} is signed in")
    step(%{state | open: MapSet.delete(state.open, account)}, account, "signed_in")
  end

  defp handle_event(state, %{"event" => "not_signed_in", "account" => account} = event),
    do: step(state, account, event["reason"], event["why"])

  # Takes signing `account` in one step (`event`, by `@signing`), and tells its person's apps.
  defp step(state, account, event, why \\ nil) do
    with %{state: was} = signing <- state.signing[account],
         to when to != nil <- @signing[{was, event}] do
      tell(signing.who)
      put_in(state.signing[account], %{signing | state: to, why: why})
    else
      _ -> state
    end
  end

  # Tells `who`'s apps that something changed here, as a call to the plugin does once it's done.
  defp tell(who) do
    service = self()
    Task.start(fn -> OneCore.Service.plugin(service, who, :changed) end)
  end

  defp keep(state, account, data, signed_in) do
    OneCore.Service.plugin(self(), state.whos[account], :store_session, [account, data, signed_in])
  rescue
    error -> Logger.warning("Messenger: #{account}'s session wasn't kept: #{Exception.message(error)}")
  end
end
