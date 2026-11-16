defmodule ServerLoad do
  @moduledoc """
  How busy a network's machines are, each measured by a small program on it, `ServerLoad.Meter`; said in words, and
  shown as the app Device Activity and its widget.
  """
  @behaviour OneCore.Plugin
  alias ServerLoad.Meter

  @gb 1_000_000_000
  @gib 1_073_741_824

  @impl true
  def apps, do: [%{name: "Device Activity", page: "client/index.html", icon: "client/icon.svg"}]

  @impl true
  def widgets, do: [%{name: "Device Activity", tool: "widget", sizes: ["4x4", "4x2", "2x2"]}]

  @impl true
  def tools do
    [
      %{
        name: "now",
        read_only: true,
        description:
          ~s[Every device that's measured, on or not, and how busy each is now: memory, CPU, GPU and disk space, like "23 GB of 30 GB (76%)". Containers a device hosts follow it, with host naming it. Use it to pick a device with room for a desktop, a model or a build.],
        inputs: %{
          type: "object",
          properties: %{
            server: %{type: "string", description: "only the device with this server key; default every device"},
            history: %{
              type: "boolean",
              description:
                "also each device's CPU and GPU, percent busy every 5 seconds over the last two minutes, oldest first"
            },
            format: %{
              type: "string",
              enum: ["text", "json"],
              description: "json: every figure as a number, with each device's server key"
            }
          }
        }
      },
      %{
        name: "widget",
        read_only: true,
        description: "Device Activity's widget, as a layout: how busy each device is, at a glance",
        inputs: %{type: "object", properties: %{size: %{type: "string", enum: ["2x2", "4x2", "4x4"]}}}
      }
    ]
  end

  @impl true
  def call("widget", inputs, call), do: ServerLoad.Widget.layout(devices(call), inputs["size"] || "4x4")

  def call("now", inputs, call) do
    devices = devices(call, inputs["server"])

    cond do
      devices == [] -> raise "No device is measured yet. `install_service` runs ServerLoad.Meter on one."
      inputs["format"] == "json" -> devices
      true -> %{devices: Enum.flat_map(devices, &entry(&1, inputs["history"]))}
    end
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

  # A device in words, then each container it hosts.
  defp entry(%{"problem" => _} = device, _history) do
    seen = device["seen"] && DateTime.to_iso8601(DateTime.from_unix!(device["seen"], :millisecond))
    [put(%{name: device["name"], online: false}, :seen, seen)]
  end

  defp entry(device, history) do
    os = %{"linux" => "Linux", "macos" => "macOS"}[device["os"]] || device["os"]

    entry =
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

    [entry | containers]
  end

  defp put(entry, _key, value) when value in [nil, false], do: entry
  defp put(entry, key, value), do: Map.put(entry, key, value)

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
