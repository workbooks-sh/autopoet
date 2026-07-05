defmodule Autopoet.Auth do
  @moduledoc """
  The app's user SESSION — a thin facade over a pluggable PROVIDER so real auth
  (Guardian / BetterAuth via the Nexus) can slot in later without touching any
  caller. Today the `Stub` provider signs a single demo user in locally.

  The session (authenticated? / user / onboarded?) lives in this Agent and persists
  to `data/session`, so a sign-in survives restarts. For development,
  `AUTOPOET_SKIP_ONBOARDING=1` pre-signs the demo user straight into the app.

  Flow the UI drives:
    * not authenticated        → the sign-in / sign-up screen
    * authenticated, !onboarded → the onboarding steps (sign UP lands here)
    * authenticated, onboarded  → the app (sign IN lands here)
  """
  use Agent

  @demo %{"id" => "demo", "name" => "demo", "email" => "demo@local"}

  def start_link(_opts), do: Agent.start_link(fn -> load() end, name: __MODULE__)

  # the auth provider is swappable — Stub now, a real one (Guardian/BetterAuth) later
  defp provider, do: Application.get_env(:autopoet, :auth_provider, Autopoet.Auth.Stub)

  def state, do: Agent.get(__MODULE__, & &1)
  def authenticated?, do: state().authenticated
  def onboarded?, do: state().onboarded
  def current_user, do: state().user
  @doc "Connected providers (%{\"github\" => true, ...}) — sign in with ONE, connect BOTH."
  def connections, do: Map.get(state(), :connections, %{})

  @doc "Returning user → straight to the app."
  def signin(params \\ %{}) do
    case provider().authenticate(params) do
      {:ok, user} -> put(%{authenticated: true, user: user, onboarded: true})
      {:error, _} = e -> e
    end
  end

  @doc "New user → into onboarding."
  def signup(params \\ %{}) do
    case provider().register(params) do
      {:ok, user} -> put(%{authenticated: true, user: user, onboarded: false})
      {:error, _} = e -> e
    end
  end

  @doc """
  OAuth entry (GitHub / Google) — the ONE door on the splash. Stubbed today: the
  provider resolves the demo user; a real OAuth provider slots in behind the same
  seam. A session that already finished onboarding lands straight in the app;
  anything else flows through the onboarding steps.
  """
  def oauth(provider_name, params \\ %{}) when provider_name in ["github", "google"] do
    case provider().authenticate(params) do
      {:ok, user} ->
        put(%{
          authenticated: true,
          user: current_user() || user,
          onboarded: onboarded?(),
          connections: Map.put(connections(), provider_name, true)
        })

      {:error, _} = e ->
        e
    end
  end

  @doc """
  THE MAIN DOOR — sign in with Workbooks. The cloud device-flow minted a PAT
  (stored in `Autopoet.Cloud`); here we turn that into the local app session
  from the cloud identity. A returning user (bootstrap marker present) lands in
  the app; a fresh one flows through onboarding → the Workbooks Cloud sell.
  """
  def sign_in_cloud do
    acct = Autopoet.Cloud.account() || %{}
    # Cloud.account/0 returns ATOM keys (:name/:email/:avatar) — the identity the
    # desktop onboarding is seeded with (name pre-fills the quiz, avatar shows).
    name = blank(acct[:name]) || blank(acct[:email]) || "you"
    onboarded = onboarded_done?()

    put(%{
      authenticated: true,
      user: %{name: name, email: acct[:email], avatar: acct[:avatar]},
      onboarded: onboarded,
      connections: connections()
    })

    {:ok, %{name: name, onboarded: onboarded}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(s), do: s

  # sign-in doors are github/google; cloudflare is connect-only (publishing)
  @connectable ~w(github google cloudflare)

  @doc "Connect an ADDITIONAL provider from onboarding (stub: always succeeds)."
  def connect(provider_name) when provider_name in @connectable,
    do: put(Map.put(state(), :connections, Map.put(connections(), provider_name, true)))

  def connect(_), do: {:error, :unknown_provider}

  @doc "Disconnect a provider — the cards toggle both ways."
  def disconnect(provider_name) when provider_name in @connectable,
    do: put(Map.put(state(), :connections, Map.delete(connections(), provider_name)))

  def disconnect(_), do: {:error, :unknown_provider}

  # DESKTOP onboarding-complete marker — its OWN file, distinct from the
  # world-seed bootstrap marker (Intake.marker/data/bootstrapped). Onboarding is
  # "done" only when the user finishes the desktop flow, NOT when the world was
  # seeded. Cloud auth = identity; all onboarding happens here, gated on this.
  defp onboard_marker, do: Path.join([Autopoet.Discovery.home(), "data", "onboarded"])
  def onboarded_done?, do: File.exists?(onboard_marker())

  def complete_onboarding do
    File.mkdir_p!(Path.dirname(onboard_marker()))
    File.write!(onboard_marker(), "done\n")
    put(Map.merge(state(), %{onboarded: true}))
  end
  def signout, do: put(%{authenticated: false, user: nil, onboarded: false, connections: %{}})

  # ── state persistence ──────────────────────────────────────────────────────
  defp put(s) do
    Agent.update(__MODULE__, fn _ -> s end)
    persist(s)
    s
  end

  defp default do
    if System.get_env("AUTOPOET_SKIP_ONBOARDING") in ["1", "true"],
      do: %{authenticated: true, user: @demo, onboarded: true, connections: %{}},
      else: %{authenticated: false, user: nil, onboarded: false, connections: %{}}
  end

  defp file, do: Path.join([Autopoet.Discovery.home(), "data", "session"])

  # session file is line-based: state tag, then name / connected lines
  defp load do
    case File.read(file()) do
      {:ok, body} ->
        [tag | rest] = String.split(body, "\n", trim: true)

        user =
          Enum.find_value(rest, @demo, fn
            "name: " <> n -> Map.put(@demo, "name", n)
            _ -> nil
          end)

        conns =
          Enum.find_value(rest, %{}, fn
            "connected: " <> list ->
              list |> String.split(",", trim: true) |> Map.new(&{String.trim(&1), true})

            _ ->
              nil
          end)

        case tag do
          # onboarded is the MARKER's truth, not the tag — a stale "in" from a
          # prior session must not skip a desktop that never finished onboarding
          "in" -> %{authenticated: true, user: user, onboarded: onboarded_done?(), connections: conns}
          "onboarding" -> %{authenticated: true, user: user, onboarded: false, connections: conns}
          _ -> default()
        end

      _ ->
        default()
    end
  end

  defp persist(s) do
    File.mkdir_p!(Path.dirname(file()))

    tag =
      cond do
        s.authenticated and s.onboarded -> "in"
        s.authenticated -> "onboarding"
        true -> "out"
      end

    name = s.user && s.user["name"]
    name_line = if name && name != "demo", do: "name: #{name}\n", else: ""

    conns = s |> Map.get(:connections, %{}) |> Map.keys() |> Enum.sort() |> Enum.join(",")
    conn_line = if conns == "", do: "", else: "connected: #{conns}\n"

    File.write!(file(), tag <> "\n" <> name_line <> conn_line)
  end

  @doc "The demo user (stub)."
  def demo, do: @demo
end

defmodule Autopoet.Auth.Provider do
  @moduledoc "The auth seam a real backend (Guardian/BetterAuth) implements later."
  @callback authenticate(params :: map) :: {:ok, map} | {:error, term}
  @callback register(params :: map) :: {:ok, map} | {:error, term}
end

defmodule Autopoet.Auth.Stub do
  @moduledoc "Development provider: any credentials resolve to the single demo user."
  @behaviour Autopoet.Auth.Provider

  @impl true
  def authenticate(_params), do: {:ok, Autopoet.Auth.demo()}

  # sign-up carries the name chosen in onboarding — the one real field so far
  @impl true
  def register(params) do
    case String.trim(params["name"] || "") do
      "" -> {:ok, Autopoet.Auth.demo()}
      name -> {:ok, Map.put(Autopoet.Auth.demo(), "name", name)}
    end
  end
end
