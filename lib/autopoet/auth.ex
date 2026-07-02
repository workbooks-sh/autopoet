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

  def complete_onboarding, do: put(Map.merge(state(), %{onboarded: true}))
  def signout, do: put(%{authenticated: false, user: nil, onboarded: false})

  # ── state persistence ──────────────────────────────────────────────────────
  defp put(s) do
    Agent.update(__MODULE__, fn _ -> s end)
    persist(s)
    s
  end

  defp default do
    if System.get_env("AUTOPOET_SKIP_ONBOARDING") in ["1", "true"],
      do: %{authenticated: true, user: @demo, onboarded: true},
      else: %{authenticated: false, user: nil, onboarded: false}
  end

  defp file, do: Path.join([Autopoet.Discovery.home(), "data", "session"])

  defp load do
    case File.read(file()) do
      {:ok, "in" <> _} -> %{authenticated: true, user: @demo, onboarded: true}
      {:ok, "onboarding" <> _} -> %{authenticated: true, user: @demo, onboarded: false}
      _ -> default()
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

    File.write!(file(), tag <> "\n")
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

  @impl true
  def register(_params), do: {:ok, Autopoet.Auth.demo()}
end
