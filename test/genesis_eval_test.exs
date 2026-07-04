defmodule Autopoet.GenesisEvalTest do
  @moduledoc """
  GENESIS gates (wb-h0tjs.1, docs/eval-genesis-plan.md §2/§4 Phase A):

    A1 blank slate — a fresh install's VISIBLE graph is exactly [self]. The
       plumbing (guide pages, limbs registry, infra limbs) exists, classified
       and hidden; no demo files exist at all.
    A2 graph budget — post-onboarding visible nodes == the persona's workspace
       manifest exactly (workspace docs + crew + the one pending proposal).
    A3 starting code — every vault page carries the three protected sections.
    A4 undo/void — rejecting the first proposal leaves a clean vault; intake
       re-run re-proposes.
    A5 no strays — nothing at the body/vault root beyond the manifest.

  A1 runs against a REAL fresh home (env-redirected, registry snapshotted);
  A2-A5 run through the same shared-home intake lane the persona evals use.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.Personas

  @reg {Nexus.Agent, :agents}

  test "A1: fresh install → visible graph == [self]; plumbing hidden, zero demo files" do
    tmp = Path.join(System.tmp_dir!(), "genesis_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    old_home = System.get_env("AUTOPOET_HOME")
    old_data = System.get_env("WB_DATA")
    old_apphome = Application.get_env(:autopoet, :home)
    reg_snapshot = :persistent_term.get(@reg, %{})

    on_exit(fn ->
      if old_home, do: System.put_env("AUTOPOET_HOME", old_home), else: System.delete_env("AUTOPOET_HOME")
      if old_data, do: System.put_env("WB_DATA", old_data), else: System.delete_env("WB_DATA")
      Application.put_env(:autopoet, :home, old_apphome)
      :persistent_term.put(@reg, reg_snapshot)
      File.rm_rf!(tmp)
    end)

    # park the shared in-memory request queue — a fresh install has none
    parked = Autopoet.Requests.drain()
    on_exit(fn -> for r <- parked, do: Autopoet.Requests.file(r[:target], r[:change]) end)

    System.put_env("AUTOPOET_HOME", tmp)
    System.put_env("WB_DATA", Path.join(tmp, "data/nexus"))
    Application.put_env(:autopoet, :home, tmp)
    :persistent_term.put(@reg, %{})

    # the REAL boot seed sequence (application.ex start/2)
    File.mkdir_p!(Nexus.Paths.data_dir())
    Autopoet.Guide.seed()
    Autopoet.Notes.seed()
    seed_limbs_like_boot()
    Autopoet.Limbs.register_from_body()

    payload = Autopoet.WorldGraph.payload()
    hidden = MapSet.new(payload.default_hidden)

    visible = Enum.reject(payload.nodes, &MapSet.member?(hidden, &1.type))
    assert Enum.map(visible, & &1.id) == ["self"],
           "A1 FAILED: fresh install shows #{inspect(Enum.map(visible, &{&1.type, &1.label}))}"

    # the plumbing EXISTS (hidden ≠ deleted): guide pages + the limbs registry
    types = Enum.frequencies_by(payload.nodes, & &1.type)
    assert types["guide"] >= 5, "guide pages missing from the (hidden) world"
    assert types["system"] >= 1, "limbs registry missing from the (hidden) world"

    # zero demo files anywhere: no welcome.md, no starter index/journal/todos
    body = Path.wildcard(Path.join(Nexus.Paths.data_dir(), "**/*.work"))
    vault = Path.wildcard(Path.join(Autopoet.Notes.dir(), "**/*"))
    demo = Enum.filter(body, &(Path.basename(&1) in ~w(index.work journal.work todos.work)))
    assert demo == [], "A1 FAILED: demo seeds present: #{inspect(demo)}"
    assert vault == [], "A1 FAILED: vault not empty at birth: #{inspect(vault)}"

    IO.puts("  ✓ GENESIS A1 — visible == [self]; #{map_size(types)} node types exist, #{Enum.count(payload.nodes) - 1} hidden/plumbing; zero demo files")
  end

  test "A2+A3+A5: post-onboarding world matches the persona manifest; pages are starting code" do
    p = Personas.named("shop-seller")

    Autopoet.Profile.clear()
    on_exit(fn -> Autopoet.Profile.clear() end)
    for {k, v} <- p.profile, do: :ok = Autopoet.Profile.put(k, v)

    File.rm(Autopoet.Intake.marker())

    case Autopoet.Intake.pending_proposal() do
      {stale, _} -> Autopoet.Proposals.reject(stale, "genesis reseed")
      nil -> :ok
    end

    assert :ok = Autopoet.Intake.run()

    plan = Autopoet.Intake.parse_plan(Autopoet.Profile.all())
    ws = plan.workspace.name

    # A2: the workspace's doc nodes classify VISIBLE; intake machinery classifies hidden
    for page <- plan.workspace.pages do
      rel = "#{ws}/#{slug(page)}.work"
      assert Autopoet.WorldGraph.classify(rel) == "doc", "A2: #{rel} must be visible"
    end

    assert Autopoet.WorldGraph.classify("intake/briefing.work") == "system"
    assert Autopoet.WorldGraph.classify("intake/scout.work") == "system"
    assert Autopoet.WorldGraph.classify("limbs.work") == "system"
    assert Autopoet.WorldGraph.classify("guide/anatomy.work") == "guide"

    # A3: every proposed vault page is sectioned starting code, brief nested (A5)
    assert {id, _brief} = Autopoet.Intake.pending_proposal()
    changes = Autopoet.Proposals.changes(id)

    assert Map.has_key?(changes, "#{ws}/first-proposal.md"), "A5: brief must nest inside the workspace"
    refute Map.has_key?(changes, "first-proposal.md"), "A5: no vault-root brief"

    pages = for page <- plan.workspace.pages, do: "#{ws}/#{slug(page)}.md"

    for rel <- pages do
      src = changes[rel]
      assert src, "A3: missing vault page #{rel}"

      for section <- ["## what this is", "## how it fills", "## first moves"] do
        assert src =~ section, "A3: #{rel} missing '#{section}'"
      end

      # starting code names the crew and the first connect — actionable, not lorem
      assert src =~ plan.agents |> hd() |> Map.get(:name)
      assert src =~ hd(plan.connect)
    end

    # A5: proposal touches nothing at the vault root except the workspace dir
    root_strays = changes |> Map.keys() |> Enum.reject(&String.starts_with?(&1, ws <> "/"))
    assert root_strays == [], "A5: vault-root strays in proposal: #{inspect(root_strays)}"

    IO.puts("  ✓ GENESIS A2/A3/A5 — #{length(pages)} sectioned pages, brief nested, machinery classified hidden")
  end

  test "A4: rejecting the first proposal leaves a clean void; intake re-proposes" do
    p = Personas.named("trader")

    Autopoet.Profile.clear()
    on_exit(fn -> Autopoet.Profile.clear() end)
    for {k, v} <- p.profile, do: :ok = Autopoet.Profile.put(k, v)

    File.rm(Autopoet.Intake.marker())

    case Autopoet.Intake.pending_proposal() do
      {stale, _} -> Autopoet.Proposals.reject(stale, "genesis reseed")
      nil -> :ok
    end

    # the void invariant is a DIGEST comparison — the shared test vault may hold
    # previously accepted worlds; a reject must add exactly nothing to it
    vault0 = vault_digest()

    assert :ok = Autopoet.Intake.run()
    assert {id, _} = Autopoet.Intake.pending_proposal()

    # reject → the vault is byte-identical to before intake, no intake proposal pends
    :ok = Autopoet.Proposals.reject(id, "not like this")
    assert vault_digest() == vault0, "A4: rejected world must not materialize"
    assert Autopoet.Intake.pending_proposal() == nil

    # re-run → a fresh proposal pends (the re-propose path)
    File.rm(Autopoet.Intake.marker())
    assert :ok = Autopoet.Intake.run()
    assert {id2, _} = Autopoet.Intake.pending_proposal()
    assert id2 != id

    Autopoet.Proposals.reject(id2, "eval cleanup")
    IO.puts("  ✓ GENESIS A4 — reject leaves a void; re-run re-proposes")
  end

  # mirror application.ex seed_limbs (private there)
  defp seed_limbs_like_boot do
    src = Path.join(:code.priv_dir(:autopoet), "seed")
    root = Nexus.Paths.data_dir()

    for f <- Path.wildcard(Path.join(src, "*.work")),
        target = Path.join(root, Path.basename(f)),
        not File.exists?(target) do
      File.cp!(f, target)
    end
  end

  defp slug(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  defp vault_digest do
    Path.wildcard(Path.join(Autopoet.Notes.dir(), "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn f -> {f, :erlang.md5(File.read!(f))} end)
  end
end
