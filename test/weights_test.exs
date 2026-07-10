defmodule Autopoet.WeightsTest do
  use ExUnit.Case, async: true

  # the baked manifest must track the real files — a weights update that skips
  # the manifest would ship a lean app that can never verify its download
  test "manifest matches the source weights on disk (size check)" do
    src = Path.expand("../data/models", __DIR__)

    if File.dir?(src) do
      for {rel, _sha, bytes} <- Autopoet.Weights.manifest() do
        path = Path.join(src, rel)
        assert File.exists?(path), "manifest names #{rel} but data/models lacks it"

        assert File.stat!(path).size == bytes,
               "#{rel}: manifest says #{bytes} bytes, disk has #{File.stat!(path).size} — regenerate desktop_ml/weights.ex"
      end
    end
  end
end
