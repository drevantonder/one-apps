defmodule AgentMemory do
  @moduledoc """
  Agent Memory: OptMem (github.com/VictorTaelin/OptMem) as an app. One log of one-line memories, kept forever,
  and a binary tree of one-line summaries over it, which the agents write when a note asks. Its tools are memo's
  commands, and work as they do there.

  A memory is a row of `log`, whose id is its place, from 0, and a summary a row of `tree`: block
  `[k * size, (k + 1) * size)` of the log. Each level of the tree is a dense prefix, so its row count says how far
  it got. Whose memory it is is whoever the app is added for: the network's, a group's or a user's.
  """
  @behaviour OneCore.App

  # The memory context: how many lines wake gives (about 8k tokens).
  @wake_lines 96
  # The longest one memory may be, in bytes.
  @entry 280
  # A wake part's or recall's largest size, in bytes, and a part's most lines, so no harness cuts it.
  @part_bytes 20_000
  @part_lines 500
  # Blocks up to this many memories compress from the log itself; bigger ones from their halves.
  @raw_max 16

  @schema [
    "create table log (id integer primary key, date text not null, text text not null)",
    "create table tree (size integer not null, k integer not null, text text not null, primary key (size, k))"
  ]

  @impl true
  def icon, do: "client/icon.svg"

  # Its data is the memory of whoever it's installed for: the network's is every agent's in it, and one installed for a person is theirs alone.
  @impl true
  def own, do: :installed

  @impl true
  def requires, do: %{"core" => ">= 0.22.18", "database" => "to keep your memory"}

  @impl true
  def entrypoints, do: [%{page: "client/index.html"}]

  @block %{type: "string", description: "a block id, as wake or a nap prompt gives it, like 16-31"}
  # One line of the memory: a memory (`hi` one past `lo`, with its `id` and `date`), or the summary of a block.
  @line %{
    type: "object",
    properties: %{
      lo: %{type: "integer", description: "The first memory it covers"},
      hi: %{type: "integer", description: "One past the last memory it covers"},
      id: %{type: "integer", description: "A memory's id"},
      date: %{type: "string", description: "A memory's day, YYYY-MM-DD"},
      text: %{type: ["string", "null"], description: "The memory, or the summary: null for one not written yet"}
    },
    required: ["lo", "hi", "text"]
  }
  @nap %{
    type: ["string", "null"],
    description: "The next compression to do before your next action, as a prompt, or null if there's none"
  }

  @impl true
  def tools do
    [
      %{
        name: "wake",
        read_only: true,
        description:
          "Read your memory: the first call of every session. Recent memories word for word, older ones as summaries, oldest first, in parts that fit any harness: run each part until one says you are awake.",
        inputs: %{
          type: "object",
          properties: %{
            part: %{
              type: "integer",
              description: "which part, from 1; a part that isn't the last says how to read the next"
            },
            T: %{type: "integer", description: "the snapshot a later part reads, as the previous part gives it"},
            format: %{
              type: "string",
              enum: ["text", "json"],
              description:
                "json for the screen: every line as `memory`, a summary not yet written as null; text (the default) to read, in parts"
            }
          }
        },
        outputs: %{
          type: "object",
          properties: %{
            count: %{type: "integer", description: "How many memories there are, the snapshot T"},
            part: %{type: "integer", description: "Which part this is, from 1"},
            parts: %{type: "integer", description: "How many parts there are"},
            lines: %{
              type: "array",
              items: %{type: "string"},
              description: "This part's lines, oldest first: #<id> <date> <memory>, or #<lo>-<hi> <summary>"
            },
            memory: %{type: "array", items: @line, description: "With format json: every line, oldest first"},
            awake: %{type: "boolean", description: "Whether you've read it all"},
            next: %{type: ["string", "null"], description: "What to run next, until you're awake"},
            nap: @nap
          },
          required: ["count"]
        }
      },
      %{
        name: "note",
        description:
          "Remember something: record one memory, one line of at most #{@entry} bytes, for every agent to recall. If it asks a compression, do it before your next action.",
        inputs: %{
          type: "object",
          properties: %{
            text: %{
              type: "string",
              description: ~s(one line, at most #{@entry} bytes, like "Sam wants mockups before any UI is built.")
            }
          },
          required: ["text"]
        },
        outputs: %{
          type: "object",
          properties: %{id: %{type: "integer", description: "The memory's id"}, nap: @nap},
          required: ["id", "nap"]
        }
      },
      %{
        name: "nap",
        description:
          "Do the pending compressions: without block and text, gives the next one; with them, saves that summary and gives the next.",
        inputs: %{
          type: "object",
          properties: %{
            block: @block,
            text: %{type: "string", description: "the summary: one line, at most #{@entry} bytes"}
          }
        },
        outputs: %{
          type: "object",
          properties: %{
            saved: %{type: ["string", "null"], description: "The block whose summary it saved, if it saved one"},
            nap: %{@nap | description: "The next compression, as a prompt, or null once nothing is left to compress"},
            left: %{type: "integer", description: "How many compressions are left, that one among them"}
          },
          required: ["saved", "nap", "left"]
        }
      },
      %{
        name: "recall",
        read_only: true,
        description:
          "Search every memory ever recorded, word for word, with a case-insensitive regular expression, to remember what was decided or tried. Gives the newest matches that fit.",
        inputs: %{
          type: "object",
          properties: %{
            pattern: %{type: "string", description: "a regular expression, like kitchen|reno or deploy.*failed"}
          },
          required: ["pattern"]
        },
        outputs: %{
          type: "object",
          properties: %{
            matches: %{type: "array", items: %{type: "string"}, description: "The newest that fit, oldest first: #<id> <date> <memory>"},
            count: %{type: "integer", description: "How many matched: more than are given where a narrower regex is needed"}
          },
          required: ["matches", "count"]
        }
      },
      %{
        name: "zoom",
        read_only: true,
        description:
          "Open one node of the memory's tree into its two halves, each a summary or, once single, the memory itself.",
        inputs: %{type: "object", properties: %{block: @block}, required: ["block"]},
        outputs: %{
          type: "object",
          properties: %{halves: %{type: "array", items: @line, description: "Its halves that have memories yet"}},
          required: ["halves"]
        }
      },
      %{
        name: "forget",
        description:
          "Drop a bad summary and every one built on it; agent-memory_nap writes them again. The memories themselves are never touched.",
        inputs: %{type: "object", properties: %{block: @block}, required: ["block"]},
        outputs: %{
          type: "object",
          properties: %{
            forgot: %{type: "integer", description: "How many summaries it dropped, for agent-memory_nap to write again"}
          },
          required: ["forgot"]
        }
      },
      %{
        name: "import",
        description:
          "Bulk-load dated memories, to start a memory from older records: lines of 'YYYY-MM-DD <text>', oldest first, none older than the newest memory already here.",
        inputs: %{
          type: "object",
          properties: %{
            text: %{
              type: "string",
              description: "lines of 'YYYY-MM-DD <text>', like 2026-11-08 Sam wants mockups before any UI is built."
            }
          },
          required: ["text"]
        },
        outputs: %{
          type: "object",
          properties: %{
            first: %{type: "integer", description: "The first imported memory's id"},
            last: %{type: "integer", description: "The last one's"},
            left: %{type: "integer", description: "How many compressions are pending: run agent-memory_nap"}
          },
          required: ["first", "last", "left"]
        }
      }
    ]
  end

  @impl true
  def call(tool, inputs, call) do
    database = OneCore.Call.app(call, "database")
    database.transaction(call, @schema, &run(tool, inputs, {database, &1}))
  end

  defp run("wake", %{"format" => "json"}, m) do
    now = count(m)
    %{count: now, memory: document(m, now)}
  end

  defp run("wake", inputs, m) do
    now = count(m)
    k = Map.get(inputs, "part", 1)
    t = Map.get(inputs, "T", now)
    if t > now, do: raise("T=#{t}, but the memory holds #{plural(now, "memory")}. Run: agent-memory_wake")

    if t == 0 do
      %{count: 0, part: 1, parts: 1, lines: [], awake: true, next: "No memories yet. Record the first with agent-memory_note.", nap: nil}
    else
      lines = document(m, t)

      case Enum.find(lines, &(&1.text == nil)) do
        nil -> awake(m, t, k, Enum.map(lines, &line/1))
        missing -> cannot_wake(m, t, missing)
      end
    end
  end

  defp run("note", %{"text" => text}, m) do
    text = line!(text)
    i = count(m)
    q(m, "insert into log (id, date, text) values (?, ?, ?)", [i, Date.to_iso8601(Date.utc_today()), text])
    %{id: i, nap: next_nap(m, i + 1)}
  end

  defp run("nap", inputs, m) when not is_map_key(inputs, "block") and not is_map_key(inputs, "text") do
    t = count(m)
    %{saved: nil, nap: next_nap(m, t), left: pending_count(m, t)}
  end

  defp run("nap", %{"block" => block, "text" => text}, m) do
    t = count(m)
    {lo, hi} = block!(block)

    case pending(m, t, 1) do
      [] ->
        %{saved: nil, nap: nil, left: 0}

      [{^lo, ^hi}] ->
        size = hi - lo
        q(m, "insert into tree (size, k, text) values (?, ?, ?)", [size, div(lo, size), line!(text)])
        %{saved: "#{lo}-#{hi - 1}", nap: next_nap(m, t), left: pending_count(m, t)}

      [{a, b}] ->
        if summary(m, lo, hi) == nil,
          do:
            raise("Wrong block: #{block}. Blocks are built in order; the next is #{a}-#{b - 1}. Run: agent-memory_nap"),
          else: %{saved: nil, nap: next_nap(m, t), left: pending_count(m, t)}
    end
  end

  defp run("nap", _inputs, _m),
    do: raise("Give both block and text, as the prompt says, or neither for the next compression.")

  # One pass, keeping only the newest matches that fit: a vague pattern matches the whole log.
  defp run("recall", %{"pattern" => pattern}, m) do
    pattern =
      case Regex.compile(pattern, "iu") do
        {:ok, pattern} -> pattern
        {:error, {why, _at}} -> raise "bad regex: #{why}"
      end

    {hits, tail, _size} =
      Stream.iterate(0, &(&1 + 4096))
      |> Stream.map(&slice(m, &1, &1 + 4096))
      |> Stream.transform(:going, fn
        _rows, :done -> {:halt, :done}
        rows, :going -> {rows, if(length(rows) < 4096, do: :done, else: :going)}
      end)
      |> Stream.map(&entry/1)
      |> Stream.filter(&Regex.match?(pattern, &1))
      |> Enum.reduce({0, :queue.new(), 0}, fn line, {hits, tail, size} ->
        fit(hits + 1, :queue.in(line, tail), size + byte_size(line) + 1)
      end)

    %{matches: :queue.to_list(tail), count: hits}
  end

  defp run("zoom", %{"block" => block}, m) do
    {lo, hi} = block!(block)
    t = count(m)
    if lo >= t, do: raise("##{block} is beyond the memory: it holds #{plural(t, "memory")}. Run: agent-memory_wake")
    mid = div(lo + hi, 2)

    # A half in the future has no memories yet.
    halves =
      for {a, b} <- [{lo, mid}, {mid, hi}], a < t do
        if b - a == 1, do: Map.merge(%{lo: a, hi: b}, hd(slice(m, a, b))), else: %{lo: a, hi: b, text: summary(m, a, b)}
      end

    %{halves: halves}
  end

  defp run("forget", %{"block" => block}, m) do
    {lo, hi} = block!(block)
    t = count(m)
    have = levels(m)

    gone =
      Stream.iterate(hi - lo, &(&1 * 2))
      |> Enum.take_while(&(&1 <= t))
      |> Enum.reduce(0, fn size, gone ->
        k = div(lo, size)
        q(m, "delete from tree where size = ? and k >= ?", [size, k])
        gone + max(0, Map.get(have, size, 0) - k)
      end)

    if gone == 0, do: raise("No summary at #{block}.")
    %{forgot: gone}
  end

  defp run("import", %{"text" => text}, m) do
    t = count(m)
    last = if t > 0, do: hd(slice(m, t - 1, t)).date, else: "0000-00-00"

    {items, _last} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
      |> Enum.map_reduce(last, fn {line, i}, last ->
        {date, body} =
          case String.split(line, " ", parts: 2) do
            [date, body] -> {date, String.trim(body)}
            [date] -> {date, ""}
          end

        cond do
          not (date =~ ~r/^\d{4}-\d{2}-\d{2}$/) ->
            raise "line #{i}: expected 'YYYY-MM-DD <text>', got: #{line}"

          not match?({:ok, _}, Date.from_iso8601(date)) ->
            raise "line #{i}: #{date} is not a real date."

          date < last ->
            raise "line #{i}: date #{date} precedes the previous memory (#{last})."

          body == "" or byte_size(body) > @entry or body =~ "\r" ->
            raise "line #{i}: #{byte_size(body)} bytes, limit #{@entry}."

          true ->
            {{date, body}, date}
        end
      end)

    if items == [], do: raise("No memories in that text.")

    for {{date, body}, i} <- Enum.with_index(items, t),
        do: q(m, "insert into log (id, date, text) values (?, ?, ?)", [i, date, body])

    n = length(items)
    %{first: t, last: t + n - 1, left: pending_count(m, t + n)}
  end

  # Wake's answer once every line it needs is written: the part asked for, and whether there's more to read.
  defp awake(m, t, k, lines) do
    parts = paginate(lines)
    count = length(parts)
    if k < 1 or k > count, do: raise("No part #{k}: the memory has #{plural(count, "part")}. Run: agent-memory_wake")
    awake = k == count

    %{
      count: t,
      part: k,
      parts: count,
      lines: Enum.at(parts, k - 1),
      awake: awake,
      next: if(not awake, do: "Not awake yet. Run: agent-memory_wake with part #{k + 1} and T #{t}"),
      nap: if(awake, do: next_nap(m, t))
    }
  end

  defp cannot_wake(m, t, %{lo: lo, hi: hi}) do
    nap = next_nap(m, t) || raise "The summary of ##{lo}-#{hi - 1} is missing. Run: agent-memory_forget #{lo}-#{hi - 1}"

    %{
      count: t,
      lines: [],
      awake: false,
      next:
        "Cannot wake: the memory context needs ##{lo}-#{hi - 1}, which is not compressed yet. " <>
          "Do the #{plural(pending_count(m, t), "compression")} nap gives, then run agent-memory_wake again.",
      nap: nap
    }
  end

  # Drops the oldest matches kept until what's kept fits a part.
  defp fit(hits, tail, size) when size <= @part_bytes, do: {hits, tail, size}

  defp fit(hits, tail, size) do
    {{:value, oldest}, tail} = :queue.out(tail)
    fit(hits, tail, size - byte_size(oldest) - 1)
  end

  # ---------------------------------------------------------------- blocks, as memo's

  # Tiles [0, t) with aligned power-of-two blocks, keeping a block whole if its size is at most alpha times its age.
  defp tile(t, alpha) do
    root = Enum.find(Stream.iterate(1, &(&1 * 2)), &(&1 >= t))
    Enum.sort(split([{0, root}], t, alpha, []))
  end

  defp split([], _t, _alpha, out), do: out
  defp split([{lo, _hi} | rest], t, alpha, out) when lo >= t, do: split(rest, t, alpha, out)

  defp split([{lo, hi} | rest], t, alpha, out) do
    size = hi - lo

    if size > 1 and (hi > t or size > alpha * (t - lo)),
      do: split([{lo, div(lo + hi, 2)}, {div(lo + hi, 2), hi} | rest], t, alpha, out),
      else: split(rest, t, alpha, [{lo, hi} | out])
  end

  # The blocks wake gives: at most `budget`, finest near t. Detail decays with age, so recent memories stay word for
  # word and old ones collapse; if everything fits, nothing is compressed.
  defp cover(t, _budget) when t <= 0, do: []
  defp cover(t, budget) when t <= budget, do: for(i <- 0..(t - 1), do: {i, i + 1})

  defp cover(t, budget) do
    {_lo, alpha} =
      Enum.reduce(1..60, {0.0, 1.0}, fn _, {lo, hi} ->
        mid = (lo + hi) / 2
        if length(tile(t, mid)) > budget, do: {mid, hi}, else: {lo, mid}
      end)

    spend(tile(t, alpha), budget)
  end

  # Sizes jump in powers of two, so alpha alone can undershoot: what's left is spent on the present.
  defp spend(blocks, budget) when length(blocks) >= budget, do: blocks

  defp spend(blocks, budget) do
    case blocks |> Enum.with_index() |> Enum.filter(fn {{a, z}, _} -> z - a > 1 end) |> List.last() do
      nil ->
        blocks

      {{a, z}, i} ->
        spend(Enum.take(blocks, i) ++ [{a, div(a + z, 2)}, {div(a + z, 2), z}] ++ Enum.drop(blocks, i + 1), budget)
    end
  end

  # `<lo>-<hi>` as wake and the nap prompts give it: inclusive at both ends, and a real block, an aligned power of two.
  defp block!(id) do
    case Regex.run(~r/^(\d+)-(\d+)$/, String.trim(id)) do
      [_, lo, hi] ->
        {lo, hi} = {String.to_integer(lo), String.to_integer(hi) + 1}
        n = hi - lo

        if n < 2 or Bitwise.band(n, n - 1) != 0 or rem(lo, n) != 0,
          do: raise("#{id} is not a block. Copy an id wake gives, like 16-31."),
          else: {lo, hi}

      nil ->
        raise "'#{id}' is not a block id. Copy it from the prompt, like 16-31."
    end
  end

  defp line!(text) do
    text = String.trim(text)
    lines = length(String.split(text, ~r/\r\n|\r|\n/))

    cond do
      text == "" ->
        raise "Empty. A memory is one line of text."

      lines > 1 ->
        raise "#{lines} lines. A memory is one line: merge them, or note them separately."

      byte_size(text) > @entry ->
        raise "Too long: #{byte_size(text)} bytes, limit #{@entry}. Accented characters cost 2 bytes. Compress it further."

      true ->
        text
    end
  end

  # ---------------------------------------------------------------- the store

  defp q({database, db}, sql, values \\ []), do: database.query(db, sql, values)

  defp count(m), do: hd(q(m, "select count(*) as n from log"))["n"]

  defp slice(m, lo, hi) do
    for row <- q(m, "select id, date, text from log where id >= ? and id < ? order by id", [lo, hi]),
        do: %{id: row["id"], date: row["date"], text: row["text"]}
  end

  defp summary(m, lo, hi) do
    case q(m, "select text from tree where size = ? and k = ?", [hi - lo, div(lo, hi - lo)]) do
      [%{"text" => text}] -> text
      [] -> nil
    end
  end

  # How many blocks each level holds.
  defp levels(m), do: Map.new(q(m, "select size, count(*) as n from tree group by size"), &{&1["size"], &1["n"]})

  # Blocks that can be built and haven't been, smallest first.
  defp pending(m, t, limit) do
    have = levels(m)

    Stream.iterate(2, &(&1 * 2))
    |> Stream.take_while(&(&1 <= t))
    |> Stream.flat_map(fn size ->
      for k <- Map.get(have, size, 0)..(div(t, size) - 1)//1, do: {k * size, (k + 1) * size}
    end)
    |> Enum.take(limit)
  end

  defp pending_count(m, t) do
    have = levels(m)

    Stream.iterate(2, &(&1 * 2))
    |> Enum.take_while(&(&1 <= t))
    |> Enum.map(&max(0, div(t, &1) - Map.get(have, &1, 0)))
    |> Enum.sum()
  end

  # The prompt for one compression.
  defp nap_prompt(m, lo, hi, left) do
    body =
      if hi - lo <= @raw_max do
        Enum.map_join(slice(m, lo, hi), "\n", &"  #{entry(&1)}")
      else
        mid = div(lo + hi, 2)

        Enum.map_join([{lo, mid}, {mid, hi}], "\n", fn {a, b} ->
          text =
            summary(m, a, b) || raise "The summary of ##{a}-#{b - 1} is missing. Run: agent-memory_forget #{a}-#{b - 1}"

          "  ##{a}-#{b - 1} #{text}"
        end)
      end

    tail =
      case left do
        0 -> ""
        1 -> "\n1 compression remains after this one."
        left -> "\n#{left} compressions remain after this one."
      end

    "Compress memories ##{lo}-#{hi - 1} into one line of at most #{@entry} bytes.\n" <>
      "Keep what has lasting effect, drop what does not. Invent nothing.\n\n#{body}\n#{tail}\n" <>
      ~s(Run: agent-memory_nap with block "#{lo}-#{hi - 1}" and text "<your line>")
  end

  defp next_nap(m, t) do
    case pending(m, t, 1) do
      [{lo, hi}] -> nap_prompt(m, lo, hi, pending_count(m, t) - 1)
      [] -> nil
    end
  end

  # The lines of the memory as of t: a memory, or a summary, which is nil until it's written.
  defp document(m, t) do
    blocks = cover(t, @wake_lines)
    first = Enum.find_value(blocks, t, fn {lo, hi} -> if hi - lo == 1, do: lo end)
    raw = Map.new(slice(m, first, t), &{&1.id, &1})
    sums = Map.new(q(m, "select size, k, text from tree"), &{{&1["size"], &1["k"]}, &1["text"]})

    for {lo, hi} <- blocks do
      if hi - lo == 1,
        do: Map.merge(%{lo: lo, hi: hi}, raw[lo]),
        else: %{lo: lo, hi: hi, text: sums[{hi - lo, div(lo, hi - lo)}]}
    end
  end

  # A line as wake gives it, or nil for a summary that isn't written.
  defp line(%{id: _} = memory), do: entry(memory)
  defp line(%{text: nil}), do: nil
  defp line(%{lo: lo, hi: hi, text: text}), do: "##{lo}-#{hi - 1} #{text}"

  defp entry(memory), do: "##{memory.id} #{memory.date} #{memory.text}"

  defp paginate(lines) do
    lines
    |> Enum.chunk_while(
      {[], 0},
      fn line, {part, size} ->
        n = byte_size(line) + 1

        if part != [] and (length(part) >= @part_lines or size + n > @part_bytes),
          do: {:cont, Enum.reverse(part), {[line], n}},
          else: {:cont, {[line | part], size + n}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {part, _} -> {:cont, Enum.reverse(part), {[], 0}}
      end
    )
  end

  defp plural(1, word), do: "1 #{word}"

  defp plural(n, word) do
    cond do
      String.ends_with?(word, "y") -> "#{n} #{String.slice(word, 0..-2//1)}ies"
      word =~ ~r/[shx]$/ -> "#{n} #{word}es"
      true -> "#{n} #{word}s"
    end
  end
end
