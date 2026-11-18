defmodule ScreenSharing.Helper do
  @moduledoc """
  Shares its Mac's screen: a small app it builds there from `server/helper/`, with swiftc, and runs once for each
  call, which takes a picture of the main display or posts the mouse and keyboard's events to it.

  The helper is a macOS app of this app's own, Screen Sharing for The One App, so that macOS asks the Mac's person
  for Screen Recording and Accessibility in its name and keeps what they allow it through the server's updates. It's
  built again only when its source changes, and macOS then asks again, as it does for any changed app that isn't
  signed by a developer. Its process keeps which permissions it has asked macOS for, so the Mac's person is asked
  at most once each while it runs.
  """
  use GenServer
  @behaviour OneCore.Service

  @app "Screen Sharing for The One App.app"

  # Where in System Settings → Privacy & Security each permission is turned on.
  @panes %{"Screen Recording" => "Screen & System Audio Recording", "Accessibility" => "Accessibility"}
  @uses %{"Screen Recording" => "see this Mac's screen", "Accessibility" => "use this Mac's mouse and keyboard"}

  @impl OneCore.Service
  def called, do: "Screen Sharing for The One App"

  @impl OneCore.Service
  def needs do
    "A Mac with Xcode or its Command Line Tools, whose swiftc builds the app it brings, Screen Sharing for The One App, " <>
      "which takes pictures of the Mac's screen and uses its mouse and keyboard. The Mac's person allows it in System Settings → Privacy & Security, " <>
      "under Screen & System Audio Recording and under Accessibility; macOS asks them on its screen the first time it's used."
  end

  @doc "The screen's size in pixels, whether macOS lets the helper see it and use it, and where the helper is."
  def status(service) do
    service |> run(["status"]) |> Map.put("app", GenServer.call(service, :app))
  end

  @doc "A PNG of the screen, in base64."
  def screenshot(service), do: run(service, ["screenshot"])

  @doc "Does a Computer Use action other than a screenshot: `inputs` as Computer Use gives them."
  def act(service, action, inputs), do: run(service, ["act", JSON.encode!(Map.put(inputs, "action", action))])

  @impl GenServer
  def init(_) do
    for program <- ["swiftc", "codesign"], System.find_executable(program) == nil do
      raise "This machine has no #{program}: Screen Sharing for The One App is built on a Mac, with Xcode or its Command Line Tools"
    end

    {:ok, %{app: built(OneCore.Service.folder(self(), "server/helper")), asked: MapSet.new()}}
  end

  @impl GenServer
  def handle_call(:app, _from, state), do: {:reply, state.app, state}

  # Whether to ask macOS for `permission` now: only the first time it's missing while this runs.
  def handle_call({:ask?, permission}, _from, state),
    do: {:reply, permission not in state.asked, %{state | asked: MapSet.put(state.asked, permission)}}

  # A new version of the app whose helper's source changed is built again, in the new folder that gives it.
  @impl GenServer
  def code_change(_version, state, _extra),
    do: {:ok, %{state | app: built(OneCore.Service.folder(self(), "server/helper"))}}

  # Runs the helper once, in the calling process, and gives what it answers.
  defp run(service, arguments) do
    app = GenServer.call(service, :app)
    program = Path.join([app, "Contents", "MacOS", "helper"])
    {output, status} = System.cmd(program, arguments)

    case JSON.decode(output) do
      {:ok, %{"ok" => answer}} -> answer
      {:ok, %{"error" => why}} -> raise why
      {:ok, %{"missing" => permission}} -> raise missing(service, program, permission)
      _ -> raise "Screen Sharing for The One App stopped, with status #{status}: #{String.slice(output, 0, 500)}"
    end
  end

  # What's missing, said for the Mac's person, after asking macOS for it the first time, which adds the helper to
  # its list in System Settings and asks there.
  defp missing(service, program, permission) do
    asked = GenServer.call(service, {:ask?, permission})
    if asked, do: System.cmd(program, ["ask", JSON.encode!(%{permission: permission})])

    "macOS doesn't let Screen Sharing for The One App #{@uses[permission]} yet. " <>
      if(asked, do: "It's asking on the Mac now. ", else: "") <>
      "On the Mac, in System Settings → Privacy & Security → #{@panes[permission]}, turn on Screen Sharing for The One App." <>
      "\n\nOnly the Mac's person can allow it: ask them, then try again."
  end

  # The helper's app, built in `folder` if it isn't there already: under another name and then renamed, so an app
  # that's there is a whole one. Signed for this Mac alone, which macOS needs of an app before it keeps a permission
  # for it.
  defp built(folder) do
    app = Path.join(folder, @app)

    if not File.exists?(app) do
      building = app <> ".building"
      File.rm_rf!(building)
      File.mkdir_p!(Path.join([building, "Contents", "MacOS"]))
      File.cp!(Path.join(folder, "Info.plist"), Path.join([building, "Contents", "Info.plist"]))
      build(folder, "swiftc", ["-O", "-o", Path.join([building, "Contents", "MacOS", "helper"]), "main.swift"])
      build(folder, "codesign", ["--force", "--sign", "-", building])
      File.rename!(building, app)
    end

    app
  end

  defp build(folder, program, arguments) do
    case System.cmd(System.find_executable(program), arguments, cd: folder, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> raise "Screen Sharing for The One App didn't build: #{program} said\n" <> output
    end
  end
end
