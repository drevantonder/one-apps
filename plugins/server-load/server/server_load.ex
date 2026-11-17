defmodule ServerLoad do
  @moduledoc """
  How busy a network's machines are, each measured by a small program on it, `ServerLoad.Meter`; said in words, and
  shown as the app Device Activity and its widget.
  """
  @behaviour OneCore.Plugin
  alias ServerLoad.Meter

  @space %{
    type: ["object", "null"],
    properties: %{used: %{type: "integer", description: "In bytes"}, total: %{type: "integer", description: "In bytes"}},
    required: ["used", "total"]
  }
  @busy %{type: "array", items: %{type: "integer"}, description: "Percent busy every 5 seconds over the last two minutes, oldest first"}

  @impl true
  def apps, do: [%{name: "Device Activity", page: "client/index.html", icon: "client/icon.svg", category: "devices"}]

  @impl true
  def widgets, do: [%{name: "Device Activity", tool: "widget", sizes: ["4x4", "4x2", "2x2"]}]

  @impl true
  def tools do
    [
      %{
        name: "now",
        read_only: true,
        description:
          "Every device that's measured, on or not, and how busy each is now: its memory, CPU, GPU and disk space, and the containers it hosts. Use it to pick a device or server with room for a desktop, a model or a build.",
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
                  problem: %{type: "string", description: "Why it isn't measured now: off, or its meter failed"},
                  seen: %{type: "integer", description: "When one that's off was last seen, in milliseconds since 1970"},
                  os: %{type: "string", description: "linux or macos"},
                  processors: %{type: "integer"},
                  load: %{type: "array", items: %{type: "number"}, description: "Load average over 1, 5 and 15 minutes"},
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
            }
          },
          required: ["devices"]
        }
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

    if devices == [], do: raise("No device is measured yet. `install_service` runs ServerLoad.Meter on one.")
    %{devices: devices}
  end

  # Every device measured, or the one with the server key `only`: what its meter says now, or for one that's off,
  # when it was last seen. One that's known to be off isn't asked. Where nothing keeps who's on, as with no address,
  # every one is.
  defp devices(call, only \\ nil) do
    servers = OneCore.Service.servers(call, Meter)
    servers = if only, do: Enum.filter(servers, &(&1 == only)), else: servers
    {off, on} = Enum.split_with(servers, &is_integer(OneCore.Service.seen(&1)))

    off =
      for server <- off do
        seen = OneCore.Service.seen(server)
        %{"server" => server, "name" => OneCore.Service.name(server), "problem" => "It's off.", "seen" => seen}
      end

    Enum.sort_by(Enum.map(on, &measure(call, &1)) ++ off, &String.downcase(&1["name"] || ""))
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
