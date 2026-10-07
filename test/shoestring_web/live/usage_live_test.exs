defmodule ShoestringWeb.UsageLiveTest do
  use ShoestringWeb.ConnCase, async: false
  import Shoestring.ConfigurationFixtures
  import Ecto.Query
  alias Shoestring.Repo
  alias Shoestring.Harness.CapacitySnapshotRecord

  test "unknown page and refresh do not invent or persist observations", %{conn: conn} do
    count = Repo.aggregate(CapacitySnapshotRecord, :count)
    {:ok, view, _} = live(conn, "/usage")
    assert has_element?(view, "#usage-accounts", "No saved allowance")
    refute has_element?(view, "#usage-accounts [role=progressbar]")
    refute has_element?(view, "#usage-accounts details")
    view |> element("#refresh-usage") |> render_click()
    assert Repo.aggregate(CapacitySnapshotRecord, :count) == count
  end

  test "stale reading keeps reported value but marks current allowance unknown", %{conn: conn} do
    capacity_fixture(%{observed_at: DateTime.add(DateTime.utc_now(), -600)})
    {:ok, view, _} = live(conn, "/usage")
    assert has_element?(view, "#usage-accounts [role=progressbar][aria-valuenow='25.0']")
    assert has_element?(view, "#usage-accounts .ss-notice", "stale")
    assert has_element?(view, "#usage-accounts .ss-unknown", "Unknown")
    assert has_element?(view, "#usage-accounts details")
  end

  test "legacy sensitive scope is redacted while allowance remains present", %{conn: conn} do
    snapshot = capacity_fixture()

    Repo.update_all(from(s in CapacitySnapshotRecord, where: s.id == ^snapshot.snapshot_id),
      set: [scope: "account-label token=synthetic-sensitive-value"]
    )

    {:ok, view, _} = live(conn, "/usage")
    refute has_element?(view, "#usage-accounts", "synthetic-sensitive-value")
    assert has_element?(view, "#usage-accounts .ss-scope", "account-label")
    assert has_element?(view, "#usage-accounts [role=progressbar][aria-valuenow='25.0']")
    assert has_element?(view, "#usage-accounts h2", "Codex")
  end
end
