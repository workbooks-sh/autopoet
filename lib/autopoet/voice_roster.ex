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

    cards =
      for name <- Autopoet.VoicePersonas.names() do
        take = Path.join(takes_dir(), name <> ".wav")
        state = v[name] || "candidate"
        desc = Autopoet.VoicePersonas.description(name)

        audio =
          if File.exists?(take),
            do: ~s(<audio controls preload="none" src="/voices/take/#{name}.wav"></audio>),
            else: ~s(<div class="note">no take yet</div>)

        ~s"""
        <div class="card st-#{state}" id="card-#{name}">
          <div class="row"><span class="name">#{name}</span>
            <span class="chip st">#{state}</span>
            <button data-n="#{name}" data-s="accepted" class="vb ok">accept</button>
            <button data-n="#{name}" data-s="rejected" class="vb no">reject</button>
            <button data-n="#{name}" data-s="clear" class="vb">clear</button>
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
      .card.st-accepted{border-color:#3f7a52}.card.st-rejected{border-color:#c0564f;opacity:.55}
      .row{display:flex;align-items:center;gap:8px}.name{font-weight:600;font-size:15px;flex:1}
      .chip{font-size:10px;text-transform:uppercase;letter-spacing:.06em;border-radius:6px;padding:3px 8px;background:#f4f6f8;color:#6a6f68}
      .st-accepted .chip.st{background:#3f7a52;color:#fff}.st-rejected .chip.st{background:#c0564f;color:#fff}
      .vb{font:600 10.5px ui-monospace,monospace;padding:4px 10px;border-radius:7px;border:1px solid #d6dbe2;background:#fff;cursor:pointer}
      .vb.ok:hover{background:#3f7a52;color:#fff}.vb.no:hover{background:#c0564f;color:#fff}
      .note{color:#6a6f68;font-size:11.5px;font-style:italic;margin:3px 0 9px}
      audio{width:100%;height:34px}
      .filters{display:flex;gap:8px;margin-bottom:16px}
      .fb{font:600 11px ui-monospace,monospace;padding:6px 14px;border-radius:9px;border:1px solid #d6dbe2;background:#fff;cursor:pointer;color:#1c2230}
      .fb.sel{background:#16161a;color:#fff;border-color:#16161a}
      .card.hid{display:none}
    </style>
    <h1>the voice roster</h1>
    <p class="sub">verdicts persist server-side (data/voices/verdicts) — regenerate takes all you like, your picks survive. accepted: <b id="nacc"></b></p>
    <div class="filters">
      <button class="fb sel" data-f="all">all</button>
      <button class="fb" data-f="accepted">accepted</button>
      <button class="fb" data-f="candidate">candidates</button>
      <button class="fb" data-f="rejected">rejected</button>
    </div>
    #{Enum.join(cards)}
    <script>
      const TOKEN = "#{token}";
      let FILTER = "all";
      function refresh() {
        document.getElementById("nacc").textContent =
          document.querySelectorAll(".card.st-accepted").length;
        document.querySelectorAll(".card").forEach(c => {
          const st = c.className.match(/st-(\w+)/)[1];
          c.classList.toggle("hid", FILTER !== "all" && st !== FILTER);
        });
      }
      document.querySelectorAll(".fb").forEach(b => b.onclick = () => {
        FILTER = b.dataset.f;
        document.querySelectorAll(".fb").forEach(x => x.classList.toggle("sel", x === b));
        refresh();
      });
      document.querySelectorAll(".vb").forEach(b => b.onclick = async () => {
        const n = b.dataset.n, s = b.dataset.s;
        await fetch(`/voices/verdict?name=${n}&state=${s}`, { method: "POST",
          headers: { authorization: "Bearer " + TOKEN } });
        const card = document.getElementById("card-" + n);
        card.className = "card st-" + (s === "clear" ? "candidate" : s);
        card.querySelector(".chip.st").textContent = s === "clear" ? "candidate" : s;
        refresh();
      });
      refresh();
    </script>
    """
  end
end
