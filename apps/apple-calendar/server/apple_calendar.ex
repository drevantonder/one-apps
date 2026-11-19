defmodule AppleCalendar do
  @moduledoc "Apple Calendar: the user's Apple Calendar on their Mac, through its service there, `AppleCalendar.Helper`."
  @behaviour OneCore.App

  # It has no app, so it says how it's called and drawn where it's shown, as the App Store.
  @impl true
  def icon, do: "icon.png"

  @impl true
  def requires, do: %{"core" => ">= 0.32.47"}

  @time "an ISO 8601 date (2026-11-01) or date-time (2026-11-01T09:00); without an offset, in the Mac's time zone"
  @id %{
    type: "string",
    description: "the event's id, as apple-calendar_events gives it; a repeating event's names one occurrence"
  }
  @future %{
    type: "boolean",
    description: "for a repeating event: this occurrence and every later one, not just this one"
  }
  @fields %{
    title: %{type: "string", description: "what it is, as the calendar shows it"},
    start: %{
      type: "string",
      description:
        "when it starts: an ISO 8601 date-time (2026-11-01T09:00, in the Mac's time zone without an offset), or a date (2026-11-01) for an all-day event"
    },
    end: %{
      type: "string",
      description:
        "when it ends: an ISO 8601 date-time, or an all-day event's last day; default an hour after start, or the same day"
    },
    all_day: %{type: "boolean", description: "an all-day event; a date as start makes one too"},
    calendar: %{
      type: "string",
      description: "a calendar's name, as apple-calendar_calendars lists them; default the Mac's default calendar"
    },
    location: %{type: "string", description: "where, as text: an address or a room"},
    notes: %{type: "string", description: "more detail, as plain text"}
  }

  # An event as EventKit has it. What it doesn't have is left out.
  @event %{
    type: "object",
    properties: %{
      id: %{type: "string", description: "For apple-calendar_update or apple-calendar_delete; a repeating event's names this occurrence"},
      title: %{type: "string"},
      calendar: %{type: "string", description: "Its calendar's name"},
      start: %{type: "string", description: "ISO 8601, in the Mac's time zone: a date for an all-day event"},
      end: %{type: "string", description: "ISO 8601, in the Mac's time zone: an all-day event's last day"},
      all_day: %{type: "boolean"},
      repeats: %{type: "boolean"},
      location: %{type: "string"},
      notes: %{type: "string"},
      url: %{type: "string"},
      attendees: %{type: "array", items: %{type: "string"}, description: "Each one's name, or address"}
    },
    required: ["id", "title", "start", "end"]
  }

  @impl true
  def tools do
    [
      %{
        name: "calendars",
        read_only: true,
        description:
          "Every calendar on the Mac, and where each syncs (iCloud, Google, Exchange). Use a name as calendar in apple-calendar_events or apple-calendar_create; only writable ones take new events.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{
            calendars: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  name: %{type: "string"},
                  id: %{type: "string"},
                  account: %{type: "string", description: "Where it syncs: iCloud, Google, Exchange"},
                  writable: %{type: "boolean", description: "Whether it takes new events"},
                  default: %{type: "boolean", description: "Whether it's the Mac's default calendar"}
                },
                required: ["name", "id", "writable"]
              }
            }
          },
          required: ["calendars"]
        }
      },
      %{
        name: "events",
        read_only: true,
        description:
          "Events between from and to, by default the coming week, earliest first, from every calendar or one, as EventKit has them, times in the Mac's time zone. Use it to see what's on today or this week, search for an event, or for an event's id to update or delete.",
        inputs: %{
          type: "object",
          properties: %{
            from: %{type: "string", description: "the range's start: #{@time}; default the start of today"},
            to: %{
              type: "string",
              description: "the range's end: #{@time}; a date includes that whole day; default a week after from"
            },
            calendar: %{
              type: "string",
              description:
                "only this calendar, by its name as apple-calendar_calendars lists them; default every calendar"
            },
            query: %{
              type: "string",
              description: "only events whose title, location or notes contain this text, any case"
            },
            limit: %{
              type: "integer",
              description: "at most this many, the earliest; default 200. For more, narrow from and to"
            }
          }
        },
        outputs: %{type: "object", properties: %{events: %{type: "array", items: @event}}, required: ["events"]}
      },
      %{
        name: "create",
        description:
          "Add an event to one of the Mac's calendars, which syncs it to that calendar's account; invitees aren't added. Gives back the new event as apple-calendar_events lists it, with its id for apple-calendar_update or apple-calendar_delete.",
        inputs: %{type: "object", required: ["title", "start"], properties: @fields},
        outputs: @event
      },
      %{
        name: "update",
        description:
          "Change an event: only the fields given change, and moving start keeps its length unless end is given too. Gives back the event as it is now.",
        inputs: %{
          type: "object",
          required: ["id"],
          properties:
            Map.merge(@fields, %{
              id: @id,
              future: @future,
              calendar: %{
                type: "string",
                description: "move it to this calendar, by its name as apple-calendar_calendars lists them"
              }
            })
        },
        outputs: @event
      },
      %{
        name: "delete",
        description:
          "Delete an event from its calendar, or one occurrence of a repeating event (with future, every later one too). It can't be undone: the calendar's account deletes it everywhere.",
        inputs: %{type: "object", required: ["id"], properties: %{id: @id, future: @future}},
        outputs: %{
          type: "object",
          properties: %{id: %{type: "string", description: "The event it deleted"}},
          required: ["id"]
        }
      }
    ]
  end

  @impl true
  def call(tool, inputs, call) do
    answer = OneCore.Service.call(call, AppleCalendar.Helper, :ask, [tool, inputs])

    case tool do
      "calendars" -> %{calendars: answer}
      "events" -> %{events: answer}
      "delete" -> %{id: inputs["id"]}
      _event -> answer
    end
  end
end
