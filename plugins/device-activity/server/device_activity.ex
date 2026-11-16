defmodule DeviceActivity do
  @moduledoc """
  Device Activity: how busy each device is, as `server-load` measures it. Server Load's meter, its service
  `ServerLoad.Meter`, is what measures each device it's installed on; this plugin says it in words, and shows it.
  """
  @behaviour OneCore.Plugin

  @gb 1_000_000_000
  @gib 1_073_741_824

  @impl true
  def uses, do: ["server-load"]

  @impl true
  def apps, do: [%{name: "Device Activity", page: "client/index.html", icon: "client/icon.svg"}]

  @impl true
  def widgets, do: [%{name: "Device Activity", tool: "widget", sizes: ["4x4", "4x2", "2x2"]}]

  @impl true
  def tools do
    [
      %{
        name: "widget",
        read_only: true,
        description: "Device Activity's widget, as a layout: how busy each device is, at a glance",
        inputs: %{type: "object", properties: %{size: %{type: "string", enum: ["2x2", "4x2", "4x4"]}}}
      },
      %{
        name: "list",
        read_only: true,
        description:
          ~s[Every one of your devices that Server Load measures, on or not, and how busy each is now: memory, CPU, GPU and disk space, like "23 GB of 30 GB (76%)". Containers a device hosts follow it, with host naming it. Use it to pick a device with room for a desktop, a model or a build.],
        inputs: %{
          type: "object",
          properties: %{
            history: %{
              type: "boolean",
              description:
                "also each device's CPU and GPU, percent busy every 5 seconds over the last two minutes, oldest first"
            },
            format: %{
              type: "string",
              enum: ["text", "json"],
              description: "json for the screen: every figure as a number"
            }
          }
        }
      }
    ]
  end

  @impl true
  def call("widget", inputs, call), do: DeviceActivity.Widget.layout(devices(call), inputs["size"] || "4x4")

  def call("list", inputs, call) do
    devices = devices(call)
    if inputs["format"] == "json", do: devices, else: %{devices: Enum.flat_map(devices, &said(&1, inputs["history"]))}
  end

  # Every device Server Load measures: what its meter says now, or for one that's off, when it was last seen. One that's
  # known to be off isn't asked. Where nothing keeps who's on, as with no address, every one is.
  defp devices(call) do
    load = OneCore.Call.plugin(call, "server-load")
    servers = OneCore.Service.servers(call, Module.concat(load, "Meter"))
    {off, on} = Enum.split_with(servers, &is_integer(OneCore.Service.seen(&1)))

    off =
      for server <- off do
        seen = OneCore.Service.seen(server)
        %{"server" => server, "name" => OneCore.Service.name(server), "problem" => "It's off.", "seen" => seen}
      end

    Enum.sort_by(load.now(call, on) ++ off, &String.downcase(&1["name"] || ""))
  end

  # A device in words, then each container it hosts.
  defp said(%{"problem" => _} = device, _history) do
    seen = device["seen"] && DateTime.to_iso8601(DateTime.from_unix!(device["seen"], :millisecond))
    [put(%{name: device["name"], online: false}, :seen, seen)]
  end

  defp said(device, history) do
    os = %{"linux" => "Linux", "macos" => "macOS"}[device["os"]] || device["os"]

    said =
      %{name: device["name"], os: os, online: true}
      |> put(:memory, device["memory"] && memory(device["memory"]))
      |> put(:cpu, percent(List.last(device["cpu"])))
      |> put(:gpu, percent(List.last(device["gpu"])))
      |> put(:disk, device["disk"] && disk(device["disk"]))
      |> put(:cpu_history, history && device["cpu"])
      |> put(:gpu_history, history && device["gpu"] != [] && device["gpu"])

    containers =
      for container <- device["containers"] do
        put(
          %{name: container["name"], kind: container["kind"], host: device["name"]},
          :memory,
          container["memory"] && "#{size(container["memory"]["used"], @gib)} in use"
        )
      end

    [said | containers]
  end

  defp put(said, _key, value) when value in [nil, false], do: said
  defp put(said, key, value), do: Map.put(said, key, value)

  defp percent(nil), do: nil
  defp percent(busy), do: "#{busy}%"

  # Memory counts in 2^30s, as macOS and Activity Monitor do, disks in 10^9s.
  defp memory(%{"used" => used, "total" => total}),
    do: "#{size(used, @gib)} of #{size(total, @gib)} (#{round(used * 100 / total)}%)"

  defp disk(%{"used" => used, "total" => total}),
    do: "#{size(total - used, @gb)} free of #{size(total, @gb)} (#{round(used * 100 / total)}% used)"

  defp size(bytes, g) when bytes >= 10 * g, do: "#{round(bytes / g)} GB"
  defp size(bytes, g) when bytes >= g, do: "#{Float.round(bytes / g, 1)} GB"
  defp size(bytes, g), do: "#{round(bytes / (g / 1000))} MB"
end
