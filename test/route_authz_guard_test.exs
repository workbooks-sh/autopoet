defmodule Autopoet.RouteAuthzGuardTest do
  @moduledoc """
  Route-authorization regression guard (wb-review, workstream A3). Every `.work` route registered in
  `Nexus.Router.routes()` must declare an EXPLICIT auth posture (`auth: :public | :user | :member |
  :admin | :owner`). A route with NO `auth:` has a `nil` policy — it fails closed on a multi-tenant nexus
  (`Nexus.Authz.route_allowed?`, wb-h8yv) but a missing annotation is almost always an oversight, so we
  fail CI on it. This is the guard that would have caught the fail-open route class the audit found.

  NOTE: it does NOT yet assert "mutations must not be :public" — the autopoet surface is currently
  blanket `auth: "trusted"` (all routes :public), which is CRITICAL finding wb-dhia3; that stronger
  assertion becomes enforceable once wb-dhia3 downgrades routes to real per-route postures.
  """
  use ExUnit.Case

  test "every registered route declares an explicit (non-nil) auth policy" do
    routes = Nexus.Router.routes()

    # Guard against a vacuous pass: the app boots in the suite, so the registry must be populated.
    assert map_size(routes) > 50,
           "route registry has only #{map_size(routes)} entries — the app did not register its routes, so this guard would be vacuous"

    missing =
      for {{method, segs}, entry} <- routes, policy_of(entry) == nil do
        "#{method} /#{Enum.join(List.wrap(segs), "/")}"
      end

    assert missing == [],
           "routes with NO explicit auth: annotation (nil policy — add an explicit `auth:`):\n" <>
             Enum.join(missing, "\n")
  end

  # The registry value is {module, fun, policy}; be tolerant of shape drift and just find the policy atom.
  defp policy_of({_mod, _fun, policy}), do: policy
  defp policy_of(%{policy: policy}), do: policy
  defp policy_of(_), do: :unknown
end
