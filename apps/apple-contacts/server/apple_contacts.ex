defmodule AppleContacts do
  @moduledoc "Apple Contacts: the user's Apple Contacts on their Mac, through its service there, `AppleContacts.Helper`."
  @behaviour OneCore.App

  # It has no app, so it says how it's called and drawn where it's shown, as the App Store.
  @impl true
  def title, do: "Apple Contacts"

  @impl true
  def icon, do: "icon.png"

  # A contact's card, with only what it has.
  @labeled &%{
    type: "array",
    items: %{
      type: "object",
      properties: Map.put(%{label: %{type: "string", description: "home, work, mobile and so on"}}, &1, %{type: "string"}),
      required: ["label", Atom.to_string(&1)]
    }
  }
  @card %{
    type: "object",
    properties: %{
      id: %{type: "string", description: "For apple-contacts_get"},
      name: %{type: "string", description: "The organization's, when the card has no name"},
      nickname: %{type: "string"},
      organization: %{type: "string"},
      job: %{type: "string"},
      phones: @labeled.(:number),
      emails: @labeled.(:address),
      addresses: Map.put(@labeled.(:address), :description, "Each a postal address, as a letter shows it"),
      birthday: %{type: "string", description: "YYYY-MM-DD, or MM-DD when the card has no year"},
      urls: %{type: "array", items: %{type: "string"}}
    },
    required: ["id", "name"]
  }

  @impl true
  def tools do
    [
      %{
        name: "search",
        read_only: true,
        description:
          "Find people in the user's contacts by name, email address or phone number, for someone's phone number, email or address before writing to them. Gives each one's card, by name.",
        inputs: %{
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: "a name or part of one (Sam, Sam Lee), an email address, or a phone number in any format"
            },
            limit: %{type: "integer", description: "at most this many, by name; default 25"}
          }
        },
        outputs: %{type: "object", properties: %{contacts: %{type: "array", items: @card}}, required: ["contacts"]}
      },
      %{
        name: "get",
        read_only: true,
        description:
          "One contact's card, by its id from apple-contacts_search. Use it to look again at someone already found; apple-contacts_search gives the same cards.",
        inputs: %{
          type: "object",
          required: ["id"],
          properties: %{id: %{type: "string", description: "the contact's id, as apple-contacts_search gives it"}}
        },
        outputs: @card
      },
      %{
        name: "me",
        read_only: true,
        description:
          "The user's own card, the one Contacts marks as theirs. Use it for their own name, phone number, email or address.",
        inputs: %{type: "object", properties: %{}},
        outputs: @card
      }
    ]
  end

  @impl true
  def call(tool, inputs, call) do
    answer = OneCore.Service.call(call, AppleContacts.Helper, :ask, [tool, inputs])
    if tool == "search", do: %{contacts: answer}, else: answer
  end
end
