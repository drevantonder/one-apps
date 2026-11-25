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
  # Each device's power as it last said, and since when it has been so.
  @schema ["create table power (device text primary key, name text, charging integer not null, since integer not null)"]

  @busy %{type: "array", items: %{type: "integer"}, description: "Percent busy every 5 seconds over the last two minutes, oldest first"}

  @impl true
  def icon, do: "client/icon.svg"

  @impl true
  def requires, do: %{"core" => ">= 0.34.593", "database" => "to keep whether each device is on its charger"}

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
        ui: "client/index.html",
        runtime_version: 5,
        description:
          "Every device that's measured, on or not, and how busy each is now: its memory, CPU, GPU and disk space, and the containers it hosts; and whether each device that says so, as a phone does, is on its charger, and since when. Use it to pick a device or server with room for a desktop, a model or a build, or to know whether someone's phone is charging.",
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
    devices = Enum.map(metered_on, &measure(call, &1)) ++ unmeasured ++ off
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

  defp measure(call, server) do
    measured =
      try do
        OneCore.Service.call(call, Meter, :now, [], server)
      rescue
        problem -> %{"problem" => Exception.message(problem)}
      end

    Map.merge(measured, %{"server" => server, "name" => OneCore.Service.name(server)})
  end
end
