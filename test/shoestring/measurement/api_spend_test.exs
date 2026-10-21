defmodule Shoestring.ApiSpendTest do
  use Shoestring.DataCase, async: false
  alias Shoestring.{ApiSpend, Repo}
  alias Shoestring.ApiSpend.{Pricing, Reservation}
  alias Shoestring.Test.ApiSpendHelpers, as: F
  @now ~U[2026-10-20 12:00:00.000000Z]

  setup do
    previous = Application.fetch_env(:shoestring, :api_execution)
    Application.put_env(:shoestring, :api_execution, F.config())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:shoestring, :api_execution, value)
        :error -> Application.delete_env(:shoestring, :api_execution)
      end
    end)

    {request, run} = F.request!(Repo)
    %{request: request, run: run, opts: [now: @now]}
  end

  test "disabled and zero-default policies refuse before recording spend", c do
    Application.delete_env(:shoestring, :api_execution)
    assert {:error, :api_disabled} = ApiSpend.reserve(c.request, c.opts)
    Application.put_env(:shoestring, :api_execution, %{enabled: true})
    assert {:error, :api_zero_cap} = ApiSpend.reserve(c.request, c.opts)
    Application.put_env(:shoestring, :api_execution, %{F.config() | monthly_cap_microusd: 0})
    assert {:error, :api_zero_cap} = ApiSpend.reserve(c.request, c.opts)
    assert Repo.aggregate(Reservation, :count) == 0
    assert {:ok, %{"remaining_microusd" => 0}} = ApiSpend.summary(c.opts)
  end

  test "price acceptance, compatible model and effective dates are required", c do
    for change <- [
          %{accepted_price_version: nil},
          %{model: "other-model"},
          %{max_output_tokens: 128_001}
        ] do
      Application.put_env(:shoestring, :api_execution, Map.merge(F.config(), change))
      assert {:error, :pricing_not_reviewed_or_compatible} = ApiSpend.reserve(c.request, c.opts)
    end

    assert {:error, :pricing_not_reviewed_or_compatible} =
             Pricing.quote(F.config(), ~U[2026-11-21 00:00:00Z])

    assert {:error, :pricing_not_reviewed_or_compatible} =
             Pricing.quote(F.config(), ~U[2026-10-19 00:00:00Z])

    assert Repo.aggregate(Reservation, :count) == 0
  end

  test "integer quotes reserve full context and output maxima, not heuristic token estimates" do
    assert {:ok, pricing, 319_096} = Pricing.quote(F.config(), @now)
    assert pricing["context_tokens"] == 1_050_000
    assert pricing["output_token_limit"] == 4096
    assert {:ok, 1} = Pricing.usage_amount(pricing, %{"input_tokens" => 1, "output_tokens" => 0})

    assert {:ok, 800} =
             Pricing.usage_amount(pricing, %{"input_tokens" => 1000, "output_tokens" => 500})

    assert {:ok, 0} = Pricing.usage_amount(pricing, %{"input_tokens" => 0, "output_tokens" => 0})

    assert {:error, :usage_outside_reserved_bounds} =
             Pricing.usage_amount(pricing, %{"input_tokens" => -1, "output_tokens" => 0})

    assert {:error, :usage_outside_reserved_bounds} =
             Pricing.usage_amount(pricing, %{"input_tokens" => 0, "output_tokens" => 4097})
  end

  test "configured allowance is occupied before another call and duplicates cannot dispatch again",
       c do
    assert {:ok, first} = ApiSpend.reserve(c.request, c.opts)
    assert first.maximum_microusd == 319_096
    assert {:error, :api_call_already_reserved} = ApiSpend.reserve(c.request, c.opts)

    for _ <- 1..2 do
      {request, _} = F.request!(Repo)
      assert {:ok, _} = ApiSpend.reserve(request, c.opts)
    end

    {request, _} = F.request!(Repo)
    assert {:error, :api_cap_exceeded} = ApiSpend.reserve(request, c.opts)
    assert Repo.aggregate(Reservation, :count) == 3

    assert {:ok, %{"reserved_microusd" => 957_288, "remaining_microusd" => 42_712}} =
             ApiSpend.summary(c.opts)
  end

  test "usage reconciles under the immutable original quote, idempotently", c do
    assert {:ok, row} = ApiSpend.reserve(c.request, c.opts)

    override =
      Pricing.entry()
      |> Map.put("version", "higher-v2")
      |> Map.put("input_microusd_per_million", 600_000)

    Application.put_env(
      :shoestring,
      :api_execution,
      Map.merge(F.config(), %{price_override: override, accepted_price_version: "higher-v2"})
    )

    usage = %{"input_tokens" => 1000, "output_tokens" => 500}
    assert {:ok, settled} = ApiSpend.reconcile(row.id, usage, c.opts)
    assert settled.reconciled_microusd == 800
    assert {:ok, ^settled} = ApiSpend.reconcile(row.id, usage, now: DateTime.add(@now, 1))

    assert {:error, :api_usage_conflict} =
             ApiSpend.reconcile(row.id, %{"input_tokens" => 1, "output_tokens" => 1}, c.opts)

    assert {:ok, %{"reserved_microusd" => 0, "reconciled_upper_microusd" => 800}} =
             ApiSpend.summary(c.opts)
  end

  test "missing or out-of-bound usage never releases allowance", c do
    assert {:ok, row} = ApiSpend.reserve(c.request, c.opts)
    assert {:ok, %{status: "unresolved"}} = ApiSpend.reconcile(row.id, %{}, c.opts)

    assert {:ok, %{status: "unresolved"}} =
             ApiSpend.reconcile(
               row.id,
               %{"input_tokens" => 2_000_000, "output_tokens" => 1},
               c.opts
             )

    assert {:ok, %{status: "unresolved"}} = ApiSpend.unresolved(row.id, c.opts)
    assert {:ok, %{"reserved_microusd" => 319_096}} = ApiSpend.summary(c.opts)
    assert Repo.get!(Reservation, row.id).reconciled_microusd == nil
  end

  test "unresolved calls carry into later months; spanning calls book both endpoints", c do
    october = ~U[2026-10-31 23:59:50.000000Z]
    november = ~U[2026-11-01 00:00:10.000000Z]
    assert {:ok, row} = ApiSpend.reserve(c.request, now: october)
    assert {:ok, %{"reserved_microusd" => 319_096}} = ApiSpend.summary(now: november)

    assert {:ok, %{reconciled_month: "2026-11", reconciled_microusd: 800}} =
             ApiSpend.reconcile(row.id, %{"input_tokens" => 1000, "output_tokens" => 500},
               now: november
             )

    for at <- [october, november] do
      assert {:ok, %{"reserved_microusd" => 0, "reconciled_upper_microusd" => 800}} =
               ApiSpend.summary(now: at)
    end
  end

  test "a lower cap exposes occupied allowance and blocks new calls without eviction", c do
    assert {:ok, row} = ApiSpend.reserve(c.request, c.opts)
    Application.put_env(:shoestring, :api_execution, %{F.config() | monthly_cap_microusd: 1})
    {request, _} = F.request!(Repo)
    assert {:error, :api_cap_exceeded} = ApiSpend.reserve(request, c.opts)

    assert {:ok, %{"over_cap_microusd" => 319_095, "remaining_microusd" => 0}} =
             ApiSpend.summary(c.opts)

    assert Repo.get!(Reservation, row.id).status == "reserved"
  end

  test "the request cannot select its cap, price or another run's ownership", c do
    Application.put_env(:shoestring, :api_execution, %{F.config() | monthly_cap_microusd: 1})
    altered = %{c.request | policy: %{"monthly_cap_microusd" => 1_000_000_000}}
    assert {:error, :api_cap_exceeded} = ApiSpend.reserve(altered, c.opts)
    Application.put_env(:shoestring, :api_execution, F.config())

    assert {:error, :api_run_not_owned} =
             ApiSpend.reserve(%{c.request | workspace_ref: "workspace/other"}, c.opts)

    c.run |> Ecto.Changeset.change(provider_id: "shoestring.harness.fake") |> Repo.update!()
    assert {:error, :api_provider_mismatch} = ApiSpend.reserve(c.request, c.opts)
    assert Repo.aggregate(Reservation, :count) == 0
  end

  test "durable schema forbids settlement without counters and time cannot release a maximum",
       c do
    assert {:ok, row} = ApiSpend.reserve(c.request, c.opts)

    assert {:error, _changeset} =
             row |> Reservation.changeset(%{status: "reconciled"}) |> Repo.update()

    assert {:error, :api_reconciliation_before_reservation} =
             ApiSpend.reconcile(row.id, %{"input_tokens" => 0, "output_tokens" => 0},
               now: DateTime.add(@now, -1)
             )

    assert {:ok, %{"reserved_microusd" => 319_096}} =
             ApiSpend.summary(now: DateTime.add(@now, 10_000_000))
  end
end
