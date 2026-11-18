defmodule ScreenSharing do
  @moduledoc """
  Screen Sharing: a person's own Mac's screen, for Computer Use. Each Mac whose server runs its service,
  `ScreenSharing.Helper`, is a screen (the hook `computer-use.screens`), which an agent sees and uses as its person
  would, while they watch.

  A Mac's screen is its person's: only they, the first its server acts for, or the network's owner use it.
  """
  @behaviour OneCore.App
  alias OneCore.{Call, Service}
  alias ScreenSharing.Helper

  @mac %{type: "string", description: "the Mac, by its server's key, as Computer Use's screens give it"}
  @at %{x: %{type: "integer", minimum: 0}, y: %{type: "integer", minimum: 0}}

  @impl true
  def icon, do: "icon.svg"

  @impl true
  def requires, do: %{"core" => ">= 0.22.18"}

  @impl true
  def hooks, do: ["computer-use.screens"]

  @impl true
  def tools do
    [
      %{
        name: "screen",
        description:
          "Look at or act on a Mac's screen, for Computer Use, whose tools are how agents use a screen, so its person sees what's done: they say what each action takes.",
        inputs: %{
          type: "object",
          required: ["mac", "action"],
          properties: %{
            mac: @mac,
            action: %{type: "string", enum: ~w(screenshot click double_click move drag scroll type key stream)},
            x: @at.x,
            y: @at.y,
            button: %{type: "string", enum: ~w(left right middle)},
            path: %{type: "array", minItems: 2, items: %{type: "object", required: ["x", "y"], properties: @at}},
            direction: %{type: "string", enum: ~w(up down left right)},
            amount: %{type: "integer", minimum: 1, maximum: 50},
            text: %{type: "string"},
            keys: %{type: "string"},
            offer: %{type: "string"}
          }
        },
        outputs: %{
          type: "object",
          description: "As Computer Use says: a screenshot, or what it did",
          properties: %{
            mimeType: %{type: "string"},
            size: %{type: "integer"},
            done: %{type: "string", description: "What it did, in a few words"}
          }
        }
      },
      %{
        name: "macs",
        read_only: true,
        description:
          "The Macs whose screens you may use: each one's name, whose it is, its screen's size in pixels, and whether macOS lets Screen Sharing see it (Screen Recording) and use it (Accessibility). Asks macOS nothing. A Mac that's off says when it was last seen; one that couldn't be asked, why.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{
            macs: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  name: %{type: ["string", "null"]},
                  mac: %{type: "string", description: "Its server's key"},
                  person: %{type: ["string", "null"], description: "Whose Mac it is: the first its server acts for"},
                  width: %{type: "integer"},
                  height: %{type: "integer"},
                  screen_recording: %{type: "boolean", description: "Whether macOS lets Screen Sharing for The One App see the screen"},
                  accessibility: %{type: "boolean", description: "Whether macOS lets it use the mouse and keyboard"},
                  app: %{type: "string", description: "Where Screen Sharing for The One App is on the Mac"},
                  seen: %{type: "integer", description: "When one that's off was last seen, in milliseconds since 1970"},
                  problem: %{type: "string", description: "Why it couldn't be asked"}
                },
                required: ["name", "mac", "person"]
              }
            }
          },
          required: ["macs"]
        }
      }
    ]
  end

  @impl true
  def call("macs", _inputs, call) do
    macs =
      for server <- Service.servers(call, Helper), may?(call, server) do
        status =
          case Service.seen(server) do
            seen when is_integer(seen) ->
              %{"seen" => seen}

            _ ->
              try do
                Service.call(call, Helper, :status, [], server)
              rescue
                problem -> %{"problem" => Exception.message(problem)}
              end
          end

        Map.merge(status, %{"name" => Service.name(server), "mac" => server, "person" => person(server)})
      end

    %{macs: macs}
  end

  def call("screen", %{"action" => "stream"}, _call),
    do: raise("A Mac's screen has no live video yet: it's shown a picture at a time.")

  def call("screen", %{"mac" => mac, "action" => action} = inputs, call) do
    # Its person sees what an agent does on their screen in Computer Use, which notes each action's `doing`.
    if call.caller == nil or Path.basename(call.caller) != "computer-use",
      do: raise("Use Computer Use's tools on a Mac's screen, so its person sees what's done there.")

    if mac not in Service.servers(call, Helper) or not may?(call, mac),
      do: raise("You may not use that Mac's screen: only its person and the network's owner may.")

    case action do
      "screenshot" ->
        {:blob, "image/png", Base.decode64!(Service.call(call, Helper, :screenshot, [], mac))}

      _ ->
        done = did(action, inputs)
        Service.call(call, Helper, :act, [action, Map.drop(inputs, ["mac", "action"])], mac)
        %{done: done}
    end
  end

  # Computer Use asks for the caller's screens: each Mac of theirs that's on is one, called what the Mac is called.
  @impl true
  def hook("computer-use.screens", _about, call) do
    for server <- Service.servers(call, Helper), not is_integer(Service.seen(server)), may?(call, server) do
      status = Service.call(call, Helper, :status, [], server)

      missing =
        for {permission, false} <- [{"Screen Recording", status["screen_recording"]}, {"Accessibility", status["accessibility"]}],
            do: permission

      %{
        "name" => Service.name(server) || server,
        "description" =>
          "#{Service.name(server)}'s own screen, as its person sees it" <>
            if(missing == [], do: "", else: "; macOS doesn't allow #{Enum.join(missing, " or ")} yet"),
        "width" => status["width"],
        "height" => status["height"],
        "tool" => "screen",
        "inputs" => %{"mac" => server}
      }
    end
  end

  # Whose Mac it is: the first its server acts for, its owner, whom it was started for.
  defp person(server), do: List.first(OneCore.Servers.members(server))

  # Only the Mac's person, or the network's owner, uses its screen.
  defp may?(call, server), do: call.subject == person(server) or Call.owns?(%{call | subject: "network"})

  defp did("click", %{"x" => x, "y" => y} = inputs), do: "Clicked #{inputs["button"] || "left"} at #{x}, #{y}"
  defp did("double_click", %{"x" => x, "y" => y}), do: "Double-clicked at #{x}, #{y}"
  defp did("move", %{"x" => x, "y" => y}), do: "Moved to #{x}, #{y}"
  defp did("drag", %{"path" => path}), do: "Dragged through #{length(path)} points"
  defp did("scroll", %{"direction" => direction} = inputs), do: "Scrolled #{direction} #{inputs["amount"] || 5}"
  defp did("type", %{"text" => text}), do: "Typed #{String.length(text)} characters"
  defp did("key", %{"keys" => keys}), do: "Pressed #{keys}"
  defp did(action, _inputs), do: raise("#{action} needs more: Computer Use's tools say what each action takes")
end
