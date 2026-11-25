defmodule WhatsApp do
  @moduledoc """
  WhatsApp: the user's WhatsApp accounts, each a phone linked as WhatsApp Desktop is linked, held on one machine
  of theirs at a time by the service `WhatsApp.Link`.

  What's kept where:

  - Messages and chats, as the link hears them, are rows of this app's database for whoever linked it, so
    reading and searching need no machine but a server.
  - The link's session, whatsmeow's own database, never touches a disk: its program sends it out, and it's kept
    as the blob `sessions/<number>` of this app's own artifact, encrypted with AES-256-GCM under a key that is
    the Vault item `WhatsApp +<number>`. Only a server chosen to open its person's Vault can start the link again.
  - Which machine holds each link is the row of `links`: a link is started only where that says, so it's never
    connected from two machines, and `move` changes it.
  """
  @behaviour OneCore.App
  alias WhatsApp.Link

  @schema [
    "create table links (account text primary key, server text not null, state text, at integer)",
    """
    create table chats (
      account text not null, jid text not null, name text not null default '', unread integer not null default 0,
      last integer not null default 0, primary key (account, jid)
    ) without rowid
    """,
    """
    create table messages (
      account text not null, chat text not null, id text not null, sender text not null,
      sender_name text not null default '', from_me integer not null, time integer not null, text text not null,
      primary key (account, chat, id)
    )
    """,
    "create index messages_by_chat on messages (account, chat, time)",
    "create index messages_by_time on messages (account, time)"
  ]

  @account %{
    type: "string",
    description: "which WhatsApp account: its number, as whatsapp_accounts lists them; default the first"
  }
  @chat "the chat: its name as whatsapp_chats gives it, or a part of it only one chat has; or a phone number with its country code (+61 400 000 000), or a JID (61400000000@s.whatsapp.net)"
  @device %{
    type: "string",
    description:
      "which of your devices that run WhatsApp to link it on, by name, as whatsapp_devices lists them; default the first"
  }
  @limit %{type: "integer", description: "at most this many; default 30"}
  @time %{type: "integer", description: "When, in milliseconds since 1970"}
  @message %{
    type: "object",
    properties: %{
      time: @time,
      from: %{type: "string", description: "Who sent it, or You for the user"},
      chat: %{type: "string", description: "With search: the chat it's in"},
      text: %{type: "string"}
    },
    required: ["time", "from", "text"]
  }
  @devices %{
    type: "object",
    properties: %{devices: %{type: "array", items: %{type: ["string", "null"]}}},
    required: ["devices"]
  }
  @codes %{
    qr: %{type: "string", description: "The QR code to scan on the phone, drawn in text"},
    code: %{type: ["string", "null"], description: "The code to type on the phone instead, given phone"}
  }
  @link_states ~w(connecting connected disconnected restarting unreachable unlinked replaced)

  @impl true
  def requires do
    %{
      "core" => ">= 0.34.593",
      "database" => "to keep your messages",
      "vault" => "to keep your WhatsApp sign-in"
    }
  end

  # Its page links a phone, as sign_in's own: it's under Accounts in the Vault, not an app on a page.
  @impl true
  def icon, do: "icon.png"

  # Each account is an item in its person's Vault, "WhatsApp <account>", which the Vault lists under Accounts.
  @impl true
  def hooks, do: ["vault.types"]

  @impl true
  def hook("vault.types", _about, _call),
    do: [%{name: "WhatsApp account", section: "Accounts", prefix: "WhatsApp ", create: %{page: "client/sign-in.html"}}]

  @impl true
  def tools do
    [
      %{
        name: "accounts",
        read_only: true,
        description:
          "The WhatsApp accounts linked on any of your devices: each one's number, where it's linked, and why it isn't connected when it isn't. Give account to the others to pick one.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{
            accounts: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  account: %{type: "string", description: "Its number, +61..."},
                  ok: %{type: "boolean", description: "Whether it's connected, or connecting by itself"},
                  state: %{type: "string", enum: @link_states, description: "Where its link is"},
                  device: %{type: "string", description: "Where it's linked"},
                  why: %{type: "string", description: "Why it isn't connected"},
                  since: %{type: "integer", description: "Since when it isn't, where that's known, in milliseconds since 1970"}
                },
                required: ["account", "ok", "state", "device"]
              }
            }
          },
          required: ["accounts"]
        }
      },
      %{
        name: "account",
        read_only: true,
        ui: "client/sign-in.html",
        path: "{account}",
        runtime_version: 5,
        description:
          "One WhatsApp account, by its number as `accounts` lists it: where it's linked and why it isn't connected, when it isn't. It's the Vault's screen of it, where it's signed out of; null once it's gone.",
        inputs: %{
          type: "object",
          required: ["account"],
          properties: %{account: %{type: "string", description: "Its number, +61..."}}
        },
        outputs: %{
          type: "object",
          properties: %{
            account: %{
              type: ["object", "null"],
              properties: %{
                account: %{type: "string", description: "Its number, +61..."},
                ok: %{type: "boolean", description: "Whether it's connected, or connecting by itself"},
                state: %{type: "string", enum: @link_states, description: "Where its link is"},
                device: %{type: "string", description: "Where it's linked"},
                why: %{type: "string", description: "Why it isn't connected"},
                since: %{type: "integer", description: "Since when it isn't, where that's known, in milliseconds since 1970"}
              }
            }
          },
          required: ["account"]
        }
      },
      %{
        name: "status",
        read_only: true,
        description:
          "Whether each WhatsApp account is linked and connected, on which device, and how many messages are kept. For why chats are missing.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{
            accounts: %{
              type: "array",
              description: "Empty when none is linked: whatsapp_sign_in links one",
              items: %{
                type: "object",
                properties: %{
                  account: %{type: "string", description: "Its number, +61..."},
                  device: %{type: "string", description: "Where it's linked"},
                  connected: %{type: "boolean"},
                  state: %{type: "string", enum: @link_states, description: "Where its link is"},
                  why: %{type: ["string", "null"], description: "Why it isn't connected"},
                  since: %{type: "integer", description: "Since when it isn't, where that's known, in milliseconds since 1970"},
                  messages: %{type: "integer", description: "How many messages are kept"},
                  chats: %{type: "integer", description: "In how many chats"}
                },
                required: ["account", "device", "connected", "state", "why", "messages", "chats"]
              }
            }
          },
          required: ["accounts"]
        }
      },
      %{
        name: "devices",
        read_only: true,
        description: "Your devices that run WhatsApp, by name: where a phone can be linked, or a link moved to.",
        inputs: %{type: "object", properties: %{}},
        outputs: @devices
      },
      %{
        name: "sign_in",
        ui: "client/sign-in.html",
        runtime_version: 5,
        description:
          "For the user: link a WhatsApp account to one of their devices, as WhatsApp Desktop is linked. Gives a QR code to scan on their phone (WhatsApp > Settings > Linked devices > Link a device) and, given phone, a code to type there instead (Link with phone number instead), for when the QR code shows on the phone itself. Chats arrive over the next few minutes.",
        inputs: %{
          type: "object",
          properties: %{
            phone: %{
              type: "string",
              description:
                "the account's number with its country code, like +61 400 000 000, for a code to type on the phone"
            },
            device: @device
          }
        },
        outputs: %{
          type: "object",
          properties:
            Map.put(@codes, :how, %{type: "string", description: "What to tell the user to do with them, on their phone"}),
          required: ["qr", "code", "how"]
        }
      },
      %{
        name: "pairing",
        read_only: true,
        description:
          "Where linking a phone that sign_in started is, for the screen: starting, pairing (with the codes), linked (with its account), ran_out (the codes ran out before the phone scanned one), failed (with why), or none (nothing started there since its link last started).",
        inputs: %{type: "object", properties: %{device: @device}},
        outputs: %{
          type: "object",
          properties: %{
            state: %{type: "string", enum: ~w(none starting pairing linked ran_out failed)},
            qr: %{type: ["string", "null"], description: "While pairing: the QR code to scan, as a PNG data URL"},
            text: %{type: ["string", "null"], description: "While pairing: the QR code, drawn in text"},
            code: %{type: ["string", "null"], description: "While pairing, given phone: the code to type on the phone instead"},
            account: %{type: ["string", "null"], description: "Once linked: its number"},
            why: %{type: ["string", "null"], description: "Why it failed"}
          },
          required: ["state"]
        }
      },
      %{
        name: "chats",
        read_only: true,
        description:
          "Recent WhatsApp chats, most recent first, to see what's new or unread, or find a chat to read, each with its last message. None yet just after linking: WhatsApp takes a few minutes to send them. Page back with skip.",
        inputs: %{
          type: "object",
          properties: %{
            account: @account,
            unread: %{type: "boolean", description: "only chats with unread messages"},
            limit: @limit,
            skip: %{
              type: "integer",
              description: "leave out this many of the most recent, to page back: 30 for the second page of 30"
            }
          }
        },
        outputs: %{
          type: "object",
          properties: %{
            chats: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  chat: %{type: "string", description: "Its name"},
                  jid: %{type: "string", description: "Its JID"},
                  unread: %{type: "integer", description: "How many are unread"},
                  last: @message
                },
                required: ["chat", "jid", "unread", "last"]
              }
            }
          },
          required: ["chats"]
        }
      },
      %{
        name: "read",
        read_only: true,
        description:
          "One WhatsApp chat's messages, newest last. WhatsApp isn't told they were read: the sender sees no blue ticks, and the chat stays unread on the phone. Page back with skip.",
        inputs: %{
          type: "object",
          required: ["chat"],
          properties: %{
            account: @account,
            chat: %{type: "string", description: @chat},
            limit: @limit,
            skip: %{
              type: "integer",
              description: "leave out this many of the newest, to read further back: 30 for the 30 before the latest 30"
            }
          }
        },
        outputs: %{
          type: "object",
          properties: %{chat: %{type: "string", description: "Its name"}, messages: %{type: "array", items: @message}},
          required: ["chat", "messages"]
        }
      },
      %{
        name: "search",
        read_only: true,
        description:
          "WhatsApp messages containing some text, across every chat or in one, newest last, each with its chat: to find something said when you don't know which chat. Page back with skip.",
        inputs: %{
          type: "object",
          required: ["query"],
          properties: %{
            account: @account,
            query: %{type: "string", description: "text to look for, any case"},
            chat: %{type: "string", description: "only in this chat: " <> @chat},
            limit: @limit,
            skip: %{type: "integer", description: "leave out this many of the newest matches, to page back"}
          }
        },
        outputs: %{type: "object", properties: %{messages: %{type: "array", items: @message}}, required: ["messages"]}
      },
      %{
        name: "send",
        description:
          "Send a WhatsApp message, as the linked account, to a chat, a contact or a phone number. It sends a real message to a real person and can't be taken back: only what the user asked to send, to whom they asked. Says to whom it went.",
        inputs: %{
          type: "object",
          required: ["chat", "text"],
          properties: %{
            account: @account,
            chat: %{type: "string", description: @chat <> "; or a contact's exact name, for someone with no chat yet"},
            text: %{type: "string", description: "the message, exactly as the user approved it"}
          }
        },
        outputs: %{
          type: "object",
          properties: %{to: %{type: "string", description: "Whom it went to, by name"}},
          required: ["to"]
        }
      },
      %{
        name: "move",
        description:
          "Move a WhatsApp link to another of your devices that runs WhatsApp, without linking again: the phone's Linked devices list doesn't change, and its messages stay. Works when the device it's on is off. Says where it went.",
        inputs: %{
          type: "object",
          required: ["to"],
          properties: %{
            account: @account,
            to: %{type: "string", description: "the device to move it to, by its name as whatsapp_devices lists it"}
          }
        },
        outputs: %{
          type: "object",
          properties: %{
            account: %{type: "string", description: "Its number, +61..."},
            device: %{type: ["string", "null"], description: "Where it is now"},
            stopped: %{
              type: "boolean",
              description: "Whether it stopped where it was; one that wasn't up won't start it again there"
            }
          },
          required: ["account", "device", "stopped"]
        }
      },
      %{
        name: "sign_out",
        description:
          "Unlink a WhatsApp account: removes it from the phone's linked devices and deletes its messages kept here. It can't be undone: linking again needs the phone, and the deleted messages don't come back. Only when the user asks to sign out.",
        inputs: %{
          type: "object",
          properties: %{
            account: %{
              type: "string",
              description: "the account's number, as whatsapp_accounts lists them; needed when several are linked"
            }
          }
        },
        outputs: %{
          type: "object",
          properties: %{account: %{type: "string", description: "The number it signed out of, +61..."}},
          required: ["account"]
        }
      }
    ]
  end

  @impl true
  def call("accounts", _inputs, call), do: %{accounts: accounts(call)}

  def call("account", %{"account" => account}, call),
    do: %{account: Enum.find(accounts(call), &(&1.account == account))}

  def call("status", _inputs, call) do
    {links, counts} =
      transaction(call, fn db ->
        {query(db, "select * from links order by rowid"),
         Map.new(
           query(
             db,
             "select account, count(*) as messages, count(distinct chat) as chats from messages group by account"
           ),
           &{&1["account"], &1}
         )}
      end)

    live = live(call, links)

    accounts =
      for link <- links do
        device = OneCore.Service.name(link["server"]) || "a device"
        count = counts[link["account"]] || %{"messages" => 0, "chats" => 0}

        Map.merge(how(link, live, device), %{
          account: "+" <> link["account"],
          device: device,
          messages: count["messages"],
          chats: count["chats"]
        })
      end

    %{accounts: accounts}
  end

  def call("devices", _inputs, call), do: %{devices: Enum.map(running(call), &OneCore.Service.name/1)}

  def call("sign_in", inputs, call) do
    phone = inputs["phone"] && pairing_phone(inputs["phone"])
    linked = OneCore.Service.call(call, Link, :sign_in, [call.subject, phone], device(call, inputs["device"]))

    how =
      "On the phone, open WhatsApp > Settings > Linked devices > Link a device, and scan this within 20 seconds (sign_in again for a new one)."

    how =
      if linked["code"],
        do: "#{how} Or tap Link with phone number instead and type #{linked["code"]} within 2 minutes.",
        else: "#{how} If this is on the phone itself, sign_in with phone instead, for a code to type there."

    %{qr: linked["text"], code: linked["code"], how: how <> " WhatsApp then sends recent chats, which takes a few minutes."}
  end

  def call("pairing", inputs, call) do
    pairing = OneCore.Service.call(call, Link, :pairing, [call.subject], device(call, inputs["device"]))
    Map.update(pairing, "account", nil, &(&1 && "+" <> &1))
  end

  def call("chats", inputs, call) do
    {limit, skip} = page(inputs)

    transaction(call, fn db ->
      account = account!(db, inputs["account"])

      rows =
        query(
          db,
          """
          select c.jid, c.name, c.unread, m.sender, m.sender_name, m.from_me, m.time, m.text from chats c
          join messages m on m.rowid = (select rowid from messages where account = c.account and chat = c.jid order by time desc, rowid desc limit 1)
          where c.account = ? and (? = 0 or c.unread > 0) order by m.time desc limit ? offset ?
          """,
          [account, if(inputs["unread"], do: 1, else: 0), limit, skip]
        )

      names = names(db, account)

      chats =
        for r <- rows do
          %{
            chat: name(names, r["jid"], r["name"]),
            jid: r["jid"],
            unread: r["unread"],
            last: message(names, r)
          }
        end

      %{chats: chats}
    end)
  end

  def call("read", %{"chat" => want} = inputs, call) do
    {limit, skip} = page(inputs)

    transaction(call, fn db ->
      account = account!(db, inputs["account"])
      {jid, name} = find!(db, account, want)

      names = names(db, account)
      %{chat: name, messages: for(m <- messages(db, account, jid, nil, limit, skip), do: message(names, m))}
    end)
  end

  def call("search", %{"query" => query} = inputs, call) do
    if String.trim(query) == "", do: raise("give a query")
    {limit, skip} = page(inputs)

    transaction(call, fn db ->
      account = account!(db, inputs["account"])
      jid = if inputs["chat"], do: elem(find!(db, account, inputs["chat"]), 0)

      names = names(db, account)

      messages =
        for m <- messages(db, account, jid, query, limit, skip),
            do: Map.put(message(names, m), :chat, name(names, m["chat"], ""))

      %{messages: messages}
    end)
  end

  def call("send", %{"chat" => to, "text" => text} = inputs, call) do
    if String.trim(text) == "", do: raise("give the text to send")

    {account, server, to} =
      transaction(call, fn db ->
        account = account!(db, inputs["account"])
        link = link!(db, account)

        to =
          case find(db, account, to) do
            {:ok, {jid, _name}} -> jid
            {:error, :none} -> String.trim(to)
            {:error, why} -> raise why
          end

        {account, link["server"], to}
      end)

    sent = OneCore.Service.call(call, Link, :send, [account, to, text], server)
    %{to: sent["name"]}
  end

  def call("move", %{"to" => to} = inputs, call) do
    server = device(call, to)

    {account, from, who} =
      transaction(call, fn db ->
        account = account!(db, inputs["account"])
        link = link!(db, account)
        if link["server"] == server, do: raise("+#{account} is linked on #{OneCore.Service.name(server)} already")
        {account, link["server"], call.subject}
      end)

    # Stopped where it was first, with its session kept, so it's never connected from two machines. A machine
    # that isn't up can't be asked, and won't start it again when it's back: the links say where it is.
    stopped =
      try do
        OneCore.Service.call(call, Link, :stop, [account], from)
        true
      rescue
        _ -> false
      end

    transaction(
      call,
      &query(&1, "update links set server = ?, state = null, at = ? where account = ?", [server, now(), account])
    )

    OneCore.Service.call(call, Link, :start, [who, account], server)
    %{account: "+" <> account, device: OneCore.Service.name(server), stopped: stopped}
  end

  def call("sign_out", inputs, call) do
    link = transaction(call, &link!(&1, account!(&1, inputs["account"], true)))

    if link["state"] == nil do
      try do
        OneCore.Service.call(call, Link, :sign_out, [link["account"]], link["server"])
      rescue
        error -> raise "Not signed out, and nothing deleted: #{Exception.message(error)}"
      end
    end

    forget(call, link["account"])
    transaction(call, &query(&1, "delete from links where account = ?", [link["account"]]))
    %{account: "+" <> link["account"]}
  end

  defp accounts(call) do
    links = transaction(call, &query(&1, "select * from links order by rowid"))
    live = live(call, links)

    for link <- links do
      device = OneCore.Service.name(link["server"]) || "a device"
      %{connected: connected, state: state, why: why} = standing = how(link, live, device)

      # On its way to connected by itself, it needs nothing of its person.
      ok = connected or state in ~w(connecting restarting disconnected)

      %{account: "+" <> link["account"], ok: ok, state: state, device: device}
      |> then(&if(why, do: Map.put(&1, :why, why), else: &1))
      |> then(&if(standing[:since], do: Map.put(&1, :since, standing.since), else: &1))
    end
  end

  @doc false
  # Something about linking changed: every app watching is told. For `WhatsApp.Link`.
  def changed(call), do: OneCore.Call.changed(call)

  @doc false
  # The links this server holds, each with its session to carry on from. For `WhatsApp.Link`.
  def here(call, server) do
    accounts = transaction(call, &query(&1, "select account from links where server = ? and state is null", [server]))
    for %{"account" => account} <- accounts, do: %{account: account, session: session(call, account)}
  end

  @doc false
  # A link's session, as its program sent it out last, for it to carry on from.
  def session(call, account) do
    key = Base.decode64!(vault(call).value(call, item(account), "key"))

    case OneCore.Artifact.read(call.own, "sessions/#{account}") do
      {:ok, <<iv::binary-12, tag::binary-16, sealed::binary>>, _tag} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, sealed, account, tag, false) do
          :error -> raise "+#{account}'s session doesn't open with its key"
          session -> Base.encode64(session)
        end

      :absent ->
        raise "+#{account} has no session kept: link it again"
    end
  end

  @doc false
  # Keeps a link's session, as its program sent it out, encrypted under its key in the Vault: a link that's new
  # gets its key and its row of `links` here.
  def store_session(call, account, server, data) do
    vault = vault(call)

    live =
      transaction(call, fn db ->
        case query(db, "select server from links where account = ? and state is null", [account]) do
          [] ->
            nil

          [%{"server" => ^server}] ->
            :here

          [%{"server" => other}] ->
            raise "+#{account} is linked on #{OneCore.Service.name(other)} already: whatsapp_move moves it"
        end
      end)

    # A link that's new is ready, whatever its account needed of its person before.
    key =
      if live == :here do
        Base.decode64!(vault.value(call, item(account), "key"))
      else
        key = :crypto.strong_rand_bytes(32)
        vault.keep(call, item(account), %{"key" => Base.encode64(key)})
        vault.state(call, item(account), :ready)
        key
      end

    iv = :crypto.strong_rand_bytes(12)
    {sealed, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, Base.decode64!(data), account, true)
    put(call.own, "sessions/#{account}", iv <> tag <> sealed)

    transaction(call, fn db ->
      query(
        db,
        "insert into links (account, server, at) values (?, ?, ?) on conflict (account) do update set server = excluded.server, state = null, at = excluded.at",
        [account, server, now()]
      )
    end)

    :ok
  end

  @doc false
  # What a link heard: messages, chats, names, reads and edits, kept as rows.
  def handle_event(call, account, event) do
    transaction(call, &store_event(&1, account, event))
    :ok
  end

  @doc false
  # A link that ended by itself: unlinked from the phone, whose session is then no use, or replaced by another copy of
  # it, which stops it here. An account unlinked on the phone gets no messages until its person links it again, so
  # its item says so in the Vault, with Sign In, and they're notified: what it kept stays, to carry on from.
  def ended(call, account, how) do
    if how == "unlinked" do
      OneCore.Artifact.remove(call.own, "sessions/#{account}")
      vault(call).state(call, item(account), :needs_action, "Unlinked on your phone", %{label: "Sign In", tool: "account", inputs: %{account: "+" <> account}})

      OneCore.Call.tool(call, "notifications", "send", %{
        "title" => "WhatsApp +#{account} was unlinked",
        "text" => "Its messages stop until you link it again, in Vault.",
        "app" => "vault"
      })
    end

    transaction(call, &query(&1, "update links set state = ?, at = ? where account = ?", [how, now(), account]))
    :ok
  end

  defp forget(call, account) do
    vault(call).remove(call, item(account))
    OneCore.Artifact.remove(call.own, "sessions/#{account}")

    transaction(call, fn db ->
      for table <- ~w(messages chats), do: query(db, "delete from #{table} where account = ?", [account])
    end)
  end

  defp store_event(db, account, %{"event" => "messages", "messages" => messages}) do
    for m <- messages, inserted?(db, account, m) do
      unread = if m["from_me"], do: "0", else: "unread + 1"

      query(
        db,
        "insert into chats (account, jid, name, unread, last) values (?, ?, ?, ?, ?) on conflict (account, jid) do update set last = max(last, excluded.last), unread = #{unread}, name = case when excluded.name = '' then name else excluded.name end",
        [account, m["chat"], m["chat_name"] || "", if(m["from_me"], do: 0, else: 1), m["time"]]
      )
    end
  end

  defp store_event(db, account, %{"event" => "history", "chats" => chats, "messages" => messages}) do
    for c <- chats || [] do
      query(
        db,
        "insert into chats (account, jid, name, unread, last) values (?, ?, ?, ?, ?) on conflict (account, jid) do update set name = case when excluded.name = '' then name else excluded.name end, unread = excluded.unread, last = max(last, excluded.last)",
        [account, c["jid"], c["name"] || "", c["unread"] || 0, c["last"] || 0]
      )
    end

    for m <- messages || [], do: inserted?(db, account, m)
  end

  defp store_event(db, account, %{"event" => "unread", "jid" => jid, "unread" => unread}),
    do: query(db, "update chats set unread = ? where account = ? and jid = ?", [unread, account, jid])

  defp store_event(db, account, %{"event" => "edit", "chat" => chat, "id" => id, "text" => text}),
    do: query(db, "update messages set text = ? where account = ? and chat = ? and id = ?", [text, account, chat, id])

  defp store_event(db, account, %{"event" => "name", "jid" => jid, "name" => name}),
    do:
      query(
        db,
        "insert into chats (account, jid, name) values (?, ?, ?) on conflict (account, jid) do update set name = excluded.name",
        [account, jid, name]
      )

  defp store_event(_db, _account, _event), do: nil

  defp inserted?(db, account, m) do
    query(
      db,
      "insert or ignore into messages (account, chat, id, sender, sender_name, from_me, time, text) values (?, ?, ?, ?, ?, ?, ?, ?) returning id",
      [account, m["chat"], m["id"], m["sender"], m["sender_name"] || "", m["from_me"] == true, m["time"], m["text"]]
    ) != []
  end

  # Where each link stands on the machine holding it, by server: what its service says, or why it couldn't be asked.
  defp live(call, links) do
    for server <- Enum.uniq(for l <- links, l["state"] == nil, do: l["server"]), into: %{} do
      {server,
       try do
         Map.new(OneCore.Service.call(call, Link, :links, [], server), &{&1["account"], &1["state"]})
       rescue
         error -> {:error, Exception.message(error)}
       end}
    end
  end

  defp how(%{"state" => "unlinked", "at" => at}, _live, _device),
    do: %{
      connected: false,
      state: "unlinked",
      since: at * 1000,
      why: "WhatsApp unlinked it, from the phone or by itself, and what was kept is deleted: link it again"
    }

  defp how(%{"state" => "replaced", "at" => at}, _live, device),
    do: %{
      connected: false,
      state: "replaced",
      since: at * 1000,
      why: "Stopped on #{device}, when another copy of this link connected elsewhere: sign it out, and link it again"
    }

  defp how(link, live, device) do
    case live[link["server"]] do
      {:error, _why} ->
        %{connected: false, state: "unreachable", why: "#{device} isn't up, so it isn't connected now"}

      %{} = here ->
        case here[link["account"]] do
          "connected" -> %{connected: true, state: "connected", why: nil}
          "connecting" -> %{connected: false, state: "connecting", why: "Connecting on #{device}"}
          "restarting" -> %{connected: false, state: "restarting", why: "Its link on #{device} stopped, and starts again in a moment"}
          _ -> %{connected: false, state: "disconnected", why: "Not connected on #{device} right now: it reconnects by itself"}
        end
    end
  end

  defp running(call), do: OneCore.Service.servers(call, Link)

  # The server that's the device called `name`, or the first that runs WhatsApp.
  defp device(call, name) do
    servers = running(call)

    cond do
      servers == [] ->
        raise "WhatsApp isn't on any of your devices yet: install_service --app whatsapp --service WhatsApp.Link runs it on one."

      name in [nil, ""] ->
        hd(servers)

      true ->
        Enum.find(servers, &(String.downcase(OneCore.Service.name(&1) || "") == String.downcase(name))) ||
          raise "No device called #{name} runs WhatsApp. It's on #{Enum.map_join(servers, ", ", &OneCore.Service.name/1)}."
    end
  end

  # The account named by its number, or the first linked. With `named`, one must be named when there are several.
  defp account!(db, want, named \\ false) do
    accounts = for %{"account" => a} <- query(db, "select account from links order by rowid"), do: a
    digits = digits(want || "")

    cond do
      accounts == [] ->
        raise "No WhatsApp account is linked: whatsapp_sign_in links one."

      digits == "" and named and length(accounts) > 1 ->
        raise "give account: which of #{Enum.map_join(accounts, ", ", &("+" <> &1))}"

      digits == "" ->
        hd(accounts)

      true ->
        Enum.find(accounts, &(&1 == digits or (String.length(digits) >= 6 and String.ends_with?(&1, digits)))) ||
          raise "No WhatsApp account +#{digits} is linked: whatsapp_accounts lists them."
    end
  end

  defp link!(db, account), do: hd(query(db, "select * from links where account = ?", [account]))

  defp find!(db, account, want) do
    case find(db, account, want) do
      {:ok, found} ->
        found

      {:error, :none} ->
        raise "no chat called #{inspect(String.trim(want))}: whatsapp_chats lists the chats; anyone else by their phone number with its country code"

      {:error, why} ->
        raise why
    end
  end

  # A chat by JID, phone number, name, or a part of a name only one chat has.
  defp find(db, account, want) do
    want = String.trim(want)
    names = names(db, account)

    cond do
      want == "" ->
        {:error, "give a chat"}

      String.contains?(want, "@") ->
        {:ok, {want, name(names, want, "")}}

      want =~ ~r/^\+?[\d\s().-]{7,}$/ ->
        if not String.starts_with?(want, "+") or String.starts_with?(digits(want), "0"),
          do: {:error, "give #{inspect(want)} with its country code, e.g. +61…"},
          else: {:ok, {digits(want) <> "@s.whatsapp.net", name(names, digits(want) <> "@s.whatsapp.net", "")}}

      true ->
        w = String.downcase(want)
        chats = for {jid, name} <- names, name != "", do: {jid, name}

        case Enum.find(chats, fn {_jid, name} -> String.downcase(name) == w end) do
          {jid, name} ->
            {:ok, {jid, name}}

          nil ->
            case Enum.filter(chats, fn {_jid, name} -> String.contains?(String.downcase(name), w) end) do
              [one] ->
                {:ok, one}

              [] ->
                {:error, :none}

              several ->
                {:error,
                 "#{inspect(want)} matches several chats: #{Enum.map_join(several, "; ", &elem(&1, 1))}. Give more of the name, or a phone number with its country code"}
            end
        end
    end
  end

  defp names(db, account),
    do: Map.new(query(db, "select jid, name from chats where account = ?", [account]), &{&1["jid"], &1["name"]})

  # What a person or a group is called: as the chats have them, else as they named themselves, else by number.
  defp name(names, jid, fallback) do
    cond do
      (names[jid] || "") != "" -> names[jid]
      (fallback || "") != "" -> fallback
      String.ends_with?(jid, "@s.whatsapp.net") -> "+" <> hd(String.split(jid, "@"))
      String.ends_with?(jid, "@g.us") -> "a group"
      true -> jid
    end
  end

  defp messages(db, account, jid, text, limit, skip) do
    like = text && "%" <> String.replace(text, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

    query(
      db,
      "select * from messages where account = ? and (? is null or chat = ?) and (? is null or text like ? escape '\\') order by time desc, rowid desc limit ? offset ?",
      [account, jid, jid, like, like, limit, skip]
    )
    |> Enum.reverse()
  end

  # A message as the tools give it: when, from whom (You for the user), and what.
  defp message(names, m) do
    from = if m["from_me"] == 1, do: "You", else: name(names, m["sender"], m["sender_name"])
    %{time: m["time"] * 1000, from: from, text: m["text"]}
  end

  defp page(inputs), do: {max(1, inputs["limit"] || 30), max(0, inputs["skip"] || 0)}

  # A phone number as WhatsApp's pairing wants it: digits only, with its country code.
  defp pairing_phone(number) do
    number = String.trim(number)

    cond do
      not (number =~ ~r/^\+?[\d\s().-]{7,}$/) ->
        raise "#{inspect(number)} isn't a phone number"

      not String.starts_with?(number, "+") or String.starts_with?(digits(number), "0") ->
        raise "give #{inspect(number)} with its country code, e.g. +61…"

      true ->
        digits(number)
    end
  end

  defp digits(text), do: String.replace(text, ~r/\D/, "")
  defp item(account), do: "WhatsApp +#{account}"
  defp vault(call), do: OneCore.Call.app(call, "vault")
  defp now, do: System.os_time(:second)

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
    database = OneCore.Call.app(call, "database")
    database.transaction(call, @schema, &fun.({database, &1}))
  end

  defp query({database, db}, sql, values \\ []), do: database.query(db, sql, values)
end
