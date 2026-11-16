defmodule AppleReminders do
  @moduledoc "Apple Reminders: the user's Apple Reminders on their Mac, through its service there, `AppleReminders.Helper`."
  @behaviour OneCore.Plugin

  @id %{type: "string", description: "the reminder's id, as apple-reminders_list gives it"}
  @priority %{type: "string", enum: ["high", "medium", "low", "none"], description: "high, medium, low or none"}
  @reminder "{ id, title, list, due, priority, notes, completed }, due a date or, with a time, an ISO 8601 date-time in the Mac's time zone, and completed when it was done"

  @impl true
  def tools do
    [
      %{
        name: "lists",
        read_only: true,
        description:
          "Every reminder list: each { name, id, account, default }, account being where it syncs (iCloud, Exchange). Use a name as list in apple-reminders_list or apple-reminders_create.",
        inputs: %{type: "object", properties: %{}}
      },
      %{
        name: "list",
        read_only: true,
        description:
          "Reminders not yet done, soonest due first and those with no due date last, from every list or one; completed ones too if asked. Gives each #{@reminder}.",
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
        }
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
        }
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
        }
      },
      %{
        name: "delete",
        description:
          "Delete a reminder from its list, on every Apple device. It can't be undone; to tick one off instead, apple-reminders_update with completed.",
        inputs: %{type: "object", required: ["id"], properties: %{id: @id}}
      }
    ]
  end

  @impl true
  def call(tool, inputs, call), do: OneCore.Service.call(call, AppleReminders.Helper, :ask, [tool, inputs])
end
