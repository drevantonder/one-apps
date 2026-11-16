defmodule AppleContacts do
  @moduledoc "Apple Contacts: the user's Apple Contacts on their Mac, through its service there, `AppleContacts.Helper`."
  @behaviour OneCore.Plugin

  @card "{ id, name, nickname, organization, job, phones, emails, addresses, birthday, urls }, each only when the card has it; name is the organization's when the card has no name, phones, emails and addresses are each { label, number } or { label, address }, and birthday is year-month-day, or month-day when the card has no year"

  @impl true
  def tools do
    [
      %{
        name: "search",
        read_only: true,
        description:
          "Find people in the user's contacts by name, email address or phone number, for someone's number or address before writing to them. Gives each #{@card}, by name.",
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
        }
      },
      %{
        name: "get",
        read_only: true,
        description:
          "One contact's card, by its id from apple-contacts_search: #{@card}. Use it to look again at someone already found; apple-contacts_search gives the same cards.",
        inputs: %{
          type: "object",
          required: ["id"],
          properties: %{id: %{type: "string", description: "the contact's id, as apple-contacts_search gives it"}}
        }
      },
      %{
        name: "me",
        read_only: true,
        description:
          "The user's own card, the one Contacts marks as theirs: #{@card}. Use it for their own name, number or address.",
        inputs: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl true
  def call(tool, inputs, call), do: OneCore.Service.call(call, AppleContacts.Helper, :ask, [tool, inputs])
end
