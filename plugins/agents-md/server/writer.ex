defmodule AgentsMd.Writer do
  @moduledoc """
  Writes AGENTS.md and the skills where each agent tool on its device reads them: as it starts, when they're
  changed, and every minute, so an agent tool installed later gets them too. They're the ones of whoever its
  server is for, or else the first it acts for: the first of `OneCore.Service.acts_for()`.

  A file starts with a comment saying where it's kept, and is written only if it's missing or what's under that
  comment is a text AGENTS.md has had, so an edit made on the device is never overwritten; `agents-md_set` changes
  it for every device.
  """
  use GenServer
  require Logger
  @behaviour OneCore.Service

  @every 60_000

  # A skill's folder this service keeps has this file in it. It's the name the app as it ran before marked its
  # skills with, so a device that had them is taken over rather than left with two of each; `@built_in` was the
  # mark on that app's own skills, which are taken over too.
  @marker ".synced-one-agents"
  @built_in ".synced-one"

  @impl OneCore.Service
  def called, do: "AGENTS.md's writer on this machine"

  @impl OneCore.Service
  def needs do
    "A Linux or Mac machine its person uses agent tools on (Claude Code, Codex, Amp, OpenCode). It writes their instructions and skills into the home folder of the user this server runs as."
  end

  @doc "Writes them now."
  def write(service), do: GenServer.call(service, :write, 30_000)

  @impl GenServer
  def init(_) do
    send(self(), :write)
    {:ok, %{logged: MapSet.new()}}
  end

  @impl GenServer
  def handle_call(:write, _from, state), do: {:reply, :ok, sync(state)}

  @impl GenServer
  def handle_info(:write, state) do
    Process.send_after(self(), :write, @every)
    {:noreply, sync(state)}
  end

  defp sync(state) do
    case OneCore.Service.acts_for() do
      [] -> state
      [who | _] -> write_all(OneCore.Service.plugin(self(), who, :files), state)
    end
  rescue
    problem -> log_once(state, "couldn't write them: " <> Exception.message(problem))
  end

  defp write_all(%{"text" => text, "skills" => skills, "revisions" => revisions}, state) do
    home = System.user_home!()
    state = instructions(text, revisions, home, state)
    Enum.reduce(skill_roots(home), state, &skills(&1, skills, &2))
  end

  # Claude Code reads only its own CLAUDE.md, never AGENTS.md. A tool that isn't on the device has no folder, and
  # gets nothing.
  defp instructions("", _revisions, _home, state), do: state

  defp instructions(text, revisions, home, state) do
    text =
      "<!-- AGENTS.md in The One App keeps this the same on every device: change it with agents-md_set (`one agents-md set`), and add a skill for every agent with agents-md_skill_set. Edited here, it stays on this device and stops updating. -->\n\n" <>
        under_comment(text) <> "\n"

    written = MapSet.new(revisions, &under_comment/1)

    files = [
      Path.join(System.get_env("CODEX_HOME") || Path.join(home, ".codex"), "AGENTS.md"),
      Path.join(home, ".config/amp/AGENTS.md"),
      Path.join(home, ".config/opencode/AGENTS.md"),
      Path.join(System.get_env("CLAUDE_CONFIG_DIR") || Path.join(home, ".claude"), "CLAUDE.md")
    ]

    for file <- files, File.dir?(Path.dirname(file)), reduce: state do
      state ->
        case File.read(file) do
          {:ok, ^text} -> state
          {:ok, now} -> if under_comment(now) in written, do: write(file, text, state), else: edited(file, state)
          {:error, _absent} -> write(file, text, state)
        end
    end
  end

  defp write(file, text, state) do
    File.write!(file, text)
    state
  end

  # An edit on the device is its person's to make, as the comment at its top says: not a problem.
  defp edited(file, state), do: log_once(state, "left #{file} alone: it was edited on this device", :info)

  # What a text says under the comment it starts with, if it starts with one, to its last line: the comment is this
  # service's, and has said different things as the plugin changed.
  defp under_comment(text), do: text |> String.replace(~r/\A<!--.*?-->\s*/s, "", global: false) |> String.trim_trailing()

  defp skill_roots(home) do
    for root <- [Path.join(home, ".claude/skills"), Path.join(home, ".agents/skills")],
        File.dir?(Path.dirname(root)),
        do: root
  end

  defp skills(root, skills, state) do
    File.mkdir_p!(root)
    state = Enum.reduce(skills, state, fn {name, files}, state -> skill(Path.join(root, name), files, state) end)

    for folder <- File.ls!(root),
        not Map.has_key?(skills, folder),
        File.regular?(Path.join([root, folder, @marker])),
        do: File.rm_rf!(Path.join(root, folder))

    state
  end

  # A skill's folder is written whole beside it and moved in, so an agent tool never reads half of one.
  defp skill(folder, files, state) do
    ours = File.regular?(Path.join(folder, @marker))
    same = ours and Enum.all?(files, fn {path, text} -> File.read(Path.join(folder, path)) == {:ok, text} end)

    cond do
      File.exists?(folder) and not ours and not File.regular?(Path.join(folder, @built_in)) ->
        log_once(state, "left #{folder} alone: it isn't a skill AGENTS.md keeps")

      same ->
        state

      path = Enum.find(Map.keys(files), &AgentsMd.outside?/1) ->
        log_once(state, "left #{folder} alone: #{path} isn't a path inside the skill")

      true ->
        writing = folder <> ".writing"
        File.rm_rf!(writing)

        for {path, text} <- files do
          File.mkdir_p!(Path.dirname(Path.join(writing, path)))
          File.write!(Path.join(writing, path), text)
        end

        File.write!(
          Path.join(writing, @marker),
          "This skill is kept the same on every device. Change it with agents-md_skill_set; delete this file to take the folder over.\n"
        )

        File.rm_rf!(folder)
        File.rename!(writing, folder)
        state
    end
  end

  # Says each problem once, not every minute.
  defp log_once(state, message, level \\ :warning) do
    if not MapSet.member?(state.logged, message), do: Logger.log(level, "AGENTS.md: " <> message)
    %{state | logged: MapSet.put(state.logged, message)}
  end
end
