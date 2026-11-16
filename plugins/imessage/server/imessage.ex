defmodule IMessage do
  @moduledoc "iMessage: the user's Messages on their Mac, iMessage and SMS, through its service there, `IMessage.Helper`."
  @behaviour OneCore.Plugin

  @chat "the chat: its name as imessage_chats gives it, a part of the name only one chat has, or its id; or a phone number with its country code (+61 400 000 000) or an email address"
  @since %{
    type: "string",
    description:
      "only messages after this: an ISO 8601 date (2026-11-01) or date-time (2026-11-01T09:00), in the Mac's time zone without an offset"
  }
  @limit %{type: "integer", description: "at most this many; default 30"}
  @message "{ time, from, text, attachments }, time ISO 8601 in the Mac's time zone, from the sender's name from Contacts (or their number), or me for the user, and attachments the files' names"

  @impl true
  def tools do
    [
      %{
        name: "chats",
        read_only: true,
        description:
          "Recent chats, most recent first, to see what's new or find a chat to read: each { chat, id, with, last, from, text, unread }, chat its name, id for imessage_read, with the people in a group, and last (an ISO 8601 time), from and text its last message. Page back with skip.",
        inputs: %{
          type: "object",
          properties: %{
            unread: %{type: "boolean", description: "only chats with unread messages"},
            limit: @limit,
            skip: %{
              type: "integer",
              description: "leave out this many of the most recent, to page back: 30 for the second page of 30"
            }
          }
        }
      },
      %{
        name: "read",
        read_only: true,
        description:
          "One chat's messages, newest last, without marking them read: each #{@message}. Page back with skip.",
        inputs: %{
          type: "object",
          required: ["chat"],
          properties: %{
            chat: %{type: "string", description: @chat},
            since: @since,
            limit: @limit,
            skip: %{
              type: "integer",
              description: "leave out this many of the newest, to read further back: 30 for the 30 before the latest 30"
            }
          }
        }
      },
      %{
        name: "search",
        read_only: true,
        description:
          "Messages containing some text, across every chat or in one, newest last: to find something said when you don't know which chat. Each is as imessage_read gives them, with chat, its chat's name. Page back with skip.",
        inputs: %{
          type: "object",
          required: ["query"],
          properties: %{
            query: %{type: "string", description: "text to look for, any case"},
            chat: %{type: "string", description: "only in this chat: #{@chat}"},
            since: @since,
            limit: @limit,
            skip: %{type: "integer", description: "leave out this many of the newest matches, to page back"}
          }
        }
      },
      %{
        name: "send",
        description:
          "Send an iMessage from the user's account to a chat, a phone number or an email address. It sends a real message to a real person and can't be taken back: only what the user asked to send, to whom they asked. Says to whom it went.",
        inputs: %{
          type: "object",
          required: ["to", "text"],
          properties: %{
            to: %{
              type: "string",
              description:
                "a phone number with its country code (+61 400 000 000), an email address, or a chat: its name or id as imessage_chats gives it"
            },
            text: %{type: "string", description: "the message, exactly as the user approved it"}
          }
        }
      }
    ]
  end

  @impl true
  def call(tool, inputs, call), do: OneCore.Service.call(call, IMessage.Helper, :ask, [tool, inputs])
end
