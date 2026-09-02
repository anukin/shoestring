defmodule Shoestring.Test.DispatchEffect do
  @behaviour Shoestring.Harness.Dispatch.Effect

  @impl true
  def perform(run, dispatch) do
    send(
      Application.fetch_env!(:shoestring, :dispatch_effect_test_pid),
      {:dispatch_effect, run.id, dispatch.dispatch_id}
    )

    Application.fetch_env!(:shoestring, :dispatch_effect_test_result)
  end
end
