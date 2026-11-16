defmodule AIUsage do
  @moduledoc """
  AI Usage: every AI plan's limits, and whether the pace lasts to reset. Its service, `AIUsage.Reader`, reads the
  plans signed in on each machine it's installed on; this asks every one of them, merges by account (the newest
  read wins, wherever it was made), keeps the readings in its database for 30 days, and says in the providers' own
  words how much is left and what the pace does: a deficit or a reserve against even use, what was expected by
  now, and whether it lasts until the window resets.

  A reading is a row of `readings`, and each account's newest is found through the index on (provider, account,
  at), so finding them costs the same however many readings are kept.
  """
  @behaviour OneCore.Plugin
  alias AIUsage.Reader

  # A reading this new is answered as it is; an older one is read again. Readings are kept this long.
  @fresh 5 * 60_000
  @keep 30 * 86_400_000

  @providers %{
    "claude" => %{title: "Claude", session: 300, weekly: 10_080},
    "codex" => %{title: "Codex", session: 300, weekly: 10_080},
    "opencodego" => %{title: "OpenCode Go", session: 300, weekly: 10_080}
  }
  @order ["claude", "codex", "opencodego"]

  @schema [
    """
    create table readings (
      provider text not null, account text not null, machine text not null, machines text not null,
      at integer not null, plan text, active integer not null, disabled integer not null,
      session_used real, session_resets integer, weekly_used real, weekly_resets integer,
      monthly_used real, monthly_resets integer, models text not null, pace text not null, extra text, note text
    )
    """,
    "create index readings_newest on readings (provider, account, at)"
  ]

  @impl true
  def uses, do: ["database"]

  # Fresh readings every five minutes, so the pace has readings far enough apart to say when a window runs out.
  @impl true
  def jobs, do: [%{tool: "status", every: 300}]

  @impl true
  def apps, do: [%{name: "AI Usage", page: "client/index.html", icon: "client/icon.svg"}]

  @percent %{type: ["number", "null"], description: "Percent"}
  # One window of a plan: how much of it is used and left, when it resets, and its pace.
  @window %{
    type: "object",
    properties: %{
      used: @percent,
      left: @percent,
      resets: %{type: ["string", "null"], description: "When, as a person reads it, like Sun at 11:59 PM"},
      countdown: %{type: ["string", "null"], description: "When, from now, like in 1d 3h"},
      pace: %{type: ["string", "null"], description: "In the provider's words: a deficit or a reserve against even use, what was expected by now, and whether it lasts"},
      will_last: %{type: ["boolean", "null"], description: "Whether the pace lasts until it resets"}
    }
  }

  @impl true
  def tools do
    [
      %{
        name: "status",
        read_only: true,
        description:
          "Every AI plan's limits (or one provider's), each Claude account apart: what's left, the pace, and whether it lasts to reset, in the providers' own words, plus which pool to spend. Fresh when older than 5 minutes, else the last read with its age.",
        inputs: %{
          type: "object",
          properties: %{
            provider: %{type: "string", enum: ["all" | @order], description: "all (the default) or one"},
            device: %{type: "string", description: "one machine to read, by name; omit for every machine's"}
          }
        },
        outputs: %{
          type: "object",
          properties: %{
            at: %{type: "integer", description: "When, in milliseconds since 1970"},
            problem: %{type: ["string", "null"], description: "Why no device's plans could be read, if none could"},
            providers: %{
              type: "array",
              description: "Each plan, by provider then account, the one in use first",
              items: %{
                type: "object",
                properties: %{
                  id: %{type: "string", enum: @order},
                  title: %{type: "string"},
                  account: %{type: ["string", "null"]},
                  active: %{type: "boolean", description: "Whether it's the account in use"},
                  disabled: %{type: "boolean"},
                  alarm: %{
                    type: ["object", "null"],
                    description: "Why it needs looking at: out now, or running out before it resets",
                    properties: %{tone: %{type: "string", enum: ["danger", "warn"]}, text: %{type: "string"}}
                  },
                  plan: %{type: ["string", "null"]},
                  machines: %{type: "array", items: %{type: "string"}, description: "Where it's signed in"},
                  updated_ago: %{type: "string", description: "How long ago it was read, like 3 min ago"},
                  outdated: %{type: "boolean", description: "Whether that's more than 5 minutes"},
                  note: %{type: ["string", "null"]},
                  session: @window,
                  weekly: @window,
                  monthly: %{anyOf: [@window, %{type: "null"}]},
                  models: %{
                    type: "array",
                    description: "Per-model windows, where the plan has them",
                    items: %{
                      type: "object",
                      properties: %{
                        name: %{type: "string"},
                        used: @percent,
                        left: @percent,
                        countdown: %{type: ["string", "null"], description: "When it resets, like in 2h 5m"}
                      }
                    }
                  },
                  extra: %{
                    type: ["object", "null"],
                    description: "Extra usage this month, in US dollars",
                    properties: %{used: %{type: "number"}, limit: %{type: "number"}}
                  },
                  steer: %{type: "string", description: "Which pool to spend, from Claude's per-model windows"}
                },
                required: ["id", "title", "active", "disabled", "machines", "updated_ago", "outdated", "session", "weekly", "models", "steer"]
              }
            }
          },
          required: ["at", "problem", "providers"]
        }
      }
    ]
  end

  @impl true
  def call("status", inputs, call) do
    now = System.os_time(:millisecond)
    ids = if inputs["provider"] in [nil, "all"], do: @order, else: [inputs["provider"]]
    database = OneCore.Call.plugin(call, "database")
    transaction = fn fun -> database.transaction(call, @schema, &fun.({database, &1})) end

    stored = transaction.(fn db -> Map.new(ids, &{&1, latest(db, &1)}) end)
    stale = Enum.filter(ids, fn id -> Enum.all?(stored[id], &(now - &1["at"] >= @fresh)) end)
    response = if stale != [], do: ask(call, inputs["device"])

    all =
      transaction.(fn db ->
        query(db, "delete from readings where at < ?", [now - @keep])

        Enum.flat_map(ids, fn id ->
          if id in stale, do: merge(db, id, stored[id], response, now), else: Enum.map(stored[id], &Map.put(&1, "now", now))
        end)
      end)

    problem = if all == [] and response, do: response[:problem]

    %{at: now, problem: problem, providers: Enum.map(all, &json(&1, now))}
  end

  # Every machine's reading, by its name: `%{answers: %{name => [reading] | %{"error" => why}}}`, or `%{problem:
  # why}` when none could be asked.
  defp ask(call, device) do
    servers = OneCore.Service.servers(call, Reader)

    servers =
      if device,
        do: Enum.filter(servers, &(String.downcase(OneCore.Service.name(&1) || "") == String.downcase(device))),
        else: servers

    cond do
      servers == [] and device ->
        %{problem: "no machine called #{device} reads your AI plans"}

      servers == [] ->
        %{
          problem:
            "no machine reads your AI plans yet: install_service --plugin ai-usage --service AIUsage.Reader runs it on one"
        }

      true ->
        responses =
          servers
          |> Task.async_stream(
            fn server ->
              try do
                OneCore.Service.call(call, Reader, :usage, [], server)
              rescue
                error -> %{"error" => Exception.message(error)}
              end
            end,
            timeout: 30_000,
            on_timeout: :kill_task
          )
          |> Enum.zip(servers)
          |> Map.new(fn
            {{:ok, response}, server} -> {OneCore.Service.name(server) || server, response}
            {{:exit, _}, server} -> {OneCore.Service.name(server) || server, %{"error" => "it didn't answer in time"}}
          end)

        %{responses: responses}
    end
  end

  # One provider's readings: the newest per account, from whichever machine read it, kept with the pace. Accounts
  # that every machine that answered no longer has are let go; those a machine couldn't read now keep their last
  # reading, with why in its note.
  defp merge(_db, _id, stored, %{problem: problem}, now),
    do: Enum.map(stored, &Map.merge(&1, %{"note" => "Couldn't update: #{problem}", "now" => now}))

  defp merge(db, id, stored, %{responses: responses}, now) do
    failed =
      for {machine, %{"error" => why}} <- responses, into: %{}, do: {machine, "#{machine}: #{String.slice(why, 0, 160)}"}

    reads =
      for {machine, list} <- Enum.sort(responses),
          is_list(list),
          read <- list,
          read["provider"] == id,
          do: {machine, read}

    has = Enum.group_by(reads, fn {_machine, read} -> key(read) end, fn {machine, _read} -> machine end)

    unread =
      for {_machine, read} <- reads, read["error"], into: %{}, do: {key(read), String.slice(read["error"], 0, 160)}

    # Each account once, a machine that read its windows before one that didn't read it (it's switched off there).
    counted =
      reads
      |> Enum.reject(fn {_machine, read} -> read["error"] end)
      |> Enum.sort_by(fn {_machine, read} -> if counted?(read), do: 0, else: 1 end)
      |> Enum.uniq_by(fn {_, read} -> key(read) end)

    results =
      for {machine, read} <- counted do
        p = @providers[id]
        account = key(read)
        session = read["session"] || %{}
        weekly = read["weekly"] || %{}
        monthly = read["monthly"] || %{}
        before = previous(db, id, account, now, session["resets_at"])

        paces = %{
          "session" => pace(session["used"], session["resets_at"], p.session, before, now),
          "weekly" => pace(weekly["used"], weekly["resets_at"], p.weekly, nil, now)
        }

        row = %{
          "provider" => id,
          "account" => account,
          "machine" => machine,
          "machines" => Enum.sort(Enum.uniq(has[account])),
          "at" => now,
          "plan" => read["plan"],
          "active" => read["active"] == true or length(counted) == 1,
          "disabled" => read["disabled"] == true,
          "session_used" => session["used"],
          "session_resets" => session["resets_at"],
          "weekly_used" => weekly["used"],
          "weekly_resets" => weekly["resets_at"],
          "monthly_used" => monthly["used"],
          "monthly_resets" => monthly["resets_at"],
          "models" => read["models"] || [],
          "pace" => paces,
          "extra" => if(is_map(read["extra"]) and read["extra"]["limit"] != nil, do: read["extra"]),
          "note" => read["note"]
        }

        query(
          db,
          "insert into readings (provider, account, machine, machines, at, plan, active, disabled, session_used, session_resets, weekly_used, weekly_resets, monthly_used, monthly_resets, models, pace, extra, note) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            id,
            account,
            machine,
            JSON.encode!(row["machines"]),
            now,
            row["plan"],
            row["active"],
            row["disabled"],
            row["session_used"],
            row["session_resets"],
            row["weekly_used"],
            row["weekly_resets"],
            row["monthly_used"],
            row["monthly_resets"],
            JSON.encode!(row["models"]),
            JSON.encode!(paces),
            row["extra"] && JSON.encode!(row["extra"]),
            row["note"]
          ]
        )

        Map.put(row, "now", now)
      end

    seen = MapSet.new(results, & &1["account"])

    gone? =
      &(Map.has_key?(responses, &1["machine"]) and not Map.has_key?(failed, &1["machine"]) and
          not Map.has_key?(unread, &1["account"]))

    for r <- stored,
        not MapSet.member?(seen, r["account"]),
        gone?.(r),
        do: query(db, "delete from readings where provider = ? and account = ?", [id, r["account"]])

    # One that couldn't be read keeps its last reading, with why; it isn't in use while another one is.
    in_use = Enum.any?(results, & &1["active"])

    left =
      for r <- stored, not MapSet.member?(seen, r["account"]), not gone?.(r) do
        why = unread[r["account"]] || failed[r["machine"]]
        r = Map.put(r, "now", now)

        if why do
          r = Map.merge(r, %{"note" => "Couldn't update: #{why}", "active" => r["active"] and not in_use})
          update = "update readings set note = ?, active = ? where provider = ? and account = ? and at = ?"
          query(db, update, [r["note"], r["active"], id, r["account"], r["at"]])
          r
        else
          r
        end
      end

    Enum.sort_by(
      results ++ left,
      &{if(&1["active"], do: 0, else: if(&1["disabled"], do: 2, else: 1)), &1["weekly_used"] || 0}
    )
  end

  defp key(read), do: read["account"] || read["email"] || ""
  defp counted?(read), do: Enum.any?(~w(session weekly monthly), &(get_in(read, [&1, "used"]) != nil))

  # Each account's newest reading of a provider, made at or before `before`, the one in use first.
  defp latest(db, provider, before \\ 9_999_999_999_999) do
    # Each account's newest time comes from the index alone, and its row is then found by it: `cross join` keeps
    # SQLite from walking every reading of the provider to match them up.
    newest = """
    select r.* from (select account, max(at) as newest from readings where provider = ? and at <= ? group by account) l
    cross join readings r on r.provider = ? and r.account = l.account and r.at = l.newest
    order by r.active desc, r.disabled, r.weekly_used
    """

    for r <- query(db, newest, [provider, before, provider]) do
      Map.merge(r, %{
        "machines" => JSON.decode!(r["machines"]),
        "active" => r["active"] == 1,
        "disabled" => r["disabled"] == 1,
        "models" => JSON.decode!(r["models"]),
        "pace" => JSON.decode!(r["pace"]),
        "extra" => r["extra"] && JSON.decode!(r["extra"])
      })
    end
  end

  # The account's last reading in the same session window, for how fast it's being used.
  defp previous(db, provider, account, now, resets) do
    rows =
      query(
        db,
        "select at, session_used, session_resets from readings where provider = ? and account = ? and at < ? order by at desc limit 5",
        [provider, account, now]
      )

    Enum.find_value(rows, fn r -> r["session_resets"] == resets && %{at: r["at"], used: r["session_used"]} end)
  end

  defp query({database, db}, sql, values), do: database.query(db, sql, values)

  # Where a window stands against even use: how far ahead or behind, what was expected by now, and whether it
  # lasts to reset, which needs two readings ten minutes apart in the same window to say how fast it goes.
  defp pace(used, resets, _minutes, _before, _now) when used == nil or resets == nil, do: nil

  defp pace(used, resets, minutes, before, now) do
    window = minutes * 60_000
    start = resets - window
    expected = ((now - start) / window * 100) |> max(0) |> min(100)
    delta = Float.round((used - expected) * 1.0, 1)
    exp = round(expected)

    cond do
      used >= 100 ->
        %{"summary" => "Out now | Expected #{exp}% used | Back at reset", "will_last" => false, "delta" => delta}

      abs(delta) < 3 ->
        %{"summary" => "On pace | Expected #{exp}% used | Lasts until reset", "will_last" => true, "delta" => delta}

      true ->
        apart = before != nil and before.at > start and before.used != nil and now - before.at > 10 * 60_000
        burn = if apart, do: (used - before.used) / (now - before.at), else: 0

        {tail, will_last} =
          cond do
            burn > 0 ->
              eta = (100 - used) / burn
              if now + eta >= resets, do: {"Lasts until reset", true}, else: {empty_in(eta), false}

            delta > 0 and not apart ->
              {"Ahead of even pace", nil}

            true ->
              {"Lasts until reset", if(delta <= 0, do: true)}
          end

        head = if delta > 0, do: "#{trim(delta)}% in deficit", else: "#{trim(-delta)}% in reserve"
        %{"summary" => "#{head} | Expected #{exp}% used | #{tail}", "will_last" => will_last, "delta" => delta}
    end
  end

  defp trim(v),
    do: v |> Float.round(1) |> then(&if(&1 == trunc(&1), do: Integer.to_string(trunc(&1)), else: Float.to_string(&1)))

  defp empty_in(eta) do
    mins = max(0, round(eta / 60_000))

    cond do
      mins < 120 -> "Projected empty in #{mins} min"
      mins < 2880 -> "Projected empty in #{div(mins, 60)}h #{rem(mins, 60)}m"
      true -> "Runs out in #{round(mins / 1440)}d"
    end
  end

  # Which pool to spend, from Claude's per-model windows.
  defp steer(models) do
    used = fn word ->
      Enum.find_value(models, &(String.contains?(String.downcase(&1["name"] || ""), word) && &1["used"]))
    end

    {opus, sonnet} = {used.("opus"), used.("sonnet")}

    head =
      [opus && "Opus #{fmt(opus)}% used", sonnet && "Sonnet #{fmt(sonnet)}% used"]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(" · ")

    cond do
      opus in [nil, false] and sonnet in [nil, false] -> ""
      (opus || 0) >= 85 and (sonnet || 0) >= 85 -> "#{head} — Haiku edits, Sonnet thinking, no Opus"
      (opus || 0) >= 85 -> "#{head} — Sonnet or Haiku; Opus review-only"
      (sonnet || 0) >= 85 -> "#{head} — Opus or Haiku; spare Sonnet"
      true -> "#{head} — any model fine"
    end
  end

  defp fmt(n) when is_float(n),
    do: if(n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(Float.round(n, 1)))

  defp fmt(n), do: to_string(n)

  # A local time, as the server's clock has it.
  defp local(ms), do: :calendar.system_time_to_local_time(ms, :millisecond)

  defp clock(ms) do
    {_, {h, m, _}} = local(ms)
    "#{rem(h + 11, 12) + 1}:#{String.pad_leading("#{m}", 2, "0")} #{if h < 12, do: "AM", else: "PM"}"
  end

  defp weekday(ms), do: Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), :calendar.day_of_the_week(elem(local(ms), 0)) - 1)

  defp month_day(ms) do
    {{_, month, day}, _} = local(ms)
    "#{Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), month - 1)} #{day}"
  end

  defp resets(nil, _now), do: "reset unknown"

  defp resets(at, now) do
    d = at - now

    cond do
      d <= 0 -> "resetting now"
      d < 2 * 3_600_000 -> if round(d / 60_000) <= 1, do: "in 1 min", else: "in #{round(d / 60_000)} min"
      elem(local(at), 0) == elem(local(now), 0) -> "today at #{clock(at)}"
      d < 7 * 86_400_000 -> "#{weekday(at)} at #{clock(at)}"
      true -> "#{month_day(at)} at #{clock(at)}"
    end
  end

  defp countdown(nil, _now), do: nil

  defp countdown(at, now) do
    m = max(0, round((at - now) / 60_000))
    h = div(m, 60)

    cond do
      m < 1 -> "now"
      m < 120 -> "in #{m} min"
      h < 48 -> "in #{h}h #{rem(m, 60)}m"
      div(h, 24) < 14 -> "in #{div(h, 24)}d #{rem(h, 24)}h"
      true -> "on #{month_day(at)}"
    end
  end

  defp ago(at, now) do
    m = max(0, round((now - at) / 60_000))

    cond do
      m < 1 -> "just now"
      m < 60 -> "#{m} min ago"
      round(m / 60) < 24 -> "#{round(m / 60)} h ago"
      true -> "#{round(m / 1440)} d ago"
    end
  end

  # Why a plan needs looking at: out now, or running out before it resets.
  defp alarm(p, now) do
    windows = [
      {"Session", p["session_used"], p["session_resets"], p["pace"]["session"]},
      {"Weekly", p["weekly_used"], p["weekly_resets"], p["pace"]["weekly"]},
      {"Monthly", p["monthly_used"], p["monthly_resets"], nil}
    ]

    Enum.find_value(windows, fn {_label, used, at, _pace} ->
      used && used >= 100 && %{tone: "danger", text: "Out, resets #{resets(at, now)}"}
    end) ||
      Enum.find_value(windows, fn {label, _used, _at, pace} ->
        if pace && pace["will_last"] == false do
          case Regex.run(~r/(?:Projected empty|Runs out) in (.+)$/, pace["summary"]) do
            [_, when_] -> %{tone: "warn", text: "#{label} runs out in #{when_}, before it resets"}
            nil -> %{tone: "warn", text: "#{label} runs out before it resets"}
          end
        end
      end)
  end

  defp meter(used, resets, pace, now) do
    %{
      used: used,
      left: used && 100 - used,
      resets: resets && resets(resets, now),
      countdown: countdown(resets, now),
      pace: pace && pace["summary"],
      will_last: pace && pace["will_last"]
    }
  end

  defp json(p, now) do
    %{
      id: p["provider"],
      title: @providers[p["provider"]].title,
      account: if(p["account"] != "", do: p["account"]),
      active: p["active"],
      disabled: p["disabled"],
      alarm: alarm(p, now),
      plan: p["plan"],
      machines: p["machines"],
      updated_ago: ago(p["at"], now),
      outdated: now - p["at"] > @fresh,
      note: p["note"],
      session: meter(p["session_used"], p["session_resets"], p["pace"]["session"], now),
      weekly: meter(p["weekly_used"], p["weekly_resets"], p["pace"]["weekly"], now),
      monthly: if(p["monthly_used"] != nil, do: meter(p["monthly_used"], p["monthly_resets"], nil, now)),
      models:
        for(
          m <- p["models"],
          do: %{
            name: m["name"],
            used: m["used"],
            left: m["used"] && 100 - m["used"],
            countdown: countdown(m["resets_at"], now)
          }
        ),
      extra: p["extra"],
      steer: steer(p["models"])
    }
  end
end
