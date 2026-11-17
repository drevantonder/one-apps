defmodule WhatsApp.Link do
  @moduledoc """
  Holds WhatsApp links on its machine: each is the program `server/bridge/`, built here with Go, linked to one account
  as WhatsApp Desktop is linked, and run for whoever linked it. The program keeps the link's session in memory only;
  what it sends out is handed to the plugin, which keeps it encrypted (`WhatsApp.store_session/4`), and a link started again,
  here or on another machine, carries on from it. What the program hears, messages and chats, goes to the plugin's
  database as it comes (`WhatsApp.heard/3`), so reading needs no machine but a server.

  Which machine holds each link is the plugin's: on starting, this asks it for the links that are this server's
  (`WhatsApp.here/2`), and `start/3` and `stop/2` move one.

  Linking a phone is in one state at a time, which changes only as `@pairing` says: `starting` (its program asking
  WhatsApp for codes), `pairing` (a QR code, and a code to type, shown), then `linked`, `ran_out` (WhatsApp stopped
  giving codes before the phone scanned one) or `failed`, with why. It's kept once it's over, for the screen to say
  so, until whoever linked starts again. A linked account's link is `connecting`, `connected` or `disconnected`,
  as its program says, and `restarting` when its program stopped by itself: that link alone starts again, from its
  session, a few seconds later, and every other link here carries on.
  """
  use GenServer
  @behaviour OneCore.Service
  require Logger

  # Starting the links this server holds needs the Vault, whose servers may not be up yet when this one starts:
  # links that couldn't start are tried again this long after.
  @again 60_000
  # A link whose program stopped by itself, which is whatsmeow's or WhatsApp's doing, starts again this long after.
  @restart 5_000

  # Linking a phone, by the state it's in and what its program says, as the moduledoc says. What isn't here leaves
  # it as it is, as codes that come after it's over.
  @pairing %{
    {"starting", "codes"} => "pairing",
    {"pairing", "codes"} => "pairing",
    {"starting", "paired"} => "linked",
    {"pairing", "paired"} => "linked",
    {"starting", "ran_out"} => "ran_out",
    {"pairing", "ran_out"} => "ran_out",
    {"starting", "fail"} => "failed",
    {"pairing", "fail"} => "failed"
  }

  @impl OneCore.Service
  def called, do: "WhatsApp's link"

  @impl OneCore.Service
  def needs do
    "Go 1.26 or newer, to build the program that links WhatsApp, and the internet, to reach WhatsApp " <>
      "(web.whatsapp.com, *.whatsapp.net) and to fetch the program's libraries the first time."
  end

  @doc "Starts linking a phone for `who`: the QR code to scan, and given `phone`, the code to type instead."
  def sign_in(service, who, phone), do: unwrap(GenServer.call(service, {:sign_in, who, phone}, 30_000))

  @doc """
  Where linking a phone here for `who` is: its `state`, the QR code and phone code while it's `pairing`, the
  `account` once it's `linked`, and `why` it `failed`. `none` when nothing was started for them since this service
  started.
  """
  def pairing(service, who), do: GenServer.call(service, {:pairing, who})

  @doc "Each link here: its `account` and its `state`, `connecting`, `connected`, `disconnected` or `restarting`."
  def links(service), do: GenServer.call(service, :links)

  @doc "Sends `text` to `to`, a JID, a phone number or a contact's exact name, as `account`."
  def send(service, account, to, text),
    do: unwrap(GenServer.call(service, {:ask, account, %{do: "send", to: to, text: text}}, 30_000))

  @doc "Starts the link of `account` here, for `who`, from the session the plugin keeps."
  def start(service, who, account), do: unwrap(GenServer.call(service, {:start, who, account}, 60_000))

  @doc "Stops the link of `account` here, once its session is kept, so another machine can carry it on."
  def stop(service, account), do: unwrap(GenServer.call(service, {:stop, account}, 60_000))

  @doc "Unlinks `account` from its phone, and stops it here."
  def sign_out(service, account), do: unwrap(GenServer.call(service, {:sign_out, account}, 30_000))

  defp unwrap({:ok, unwrap}), do: unwrap
  defp unwrap({:error, why}), do: raise(why)

  @impl GenServer
  def init(_) do
    if System.find_executable("go") == nil, do: raise("This machine has no Go to build the WhatsApp link with")
    {:ok, %{program: nil, ports: %{}, accounts: %{}, pairing: nil, restarting: %{}, request_id: 0}, {:continue, :build}}
  end

  @impl GenServer
  def handle_continue(:build, state) do
    # Linking a phone under way in the service this one replaces is over: a screen showing it asks again.
    for who <- OneCore.Service.acts_for(), do: tell(who)
    send(self(), :start)
    {:noreply, %{state | program: build(OneCore.Service.folder(self(), "server/bridge"))}}
  end

  # Built under another name and then renamed, so a program that's there is a whole one.
  defp build(folder) do
    built = Path.join(folder, "whatsapp-link")

    if not File.exists?(built) do
      case System.cmd("go", ["build", "-o", built <> ".building", "."], cd: folder, stderr_to_stdout: true) do
        {_, 0} -> File.rename!(built <> ".building", built)
        {output, _} -> raise "The WhatsApp link didn't build:\n" <> output
      end
    end

    built
  end

  @impl GenServer
  def handle_info(:start, state) do
    {state, failed} =
      Enum.reduce(OneCore.Service.acts_for(), {state, false}, fn who, {state, failed} ->
        try do
          here = OneCore.Service.plugin(self(), who, :here, [OneCore.Service.server()])

          state =
            Enum.reduce(here, state, fn %{"account" => account, "session" => session}, state ->
              if Map.has_key?(state.accounts, account), do: state, else: open(state, who, account, session)
            end)

          {state, failed}
        rescue
          error ->
            Logger.warning("WhatsApp: the links of #{who} didn't start here: #{Exception.message(error)}")
            {state, true}
        end
      end)

    if failed, do: Process.send_after(self(), :start, @again)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, part}}}, state) do
    {:noreply, update_in(state.ports[port].buffer, &(&1 <> part))}
  end

  def handle_info({port, {:data, {:eol, part}}}, state) do
    line = state.ports[port].buffer <> part
    state = put_in(state.ports[port].buffer, "")
    {:noreply, handle_event(state, port, JSON.decode!(line))}
  end

  # A program that stopped by itself: linking a phone has failed, or a linked account starts again in a moment, on
  # its own. Every other link carries on.
  def handle_info({port, {:exit_status, status}}, state) when is_map_key(state.ports, port) do
    link = state.ports[port]
    why = "Its program stopped, with status #{status}."
    pairing = pairing?(state, port)
    state = close(state, port, :exited)

    cond do
      pairing ->
        {:noreply, pair(state, "fail", %{why: "WhatsApp's link stopped before the phone linked.\n\n#{why}"})}

      link.account ->
        Logger.warning("WhatsApp: +#{link.account}'s link stopped (#{why}) It starts again in #{div(@restart, 1000)} s.")
        Process.send_after(self(), {:restart, link.account}, @restart)
        tell(link.who)
        {:noreply, put_in(state.restarting[link.account], %{who: link.who, why: why})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:restart, account}, state) do
    case Map.pop(state.restarting, account) do
      {nil, _} ->
        {:noreply, state}

      {%{who: who} = was, restarting} ->
        try do
          session = OneCore.Service.plugin(self(), who, :session, [account])
          {:noreply, open(%{state | restarting: restarting}, who, account, session)}
        rescue
          error ->
            Logger.warning("WhatsApp: +#{account}'s link didn't start again here: #{Exception.message(error)}")
            Process.send_after(self(), {:restart, account}, @again)
            {:noreply, put_in(state.restarting[account], %{was | why: Exception.message(error)})}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:sign_in, who, phone}, from, state) do
    state = if state.pairing && state.pairing.port, do: close(state, state.pairing.port), else: state
    state = open(state, who, nil, "")
    {:noreply, ask(state, state.pairing.port, %{do: "pair", phone: phone || ""}, from)}
  end

  def handle_call({:pairing, who}, _from, %{pairing: %{who: who} = pairing} = state),
    do: {:reply, Map.take(pairing, [:state, :qr, :code, :text, :account, :why]), state}

  def handle_call({:pairing, _who}, _from, state), do: {:reply, %{state: "none"}, state}

  def handle_call(:links, _from, state) do
    running = for {account, port} <- state.accounts, do: %{account: account, state: state.ports[port].state}
    {:reply, running ++ for({account, _} <- state.restarting, do: %{account: account, state: "restarting"}), state}
  end

  def handle_call({:ask, account, command}, from, state) do
    case state.accounts[account] do
      nil -> {:reply, {:error, "+#{account} isn't linked on #{OneCore.Service.name(OneCore.Service.server())}"}, state}
      port -> {:noreply, ask(state, port, command, from)}
    end
  end

  def handle_call({:start, who, account}, _from, state) do
    if Map.has_key?(state.accounts, account) do
      {:reply, {:ok, "started"}, state}
    else
      session = OneCore.Service.plugin(self(), who, :session, [account])
      {:reply, {:ok, "started"}, open(state, who, account, session)}
    end
  end

  # Its session as it is now is kept before it stops: the program is asked for it, and the answer handled as a
  # `session` event is (`heard/3`), then the program is closed.
  def handle_call({:stop, account}, from, state) do
    case state.accounts[account] do
      nil -> {:reply, {:ok, "stopped"}, state}
      port -> {:noreply, ask(state, port, %{do: "session"}, {:closing, from, :keep})}
    end
  end

  def handle_call({:sign_out, account}, from, state) do
    case state.accounts[account] do
      nil -> {:reply, {:error, "+#{account} isn't linked here"}, state}
      port -> {:noreply, ask(state, port, %{do: "logout"}, {:closing, from, :forget})}
    end
  end

  # Starts a link's program, with the session to carry on from: a new link's is empty, and linking a phone starts.
  defp open(state, who, account, session) do
    port = Port.open({:spawn_executable, state.program}, [:binary, :exit_status, line: 1_048_576])
    Port.command(port, JSON.encode!(%{session: session || ""}) <> "\n")
    link = %{who: who, account: account, buffer: "", waiting: %{}, state: "connecting"}
    state = put_in(state.ports[port], link)

    if account do
      put_in(state.accounts[account], port)
    else
      tell(who)
      %{state | pairing: %{who: who, port: port, state: "starting", qr: nil, code: nil, text: nil, account: nil, why: nil}}
    end
  end

  # Stops a link's program, unless it has stopped by itself (`:exited`). Linking a phone that's still under way keeps
  # its state, as what stopped it says what that is.
  defp close(state, port, how \\ :close) do
    if how == :close, do: Port.close(port)
    {link, ports} = Map.pop(state.ports, port)
    for {_id, from} <- link.waiting, do: reply(from, {:error, "The link stopped"})
    pairing = if state.pairing && state.pairing.port == port, do: %{state.pairing | port: nil}, else: state.pairing
    %{state | ports: ports, accounts: Map.reject(state.accounts, fn {_, p} -> p == port end), pairing: pairing}
  end

  # Takes linking a phone one step (`event`, by `@pairing`), with `changes`, and tells its person's apps. Once it's
  # over, its program stops, unless it linked.
  defp pair(state, event, changes) do
    pairing = state.pairing
    to = @pairing[{pairing.state, event}]

    if to do
      state = %{state | pairing: Map.merge(pairing, changes) |> Map.put(:state, to)}
      tell(pairing.who)
      if to in ~w(ran_out failed) and pairing.port, do: close(state, pairing.port), else: state
    else
      state
    end
  end

  # Tells `who`'s apps that something changed here, as a call to the plugin does once it's done.
  defp tell(who) do
    service = self()
    Task.start(fn -> OneCore.Service.plugin(service, who, :changed) end)
  end

  defp ask(state, port, command, from) do
    id = state.request_id + 1
    Port.command(port, JSON.encode!(Map.put(command, :id, id)) <> "\n")
    state = put_in(state.ports[port].waiting[id], from)
    %{state | request_id: id}
  end

  defp reply({:closing, from, _then}, response), do: GenServer.reply(from, response)
  defp reply(from, response), do: GenServer.reply(from, response)

  # What the program says: an answer to what it was asked, or something it heard.
  defp handle_event(state, port, %{"id" => id} = response) do
    {from, state} = pop_in(state.ports[port].waiting[id])
    result = if Map.has_key?(response, "error"), do: {:error, response["error"]}, else: {:ok, response["ok"]}

    case from do
      {:closing, _from, then} ->
        link = state.ports[port]
        if then == :keep and match?({:ok, _}, result), do: keep(link, elem(result, 1))
        reply(from, result)
        close(state, port)

      from ->
        reply(from, result)

        case {pairing?(state, port), result} do
          {true, {:ok, codes}} -> shows(state, codes)
          {true, {:error, why}} -> pair(state, "fail", %{why: why})
          _ -> state
        end
    end
  end

  defp handle_event(state, port, %{"event" => "qr"} = qr),
    do: if(pairing?(state, port), do: shows(state, qr), else: state)

  # WhatsApp stopped giving codes: they ran out, or it said why it wouldn't.
  defp handle_event(state, port, %{"event" => "unpaired"} = unpaired) do
    cond do
      not pairing?(state, port) -> state
      unpaired["ran_out"] -> pair(state, "ran_out", %{qr: nil, code: nil})
      true -> pair(state, "fail", %{qr: nil, code: nil, why: unpaired["why"]})
    end
  end

  defp handle_event(state, port, %{"event" => "paired", "account" => account}) do
    Logger.info("WhatsApp: linked +#{account} here")
    state = put_in(state.ports[port].account, account)
    state = pair(state, "paired", %{account: account, port: nil, qr: nil, code: nil})
    put_in(state.accounts[account], port)
  end

  defp handle_event(state, port, %{"event" => "session", "data" => data}) do
    keep(state.ports[port], data)
    state
  end

  defp handle_event(state, port, %{"event" => event}) when event in ["connected", "disconnected"] do
    link = state.ports[port]
    if link.account, do: tell(link.who)
    put_in(state.ports[port].state, event)
  end

  # The phone, or WhatsApp, unlinked it, or another copy of it connected somewhere else: it stops here, and the
  # plugin keeps which, for the person to see.
  defp handle_event(state, port, %{"event" => event}) when event in ["unlinked", "replaced"] do
    link = state.ports[port]
    Logger.warning("WhatsApp: +#{link.account} was #{event}")
    if link.account, do: OneCore.Service.plugin(self(), link.who, :ended, [link.account, event])
    close(state, port)
  end

  defp handle_event(state, port, event) do
    link = state.ports[port]
    if link.account, do: OneCore.Service.plugin(self(), link.who, :handle_event, [link.account, event])
    state
  end

  defp pairing?(state, port), do: state.pairing != nil and state.pairing.port == port

  # New codes to show: the QR code, drawn as a picture and as text, and the code to type, which comes only once.
  defp shows(state, codes) do
    pairing = state.pairing
    pair(state, "codes", %{qr: codes["png"] || pairing.qr, text: codes["text"] || pairing.text, code: codes["code"] || pairing.code})
  end

  defp keep(link, data) do
    OneCore.Service.plugin(self(), link.who, :store_session, [link.account, OneCore.Service.server(), data])
  rescue
    error -> Logger.warning("WhatsApp: +#{link.account}'s session wasn't kept: #{Exception.message(error)}")
  end
end
