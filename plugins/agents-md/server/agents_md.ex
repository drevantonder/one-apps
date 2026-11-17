defmodule AgentsMd do
  @moduledoc """
  AGENTS.md: the AGENTS.md and skills every agent tool on every device gets. They're rows of `records` in the
  database of whoever the plugin is added for, oldest first, each a revision; the newest of each says what's
  current. Its service, `AgentsMd.Writer`, on each device it's installed on, writes them where each agent tool there
  reads them.
  """
  @behaviour OneCore.Plugin
  alias AgentsMd.Writer

  @schema [
    "create table records (n integer primary key, kind text not null, data text not null, time integer not null, by text)"
  ]

  @skill %{type: "string", description: "the skill's name, from agents-md_skills, like writing-for-agents"}
  @revision %{
    type: "string",
    description: "The new revision's id, for agents-md_restore. Every device's agent tools get it within a minute"
  }
  @made %{type: "object", properties: %{id: @revision}, required: ["id"]}
  @named %{type: "object", properties: %{name: %{type: "string"}, id: @revision}, required: ["name", "id"]}

  @impl true
  def title, do: "Agent Instructions"

  @impl true
  def icon, do: "icon.svg"

  @impl true
  def requires, do: %{"core" => "~> 0.18.0", "database" => "to keep your instructions and skills"}

  @impl true
  def tools do
    [
      %{
        name: "get",
        read_only: true,
        description:
          "The AGENTS.md every agent tool on every device gets: the instructions Claude Code reads as CLAUDE.md, and Codex, OpenCode and Amp as AGENTS.md. Read it before agents-md_set, which replaces all of it.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{text: %{type: "string", description: "The whole AGENTS.md, as markdown"}},
          required: ["text"]
        }
      },
      %{
        name: "set",
        description:
          "Replace the AGENTS.md (CLAUDE.md) every agent tool on every device gets, its instructions: all of it, so start from agents-md_get's text. agents-md_history keeps the old one.",
        inputs: %{
          type: "object",
          properties: %{text: %{type: "string", description: "the whole new AGENTS.md, as markdown"}},
          required: ["text"]
        },
        outputs: @made
      },
      %{
        name: "skills",
        read_only: true,
        description: "Every skill on every device: its name and description. agents-md_skill reads one's files.",
        inputs: %{type: "object", properties: %{}},
        outputs: %{
          type: "object",
          properties: %{
            skills: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{name: %{type: "string"}, description: %{type: "string"}},
                required: ["name", "description"]
              }
            }
          },
          required: ["skills"]
        }
      },
      %{
        name: "skill",
        read_only: true,
        description: "One skill's files, each one's text by its path in the skill.",
        inputs: %{type: "object", properties: %{name: @skill}, required: ["name"]},
        outputs: %{
          type: "object",
          properties: %{
            name: %{type: "string"},
            files: %{type: "object", additionalProperties: %{type: "string"}, description: "Each file's text, by its path"}
          },
          required: ["name", "files"]
        }
      },
      %{
        name: "skill_set",
        description:
          "Add or replace a skill on every device: all of its files, SKILL.md among them, starting with frontmatter giving its name and description (what it's for, and when to use it).",
        inputs: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "the skill's folder name: lowercase words joined by -, like writing-for-agents"
            },
            files: %{
              type: "object",
              additionalProperties: %{type: "string"},
              description:
                ~s(each file's path within the skill → its text, like { "SKILL.md": "---\\nname: writing-for-agents\\ndescription: ...\\n---\\n..." })
            }
          },
          required: ["name", "files"]
        },
        outputs: @named
      },
      %{
        name: "skill_remove",
        description:
          "Remove a skill from every device. agents-md_history with its name, then agents-md_restore, brings it back.",
        inputs: %{type: "object", properties: %{name: @skill}, required: ["name"]},
        outputs: @named
      },
      %{
        name: "history",
        read_only: true,
        description:
          "Every revision of AGENTS.md, or of a skill if given its name, newest first: each one's id (for agents-md_restore), when (ISO 8601), who made it, its size and its first changed line.",
        inputs: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "a skill's name, from agents-md_skills, like writing-for-agents; omit for AGENTS.md"
            }
          }
        },
        outputs: %{
          type: "object",
          properties: %{
            revisions: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  id: %{type: "string", description: "For agents-md_restore"},
                  time: %{type: "string", description: "When, in ISO 8601"},
                  by: %{type: ["string", "null"], description: "Who made it"},
                  size: %{type: "integer", description: "In bytes"},
                  change: %{type: "string", description: "Its first changed line, + added or - taken out, or removed"}
                },
                required: ["id", "time", "by", "size", "change"]
              }
            }
          },
          required: ["revisions"]
        }
      },
      %{
        name: "restore",
        description:
          "Make an older revision of AGENTS.md or a skill the current one again, on every device. The one it replaces stays in agents-md_history.",
        inputs: %{
          type: "object",
          properties: %{id: %{type: "string", description: "the revision's id, from agents-md_history"}},
          required: ["id"]
        },
        outputs: %{
          type: "object",
          properties: %{
            id: @revision,
            name: %{type: ["string", "null"], description: "The skill it restored, or null for AGENTS.md"}
          },
          required: ["id", "name"]
        }
      }
    ]
  end

  @impl true
  def call(tool, inputs, call) do
    database = OneCore.Call.plugin(call, "database")
    result = database.transaction(call, @schema, &run(tool, inputs, call, {database, &1}))
    if tool in ["set", "skill_set", "skill_remove", "restore"], do: tell_devices(call)
    result
  end

  @doc """
  AGENTS.md and every skill's files, as the service writes them: `%{"text" => text, "skills" => %{name => files},
  "revisions" => texts}`, each skill's files by their paths, and every text AGENTS.md has had.
  """
  def files(call) do
    database = OneCore.Call.plugin(call, "database")

    database.transaction(call, @schema, fn db ->
      records = records({database, db})
      {text, skills} = state(records)
      revisions = for %{kind: "agentsmd", data: data} <- records, do: to_string(data["text"])
      %{"text" => text, "skills" => skills, "revisions" => revisions}
    end)
  end

  @doc "Whether a skill's file's path leads out of its folder."
  def outside?(path) do
    String.starts_with?(path, "/") or String.contains?(path, "\\") or
      Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."]))
  end

  defp run("get", _inputs, _call, db), do: %{text: elem(state(records(db)), 0)}

  defp run("set", %{"text" => text}, call, db) do
    %{id: keep(db, call, "agentsmd", %{text: text})}
  end

  defp run("skills", _inputs, _call, db) do
    skills =
      for {name, files} <- elem(state(records(db)), 1) do
        front = frontmatter(files["SKILL.md"])
        %{name: name, description: (is_map(front) && front["description"]) || ""}
      end

    %{skills: skills}
  end

  defp run("skill", %{"name" => name}, _call, db),
    do: %{name: name, files: named(elem(state(records(db)), 1), name)}

  defp run("skill_set", %{"name" => name, "files" => files}, call, db) do
    if why = invalid(name, files) || unintroduced(name, files), do: raise(why)
    %{name: name, id: keep(db, call, "skill", %{name: name, files: files})}
  end

  defp run("skill_remove", %{"name" => name}, call, db) do
    named(elem(state(records(db)), 1), name)
    %{name: name, id: keep(db, call, "skill_removed", %{name: name})}
  end

  defp run("history", inputs, _call, db), do: %{revisions: history(records(db), inputs["name"])}

  defp run("restore", %{"id" => id}, call, db) do
    case Enum.find(records(db), &(&1.id == id)) do
      nil ->
        raise "No revision #{id}: ids come from agents-md_history"

      %{kind: "agentsmd", data: data} ->
        %{id: keep(db, call, "agentsmd", data), name: nil}

      %{kind: "skill", data: %{"name" => name, "files" => files} = data} ->
        if why = invalid(name, files), do: raise(why)
        %{id: keep(db, call, "skill", data), name: name}

      _ ->
        raise "#{id} isn't a revision of AGENTS.md or a skill"
    end
  end

  # Every device that writes them writes them again now, rather than within the minute. One that isn't up writes
  # them as it starts again.
  defp tell_devices(call) do
    for server <- OneCore.Service.servers(call, Writer) do
      try do
        OneCore.Service.call(call, Writer, :write, [], server)
      rescue
        _not_up -> :written_as_it_starts
      end
    end
  end

  defp records({database, db}) do
    for row <- database.query(db, "select n, kind, data, time, by from records order by n", []) do
      %{id: to_string(row["n"]), kind: row["kind"], data: JSON.decode!(row["data"]), time: row["time"], by: row["by"]}
    end
  end

  # Keeps a revision, and gives its id.
  defp keep({database, db}, call, kind, data) do
    database.query(db, "insert into records (kind, data, time, by) values (?, ?, ?, ?)", [
      kind,
      JSON.encode!(data),
      System.system_time(:millisecond),
      call.actor
    ])

    to_string(hd(database.query(db, "select max(n) as n from records", []))["n"])
  end

  # What's current: AGENTS.md's text, and each skill's files by its name.
  defp state(records) do
    Enum.reduce(records, {"", %{}}, fn
      %{kind: "agentsmd", data: data}, {_text, skills} ->
        {to_string(data["text"]), skills}

      %{kind: "skill", data: %{"name" => name, "files" => files}}, {text, skills} ->
        if invalid(name, files), do: {text, skills}, else: {text, Map.put(skills, name, files)}

      %{kind: "skill_removed", data: %{"name" => name}}, {text, skills} ->
        {text, Map.delete(skills, name)}
    end)
  end

  defp named(skills, name) do
    skills[name] ||
      raise "No skill #{name}: " <>
              if(skills == %{},
                do: "there are none yet; agents-md_skill_set adds one",
                else: "there's #{Enum.join(Map.keys(skills), ", ")}"
              )
  end

  defp invalid(name, files) do
    cond do
      not (is_binary(name) and name =~ ~r/^[a-z0-9-]+$/) -> "Not added: skill names are lowercase words joined by -"
      not (is_map(files) and is_binary(files["SKILL.md"])) -> "Not added: a skill needs a SKILL.md"
      path = Enum.find(Map.keys(files), &outside?/1) -> "#{path} isn't a path inside the skill"
      true -> nil
    end
  end

  # Agent tools load a skill by its frontmatter's name and description.
  defp unintroduced(name, files) do
    example = "---\nname: #{name}\ndescription: what it's for, and when to use it\n---"

    case frontmatter(files["SKILL.md"]) do
      why when is_binary(why) ->
        "Not added: SKILL.md's #{why}:\n#{example}"

      %{"name" => ^name, "description" => _} ->
        nil

      %{"name" => other, "description" => _} ->
        "Not added: SKILL.md's frontmatter names it #{other}, not #{name}: they must be the same"

      %{"name" => _} ->
        "Not added: SKILL.md's frontmatter has no description, which says what it's for and when to use it:\n#{example}"

      _ ->
        "Not added: SKILL.md's frontmatter has no name; it starts:\n#{example}"
    end
  end

  # A SKILL.md's frontmatter as agent tools read it: YAML between a first line of --- and the next. Text says
  # what's wrong with it.
  defp frontmatter(markdown) do
    with ["---" | rest] <- String.split(markdown, ~r/\r?\n/),
         {front, [_end | _]} <- Enum.split_while(rest, &(String.trim_trailing(&1) != "---")),
         {:ok, %{} = front} <- YamlElixir.read_from_string(Enum.join(front, "\n")) do
      for {key, value} <- front, is_binary(value) and String.trim(value) != "", into: %{} do
        {to_string(key), String.trim(value)}
      end
    else
      [_first | _] -> "first line must be ---, starting its frontmatter"
      {_front, []} -> "frontmatter must end with a line of ---"
      _ -> "frontmatter isn't YAML"
    end
  end

  defp history(records, skill) do
    records
    |> Enum.flat_map(fn record ->
      case {skill, record} do
        {nil, %{kind: "agentsmd", data: data}} ->
          [{record, to_string(data["text"])}]

        {name, %{kind: "skill", data: %{"name" => name, "files" => files}}} ->
          [{record, Enum.map_join(Enum.sort(files), fn {path, text} -> "--- #{path}\n#{text}\n" end)}]

        {name, %{kind: "skill_removed", data: %{"name" => name}}} ->
          [{record, nil}]

        _ ->
          []
      end
    end)
    |> Enum.map_reduce("", fn {record, now}, before ->
      revision = %{
        id: record.id,
        time: DateTime.to_iso8601(DateTime.from_unix!(record.time, :millisecond)),
        by: record.by,
        size: byte_size(now || ""),
        change: if(now, do: first_change(before, now), else: "removed")
      }

      {revision, now || ""}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp first_change(before, now) do
    {a, b} = {lines(before), lines(now)}
    same = Enum.count(Enum.take_while(Enum.zip(a, b), fn {x, y} -> x == y end))

    cond do
      same < length(b) -> "+ " <> String.slice(Enum.at(b, same), 0, 100)
      same < length(a) -> "- " <> String.slice(Enum.at(a, same), 0, 100)
      true -> "no change"
    end
  end

  defp lines(""), do: []
  defp lines(text), do: String.split(text, "\n")
end
