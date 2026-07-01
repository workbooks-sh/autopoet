defmodule Autopoet.Phase0Test do
  use ExUnit.Case

  # Phase 0, proven through the REAL production path: real bus, real hook dispatch,
  # real supervised-task effect run, real capture subscriber.

  test "effect runs SETTLE with cause + duration, and both events land in the capture trace" do
    Nexus.Events.subscribe()
    Nexus.Effects.register("phase0_noop", fn _args, _event, _ctx -> :ok end)

    Nexus.Hook.register(%{
      name: "phase0_hook",
      match: %{tags: ["phase0"]},
      trigger: nil,
      title: "phase0",
      visible_to: nil,
      effects: [%{name: "phase0_noop", args: %{}}]
    })

    ev = Nexus.Events.emit(%{kind: "phase0.test", tags: ["phase0"]})

    assert_receive {:event, %{kind: "effect.settled"} = settled}, 2_000
    assert settled[:cause] == ev[:id]
    assert settled[:status] == :ok
    assert settled[:hook] == "phase0_hook"
    assert settled[:effect] == "phase0_noop"
    assert is_integer(settled[:duration_us])

    # settled events are broadcast-only feedback: they never re-enter hook dispatch
    settled_id = settled[:id]
    refute_receive {:event, %{kind: "effect.settled", cause: ^settled_id}}, 300

    # capture wrote both the workload event and its settlement, replayably
    Process.sleep(200)
    frames = read_todays_frames()
    assert Enum.any?(frames, &(&1[:id] == ev[:id]))
    assert Enum.any?(frames, &(&1[:kind] == "effect.settled" and &1[:cause] == ev[:id]))
  end

  test "a chained emit stamps cause — causation chains are reconstructable" do
    Nexus.Events.subscribe()

    Nexus.Hook.register(%{
      name: "phase0_chain",
      match: %{tags: ["phase0chain"]},
      trigger: nil,
      title: "chain",
      visible_to: nil,
      effects: [%{name: "emit", args: %{kind: "phase0.chained", tags: []}}]
    })

    ev = Nexus.Events.emit(%{kind: "phase0.chain", tags: ["phase0chain"]})

    assert_receive {:event, %{kind: "phase0.chained"} = chained}, 2_000
    assert chained[:cause] == ev[:id]
    assert chained[:depth] == 1
  end

  defp read_todays_frames do
    path = Path.join(Autopoet.Capture.dir(), Date.to_iso8601(Date.utc_today()) <> ".etfs")

    path
    |> File.read!()
    |> unfold([])
    |> Enum.reverse()
  end

  defp unfold(<<size::32, blob::binary-size(size), rest::binary>>, acc),
    do: unfold(rest, [:erlang.binary_to_term(blob) | acc])

  defp unfold(_, acc), do: acc
end
