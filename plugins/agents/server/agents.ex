defmodule Agents do
  @moduledoc """
  AGENTS.md: the AGENTS.md and skills every agent tool on every device gets. They're rows of `records` in the
  database of whoever the plugin is added for, oldest first, each a revision; the newest of each says what's
  current. Its service, `Agents.Writer`, on each device it's installed on, writes them where each agent tool there
  reads them.
  """
  @behaviour OneCore.Plugin
  alias Agents.Writer

  @schema [
    "create table records (n integer primary key, kind text not null, data text not null, time integer not null, by text)"
  ]

  @skill %{type: "string", description: "the skill's name, from agents_skills, like writing-for-agents"}
  @every_device "every device's agent tools get it within a minute"

  @impl true
  def uses, do: ["database"]

  @impl true
  def tools do
    [
      %{
        name: "get",
        read_only: true,
        description:
          "The AGENTS.md every agent tool on every device gets, as { text }. Read it before agents_set, which replaces all of it.",
        inputs: %{type: "object", properties: %{}}
      },
      %{
        name: "set",
        description:
          "Replace the AGENTS.md every agent tool on every device gets: all of it, so start from agents_get's text. agents_history keeps the old one.",
        inputs: %{
          type: "object",
          properties: %{text: %{type: "string", description: "the whole new AGENTS.md, as markdown"}},
          required: ["text"]
        }
      },
      %{
        name: "skills",
        read_only: true,
        description: "Every skill on every device: its name and description. agents_skill reads one's files.",
        inputs: %{type: "object", properties: %{}}
      },
      %{
        name: "skill",
        read_only: true,
        description: "One skill's files, as { name, files: { path: text } }.",
        inputs: %{type: "object", properties: %{name: @skill}, required: ["name"]}
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
        }
      },
      %{
        name: "skill_remove",
        description:
          "Remove a skill from every device. agents_history with its name, then agents_restore, brings it back.",
        inputs: %{type: "object", properties: %{name: @skill}, required: ["name"]}
      },
      %{
        name: "history",
        read_only: true,
        description:
          "Every revision of AGENTS.md, or of a skill if given its name, newest first: each one's id (for agents_restore), when (ISO 8601), who made it, its size and its first changed line.",
        inputs: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "a skill's name, from agents_skills, like writing-for-agents; omit for AGENTS.md"
            }
          }
        }
      },
      %{
        name: "restore",
        description:
          "Make an older revision of AGENTS.md or a skill the current one again, on every device. The one it replaces stays in agents_history.",
        inputs: %{
          type: "object",
          properties: %{id: %{type: "string", description: "the revision's id, from agents_history"}},
          required: ["id"]
        }
      }
    ]
  end

  @impl true
  def call(tool, inputs, call) do
    database = OneCore.Call.plugin(call, "database")
    answer = database.transaction(call, @schema, &run(tool, inputs, call, {database, &1}))
    if tool in ["set", "skill_set", "skill_remove", "restore"], do: tell_devices(call)
    answer
  end

  @doc """
  AGENTS.md and every skill's files, as the service writes them: `%{"text" => text, "skills" => %{name => files}}`,
  each skill's files by their paths.
  """
  def files(call) do
    database = OneCore.Call.plugin(call, "database")
    {text, skills} = database.transaction(call, @schema, &state(records({database, &1})))
    %{"text" => text, "skills" => skills}
  end

  @doc "Whether a skill's file's path leads out of its folder."
  def outside?(path) do
    String.starts_with?(path, "/") or String.contains?(path, "\\") or
      Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."]))
  end

  defp run("get", _inputs, _call, db), do: %{text: elem(state(records(db)), 0)}

  defp run("set", %{"text" => text}, call, db) do
    keep(db, call, "agentsmd", %{text: text})
    "AGENTS.md is set; #{@every_device}."
  end

  defp run("skills", _inputs, _call, db) do
    for {name, files} <- elem(state(records(db)), 1) do
      front = frontmatter(files["SKILL.md"])
      %{name: name, description: (is_map(front) && front["description"]) || ""}
    end
  end

  defp run("skill", %{"name" => name}, _call, db),
    do: %{name: name, files: named(elem(state(records(db)), 1), name)}

  defp run("skill_set", %{"name" => name, "files" => files}, call, db) do
    if why = invalid(name, files) || unintroduced(name, files), do: raise(why)
    keep(db, call, "skill", %{name: name, files: files})
    "#{name} is set; #{@every_device}."
  end

  defp run("skill_remove", %{"name" => name}, call, db) do
    named(elem(state(records(db)), 1), name)
    keep(db, call, "skill_removed", %{name: name})
    "#{name} is removed; #{@every_device}."
  end

  defp run("history", inputs, _call, db), do: history(records(db), inputs["name"])

  defp run("restore", %{"id" => id}, call, db) do
    case Enum.find(records(db), &(&1.id == id)) do
      nil ->
        raise "No revision #{id}: ids come from agents_history"

      %{kind: "agentsmd", data: data} ->
        keep(db, call, "agentsmd", data)
        "That AGENTS.md is current again; #{@every_device}."

      %{kind: "skill", data: %{"name" => name, "files" => files} = data} ->
        if why = invalid(name, files), do: raise(why)
        keep(db, call, "skill", data)
        "That #{name} is current again; #{@every_device}."

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

  defp keep({database, db}, call, kind, data) do
    database.query(db, "insert into records (kind, data, time, by) values (?, ?, ?, ?)", [
      kind,
      JSON.encode!(data),
      System.system_time(:millisecond),
      call.actor
    ])
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
                do: "there are none yet; agents_skill_set adds one",
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
