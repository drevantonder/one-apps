defmodule AIUsage.Reader do
  @moduledoc """
  Reads the AI plans signed in on its machine, from the providers themselves: Claude Code's own sign-in and every
  account claude-swap keeps, Codex's and OpenCode Go's, where those tools keep them. It asks each provider for that
  account's numbers and gives back only those: used percent, reset times, per-model windows and the plan. A token
  never leaves it, not in an answer, a log or an error.

  It only reads, and never renews a sign-in: renewing one would sign out the tool it belongs to. One whose access
  token ran out says so, and renews the next time its tool is used. An account claude-swap has switched off isn't
  read, and one its provider rate limits isn't asked again until the provider's `retry-after` has passed: its
  process keeps when each may be asked again.
  """
  use GenServer
  @behaviour OneCore.Service

  @claude "https://api.anthropic.com/api/oauth/usage"
  @codex "https://chatgpt.com/backend-api/wham/usage"
  @opencode "https://opencode.ai/zen/go/v1/usage"

  @impl OneCore.Service
  def called, do: "AI Usage's reader"

  @impl OneCore.Service
  def needs do
    "A machine its person signs in to Claude Code, Codex or OpenCode Go on, as the user its server runs as. " <>
      "It reads their sign-ins where those tools keep them, and reaches api.anthropic.com, chatgpt.com and opencode.ai."
  end

  @doc """
  Every plan signed in here, each read from its provider: `provider`, `account`, `email`, `active` (the one its tool
  is signed in to now), `disabled`, `plan`, and its `session`, `weekly` and `monthly` windows (`used` percent,
  `resets_at` in milliseconds), its per-model `models`, its `extra` usage and a `note` ("Plan ended"), or an `error`
  saying why it couldn't be read. A disabled account has no windows: it isn't read.
  """
  def usage(service) do
    accounts = accounts()
    held = GenServer.call(service, :held)

    accounts
    |> Task.async_stream(&reading(&1, held, service), timeout: 20_000, on_timeout: :kill_task)
    |> Enum.zip(accounts)
    |> Enum.map(fn
      {{:ok, read}, _account} -> read
      {{:exit, _}, account} -> Map.put(said(account), "error", "#{title(account.provider)} didn't answer in time")
    end)
  end

  @impl GenServer
  def init(_), do: {:ok, %{}}

  # When each rate-limited account may be asked again, in milliseconds.
  @impl GenServer
  def handle_call(:held, _from, held), do: {:reply, held, held}

  @impl GenServer
  def handle_cast({:hold, key, until}, held), do: {:noreply, Map.put(held, key, until)}

  # A version before this one kept nothing in its process.
  @impl GenServer
  def code_change(_old, held, _extra), do: {:ok, held || %{}}

  # What's said of an account, without its token.
  defp said(a) do
    label =
      cond do
        a.email == "" -> ""
        a.org == "" or String.ends_with?(a.org, "'s Organization") -> "Personal · #{a.email}"
        true -> "#{a.org} · #{a.email}"
      end

    %{
      "provider" => a.provider,
      "account" => label,
      "email" => a.email,
      "active" => a.active,
      "disabled" => a.disabled,
      "plan" => a.plan
    }
  end

  defp reading(a, held, service) do
    key = {a.provider, a.email, a.org}

    cond do
      a.disabled ->
        said(a)

      Map.get(held, key, 0) > now() ->
        Map.put(said(a), "error", "rate limited by #{title(a.provider)}")

      a.expires_at && a.expires_at < now() ->
        Map.put(said(a), "error", "its sign-in ran out #{ago(a.expires_at)} ago; it renews when #{a.tool} is next used")

      true ->
        try do
          Map.merge(said(a), fetch(a))
        rescue
          error in RuntimeError -> Map.put(said(a), "error", error.message)
        catch
          {:rate_limited, seconds} ->
            if seconds, do: GenServer.cast(service, {:hold, key, now() + seconds * 1000})
            Map.put(said(a), "error", "rate limited by #{title(a.provider)}")
        end
    end
  end

  defp ago(at) do
    m = div(now() - at, 60_000)

    cond do
      m < 60 -> "#{m} min"
      m < 1440 -> "#{div(m, 60)} h"
      true -> "#{div(m, 1440)} d"
    end
  end

  defp now, do: System.os_time(:millisecond)

  defp title("claude"), do: "Claude"
  defp title("codex"), do: "Codex"
  defp title(_), do: "OpenCode"

  # The accounts signed in here: claude-swap's, or Claude Code's own where it has none; Codex's; OpenCode Go's.
  defp accounts do
    claude = with [] <- claude_swap(), do: List.wrap(claude_code())
    claude ++ List.wrap(codex()) ++ List.wrap(opencode())
  end

  defp account(fields) do
    Map.merge(
      %{email: "", org: "", active: true, disabled: false, plan: nil, expires_at: nil, account_id: ""},
      fields
    )
  end

  defp home, do: System.user_home!()
  defp env(name), do: System.get_env(name) |> then(&if(&1 in [nil, ""], do: nil, else: &1))
  defp data_home, do: env("XDG_DATA_HOME") || Path.join(home(), ".local/share")

  defp json(path) do
    with {:ok, text} <- File.read(path), {:ok, value} <- JSON.decode(text), do: value, else: (_ -> nil)
  end

  # The OAuth fields of Claude's credentials: its access token and when it runs out.
  defp oauth(text) do
    with {:ok, %{"claudeAiOauth" => %{"accessToken" => token} = o}} <- JSON.decode(text) do
      {token, o["expiresAt"]}
    else
      _ -> nil
    end
  end

  # A Keychain item's text, on a Mac: what `security find-generic-password -w` gives.
  defp keychain(service, account) do
    with "/usr/bin/security" <- System.find_executable("security"),
         {text, 0} <-
           System.cmd("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"],
             stderr_to_stdout: true
           ) do
      String.trim(text)
    else
      _ -> nil
    end
  end

  # claude-swap's accounts in its rotation order, from its sequence.json, each one's credentials from its own file
  # (base64'd JSON) or, on a Mac, its Keychain item. Its folder is $XDG_DATA_HOME/claude-swap, or on a Mac
  # ~/.claude-swap-backup. The active one is the one Claude Code is signed in to now, by its account and organization.
  defp claude_swap do
    {_config, settings} = claude_config()
    me = (json(settings) || %{})["oauthAccount"] || %{}

    dir =
      Enum.find([Path.join(data_home(), "claude-swap"), Path.join(home(), ".claude-swap-backup")], fn dir ->
        File.regular?(Path.join(dir, "sequence.json"))
      end)

    with dir when dir != nil <- dir,
         %{"accounts" => accounts} = seq when is_map(accounts) <- json(Path.join(dir, "sequence.json")) do
      order = Enum.map(seq["sequence"] || [], &to_string/1)
      order = order ++ (Map.keys(accounts) -- order)

      for n <- order,
          meta = accounts[n],
          meta != nil,
          email = meta["email"] || "",
          creds = swap_credentials(dir, n, email),
          {token, expires_at} <- [creds && oauth(creds)] |> Enum.reject(&is_nil/1) do
        account(%{
          provider: "claude",
          tool: "Claude Code",
          email: email,
          org: meta["organizationName"] || "",
          active:
            me["accountUuid"] != nil and meta["uuid"] == me["accountUuid"] and
              meta["organizationUuid"] == me["organizationUuid"],
          disabled: meta["disabled"] == true,
          token: token,
          expires_at: expires_at
        })
      end
    else
      _ -> []
    end
  end

  defp swap_credentials(dir, n, email) do
    case File.read(Path.join([dir, "credentials", ".creds-#{n}-#{email}.enc"])) do
      {:ok, text} ->
        case Base.decode64(String.trim(text)) do
          {:ok, decoded} -> decoded
          :error -> nil
        end

      _ ->
        keychain("claude-swap", "account-#{n}-#{email}")
    end
  end

  # Claude Code's folder, and its .claude.json, which says who it's signed in as: in that folder when
  # CLAUDE_CONFIG_DIR names one, and in the home folder otherwise.
  defp claude_config do
    case env("CLAUDE_CONFIG_DIR") do
      nil -> {Path.join(home(), ".claude"), Path.join(home(), ".claude.json")}
      dir -> {dir, Path.join(dir, ".claude.json")}
    end
  end

  # Claude Code's own sign-in: .credentials.json in its folder (on a Mac, its Keychain item).
  defp claude_code do
    {config, settings} = claude_config()

    text =
      case File.read(Path.join(config, ".credentials.json")) do
        {:ok, text} -> text
        _ -> keychain("Claude Code-credentials", env("USER") || "")
      end

    with text when text != nil <- text, {token, expires_at} <- oauth(text) do
      me = (json(settings) || %{})["oauthAccount"] || %{}

      account(%{
        provider: "claude",
        tool: "Claude Code",
        email: me["emailAddress"] || "",
        org: me["organizationName"] || "",
        token: token,
        expires_at: expires_at
      })
    end
  end

  # Codex's sign-in: auth.json's access token and account id, its email and plan in the id token's claims.
  defp codex do
    dir = env("CODEX_HOME") || Path.join(home(), ".codex")

    with %{"tokens" => %{"access_token" => token} = tokens} <- json(Path.join(dir, "auth.json")) do
      claims = claims(tokens["id_token"] || "")
      auth = claims["https://api.openai.com/auth"] || %{}

      account(%{
        provider: "codex",
        tool: "Codex",
        email: claims["email"] || "",
        plan: auth["chatgpt_plan_type"] || claims["chatgpt_plan_type"],
        token: token,
        account_id: tokens["account_id"] || ""
      })
    else
      _ -> nil
    end
  end

  # A JWT's claims, unchecked: it's this machine's own file, and only its email and plan are read.
  defp claims(jwt) do
    with [_, part | _] <- String.split(jwt, "."),
         {:ok, raw} <- Base.url_decode64(part, padding: false),
         {:ok, claims} when is_map(claims) <- JSON.decode(raw) do
      claims
    else
      _ -> %{}
    end
  end

  # OpenCode Go's key: auth.json where older OpenCode kept it, or the credential table of its opencode.db.
  defp opencode do
    dir = Path.join(data_home(), "opencode")
    auth = json(Path.join(dir, "auth.json")) || %{}

    key =
      get_in(auth, ["opencode", "key"]) || get_in(auth, ["opencode", "access"]) || get_in(auth, ["opencodego", "key"])

    cond do
      key -> go(key, "")
      File.regular?(Path.join(dir, "opencode.db")) -> opencode_db(Path.join(dir, "opencode.db"))
      true -> nil
    end
  end

  defp go(key, email), do: account(%{provider: "opencodego", tool: "OpenCode", email: email, plan: "Go", token: key})

  defp opencode_db(path) do
    {:ok, db} = Sqlite.open("file:#{path}?mode=ro")

    with {:ok, [%{"value" => value}]} <-
           Sqlite.query(db, "select value from credential where integration_id = 'opencode-go' limit 1", []),
         {:ok, %{"key" => key}} <- JSON.decode(value) do
      email =
        case Sqlite.query(db, "select email from account limit 1", []) do
          {:ok, [%{"email" => email}]} -> email || ""
          _ -> ""
        end

      go(key, email)
    else
      _ -> nil
    end
  end

  # A GET with the account's token, only ever to its provider's own usage endpoint. What goes wrong is said in
  # words of its own, never the request's.
  defp get(a, url, headers) do
    case Req.get(url,
           headers: [{"authorization", "Bearer #{a.token}"} | headers],
           retry: false,
           receive_timeout: 15_000,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        case JSON.decode(body) do
          {:ok, json} -> json
          _ -> raise "#{title(a.provider)} answered with something that isn't JSON"
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        raise "its sign-in was refused; it renews when #{a.tool} is next used"

      {:ok, %{status: 429} = response} ->
        throw({:rate_limited, retry_after(response)})

      _ ->
        raise "#{title(a.provider)} couldn't be reached"
    end
  end

  # The seconds a provider's `retry-after` asks to wait, when it gives them as a number.
  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(value),
         do: seconds,
         else: (_ -> nil)
  end

  defp window(used, resets), do: %{"used" => number(used), "resets_at" => ms(resets)}

  defp number(v) when is_number(v), do: v
  defp number(_), do: nil

  # An ISO 8601 time, or unix seconds or milliseconds, as milliseconds.
  defp ms(v) when is_integer(v) and v < 1_000_000_000_000, do: v * 1000
  defp ms(v) when is_integer(v), do: v
  defp ms(v) when is_float(v), do: ms(trunc(v))

  defp ms(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, at, _} ->
        DateTime.to_unix(at, :millisecond)

      _ ->
        case Integer.parse(v) do
          {n, ""} -> ms(n)
          _ -> nil
        end
    end
  end

  defp ms(_), do: nil

  defp fetch(%{provider: "claude"} = a) do
    j = get(a, @claude, [{"anthropic-beta", "oauth-2025-04-20"}, {"user-agent", "claude-code/2.0"}])
    w = fn key -> window(get_in(j, [key, "utilization"]), get_in(j, [key, "resets_at"])) end

    models =
      for {key, name} <- [{"seven_day_sonnet", "Sonnet"}, {"seven_day_opus", "Opus"}], is_map(j[key]) do
        %{"name" => name, "used" => number(j[key]["utilization"]), "resets_at" => ms(j[key]["resets_at"])}
      end

    extra = j["extra_usage"]
    # A Claude plan always has a session and a weekly window; an account without either has none.
    ended = j["five_hour"] == nil and j["seven_day"] == nil

    %{
      "note" => if(ended, do: "Plan ended"),
      "session" => w.("five_hour"),
      "weekly" => w.("seven_day"),
      "monthly" => window(nil, nil),
      "models" => models,
      "extra" => if(is_map(extra), do: %{"used" => extra["used_credits"], "limit" => extra["monthly_limit"]})
    }
  end

  defp fetch(%{provider: "codex"} = a) do
    j = get(a, @codex, [{"chatgpt-account-id", a.account_id}, {"user-agent", "codex/1.0"}])
    w = fn key -> window(get_in(j, ["rate_limit", key, "used_percent"]), get_in(j, ["rate_limit", key, "reset_at"])) end

    read = %{
      "session" => w.("primary_window"),
      "weekly" => w.("secondary_window"),
      "monthly" => window(nil, nil),
      "models" => []
    }

    if read["session"]["used"] == nil and read["weekly"]["used"] == nil,
      do: raise("Codex's usage endpoint gave no windows")

    if is_binary(j["plan_type"]) and j["plan_type"] != "", do: Map.put(read, "plan", j["plan_type"]), else: read
  end

  defp fetch(a) do
    j = get(a, @opencode, [{"user-agent", "opencode/2.2.5"}])
    w = fn key -> window(get_in(j, ["usage", key, "percent"]), get_in(j, ["usage", key, "resetsAt"])) end
    read = %{"session" => w.("rolling"), "weekly" => w.("weekly"), "monthly" => w.("monthly"), "models" => []}

    if read["session"]["used"] == nil and read["weekly"]["used"] == nil,
      do: raise("OpenCode's usage endpoint gave no windows")

    read
  end
end
