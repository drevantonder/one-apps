defmodule StayAwake.Mac do
  @moduledoc """
  Holds its Mac awake while Stay Awake is on: `caffeinate -s` keeps a Mac from sleeping, lid shut or not, and
  macOS honours that only on power, so on battery it sleeps as usual. It's on unless turned off, which it keeps
  in its folder as a file named `off`.

  `caffeinate` runs as a launchd agent of the Mac's user (`~/Library/LaunchAgents/app.theone.stay-awake.plist`,
  kept alive by launchd), not as a program of this service: so the Mac stays held while the server restarts,
  crashes or doesn't start, and it can still be reached to fix it. The agent is added when it's turned on, if it
  isn't there already, and goes when it's turned off, and when this service stops for good: uninstalled, or its
  app is.
  """
  use GenServer
  @behaviour OneCore.Service

  @label "app.theone.stay-awake"

  @impl OneCore.Service
  def called, do: "Stay Awake on this Mac"

  @impl OneCore.Service
  def os, do: ["darwin"]

  @impl OneCore.Service
  def needs do
    "A Mac: macOS's caffeinate, which keeps it from sleeping while it's plugged in, run by launchd, and pmset, which says whether it is."
  end

  @doc "Whether Stay Awake is on, whether it's holding the Mac awake now, and whether the Mac is plugged in."
  def status(service), do: GenServer.call(service, :status)

  @doc "Turns Stay Awake on or off, and gives `status/1` after."
  def set(service, on), do: GenServer.call(service, {:set, on})

  @impl GenServer
  def init(_) do
    for program <- ["caffeinate", "pmset", "launchctl"],
        System.find_executable(program) == nil,
        do: raise("This machine has no #{program}: Stay Awake keeps a Mac awake")

    off = Path.join(OneCore.Service.folder(self()), "off")
    hold(not File.exists?(off))
    {:ok, %{off: off}}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  def handle_call({:set, on}, _from, state) do
    if on, do: File.rm_rf!(state.off), else: File.write!(state.off, "")
    hold(on)
    {:reply, status_of(state), state}
  end

  # It's removed when it's no longer to run on this Mac: it, or its app, was uninstalled. The server stopping or
  # crashing ends it otherwise, and leaves the Mac held.
  @impl GenServer
  def terminate({:shutdown, :removed}, _state), do: hold(false)
  def terminate(_why, _state), do: :ok

  # The agent is left as it is when it's already there, so the Mac is never held twice, nor let go meanwhile.
  defp hold(true) do
    if agent() == nil do
      File.mkdir_p!(Path.dirname(plist()))
      File.write!(plist(), plist_for(System.find_executable("caffeinate")))
      launchctl(["bootstrap", domain(), plist()])
    end

    :ok
  end

  defp hold(false) do
    if agent() != nil, do: launchctl(["bootout", "#{domain()}/#{@label}"])
    File.rm_rf!(plist())
    :ok
  end

  defp plist, do: Path.expand("~/Library/LaunchAgents/#{@label}.plist")

  defp plist_for(caffeinate) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{caffeinate}</string>
        <string>-s</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
    </dict>
    </plist>
    """
  end

  # The domain of the Mac's user, whose agents run while they're logged in.
  defp domain do
    {uid, 0} = System.cmd("id", ["-u"])
    "gui/#{String.trim(uid)}"
  end

  # How launchd describes the agent, while it has it: `nil` otherwise.
  defp agent do
    case System.cmd(System.find_executable("launchctl"), ["print", "#{domain()}/#{@label}"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      _ -> nil
    end
  end

  defp launchctl(arguments) do
    case System.cmd(System.find_executable("launchctl"), arguments, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "launchctl #{Enum.join(arguments, " ")} failed (#{status}): #{String.trim(output)}"
    end
  end

  # Holding is the agent's caffeinate asserting PreventSystemSleep, as `pmset -g assertions` lists it:
  # "pid 123(caffeinate): [0x…] 00:01:02 PreventSystemSleep named: …". pmset's first line of `-g ps` names where
  # the power comes from: "Now drawing from 'AC Power'".
  defp status_of(state) do
    {power, _status} = System.cmd(System.find_executable("pmset"), ["-g", "ps"])
    plugged_in = String.contains?(hd(String.split(power, "\n")), "AC Power")
    %{on: not File.exists?(state.off), holding: asserting?(agent()), plugged_in: plugged_in}
  end

  defp asserting?(nil), do: false

  defp asserting?(agent) do
    pid = with [_, pid] <- Regex.run(~r/^\s*pid = (\d+)$/m, agent), do: pid
    {assertions, _status} = System.cmd(System.find_executable("pmset"), ["-g", "assertions"])
    Regex.match?(~r/pid #{pid}\(caffeinate\):.*PreventSystemSleep/, assertions)
  end
end
