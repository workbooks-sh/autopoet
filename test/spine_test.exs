defmodule Autopoet.SpineTest do
  @moduledoc """
  The project spine (lifecycle-plan §1) — many projects, ONE organism:
  create → launch desk (Registry-named, slug-derived paths) → heartbeat in the
  project's own artifacts dir → halt → archive moves the body subtree. Hermetic
  (brain_live false: desks tick, no LLM leaves the building).
  """
  use ExUnit.Case, async: false

  test "project lifecycle: create → launch → heartbeat → second project coexists → archive" do
    slug = "spine-test-#{System.os_time(:millisecond)}"

    # birth
    assert {:ok, p} = Autopoet.Projects.create(slug, archetype: :venture)
    assert p.status == :genesis
    assert {:error, :exists} = Autopoet.Projects.create(slug)
    assert File.dir?(Autopoet.Projects.body_root(slug))

    # desk launches under the DynamicSupervisor, Registry-named by slug
    assert {:ok, pid} = Autopoet.Desks.launch(slug)
    assert Autopoet.Desks.running?(slug)
    assert Autopoet.Desks.whereis(slug) == pid

    # a SECOND project runs beside it — one organism, many desks
    slug2 = slug <> "-b"
    assert {:ok, _} = Autopoet.Projects.create(slug2)
    assert {:ok, pid2} = Autopoet.Desks.launch(slug2)
    assert pid != pid2
    assert slug in Autopoet.Desks.running() and slug2 in Autopoet.Desks.running()

    # first tick (5s) heartbeats into the PROJECT's artifacts dir
    Process.sleep(5_600)
    hb = Path.join(Autopoet.Projects.artifacts_dir(slug), "state.txt")
    assert File.exists?(hb)
    assert Autopoet.Venture.status(slug).work_cycles >= 0

    # live facts on the record
    assert %{desk_running: true, chartered: false} = Autopoet.Projects.get(slug)

    # archive: desk stops, body subtree moves, record marked
    assert :ok = Autopoet.Projects.archive(slug)
    refute Autopoet.Desks.running?(slug)
    refute File.dir?(Autopoet.Projects.body_root(slug))
    assert %{status: :archived} = Map.get(Autopoet.Projects.all(), slug)

    # the sibling survives its neighbor's death
    assert Autopoet.Desks.running?(slug2)
    Autopoet.Projects.archive(slug2)

    IO.puts("  ✓ spine — two desks, one organism; slug-derived paths; archive clean")
  end
end
