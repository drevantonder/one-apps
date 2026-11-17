defmodule StayAwake.Mac do
  @moduledoc """
  Holds its Mac awake while Stay Awake is on: `caffeinate -s` keeps a Mac from sleeping, lid shut or not, and
  macOS honours that only on power, so on battery it sleeps as usual. It's on unless turned off, which it keeps
  in its folder as a file named `off`.

  `caffeinate` holds the Mac for as long as the program it's given runs, here `cat` reading this service's
  output, which closes when this process ends however it ends: so the Mac is never held by a service that's gone.
  """
  use GenServer
  @behaviour OneCore.Service

  @impl OneCore.Service
  def called, do: "Stay Awake on this Mac"

  @impl OneCore.Service
  def needs do
    "A Mac: macOS's caffeinate, which keeps it from sleeping while it's plugged in, and pmset, which says whether it is."
  end

  @doc "Whether Stay Awake is on, whether it's holding the Mac awake now, and whether the Mac is plugged in."
  def status(service), do: GenServer.call(service, :status)

  @doc "Turns Stay Awake on or off, and gives `status/1` after."
  def set(service, on), do: GenServer.call(service, {:set, on})

  @impl GenServer
  def init(_) do
    for program <- ["caffeinate", "pmset"],
        System.find_executable(program) == nil,
        do: raise("This machine has no #{program}: Stay Awake keeps a Mac awake")

    off = Path.join(OneCore.Service.folder(self()), "off")
    {:ok, hold(%{off: off, holding: nil}, not File.exists?(off))}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  def handle_call({:set, on}, _from, state) do
    if on, do: File.rm_rf!(state.off), else: File.write!(state.off, "")
    state = hold(state, on)
    {:reply, status_of(state), state}
  end

  # caffeinate stopped by itself, so the service does too, and its server starts both again.
  @impl GenServer
  def handle_info({holding, {:exit_status, status}}, %{holding: holding}) do
    raise "caffeinate stopped, with status #{status}"
  end

  defp hold(%{holding: nil} = state, true) do
    caffeinate = System.find_executable("caffeinate")
    args = ["-s", System.find_executable("cat")]
    %{state | holding: Port.open({:spawn_executable, caffeinate}, [:binary, :exit_status, args: args])}
  end

  defp hold(%{holding: holding} = state, false) when holding != nil do
    Port.close(holding)
    %{state | holding: nil}
  end

  defp hold(state, _on), do: state

  # pmset's first line names where the power comes from: "Now drawing from 'AC Power'".
  defp status_of(state) do
    {output, _status} = System.cmd(System.find_executable("pmset"), ["-g", "ps"])
    plugged_in = String.contains?(hd(String.split(output, "\n")), "AC Power")
    %{on: not File.exists?(state.off), holding: state.holding != nil, plugged_in: plugged_in}
  end
end
