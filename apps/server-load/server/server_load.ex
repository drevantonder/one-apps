defmodule ServerLoad do
  @moduledoc """
  How busy a network's machines are, each measured by a small program on it, `ServerLoad.Meter`, and whether a device
  is on its charger, as it says with `power`; said in words, and shown as the app Device Activity and its widget.
  """
  @behaviour OneCore.App
  alias ServerLoad.Meter

  @space %{
    type: ["object", "null"],
    properties: %{used: %{type: "integer", description: "In bytes"}, total: %{type: "integer", description: "In bytes"}},
    required: ["used", "total"]
  }
  # Each device's power as it last said, and since when it has been so; and each metered device's last reading.
  @schema [
    "create table power (device text primary key, name text, charging integer not null, since integer not null)",
    "create table readings (server text primary key, at integer not null, reading text not null)"
  ]

  @busy %{type: "array", items: %{type: "integer"}, description: "Percent busy every 5 seconds over the last two minutes, oldest first"}

  @impl true
  def icon, do: "client/icon.svg"

  @impl true
  def requires, do: %{"core" => ">= 0.37.182", "database" => "to keep each device's last reading and whether it's on its charger"}

  @impl true
  def entrypoints, do: [%{page: "client/index.html", runtime_version: 5}]

  @impl true
  def widgets, do: [%{tool: "widget", sizes: ["4x4", "4x2", "2x2"]}]

  @impl true
  def tools do
    [
      %{
        name: "now",
        read_only: true,
        max_age: 5,
        ui: "client/index.html",
        runtime_version: 5,
        description:
          "Every device that's measured, on or not, and how busy each is now: its memory, CPU, GPU and disk space, and the containers it hosts; and whether each device that says so, as a phone does, is on its charger, and since when. Answers at once with each device's last reading and refreshes stale meters in the background. Use it to pick a device or server with room for a desktop, a model or a build, or to know whether someone's phone is charging.",
        inputs: %{
          type: "object",
          properties: %{
            server: %{type: "string", description: "only the device with this server key; default every device"}
          }
        },
        outputs: %{
          type: "object",
          properties: %{
            devices: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  server: %{type: "string", description: "Its server key"},
                  name: %{type: ["string", "null"]},
                  at: %{type: "integer", description: "When this reading was taken, in milliseconds since 1970"},
                  problem: %{type: "string", description: "Why it isn't measured now: off, its meter isn't running on it, or its meter failed"},
                  seen: %{type: "integer", description: "When one that's off was last seen, in milliseconds since 1970"},
                  os: %{type: "string", description: "linux, macos or windows"},
                  processors: %{type: "integer"},
                  load: %{type: "array", items: %{type: "number"}, description: "Load average over 1, 5 and 15 minutes"},
                  container: %{type: "string", description: "If it is a container, its name on its host, which doesn't list it again"},
                  since: %{type: "integer", description: "When it started, in seconds since 1970"},
                  memory: @space,
                  disk: @space,
                  cpu: @busy,
                  gpu: %{@busy | description: "The same of its GPU, if it has one"},
                  containers: %{
                    type: "array",
                    items: %{
                      type: "object",
                      properties: %{
                        name: %{type: "string"},
                        kind: %{type: "string"},
                        memory: Map.put(@space, :description, "A total of 0 has no limit of its own")
                      },
                      required: ["name", "kind", "memory"]
                    }
                  }
                },
                required: ["server", "name"]
              }
            },
            power: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  device: %{type: "string", description: "Its device key"},
                  name: %{type: ["string", "null"]},
                  charging: %{type: "boolean", description: "Whether it's on its charger"},
                  since: %{type: "integer", description: "Since when, in milliseconds since 1970"}
                },
                required: ["device", "name", "charging", "since"]
              }
            }
          },
          required: ["devices", "power"]
        }
      },
      %{
        name: "power",
        changes: ["now"],
        description:
          "Says whether the device calling is on its charger, as the One App on an iPhone does when a Shortcuts automation runs its On Charger as it's plugged in or unplugged.",
        inputs: %{
          type: "object",
          properties: %{
            charging: %{type: "boolean", description: "Whether it's on its charger"},
            name: %{type: "string", description: "What the device is called"}
          },
          required: ["charging"]
        },
        outputs: %{type: "object", properties: %{since: %{type: "integer", description: "Since when it has been so, in milliseconds since 1970"}}, required: ["since"]}
      },
      %{
        name: "widget",
        read_only: true,
        max_age: 60,
        description: "Device Activity's widget, as a layout: how busy each device is, at a glance",
        inputs: %{type: "object", properties: %{size: %{type: "string", enum: ["2x2", "4x2", "4x4"]}}},
        outputs: %{type: "object", properties: %{part: %{type: "string"}}, required: ["part"]}
      }
    ]
  end

  @impl true
  def call("widget", inputs, call), do: ServerLoad.Widget.layout(devices(call), inputs["size"] || "4x4")

  def call("now", inputs, call) do
    devices = devices(call, inputs["server"])
    power = power(call)

    if devices == [] and power == [],
      do: raise("No device is measured yet. `install_service` runs ServerLoad.Meter on one.")

    %{devices: devices, power: power}
  end

  def call("power", inputs, call) do
    device = (OneCore.Call.client(call) || %{})["device"] || raise "Only a device says whether it's on its charger."
    database = OneCore.Call.app(call, "database")

    database.transaction(call, @schema, fn db ->
      # Since when is kept while it says the same again.
      [%{"since" => since}] =
        database.query(
          db,
          """
          insert into power (device, name, charging, since) values (?, ?, ?, ?)
          on conflict (device) do update set name = excluded.name, charging = excluded.charging,
            since = case when power.charging = excluded.charging then power.since else excluded.since end
          returning since
          """,
          [device, inputs["name"], if(inputs["charging"], do: 1, else: 0), System.system_time(:millisecond)]
        )

      %{since: since}
    end)
  end

  defp power(call) do
    database = OneCore.Call.app(call, "database")

    database.transaction(call, @schema, fn db ->
      for row <- database.query(db, "select device, name, charging, since from power order by name", []),
          do: %{row | "charging" => row["charging"] == 1}
    end)
  end

  # Every device, or the one with the server key `only`: what its meter says now, or for one that's off, when it was
  # last seen, or for one with no meter, that it isn't measured, as Task Manager and Activity Monitor show the device
  # they run on and a person doesn't wonder where one went. One that's known to be off isn't asked. Where nothing keeps
  # who's on, as with no address, every one is.
  defp devices(call, only \\ nil) do
    metered = OneCore.Service.servers(call, Meter)
    servers = Enum.uniq(metered ++ OneCore.Apps.covering(OneCore.User.owner(call.subject) || "network"))
    servers = if only, do: Enum.filter(servers, &(&1 == only)), else: servers
    {off, on} = Enum.split_with(servers, &is_integer(OneCore.Service.seen(&1)))
    {metered_on, unmetered_on} = Enum.split_with(on, &(&1 in metered))

    off =
      for server <- off do
        seen = OneCore.Service.seen(server)
        problem = if server in metered, do: "It's off.", else: unmeasured()
        %{"server" => server, "name" => OneCore.Service.name(server), "problem" => problem, "seen" => seen}
      end

    unmeasured = for server <- unmetered_on, do: %{"server" => server, "name" => OneCore.Service.name(server), "problem" => unmeasured()}
    devices = cached_or_refresh(call, metered_on) ++ unmeasured ++ off
    Enum.sort_by(without_devices(devices), &String.downcase(&1["name"] || ""))
  end

  defp unmeasured, do: "Not measured: its meter isn't running on it."

  # A container that is a device itself is listed as that device, with its own readings, and not again under its host.
  # One that's on says it's a container; one that's off, as a server is while it restarts on an update, says nothing,
  # so it's known by its name, which is its host name, as the container's is.
  defp without_devices(devices) do
    own = for device <- devices, into: MapSet.new(), do: device["container"] || device["name"]

    for device <- devices do
      Map.update(device, "containers", [], fn containers -> Enum.reject(containers, &(&1["name"] in own)) end)
    end
  end

  # How long a machine has to answer, in milliseconds: a meter that doesn't answer in 3 s says so itself
  # (`ServerLoad.Meter`), and a machine that doesn't answer at all isn't waited on for much longer.
  @answer 4_000
  # A reading younger than this (ms) isn't refreshed again: the page asks every 5 s, so each poll refreshes once,
  # while bursts from `changed` notices don't stampede meters.
  @fresh 4_000
  # Safety expiry (ms) for an in-flight refresh mark, in case a task is killed before its `after` runs.
  @lock_ttl 10_000

  # Answers at once with each device's last kept reading, and refreshes stale or missing meters in the background so
  # each device updates as its own meter answers without waiting on the slowest one.
  defp cached_or_refresh(_call, []), do: []

  defp cached_or_refresh(call, servers) do
    stored = read_readings(call)
    now_ms = System.os_time(:millisecond)

    stale =
      Enum.filter(servers, fn server ->
        case Map.get(stored, server) do
          {at, _measured} -> now_ms - at >= @fresh
          nil -> true
        end
      end)

    if stale != [], do: refresh_async(call, stale, stored)

    for server <- servers do
      base = %{"server" => server, "name" => OneCore.Service.name(server)}

      case Map.get(stored, server) do
        {at, measured} -> Map.merge(measured, Map.put(base, "at", at))
        nil -> Map.put(base, "problem", "Measuring…")
      end
    end
  end

  defp read_readings(call) do
    database = OneCore.Call.app(call, "database")

    database.transaction(call, @schema, fn db ->
      for %{"server" => server, "at" => at, "reading" => json} <- database.query(db, "select server, at, reading from readings", []),
          into: %{} do
        {server, {at, JSON.decode!(json)}}
      end
    end)
  end

  defp refresh_async(call, servers, stored) do
    for server <- servers do
      key = {call.subject, server}

      if claim(key) do
        had_prior = Map.has_key?(stored, server)

        Task.start(fn ->
          try do
            measure_one(call, server, had_prior)
          after
            release(key)
          end
        end)
      end
    end
  end

  defp measure_one(call, server, had_prior) do
    {answered, failed} = OneCore.Asks.each([server], &OneCore.Service.call(call, Meter, :now, [], &1), @answer)
    at = System.os_time(:millisecond)
    database = OneCore.Call.app(call, "database")

    case List.keyfind(answered, server, 0) do
      {_server, measured} ->
        json = JSON.encode!(measured)

        database.transaction(call, @schema, fn db ->
          database.query(
            db,
            """
            insert into readings (server, at, reading) values (?, ?, ?)
            on conflict (server) do update set at = excluded.at, reading = excluded.reading
            """,
            [server, at, json]
          )
        end)

        OneCore.Call.changed(call)

      nil ->
        # Keep a prior good reading (with its age) if the meter fails transiently; record the problem only if none exists yet.
        if not had_prior do
          json = JSON.encode!(%{"problem" => failed[server]})

          database.transaction(call, @schema, fn db ->
            database.query(
              db,
              "insert into readings (server, at, reading) values (?, ?, ?) on conflict (server) do nothing",
              [server, at, json]
            )
          end)

          OneCore.Call.changed(call)
        end
    end
  end

  # In-flight refresh marks, held in a named ETS table owned by a tiny idle process so it outlives request processes.
  defp claim(key) do
    table = ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, started}] when now - started < @lock_ttl ->
        false

      _ ->
        :ets.insert(table, {key, now})
        true
    end
  end

  defp release(key) do
    if :ets.whereis(:server_load_refreshing) != :undefined, do: :ets.delete(:server_load_refreshing, key)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(:server_load_refreshing) do
      :undefined ->
        parent = self()

        spawn(fn ->
          created =
            try do
              :ets.new(:server_load_refreshing, [:named_table, :public, :set])
              true
            rescue
              ArgumentError -> false
            end

          send(parent, :ready)
          if created, do: receive(do: (:stop -> :ok))
        end)

        receive do
          :ready -> :server_load_refreshing
        after
          1_000 -> :server_load_refreshing
        end

      _ref ->
        :server_load_refreshing
    end
  end
end
