defmodule AppleReminders do
  @moduledoc "Apple Reminders: the user's Apple Reminders on their Mac, through its service there, `AppleReminders.Helper`."
  @behaviour OneCore.Plugin

  # It has no app, so it says how it's called and drawn where it's shown, as the App Store.
  @impl true
  def title, do: "Reminders"

  @impl true
  def icon, do: "icon.png"

  @id %{type: "string", description: "the reminder's id, as apple-reminders_list gives it"}
  @priority %{type: "string", enum: ["high", "medium", "low", "none"], description: "high, medium, low or none"}
  # A reminder, with only what it has.
  @reminder %{
    type: "object",
    properties: %{
      id: %{type: "string", description: "For apple-reminders_update or apple-reminders_delete"},
      title: %{type: "string"},
      list: %{type: "string", description: "Its list's name"},
      due: %{type: "string", description: "An ISO 8601 date, or with a time a date-time in the Mac's time zone"},
      priority: %{type: "string", enum: ["high", "medium", "low"]},
      notes: %{type: "string"},
      completed: %{type: "string", description: "When it was done, in ISO 8601, if it was"}
    },
    required: ["id", "title"]
  }

  @impl true
  def tools do
    [
      %{
        name: "lists",
        read_only: true,
        description:
          "Every reminder list, and where each syncs (iCloud, Exchange). Use a name as list in apple-reminders_list or apple-reminders_create.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{
            lists: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  name: %{type: "string"},
                  id: %{type: "string"},
                  account: %{type: "string", description: "Where it syncs: iCloud, Exchange"},
                  default: %{type: "boolean", description: "Whether it's the Mac's default list"}
                },
                required: ["name", "id"]
              }
            }
          },
          required: ["lists"]
        }
      },
      %{
        name: "list",
        read_only: true,
        description:
          "Reminders and to-dos not yet done, soonest due first and those with no due date last, from every list or one; completed ones too if asked. Use it to search them, or for one's id to update or delete.",
        inputs: %{
          type: "object",
          properties: %{
            list: %{
              type: "string",
              description: "only this list, by its name as apple-reminders_lists lists them; default every list"
            },
            until: %{
              type: "string",
              description:
                "only those due by then: an ISO 8601 date (2026-11-01, the whole day) or date-time (2026-11-01T09:00)"
            },
            query: %{type: "string", description: "only those whose title or notes contain this text, any case"},
            completed: %{type: "boolean", description: "include completed reminders too"},
            limit: %{
              type: "integer",
              description: "at most this many, the soonest due; default 100. For more, narrow by list, until or query"
            }
          }
        },
        outputs: %{type: "object", properties: %{reminders: %{type: "array", items: @reminder}}, required: ["reminders"]}
      },
      %{
        name: "create",
        description:
          "Add a reminder to a list, which syncs to the user's other Apple devices; a due time alerts them then. Gives back the new reminder as apple-reminders_list gives them, with its id for apple-reminders_update or apple-reminders_delete.",
        inputs: %{
          type: "object",
          required: ["title"],
          properties: %{
            title: %{type: "string", description: "what to be reminded of, as the list shows it"},
            list: %{
              type: "string",
              description: "a list's name, as apple-reminders_lists lists them; default the Mac's default list"
            },
            due: %{
              type: "string",
              description:
                "an ISO 8601 date (2026-11-01), or a date-time (2026-11-01T09:00, in the Mac's time zone without an offset) to be alerted then"
            },
            notes: %{type: "string", description: "more detail, as plain text"},
            priority: @priority
          }
        },
        outputs: @reminder
      },
      %{
        name: "update",
        description:
          "Change a reminder, or mark it done with completed: only the fields given change. Gives back the reminder as it is now.",
        inputs: %{
          type: "object",
          required: ["id"],
          properties: %{
            id: @id,
            title: %{type: "string", description: "a new title"},
            list: %{
              type: "string",
              description: "move it to this list, by its name as apple-reminders_lists lists them"
            },
            due: %{type: "string", description: "an ISO 8601 date or date-time, or none to clear it"},
            notes: %{type: "string", description: "new notes, in place of the old"},
            priority: @priority,
            completed: %{type: "boolean", description: "true marks it done; false makes it not done again"}
          }
        },
        outputs: @reminder
      },
      %{
        name: "delete",
        description:
          "Delete a reminder from its list, on every Apple device. It can't be undone; to tick one off instead, apple-reminders_update with completed.",
        inputs: %{type: "object", required: ["id"], properties: %{id: @id}},
        outputs: %{
          type: "object",
          properties: %{id: %{type: "string", description: "The reminder it deleted"}},
          required: ["id"]
        }
      }
    ]
  end

  @impl true
  def call(tool, inputs, call) do
    answer = OneCore.Service.call(call, AppleReminders.Helper, :ask, [tool, inputs])

    case tool do
      "lists" -> %{lists: answer}
      "list" -> %{reminders: answer}
      "delete" -> %{id: inputs["id"]}
      _reminder -> answer
    end
  end
end
