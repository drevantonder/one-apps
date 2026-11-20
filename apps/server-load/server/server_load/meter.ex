defmodule ServerLoad.Meter do
  @moduledoc """
  Measures the machine it runs on, with a program of its own: `server/meter/main.rs`, which it builds there and
  starts, or on Windows, which has no Rust compiler, `server/meter/meter.ps1`, which PowerShell runs as it is.

  It holds the running program between calls. Asked for a measurement, it writes the program a line and reads
  the line that comes back.
  """
  use GenServer
  @behaviour OneCore.Service

  @impl OneCore.Service
  def called, do: "Device Activity's meter"

  @impl OneCore.Service
  def os, do: ["linux", "darwin", "win32"]

  @impl OneCore.Service
  def needs,
    do:
      "On Linux or a Mac, Rust's compiler, rustc, on the machine, to build the program that measures it. On Windows, PowerShell, which it has."

  @doc "This machine's processors, its load over the last 1, 5 and 15 minutes, and since when it's measured."
  def now(service), do: GenServer.call(service, :now)

  @impl GenServer
  def init(_), do: {:ok, start(OneCore.Service.folder(self(), "server/meter"))}

  @impl GenServer
  def handle_call(:now, _from, %{program: program} = state) do
    Port.command(program, "now\n")

    receive do
      {^program, {:data, {:eol, line}}} -> {:reply, JSON.decode!(line), state}
      {^program, {:exit_status, status}} -> raise "Its program stopped, with status #{status}"
    end
  end

  # The program stopped by itself, so the service does too, and its server starts both again.
  @impl GenServer
  def handle_info({program, {:exit_status, status}}, %{program: program}) do
    raise "Its program stopped, with status #{status}"
  end

  # A new version of the app. The program carries on through it unless its own source changed, which gives
  # it a new folder: then it's built and started again.
  @impl GenServer
  def code_change(_version, state, _extra) do
    case OneCore.Service.folder(self(), "server/meter") do
      folder when folder == state.folder ->
        {:ok, state}

      folder ->
        Port.close(state.program)
        {:ok, start(folder)}
    end
  end

  # The program reads lines until its input closes, which is when this process ends or closes it. So nothing
  # more is needed to stop it.
  defp start(folder) do
    case :os.type() do
      {:win32, _} ->
        powershell = System.find_executable("powershell") || raise "This machine has no PowerShell to run the meter with"
        script = Path.join(folder, "meter.ps1")
        args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script]
        %{folder: folder, program: Port.open({:spawn_executable, powershell}, [:binary, :exit_status, :hide, args: args, line: 4096])}

      _ ->
        built = Path.join(folder, "meter")
        if not File.exists?(built), do: build(folder, built)
        %{folder: folder, program: Port.open({:spawn_executable, built}, [:binary, :exit_status, line: 4096])}
    end
  end

  # Built under another name and then renamed, so a program that's there is a whole one.
  defp build(folder, built) do
    rustc = System.find_executable("rustc") || raise "This machine has no rustc to build the meter with"
    building = ["--edition", "2021", "-O", "-o", built <> ".building", "main.rs"]

    case System.cmd(rustc, building, cd: folder, stderr_to_stdout: true) do
      {_, 0} -> File.rename!(built <> ".building", built)
      {output, _} -> raise "The meter didn't build:\n" <> output
    end
  end
end
