defmodule Autopoet.Eval.Order2 do
  @moduledoc """
  Order-2 pathway candidate (tournament entrant, NOT wired live): the miss
  taxonomy showed 79–90% of hebb misses on real traces are RANK misses — the
  edge exists but first-order context can't rank it into the top-k. The
  cheapest context-depth fix is a bigram-context count model: edges keyed on
  `prev2 ⨝ prev1 → next`, BACKING OFF to the plain order-1 model when the
  composite context is cold. Same Hebbian arithmetic (Model.observe_edge —
  the real production math), gradient-free, microseconds, cloud-trivial.

  If THIS stalls too, the next rungs are the semantic nominator (D3) and only
  then learned sequence models — each as one more tournament row.
  """

  alias Autopoet.Shadow.Hebb.Model

  def new(cfg \\ %{}) do
    %{o2: Model.new(cfg), o1: Model.new(cfg), p1: nil, p2: nil}
  end

  def observe(s, sig) do
    o1 = Model.observe(s.o1, sig)

    o2 =
      if s.p1 && s.p2,
        do: Model.observe_edge(s.o2, ctx(s.p2, s.p1), sig),
        else: %{s.o2 | t: s.o2.t + 1}

    %{s | o1: o1, o2: o2, p2: s.p1, p1: sig}
  end

  @doc "Predict next: order-2 context first, order-1 fills the remaining slots."
  def predict_next(s, k) do
    deep = if s.p1 && s.p2, do: Model.predict(s.o2, ctx(s.p2, s.p1), k), else: []
    shallow = Model.predict(s.o1, s.p1, k)
    Enum.take(deep ++ (shallow -- deep), k)
  end

  defp ctx(p2, p1), do: p2 <> "⨝" <> p1
end
