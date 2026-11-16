defmodule Messenger.Browser do
  @moduledoc """
  Holds Messenger's browser on its machine: the program `server/browser/`, run with Bun, which reads and sends in
  messenger.com through Playwright. An account's browser opens from its session, which the plugin keeps encrypted
  (`Messenger.session/2`) and hands over the first time an account is asked for; what the program sends back as
  that session changes, and once someone signs in, goes back to the plugin (`Messenger.kept/4`). Any machine
  that runs this can read any of its person's accounts.
  """
  use GenServer
  @behaviour OneCore.Service
  require Logger

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

  @doc "Closes `account`'s browser here, if it's open, its session kept first."
  def close(service, account), do: GenServer.call(service, {:close, account}, 60_000)

  @impl GenServer
  def init(_) do
    bun = System.find_executable("bun") || raise "This machine has no Bun to run Messenger's browser with"

    {:ok, %{bun: bun, port: nil, buffer: "", waiting: %{}, asked: 0, open: MapSet.new(), whos: %{}},
     {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    folder = OneCore.Service.folder(self(), "server/browser")

    if not File.dir?(Path.join(folder, "node_modules")) do
      {said, status} = System.cmd(state.bun, ["install"], cd: folder, stderr_to_stdout: true)
      if status != 0, do: raise("Messenger's browser didn't install:\n" <> said)
    end

    port =
      Port.open({:spawn_executable, state.bun}, [:binary, :exit_status, line: 1_048_576, args: ["main.js"], cd: folder])

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
    {:noreply, ask(state, %{"do" => "sign_in", "account" => account}, {from, account, nil})}
  end

  def handle_call({:close, account}, from, state) do
    {:noreply, ask(state, %{"do" => "close", "account" => account}, {from, account, nil})}
  end

  defp ask(state, command, from) do
    id = state.asked + 1
    Port.command(state.port, JSON.encode!(Map.put(command, "id", id)) <> "\n")
    %{state | asked: id, waiting: Map.put(state.waiting, id, from)}
  end

  @impl GenServer
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> part}}

  def handle_info({port, {:data, {:eol, part}}}, %{port: port} = state) do
    line = state.buffer <> part
    {:noreply, heard(%{state | buffer: ""}, JSON.decode!(line))}
  end

  # The program stopped by itself, so the service does too, and its server starts both again.
  def handle_info({port, {:exit_status, status}}, %{port: port}),
    do: raise("Messenger's browser stopped, with status #{status}")

  defp heard(state, %{"id" => id} = answer) do
    {{from, account, effect}, waiting} = Map.pop(state.waiting, id)
    GenServer.reply(from, Map.take(answer, ["ok", "error", "code"]))

    # An account's browser is open once a command ran on it, and not once Messenger signed it out.
    open =
      cond do
        answer["code"] in ["signed_out", "no_session"] -> MapSet.delete(state.open, account)
        effect == :opens -> MapSet.put(state.open, account)
        true -> state.open
      end

    %{state | waiting: waiting, open: open}
  end

  defp heard(state, %{"event" => "session", "account" => account, "data" => data}) do
    keep(state, account, data, false)
    %{state | open: MapSet.delete(state.open, account)}
  end

  defp heard(state, %{"event" => "signed_in", "account" => account, "data" => data}) do
    keep(state, account, data, true)
    Logger.info("Messenger: #{account} is signed in")
    %{state | open: MapSet.delete(state.open, account)}
  end

  defp heard(state, %{"event" => "not_signed_in"}), do: state

  defp keep(state, account, data, signed_in) do
    OneCore.Service.plugin(self(), state.whos[account], :kept, [account, data, signed_in])
  rescue
    error -> Logger.warning("Messenger: #{account}'s session wasn't kept: #{Exception.message(error)}")
  end
end
