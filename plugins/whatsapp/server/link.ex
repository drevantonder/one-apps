defmodule WhatsApp.Link do
  @moduledoc """
  Holds WhatsApp links on its machine: each is the program `server/bridge/`, built here with Go, linked to one account
  as WhatsApp Desktop is linked, and run for whoever linked it. The program keeps the link's session in memory only;
  what it sends out is handed to the plugin, which keeps it encrypted (`WhatsApp.store_session/4`), and a link started again,
  here or on another machine, carries on from it. What the program hears, messages and chats, goes to the plugin's
  database as it comes (`WhatsApp.heard/3`), so reading needs no machine but a server.

  Which machine holds each link is the plugin's: on starting, this asks it for the links that are this server's
  (`WhatsApp.here/2`), and `start/3` and `stop/2` move one.
  """
  use GenServer
  @behaviour OneCore.Service
  require Logger

  # Starting the links this server holds needs the Vault, whose servers may not be up yet when this one starts:
  # links that couldn't start are tried again this long after.
  @again 60_000

  @impl OneCore.Service
  def called, do: "WhatsApp's link"

  @impl OneCore.Service
  def needs do
    "Go 1.26 or newer, to build the program that links WhatsApp, and the internet, to reach WhatsApp " <>
      "(web.whatsapp.com, *.whatsapp.net) and to fetch the program's libraries the first time."
  end

  @doc "Starts linking a phone for `who`: the QR code to scan, and given `phone`, the code to type instead."
  def sign_in(service, who, phone), do: answer(GenServer.call(service, {:sign_in, who, phone}, 30_000))

  @doc "The QR code and phone code while a phone is linking here, or nothing."
  def pairing(service), do: GenServer.call(service, :pairing)

  @doc "Each link here: its `account` and whether it's `connected`."
  def links(service), do: GenServer.call(service, :links)

  @doc "Sends `text` to `to`, a JID, a phone number or a contact's exact name, as `account`."
  def send(service, account, to, text),
    do: answer(GenServer.call(service, {:ask, account, %{do: "send", to: to, text: text}}, 30_000))

  @doc "Starts the link of `account` here, for `who`, from the session the plugin keeps."
  def start(service, who, account), do: answer(GenServer.call(service, {:start, who, account}, 60_000))

  @doc "Stops the link of `account` here, once its session is kept, so another machine can carry it on."
  def stop(service, account), do: answer(GenServer.call(service, {:stop, account}, 60_000))

  @doc "Unlinks `account` from its phone, and stops it here."
  def sign_out(service, account), do: answer(GenServer.call(service, {:sign_out, account}, 30_000))

  defp answer({:ok, answer}), do: answer
  defp answer({:error, why}), do: raise(why)

  @impl GenServer
  def init(_) do
    if System.find_executable("go") == nil, do: raise("This machine has no Go to build the WhatsApp link with")
    {:ok, %{program: nil, ports: %{}, accounts: %{}, pairing: nil, request_id: 0}, {:continue, :build}}
  end

  @impl GenServer
  def handle_continue(:build, state) do
    send(self(), :start)
    {:noreply, %{state | program: build(OneCore.Service.folder(self(), "server/bridge"))}}
  end

  # Built under another name and then renamed, so a program that's there is a whole one.
  defp build(folder) do
    built = Path.join(folder, "whatsapp-link")

    if not File.exists?(built) do
      case System.cmd("go", ["build", "-o", built <> ".building", "."], cd: folder, stderr_to_stdout: true) do
        {_, 0} -> File.rename!(built <> ".building", built)
        {said, _} -> raise "The WhatsApp link didn't build:\n" <> said
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

  # A program that stopped by itself stops the service too, and its server starts the service again, which
  # starts the links again.
  def handle_info({port, {:exit_status, status}}, state) when is_map_key(state.ports, port) do
    raise "A WhatsApp link's program stopped, with status #{status}"
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:sign_in, who, phone}, from, state) do
    state = if state.pairing, do: close(state, state.pairing), else: state
    state = open(state, who, nil, "")
    port = state.pairing
    {:noreply, ask(state, port, %{do: "pair", phone: phone || ""}, from)}
  end

  def handle_call(:pairing, _from, %{pairing: nil} = state), do: {:reply, %{}, state}

  def handle_call(:pairing, _from, state) do
    link = state.ports[state.pairing]
    {:reply, Map.take(link, [:qr, :code, :why]), state}
  end

  def handle_call(:links, _from, state) do
    {:reply, for({account, port} <- state.accounts, do: %{account: account, connected: state.ports[port].connected}),
     state}
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

  # Starts a link's program, with the session to carry on from: a new link's is empty.
  defp open(state, who, account, session) do
    port = Port.open({:spawn_executable, state.program}, [:binary, :exit_status, line: 1_048_576])
    Port.command(port, JSON.encode!(%{session: session || ""}) <> "\n")
    link = %{who: who, account: account, buffer: "", waiting: %{}, connected: false, qr: nil, code: nil, why: nil}
    state = put_in(state.ports[port], link)
    if account, do: put_in(state.accounts[account], port), else: %{state | pairing: port}
  end

  defp close(state, port) do
    Port.close(port)
    {link, ports} = Map.pop(state.ports, port)
    for {_id, from} <- link.waiting, do: reply(from, {:error, "The link stopped"})

    %{
      state
      | ports: ports,
        accounts: Map.reject(state.accounts, fn {_, p} -> p == port end),
        pairing: if(state.pairing == port, do: nil, else: state.pairing)
    }
  end

  defp ask(state, port, command, from) do
    id = state.request_id + 1
    Port.command(port, JSON.encode!(Map.put(command, :id, id)) <> "\n")
    state = put_in(state.ports[port].waiting[id], from)
    %{state | request_id: id}
  end

  defp reply({:closing, from, _then}, answer), do: GenServer.reply(from, answer)
  defp reply(from, answer), do: GenServer.reply(from, answer)

  # What the program says: an answer to what it was asked, or something it heard.
  defp handle_event(state, port, %{"id" => id} = answer) do
    {from, state} = pop_in(state.ports[port].waiting[id])
    said = if Map.has_key?(answer, "error"), do: {:error, answer["error"]}, else: {:ok, answer["ok"]}

    case from do
      {:closing, _from, then} ->
        link = state.ports[port]
        if then == :keep and match?({:ok, _}, said), do: keep(link, elem(said, 1))
        reply(from, said)
        close(state, port)

      from ->
        reply(from, said)
        if state.pairing == port and match?({:ok, _}, said), do: shows(state, port, elem(said, 1)), else: state
    end
  end

  defp handle_event(state, port, %{"event" => "qr"} = qr), do: shows(state, port, qr)

  defp handle_event(state, port, %{"event" => "unpaired", "why" => why}) do
    state = put_in(state.ports[port].why, why)
    put_in(state.ports[port].qr, nil)
  end

  defp handle_event(state, port, %{"event" => "paired", "account" => account}) do
    Logger.info("WhatsApp: linked +#{account} here")
    state = put_in(state.ports[port].account, account)
    state = %{state | pairing: nil}
    put_in(state.accounts[account], port)
  end

  defp handle_event(state, port, %{"event" => "session", "data" => data}) do
    keep(state.ports[port], data)
    state
  end

  defp handle_event(state, port, %{"event" => event}) when event in ["connected", "disconnected"] do
    put_in(state.ports[port].connected, event == "connected")
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

  defp shows(state, port, qr) do
    link = %{state.ports[port] | qr: qr["png"] || state.ports[port].qr, why: nil}
    link = if qr["code"], do: %{link | code: qr["code"]}, else: link
    put_in(state.ports[port], Map.put(link, :text, qr["text"]))
  end

  defp keep(link, data) do
    OneCore.Service.plugin(self(), link.who, :store_session, [link.account, OneCore.Service.server(), data])
  rescue
    error -> Logger.warning("WhatsApp: +#{link.account}'s session wasn't kept: #{Exception.message(error)}")
  end
end
