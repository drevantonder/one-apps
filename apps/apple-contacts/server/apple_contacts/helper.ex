defmodule AppleContacts.Helper do
  @moduledoc """
  Runs Apple Contacts for the One App on its Mac: a small app of its own, built and signed with a Developer ID
  by `tooling/mac-helper` from `server/bin/helper/`, which it starts. It holds the running helper between calls, writes it a line for each call and hands back the
  line it answers, in turn.

  The helper is a macOS app of this app's own, with a name and a purpose for its permission, so that macOS asks the
  Mac's person in its name and keeps the answer for it, through updates of the server that started it, and removing
  the app removes it and what it was allowed. It's signed by a developer, so macOS keeps what it's allowed through every build of it.
  """
  use GenServer
  @behaviour OneCore.Service

  @app "Apple Contacts for the One App.app"

  @impl OneCore.Service
  def called, do: "Apple Contacts for the One App"

  @impl OneCore.Service
  def needs do
    "A Mac with macOS 14 or later, and the app it brings, Apple Contacts for the One App, " <>
      "which reaches Contacts. macOS asks the Mac's person once, on its screen, to let it use their contacts."
  end

  @doc "Asks the helper for `function` with `inputs`, and gives its answer, or raises with what it said."
  def ask(service, function, inputs) do
    case GenServer.call(service, {:ask, %{function: function, inputs: inputs}}, 120_000) do
      %{"ok" => result} -> result
      %{"error" => why} -> raise why
    end
  end

  @impl GenServer
  def init(_) do
    {:ok, start(OneCore.Service.folder(self(), "server/bin/helper"))}
  end

  @impl GenServer
  def handle_call({:ask, ask}, from, %{helper: helper} = state) do
    Port.command(helper, [JSON.encode!(ask), "\n"])
    {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
  end

  # An answer longer than a line the port reads at once comes in parts.
  @impl GenServer
  def handle_info({helper, {:data, {:noeol, part}}}, %{helper: helper} = state),
    do: {:noreply, %{state | reading: [state.reading, part]}}

  def handle_info({helper, {:data, {:eol, part}}}, %{helper: helper} = state) do
    {{:value, from}, waiting} = :queue.out(state.waiting)
    GenServer.reply(from, JSON.decode!(IO.iodata_to_binary([state.reading, part])))
    {:noreply, %{state | waiting: waiting, reading: []}}
  end

  # The helper stopped by itself, so the service does too, and its server starts both again.
  def handle_info({helper, {:exit_status, status}}, %{helper: helper}) do
    raise "Apple Contacts for the One App stopped, with status #{status}"
  end

  # A new version of the app. The helper carries on through it unless its own source changed, which gives it a
  # new folder: then it's built and started again.
  @impl GenServer
  def code_change(_version, state, _extra) do
    case OneCore.Service.folder(self(), "server/bin/helper") do
      folder when folder == state.folder ->
        {:ok, state}

      folder ->
        Port.close(state.helper)

        for from <- :queue.to_list(state.waiting),
            do: GenServer.reply(from, %{"error" => "The helper was updated: ask again"})

        {:ok, start(folder)}
    end
  end

  # The helper reads lines until its input closes, which is when this process ends or closes it.
  defp start(folder) do
    app = Path.join(folder, @app)
    if not File.exists?(app), do: build(folder, app)
    program = Path.join([app, "Contents", "MacOS", "helper"])
    helper = Port.open({:spawn_executable, program}, [:binary, :exit_status, line: 65_536])
    %{folder: folder, helper: helper, waiting: :queue.new(), reading: []}
  end

  # The app is the build `tooling/mac-helper` made of it, signed by a developer. Unpacked under another name and then
  # renamed, so an app that's there is a whole one.
  defp build(folder, app) do
    building = app <> ".building"
    File.rm_rf!(building)
    File.mkdir_p!(building)
    {_, 0} = System.cmd("tar", ["-xzf", Path.join(folder, "macos-aarch64"), "-C", building])
    File.rename!(Path.join(building, Path.basename(app)), app)
    File.rm_rf!(building)
  end
end
