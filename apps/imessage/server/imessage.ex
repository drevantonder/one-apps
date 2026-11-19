defmodule IMessage do
  @moduledoc "iMessage: the user's Messages on their Mac, iMessage and SMS, through its service there, `IMessage.Helper`."
  @behaviour OneCore.App

  # It has no app, so it says how it's called and drawn where it's shown, as the App Store.
  @impl true
  def icon, do: "icon.png"

  @impl true
  def requires, do: %{"core" => ">= 0.32.47"}

  @chat "the chat: its name as imessage_chats gives it, a part of the name only one chat has, or its id; or a phone number with its country code (+61 400 000 000) or an email address"
  @since %{
    type: "string",
    description:
      "only messages after this: an ISO 8601 date (2026-11-01) or date-time (2026-11-01T09:00), in the Mac's time zone without an offset"
  }
  @limit %{type: "integer", description: "at most this many; default 30"}
  @message %{
    type: "object",
    properties: %{
      time: %{type: "string", description: "ISO 8601, in the Mac's time zone"},
      from: %{type: "string", description: "The sender's name from Contacts, or their number, or me for the user"},
      text: %{type: "string"},
      attachments: %{type: "array", items: %{type: "string"}, description: "The files' names"},
      chat: %{type: "string", description: "With search: its chat's name"}
    },
    required: ["time", "from"]
  }
  @messages %{type: "object", properties: %{messages: %{type: "array", items: @message}}, required: ["messages"]}

  @impl true
  def tools do
    [
      %{
        name: "chats",
        read_only: true,
        description:
          "Recent chats and texts, most recent first, to see what's new or unread, or find a chat to read, each with its last message. Page back with skip.",
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
        },
        outputs: %{
          type: "object",
          properties: %{
            chats: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  chat: %{type: "string", description: "Its name"},
                  id: %{type: "string", description: "For imessage_read"},
                  with: %{type: "array", items: %{type: "string"}, description: "The people in a group"},
                  last: %{type: "string", description: "When its last message came, in ISO 8601"},
                  from: %{type: "string", description: "Who sent its last message, or me"},
                  text: %{type: "string", description: "Its last message"},
                  unread: %{type: "integer", description: "How many are unread, if any"}
                },
                required: ["chat", "id", "last"]
              }
            }
          },
          required: ["chats"]
        }
      },
      %{
        name: "read",
        read_only: true,
        description:
          "One chat's messages and texts, newest last, without marking them read. Page back with skip.",
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
        },
        outputs: @messages
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
        },
        outputs: @messages
      },
      %{
        name: "send",
        description:
          "Send an iMessage or text from the user's account to a chat, a phone number or an email address. It sends a real message to a real person and can't be taken back: only what the user asked to send, to whom they asked. Says to whom it went.",
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
        },
        outputs: %{
          type: "object",
          properties: %{to: %{type: "string", description: "The chat it went to, by its name"}},
          required: ["to"]
        }
      }
    ]
  end

  @impl true
  def call(tool, inputs, call) do
    answer = OneCore.Service.call(call, IMessage.Helper, :ask, [tool, inputs])

    # The helper on the Mac says to whom a message went as a sentence, and stays as it is: a changed helper is a new
    # app to macOS, which asks its person again to let it control Messages.
    case {tool, answer} do
      {"chats", chats} -> %{chats: chats}
      {"send", "Sent to " <> to} -> %{to: String.trim_trailing(to, ".")}
      {_messages, messages} -> %{messages: messages}
    end
  end
end
