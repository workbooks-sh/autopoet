defmodule Autopoet.Weights do
  @moduledoc """
  ML weights on FIRST RUN, not in the bundle (wb-yucr0). The dmg carried 826MB
  of onnx weights — 70% of its size — and every packaging stage (codesign
  hashing, dmg compression, the 900MB notary upload) paid for them. The lean
  app ships without `Resources/models`; this process fills the writable
  models dir (`Discovery.models_dir/0` → Application Support) once, verifying
  every file against a compile-time sha256 manifest, then reloads the voice
  engines. A bundle that DOES carry models (BUNDLE_WEIGHTS=1 builds, dev trees)
  is detected as already-complete and nothing downloads.

  Engines boot before the download finishes — their existing "loading/off"
  states cover the gap; each gets a `:reload` cast when the files land.
  """
  use GenServer

  # the R2 public bucket (zero-egress), versioned prefix — weights and app
  # move independently; a new weights rev = new prefix, old apps keep working
  @base "https://pub-WEIGHTS-PENDING.r2.dev/v1"

  # sha256 manifest of every file the engines load — baked at compile time so
  # the download source can't drift silently ({path, sha256, bytes})
  @manifest [
    {"kokoro/model_fp32.onnx", "8fbea51ea711f2af382e88c833d9e288c6dc82ce5e98421ea61c058ce21a34cb", 325_532_232},
    {"kokoro/tokenizer.json", "77a02c8e164413299b4b4c403b14f8e0e1c1b727db4d46a09d6327b861060a34", 3_497},
    {"kokoro/voices/af_aoede.bin", "4a004c33430762e2461eedb2013fad808ef4ab3121f5300f554476caf58d8361", 522_240},
    {"kokoro/voices/af_bella.bin", "f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b", 522_240},
    {"kokoro/voices/af_heart.bin", "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b", 522_240},
    {"kokoro/voices/af_kore.bin", "9be5221b6a941c04b561959b8ff0b06e809444dcc4ab7e75a7b23606f691819e", 522_240},
    {"kokoro/voices/af_nicole.bin", "cd2191ab31b914ed7b318416b0e4440fdf392ddad9106a060819aa600a64f59a", 522_240},
    {"kokoro/voices/af_sarah.bin", "4409fbc125afabacc615d94db5398d847006a737b0247d6892b7a9a0007a2f0a", 522_240},
    {"kokoro/voices/af_sky.bin", "4435255c9744f3f31659e0d714ab7689bf65d9e77ec1cce060f083912614f0b9", 522_240},
    {"kokoro/voices/am_adam.bin", "162b035ed91cfc48b6046982184c645f72edcdd1b82843347f605d7bf7b15716", 522_240},
    {"kokoro/voices/am_michael.bin", "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1", 522_240},
    {"kokoro/voices/am_onyx.bin", "da5d135b424164916d75a68ffb4c2abce3d7d5ccc82dd1ee6cf447ce286145e6", 522_240},
    {"kokoro/voices/am_puck.bin", "fcf73c989033e9233e0b98713eca600c8c74dcc1614b37009d5450ff4a2274a0", 522_240},
    {"kokoro/voices/am_santa.bin", "61150cf726ab6c5ed7a99f90a304f91f5a72c00c592e89ec94e5df11c319227a", 522_240},
    {"kokoro/voices/bf_alice.bin", "08afa6ba24da61ea5e8efa139e5aadc938d83f0a6da5a900adaf763ac1da5573", 522_240},
    {"kokoro/voices/bf_emma.bin", "669fe0647f9dd04fcab92f1439a40eeb4c8b4ab1f82e4996fe3d918ce4a63b73", 522_240},
    {"kokoro/voices/bf_isabella.bin", "3754352c4aaa46d17f27654ab7518d65b62ad6163a0f55a5f4330c2da2c4e94f", 522_240},
    {"kokoro/voices/bf_lily.bin", "5e0ee32ebe64a467124976b14e69590746f1c4ce41a12b587a50c862edfea335", 522_240},
    {"kokoro/voices/bm_fable.bin", "f889083196807b4adb15e9204252165f503b8d33d3982e681c52443c49d798f1", 522_240},
    {"kokoro/voices/bm_george.bin", "c4b235a4c1f2cd3b939fed08b899ce9385638b763f7b73a59616c4fc9bd6c9bc", 522_240},
    {"kokoro/voices/bm_lewis.bin", "b8f671cef828c30e66fdf0b0756a76bba58f6bb3398cbbf27058642acbcedb97", 522_240},
    {"moonshine/encoder_model.onnx", "153e128e7abd64a74ee47f2c3f585c3171c4d46cbb368b032827934c4e01e779", 80_818_781},
    {"moonshine/decoder_model.onnx", "d957c6418d65baee2842373c6842846c3ed6c9d9fc0ef48d790b110665e18063", 165_786_949},
    {"moonshine/decoder_with_past_model.onnx", "2d8740fb19673870125ed6f15370dd316c8c43d266e0846a6f456b354cebf169", 154_634_914},
    {"moonshine/tokenizer.json", "b68b995a58b3373db6c4f46864a9db50cd1333d086150ffa2c1096581ede9c10", 1_985_533},
    {"affect/model_quantized.onnx", "0c1981c5b479674747911c8e2228f0c4ec90bf47bf66e830f7d4fc62be082958", 125_397_543},
    {"affect/tokenizer.json", "90e2336a1cdacffe5d4328ab323aa9e5c33889026e4e4881323bebdeeb0e179d", 2_108_856}
  ]

  # the engines to poke once files land — each re-runs its load continue
  @engines [Autopoet.Kokoro, Autopoet.Stt, Autopoet.Affect]

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc ~S{"ready" | "fetching" | "off" — for status surfaces.}
  def status do
    GenServer.call(__MODULE__, :status, 1_000)
  catch
    :exit, _ -> "off"
  end

  @doc "True when every manifest file is present at its full size."
  def complete?, do: Enum.all?(@manifest, &present?/1)

  @doc "The baked file manifest — {relative_path, sha256, bytes} per file."
  def manifest, do: @manifest

  @impl true
  def init(:ok) do
    if complete?() do
      {:ok, :ready}
    else
      send(self(), :fetch)
      {:ok, :fetching}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, to_string(state), state}

  @impl true
  def handle_info(:fetch, _state) do
    if String.contains?(@base, "PENDING") do
      Autopoet.Log.puts("weights: models absent and no download source configured — voice engines stay off")
      {:noreply, :off}
    else
      server = self()
      Task.start(fn -> send(server, {:fetched, fetch_all()}) end)
      {:noreply, :fetching}
    end
  end

  def handle_info({:fetched, :ok}, _state) do
    Autopoet.Log.puts("weights: all models verified — reloading voice engines")
    for mod <- @engines, do: GenServer.cast(mod, :reload)
    {:noreply, :ready}
  end

  def handle_info({:fetched, {:error, why}}, _state) do
    Autopoet.Log.puts("weights: download FAILED (#{inspect(why)}) — retrying in 60s")
    Process.send_after(self(), :fetch, 60_000)
    {:noreply, :fetching}
  end

  # ── the download (sequential; tmp + sha256 verify + rename = atomic) ────────

  defp fetch_all do
    missing = Enum.reject(@manifest, &present?/1)
    total = Enum.count(missing)
    Autopoet.Log.puts("weights: fetching #{total} file(s), #{mb(missing)}MB — voice comes up when done")

    missing
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {{rel, sha, bytes}, n}, :ok ->
      case fetch_one(rel, sha, bytes) do
        :ok ->
          Autopoet.Log.puts("weights: #{n}/#{total} #{rel} ok")
          {:cont, :ok}

        {:error, why} ->
          {:halt, {:error, {rel, why}}}
      end
    end)
  end

  defp fetch_one(rel, sha, bytes) do
    dest = Path.join(models_dir(), rel)
    tmp = dest <> ".part"
    File.mkdir_p!(Path.dirname(dest))
    File.rm(tmp)

    url = ~c"#{@base}/#{rel}"

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {url, []}, [ssl: ssl, timeout: 600_000], stream: to_charlist(tmp)) do
      {:ok, :saved_to_file} ->
        with {:size, ^bytes} <- {:size, File.stat!(tmp).size},
             {:sha, ^sha} <- {:sha, sha256(tmp)} do
          File.rename!(tmp, dest)
          :ok
        else
          {what, got} ->
            File.rm(tmp)
            {:error, {what, got}}
        end

      {:ok, {{_, code, _}, _, _}} ->
        File.rm(tmp)
        {:error, {:http, code}}

      {:error, why} ->
        File.rm(tmp)
        {:error, why}
    end
  end

  defp present?({rel, _sha, bytes}) do
    case File.stat(Path.join(models_dir(), rel)) do
      {:ok, %{size: ^bytes}} -> true
      _ -> false
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp models_dir, do: Autopoet.Discovery.models_dir()

  defp mb(files), do: files |> Enum.map(fn {_, _, b} -> b end) |> Enum.sum() |> div(1_048_576)
end
