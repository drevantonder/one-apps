defmodule Mac do
  @moduledoc """
  What of a Mac its person's apps and agents reach: Calendar, Reminders, Contacts and Messages. The plugins
  `calendar`, `reminders`, `contacts` and `imessage` each use this one for their part of it, through `ask/4`.

  Its service, `Mac.Helper`, on the Mac it's installed on, builds and runs a small app of its own, The One App
  Helper, which reaches each through the frameworks macOS gives for it. macOS asks the Mac's person for each
  permission under that app's name, once.
  """
  @behaviour OneCore.Plugin
  alias Mac.Helper

  @impl true
  def tools do
    [
      %{
        name: "permissions",
        read_only: true,
        description:
          "What macOS lets The One App Helper reach on the Mac: calendars, reminders and contacts (allowed, not allowed, or not asked yet), messages (allowed, or needs Full Disk Access) and sending (whether it may control Messages), and where the helper app is, to add it in System Settings. Reads none of them.",
        inputs: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl true
  def call("permissions", _inputs, call), do: ask(call, "mac", "permissions", %{})

  @doc """
  Asks the Mac for `function` of `part` (`"calendar"`, `"reminders"`, `"contacts"` or `"imessage"`) with a tool's
  `inputs`, and gives the answer. Raises with what the helper said otherwise, such as which permission macOS hasn't
  given it and where to give it. For a plugin that uses this one.
  """
  def ask(call, part, function, inputs),
    do: OneCore.Service.call(call, Helper, :ask, [part, function, inputs])
end
