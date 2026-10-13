defmodule Shoestring.Cobbler.ReservationPolicyTest do
  use ExUnit.Case, async: true
  alias Shoestring.Cobbler.ReservationPolicy

  test "defaults keep every configured concurrency allowance at one" do
    assert {:ok, policy} = ReservationPolicy.new()

    assert ReservationPolicy.to_map(policy) == %{
             "version" => 1,
             "global_limit" => 1,
             "provider_account_limit" => 1,
             "goal_limit" => 1,
             "account_units" => 1,
             "task_units" => 1
           }

    assert {:ok, ^policy} = ReservationPolicy.new(ReservationPolicy.to_map(policy))
  end

  test "configuration accepts bounded integer weights and rejects ambiguous or impossible limits" do
    assert {:ok, %{task_units: 2, account_units: 3}} =
             ReservationPolicy.new(%{"task_units" => 2, "account_units" => 3})

    for key <- [:global_limit, :provider_account_limit, :goal_limit, :account_units, :task_units],
        value <- [nil, 0, -1, 65, 1.5, "2"] do
      assert {:error, %Ecto.Changeset{}} = ReservationPolicy.new(%{key => value})
    end

    assert {:error, _} = ReservationPolicy.new(%{version: 2})
    assert {:error, _} = ReservationPolicy.new(%{task_units: 2, account_units: 1})
    assert {:error, _} = ReservationPolicy.new([])
  end
end
