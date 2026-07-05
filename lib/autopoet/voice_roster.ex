defmodule Autopoet.VoiceRoster do
  @moduledoc """
  The persistent voice roster — verdicts (accepted/rejected) for personas,
  surviving every page regeneration. State is a plain line file
  (`data/voices/verdicts`: `name state` per line); takes live in
  `data/voices/takes/<name>.wav`. The roster page is served BY the app
  (`GET /voices/roster`) so flips POST same-origin and persist — no more
  throwaway Desktop HTML.
  """

  def dir, do: Path.join([Autopoet.Discovery.home(), "data", "voices"])
  def takes_dir, do: Path.join(dir(), "takes")
  defp verdicts_path, do: Path.join(dir(), "verdicts")
  defp accents_path, do: Path.join(dir(), "accents")

  @accent_opts ["english", "british", "australian", "other"]

  @doc "Accent tags as %{name => accent}."
  def accents do
    case File.read(accents_path()) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, " ", parts: 2) do
            [name, a] when a in @accent_opts -> Map.put(acc, name, a)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc "Tag a voice's PERCEIVED accent (what it actually sounds like)."
  def set_accent(name, accent) when accent in @accent_opts do
    name = Path.basename(to_string(name))
    a = Map.put(accents(), name, accent)
    File.mkdir_p!(dir())
    File.write!(accents_path(), Enum.map_join(a, "\n", fn {k, s} -> "#{k} #{s}" end) <> "\n")
    :ok
  end

  def set_accent(_, _), do: {:error, :bad_accent}

  @doc "All verdicts as %{name => \"accepted\" | \"rejected\"}."
  def verdicts do
    case File.read(verdicts_path()) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, " ", parts: 2) do
            [name, state] when state in ["accepted", "rejected"] -> Map.put(acc, name, state)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc "Set a verdict: \"accepted\" | \"rejected\" | \"clear\"."
  def set(name, state) when state in ["accepted", "rejected", "clear"] do
    name = Path.basename(to_string(name))
    v = if state == "clear", do: Map.delete(verdicts(), name), else: Map.put(verdicts(), name, state)
    File.mkdir_p!(dir())
    File.write!(verdicts_path(), Enum.map_join(v, "\n", fn {k, s} -> "#{k} #{s}" end) <> "\n")
    :ok
  end

  @doc "The roster page — personas + takes + verdicts, flip buttons wired."
  def html(token) do
    v = verdicts()
    acc_tags = accents()

    cards =
      for name <- Autopoet.VoicePersonas.names() do
        take = Path.join(takes_dir(), name <> ".wav")
        state = v[name] || "candidate"
        desc = Autopoet.VoicePersonas.description(name)

        audio =
          if File.exists?(take),
            do: ~s(<audio controls preload="none" src="/voices/take/#{name}.wav"></audio>),
            else: ~s(<div class="note">no take yet</div>)

        opts =
          Enum.map_join(["accepted", "candidate", "rejected"], fn st ->
            sel = if st == state, do: " selected", else: ""
            ~s(<option value="#{st}"#{sel}>#{st}</option>)
          end)

        accent = acc_tags[name] || "english"

        aopts =
          Enum.map_join(["english", "british", "australian", "other"], fn a ->
            sel = if a == accent, do: " selected", else: ""
            ~s(<option value="#{a}"#{sel}>#{a}</option>)
          end)

        ~s"""
        <div class="card" data-state="#{state}" id="card-#{name}">
          <div class="row"><span class="name">#{name}</span>
            <span class="selwrap"><select class="asel" data-n="#{name}">#{aopts}</select></span>
            <span class="selwrap"><select class="vsel" data-n="#{name}">#{opts}</select></span>
          </div>
          <div class="note">“#{desc}”</div>
          #{audio}
        </div>
        """
      end

    ~s"""
    <!doctype html><meta charset="utf-8"><title>voice roster</title>
    <style>
      body{font:14px/1.6 ui-monospace,Menlo,monospace;background:#f7f6f1;color:#16161a;max-width:680px;margin:40px auto;padding:0 20px}
      h1{font-size:20px}.sub{color:#6a6f68;margin-bottom:20px}
      .card{background:#fff;border:1.6px solid #e2e6ec;border-radius:15px;padding:13px 17px;margin-bottom:11px}
      .card[data-state="accepted"]{border-color:#3f7a52}
      .card[data-state="rejected"]{border-color:#c0564f;opacity:.55}
      .row{display:flex;align-items:center;gap:8px}.name{font-weight:600;font-size:15px;flex:1}
      .chip{font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-radius:6px;padding:3px 8px;background:#f4f6f8;color:#6a6f68}
      .selwrap{position:relative;display:inline-block}
      .selwrap::after{content:"▾";position:absolute;right:10px;top:50%;transform:translateY(-50%);pointer-events:none;font-size:10px;color:#6a6f68}
      .vsel,.fsel,.asel{appearance:none;-webkit-appearance:none;font:600 11.5px ui-monospace,monospace;color:#1c2230;
        background:#fff;border:1.4px solid #d6dbe2;border-radius:9px;padding:6px 26px 6px 12px;cursor:pointer}
      .card[data-state="accepted"] .vsel{border-color:#3f7a52;background:#3f7a52;color:#fff}
      .card[data-state="rejected"] .vsel{border-color:#c0564f;background:#c0564f;color:#fff}
      .card[data-state="accepted"] .selwrap::after,.card[data-state="rejected"] .selwrap::after{color:#fff}
      .note{color:#6a6f68;font-size:11.5px;font-style:italic;margin:3px 0 9px}
      audio{width:100%;height:34px}
      .filters{margin-bottom:16px}
      .card.hid{display:none}
    </style>
    <h1>the voice roster</h1>
    <p class="sub">verdicts persist server-side (data/voices/verdicts) — regenerate takes all you like, your picks survive. accepted: <b id="nacc"></b></p>
    <div class="filters">
      <span class="selwrap"><select class="fsel" id="filter">
        <option value="all">show: all</option>
        <option value="accepted">show: accepted</option>
        <option value="candidate">show: candidates</option>
        <option value="rejected">show: rejected</option>
      </select></span>
    </div>
    #{Enum.join(cards)}
    <script>
      const TOKEN = "#{token}";
      const filterSel = document.getElementById("filter");
      function refresh() {
        document.getElementById("nacc").textContent =
          document.querySelectorAll('.card[data-state="accepted"]').length;
        const f = filterSel.value;
        document.querySelectorAll(".card").forEach(c =>
          c.classList.toggle("hid", f !== "all" && c.dataset.state !== f));
      }
      filterSel.onchange = refresh;
      document.querySelectorAll(".asel").forEach(sel => sel.onchange = () =>
        fetch(`/voices/accent?name=${sel.dataset.n}&accent=${sel.value}`, { method: "POST",
          headers: { authorization: "Bearer " + TOKEN } }));
      document.querySelectorAll(".vsel").forEach(sel => sel.onchange = async () => {
        const n = sel.dataset.n, st = sel.value;
        const server = st === "candidate" ? "clear" : st;
        await fetch(`/voices/verdict?name=${n}&state=${server}`, { method: "POST",
          headers: { authorization: "Bearer " + TOKEN } });
        document.getElementById("card-" + n).dataset.state = st;
        refresh();
      });
      refresh();
    </script>
    """
  end
end
