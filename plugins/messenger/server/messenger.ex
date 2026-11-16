defmodule Messenger do
  @moduledoc """
  Messenger: the user's Facebook Messenger, read and sent through messenger.com in a browser that the service
  `Messenger.Browser` holds on a machine of theirs. Each account is a sign-in to messenger.com, named by its person
  (Personal, Work).

  An account's session, its browser's cookies, local storage and IndexedDB, never touches a disk: it's kept as the
  blob `sessions/<account>` of this plugin's own artifact, encrypted with AES-256-GCM under a key that is the
  Vault item `Messenger <account>`, and only a server chosen to open its person's Vault opens it. Which accounts
  there are, and why one needs signing in again, are rows of this plugin's database.
  """
  @behaviour OneCore.Plugin
  alias Messenger.Browser

  @schema ["create table accounts (name text primary key, why text, at integer not null)"]

  @account %{
    type: "string",
    description: "which account, by the name it was signed in as, as messenger_accounts lists them; default the first"
  }
  @chat "the chat: its name as messenger_chats gives it, or a part of it only one recent chat has"

  @impl true
  def uses, do: ["database", "vault"]

  # Its page signs an account in, as sign_in's own: it's in Accounts, not an app on a page.
  @impl true
  def title, do: "Messenger"

  @impl true
  def icon, do: "icon.png"

  @impl true
  def tools do
    [
      %{
        name: "accounts",
        read_only: true,
        description:
          "The Messenger accounts signed in, the default first: each { account, ok }, with why when ok is false and it needs signing in again. Give account to the others to pick one.",
        inputs: %{type: "object", properties: %{}}
      },
      %{
        name: "devices",
        read_only: true,
        description: "Your devices that run Messenger's browser, by name: where an account can be signed in.",
        inputs: %{type: "object", properties: %{}}
      },
      %{
        name: "chats",
        read_only: true,
        description:
          ~s|The recent Messenger chats messenger.com shows, newest first, to see what's new or find a chat to read: one a line, "Sam (unread), <time>: last message", the time as Messenger shows it. Older chats aren't reached. Takes some seconds: a browser reads it.|,
        inputs: %{
          type: "object",
          properties: %{account: @account, unread: %{type: "boolean", description: "only chats with unread messages"}}
        }
      },
      %{
        name: "read",
        description:
          ~s|A recent chat's latest messages, as messenger.com shows them when it opens, newest last: one a line, "[time] Sam: text", the time as Messenger shows it. Opening a chat marks it read, so one that was unread is marked unread again afterwards, but the sender may see it as seen.|,
        inputs: %{
          type: "object",
          required: ["chat"],
          properties: %{account: @account, chat: %{type: "string", description: @chat}}
        }
      },
      %{
        name: "search",
        read_only: true,
        description:
          ~s|Messages containing some words, across every chat, as Messenger's search finds them: to find something said when you don't know which chat. One a line: the chat and the message when it has one match ("Sam, <time>: text"), or how many ("Family: 3 matching messages"), for messenger_read.|,
        inputs: %{
          type: "object",
          required: ["query"],
          properties: %{
            account: @account,
            query: %{type: "string", description: "words to find, as you'd type them in Messenger's search"}
          }
        }
      },
      %{
        name: "send",
        description:
          "Send a Messenger message, as the user, to a recent chat or to someone by their exact name. It sends a real message to a real person and can't be taken back: only what the user asked to send, to whom they asked. Says to whom it went.",
        inputs: %{
          type: "object",
          required: ["chat", "text"],
          properties: %{
            account: @account,
            chat: %{type: "string", description: @chat <> "; or anyone else by their exact name, as Messenger shows it"},
            text: %{type: "string", description: "the message, exactly as the user approved it"}
          }
        }
      },
      %{
        name: "sign_in",
        ui: "client/index.html",
        description:
          "For the user: opens a browser window on one of their devices at messenger.com, for them to sign in there themselves; never sign in for them. It's kept once their chats show. Signs the first account in again when none is given.",
        inputs: %{
          type: "object",
          properties: %{
            account: %{type: "string", description: "a name for the account, like Personal or Work"},
            device: %{
              type: "string",
              description:
                "the device whose screen they'll sign in at, by name, as messenger_devices lists them; default the first"
            }
          }
        }
      },
      %{
        name: "sign_out",
        description:
          "Stop reading an account: its session is deleted here. Messenger itself isn't told, so the user signs that browser out in Facebook's settings if they want it gone there too.",
        inputs: %{
          type: "object",
          required: ["account"],
          properties: %{account: %{type: "string", description: "the account's name, as messenger_accounts lists them"}}
        }
      }
    ]
  end

  @impl true
  def call("accounts", _inputs, call) do
    for a <- transaction(call, &query(&1, "select * from accounts order by rowid")) do
      if a["why"],
        do: %{account: a["name"], ok: false, why: a["why"]},
        else: %{account: a["name"], ok: true}
    end
  end

  def call("devices", _inputs, call), do: Enum.map(OneCore.Service.servers(call, Browser), &OneCore.Service.name/1)

  def call("chats", inputs, call), do: browse(call, inputs, %{"do" => "chats", "unread" => inputs["unread"] == true})
  def call("read", inputs, call), do: browse(call, inputs, %{"do" => "read", "chat" => inputs["chat"]})
  def call("search", inputs, call), do: browse(call, inputs, %{"do" => "search", "query" => inputs["query"]})

  def call("send", inputs, call),
    do: browse(call, inputs, %{"do" => "send", "chat" => inputs["chat"], "text" => inputs["text"]})

  def call("sign_in", inputs, call) do
    account =
      case String.trim(inputs["account"] || "") do
        "" ->
          transaction(
            call,
            &(List.first(query(&1, "select name from accounts order by rowid")) || %{"name" => "Personal"})
          )["name"]

        name ->
          name
      end

    server = device(call, inputs["device"])
    response = OneCore.Service.call(call, Browser, :sign_in, [call.subject, account], server)
    if response["error"], do: raise(response["error"])

    "A browser window opened on #{OneCore.Service.name(server)}, at messenger.com: the user signs in there as #{account}, " <>
      "and ticks Keep me signed in. It's kept as soon as their chats show, and the window closes."
  end

  def call("sign_out", %{"account" => want}, call) do
    account = transaction(call, &account!(&1, want))

    for server <- OneCore.Service.servers(call, Browser) do
      try do
        OneCore.Service.call(call, Browser, :close, [account], server)
      rescue
        _ -> :not_up
      end
    end

    OneCore.Call.plugin(call, "vault").remove(call, item(account))
    OneCore.Artifact.remove(call.own, "sessions/#{account}")
    transaction(call, &query(&1, "delete from accounts where name = ?", [account]))
    "Messenger no longer reads #{account}, and its session is deleted."
  end

  # Runs a command of the browser's on an account. One that Messenger signed out is kept as needing signing in:
  # a read says so as its answer, and a send fails.
  defp browse(call, inputs, command) do
    account = transaction(call, &account!(&1, inputs["account"]))

    running!(call)

    case OneCore.Service.call(call, Browser, :run, [call.subject, account, command]) do
      %{"ok" => response} ->
        transaction(call, &query(&1, "update accounts set why = null where name = ? and why is not null", [account]))
        response

      %{"code" => "signed_out", "error" => why} ->
        transaction(
          call,
          &query(&1, "update accounts set why = ? where name = ?", ["Messenger signed it out: sign in again", account])
        )

        if command["do"] == "send", do: raise(why), else: why

      %{"error" => why} ->
        raise why
    end
  end

  @doc false
  # An account's session, to open its browser from, or nil when there's none.
  def session(call, account) do
    key = Base.decode64!(OneCore.Call.plugin(call, "vault").value(call, item(account), "key"))

    case OneCore.Artifact.read(call.own, "sessions/#{account}") do
      {:ok, <<iv::binary-12, tag::binary-16, sealed::binary>>, _tag} ->
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, sealed, account, tag, false)
        |> then(&if(&1 == :error, do: nil, else: &1))

      :absent ->
        nil
    end
  end

  @doc false
  # Keeps an account's session, encrypted under its key in the Vault. Signing in makes the account, with a new key.
  def store_session(call, account, data, signed_in) do
    vault = OneCore.Call.plugin(call, "vault")

    key =
      if signed_in do
        made = :crypto.strong_rand_bytes(32)
        vault.keep(call, item(account), %{"key" => Base.encode64(made)})
        made
      else
        Base.decode64!(vault.value(call, item(account), "key"))
      end

    iv = :crypto.strong_rand_bytes(12)
    {sealed, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, data, account, true)
    put(call.own, "sessions/#{account}", iv <> tag <> sealed)

    if signed_in do
      transaction(call, fn db ->
        query(
          db,
          "insert into accounts (name, at) values (?, ?) on conflict (name) do update set why = null, at = excluded.at",
          [account, System.os_time(:second)]
        )
      end)
    end

    :ok
  end

  defp account!(db, want) do
    names = for %{"name" => n} <- query(db, "select name from accounts order by rowid"), do: n

    cond do
      names == [] ->
        raise "Messenger isn't signed in yet: messenger_sign_in opens a window to sign in at"

      want in [nil, ""] ->
        hd(names)

      true ->
        Enum.find(names, &(String.downcase(&1) == String.downcase(want))) ||
          raise("No Messenger account called #{want}: it's #{Enum.join(names, ", ")}")
    end
  end

  # The servers that run the browser. A command goes to this one if it does, else the first that's up.
  defp running!(call) do
    with [] <- OneCore.Service.servers(call, Browser),
         do:
           raise(
             "Messenger's browser isn't on any of your devices yet: install_service --plugin messenger --service Messenger.Browser runs it on one."
           )
  end

  defp device(call, name) do
    servers = running!(call)

    if name in [nil, ""],
      do: hd(servers),
      else:
        Enum.find(servers, &(String.downcase(OneCore.Service.name(&1) || "") == String.downcase(name))) ||
          raise(
            "No device called #{name} runs Messenger's browser. It's on #{Enum.map_join(servers, ", ", &OneCore.Service.name/1)}."
          )
  end

  defp item(account), do: "Messenger #{account}"

  # A blob replaced whole, whatever was there.
  defp put(artifact, name, data) do
    case OneCore.Artifact.read(artifact, name) do
      :absent ->
        if OneCore.Artifact.write(artifact, name, data) == :ok, do: :ok, else: put(artifact, name, data)

      {:ok, _, tag} ->
        if OneCore.Artifact.replace(artifact, name, data, tag) == :ok, do: :ok, else: put(artifact, name, data)
    end
  end

  defp transaction(call, fun) do
    database = OneCore.Call.plugin(call, "database")
    database.transaction(call, @schema, &fun.({database, &1}))
  end

  defp query({database, db}, sql, values \\ []), do: database.query(db, sql, values)
end
