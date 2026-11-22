defmodule ServerLoad.Meter do
  @moduledoc """
  Measures the machine it runs on, with a program of its own: `server/meter/main.rs`, which it builds there and
  starts, or on Windows, which has no Rust compiler, `server/meter/meter.ps1`, which PowerShell runs as it is.

  It holds the running program between calls. Asked for a measurement, it writes the program a line and reads
  the line that comes back. A program that doesn't answer within a few seconds, as a Windows one whose GPU's driver
  had hung didn't (the Surface, 22 Nov 2026), is killed, and the call fails rather than waiting on it: the next is
  answered by a new one. A new one is asked for a line as it starts, and is ready once it's answered, which a
  PowerShell takes several seconds to; until then a call fails at once, and one that hasn't answered in 30 seconds
  is killed too, with another started only when it's asked for, so a machine where none can start isn't given a new
  one every few seconds.
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
  def now(service) do
    case GenServer.call(service, :now) do
      {:ok, measured} -> measured
      {:error, why} -> raise why
    end
  end

  # How long a program that's ready has to answer, and one that's starting to answer the line it's asked as it starts.
  @answer 3_000
  @start 30_000

  @impl GenServer
  def init(_), do: {:ok, start(OneCore.Service.folder(self(), "server/meter"))}

  @impl GenServer
  def handle_call(:now, _from, %{program: nil} = state), do: {:reply, {:error, "Its meter is starting."}, start(state.folder)}

  def handle_call(:now, _from, %{ready: false} = state) do
    if System.monotonic_time(:millisecond) - state.started < @start do
      {:reply, {:error, "Its meter is starting."}, state}
    else
      kill(state.program)
      {:reply, {:error, "Its meter didn't start within #{div(@start, 1000)} seconds, so it's ended, and a new one starts when it's next asked."}, %{state | program: nil}}
    end
  end

  def handle_call(:now, _from, %{program: program} = state) do
    Port.command(program, "now\n")

    receive do
      {^program, {:data, {:eol, line}}} -> {:reply, {:ok, JSON.decode!(line)}, state}
      {^program, {:exit_status, status}} -> raise "Its program stopped, with status #{status}"
    after
      @answer ->
        kill(program)
        {:reply, {:error, "Its meter didn't answer within #{div(@answer, 1000)} seconds, so it's ended, and a new one starts when it's next asked."}, %{state | program: nil}}
    end
  end

  # The answer to the line a program's asked as it starts: it's ready.
  @impl GenServer
  def handle_info({program, {:data, {:eol, _line}}}, %{program: program, ready: false} = state), do: {:noreply, %{state | ready: true}}

  # The program stopped by itself, so the service does too, and its server starts both again.
  def handle_info({program, {:exit_status, status}}, %{program: program}) do
    raise "Its program stopped, with status #{status}"
  end

  # What a program that was killed said before it ended.
  def handle_info({program, _message}, state) when is_port(program), do: {:noreply, state}

  # A new version of the app. The program carries on through it unless its own source changed, which gives
  # it a new folder: then it's built and started again.
  @impl GenServer
  def code_change(_version, state, _extra) do
    case OneCore.Service.folder(self(), "server/meter") do
      # One started by a version before this one is taken as ready.
      folder when folder == state.folder ->
        {:ok, Map.merge(%{ready: true, started: 0}, state)}

      folder ->
        if state.program, do: kill(state.program)
        {:ok, start(folder)}
    end
  end

  # The program reads lines until its input closes, which is when this process ends or closes it. So nothing
  # more is needed to stop one that answers. It's asked for a line at once, whose answer says it's ready.
  defp start(folder) do
    program =
      case :os.type() do
        {:win32, _} ->
          powershell = System.find_executable("powershell") || raise "This machine has no PowerShell to run the meter with"
          script = Path.join(folder, "meter.ps1")
          args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script]
          Port.open({:spawn_executable, powershell}, [:binary, :exit_status, :hide, args: args, line: 4096])

        _ ->
          built = Path.join(folder, "meter")
          if not File.exists?(built), do: build(folder, built)
          Port.open({:spawn_executable, built}, [:binary, :exit_status, line: 4096])
      end

    Port.command(program, "now\n")
    %{folder: folder, program: program, ready: false, started: System.monotonic_time(:millisecond)}
  end

  # One that doesn't answer may not read its input either, so it's killed, with what it started.
  defp kill(program) do
    with {:os_pid, pid} <- Port.info(program, :os_pid) do
      case :os.type() do
        {:win32, _} -> System.cmd("taskkill", ["/F", "/T", "/PID", "#{pid}"], stderr_to_stdout: true)
        # It leads a process group of its own, as every program a server starts does.
        _ -> System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
      end
    end

    Port.close(program)
  catch
    # It had ended already.
    :error, :badarg -> :ok
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
