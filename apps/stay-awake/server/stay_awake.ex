defmodule StayAwake do
  @moduledoc """
  Stay Awake: a Mac it's on for doesn't sleep while it's plugged in, even with its lid shut and its display off,
  so its person's other devices and their agents can still reach it. On battery it sleeps as usual. Its service,
  `StayAwake.Mac`, on each Mac it's installed on, holds that Mac awake, and keeps whether it's on.
  """
  @behaviour OneCore.App
  alias StayAwake.Mac

  # A Mac that goes off or comes back says nothing, and "Seen 2 minutes ago" ages, so the Home Screen asks again this
  # often (seconds) while the widget shows.
  @refresh 60

  @device %{type: "string", description: "the Mac, by name, as `services` names it; else the first that has Stay Awake"}

  # How Stay Awake stands on a Mac.
  @status %{
    type: "object",
    properties: %{
      on: %{type: "boolean", description: "Whether Stay Awake is on for it"},
      holding: %{type: "boolean", description: "Whether it's keeping it from sleeping now"},
      plugged_in: %{type: "boolean", description: "Whether it's plugged in: on battery it sleeps as usual"}
    },
    required: ["on", "holding", "plugged_in"]
  }

  @impl true
  def icon, do: "client/icon.svg"

  @impl true
  def requires, do: %{"core" => ">= 0.32.47"}

  @impl true
  def hooks, do: ["settings.sections"]

  # Its switch is a group on the Mac's page in Settings, where its service runs.
  @impl true
  def hook("settings.sections", _about, _call), do: [%{in: "device", component: "mac", service: true}]

  @impl true
  def widgets, do: [%{tool: "widget", sizes: ["2x2", "4x2"]}]

  @impl true
  def tools do
    [
      %{
        name: "widget",
        read_only: true,
        description: "Stay Awake's widget, as a layout: each Mac it's on for, with a switch",
        inputs: %{type: "object", properties: %{size: %{type: "string", enum: ["2x2", "4x2"]}}},
        outputs: %{type: "object", properties: %{part: %{type: "string"}}, required: ["part"]}
      },
      %{
        name: "status",
        read_only: true,
        description:
          "Whether Stay Awake is on for a Mac, whether it's keeping it from sleeping now, and whether it's plugged in: a Mac on battery sleeps as usual.",
        inputs: %{type: "object", properties: %{device: @device}},
        outputs: @status
      },
      %{
        name: "set",
        description:
          "Turn Stay Awake on or off for a Mac. On, it doesn't sleep while it's plugged in, even with its lid shut; off, it sleeps as usual. Gives how it stands after.",
        inputs: %{
          type: "object",
          required: ["on"],
          properties: %{on: %{type: "boolean"}, device: @device}
        },
        outputs: @status
      },
      %{
        name: "macs",
        read_only: true,
        description:
          "Every Mac Stay Awake is installed on, by name, and how each stands, as stay-awake_status says it; a Mac that's off has when it was last seen instead, and one that can't be asked a problem.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{
            macs: %{
              type: "array",
              items: %{
                type: "object",
                properties:
                  Map.merge(@status.properties, %{
                    name: %{type: ["string", "null"]},
                    server: %{type: "string", description: "The Mac's server, by its key"},
                    problem: %{type: "string", description: "Why it couldn't be asked: off, or what went wrong"},
                    seen: %{type: "integer", description: "When one that's off was last seen, in milliseconds since 1970"}
                  }),
                required: ["name"]
              }
            }
          },
          required: ["macs"]
        }
      }
    ]
  end

  @impl true
  def call("status", inputs, call), do: OneCore.Service.call(call, Mac, :status, [], mac(call, inputs["device"]))

  def call("set", %{"on" => on} = inputs, call),
    do: OneCore.Service.call(call, Mac, :set, [on], mac(call, inputs["device"]))

  # Each Mac's switch, with a grey line saying how it stands, or for one that's off, when it was last seen.
  def call("widget", _inputs, call) do
    rows =
      for mac <- call("macs", %{}, call).macs do
        says =
          cond do
            mac["problem"] -> seen(mac["seen"])
            not mac["on"] -> "Sleeps as usual"
            mac["plugged_in"] -> "Awake while plugged in"
            true -> "On battery, so it sleeps as usual"
          end

        switch = %{
          part: "switch",
          label: mac["name"],
          on: mac["on"] == true,
          tool: "set",
          inputs: %{device: mac["name"]}
        }

        line = %{part: "text", text: says, size: "sm", tone: "muted", lines: 1}
        %{part: "column", gap: 2, dim: mac["problem"] != nil, parts: [switch | if(says, do: [line], else: [])]}
      end

    if rows == [],
      do: %{part: "text", text: "No Mac has Stay Awake yet.", size: "sm", tone: "muted", refresh: @refresh},
      else: %{part: "column", gap: 8, refresh: @refresh, parts: rows}
  end

  # A Mac that's off isn't asked: it says when it was last seen instead.
  def call("macs", _inputs, call) do
    macs =
      for server <- OneCore.Service.servers(call, Mac) do
        status =
          case OneCore.Service.seen(server) do
            seen when is_integer(seen) ->
              %{"problem" => "It's off.", "seen" => seen}

            # On, or nothing keeps who's on, as with no address.
            _ ->
              try do
                OneCore.Service.call(call, Mac, :status, [], server)
              rescue
                problem -> %{"problem" => Exception.message(problem)}
              end
          end

        status |> Map.put("name", OneCore.Service.name(server)) |> Map.put("server", server)
      end

    %{macs: macs}
  end

  # The server that is the Mac called `name`, or the first that has Stay Awake.
  defp mac(call, name) do
    servers = OneCore.Service.servers(call, Mac)

    cond do
      servers == [] ->
        raise "No Mac has Stay Awake yet: `install_service --app stay-awake --service StayAwake.Mac` runs it on one."

      name == nil ->
        hd(servers)

      true ->
        Enum.find(servers, &(String.downcase(OneCore.Service.name(&1) || "") == String.downcase(name))) ||
          raise "No Mac called #{name} has Stay Awake. It's on #{Enum.map_join(servers, ", ", &OneCore.Service.name/1)}."
    end
  end

  # When a machine that's off was last seen, as a grey line says it: "Seen 2 minutes ago". Nothing for one never seen.
  defp seen(nil), do: nil

  defp seen(at) do
    minutes = max(div(System.os_time(:millisecond) - at, 60_000), 1)

    {count, unit} =
      cond do
        minutes < 60 -> {minutes, "minute"}
        minutes < 48 * 60 -> {div(minutes, 60), "hour"}
        true -> {div(minutes, 24 * 60), "day"}
      end

    "Seen #{count} #{unit}#{if count == 1, do: "", else: "s"} ago"
  end
end
