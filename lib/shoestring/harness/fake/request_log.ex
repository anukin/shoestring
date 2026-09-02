defmodule Shoestring.Harness.Fake.RequestLog do
  @moduledoc """
  An in-process request recorder for the fake harness adapter.

  Records every start, resume, and cancel call so tests can assert what the
  adapter received. Key invariant: the log proves that raw prior transcripts
  and forbidden data were NOT passed (handoff privacy).
  """

  use Agent

  @type entry ::
          {:start, Shoestring.Harness.RunRequest.t()}
          | {:resume, Shoestring.Harness.RunRequest.t()}
          | {:cancel, Shoestring.Harness.RunIdentity.t()}

  @spec start() :: {:ok, pid()}
  def start, do: Agent.start(fn -> [] end)

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, opts)
  end

  @spec record(pid(), entry()) :: :ok
  def record(pid, entry) do
    Agent.update(pid, fn entries -> [entry | entries] end)
  end

  @spec all(pid()) :: [entry()]
  def all(pid) do
    Agent.get(pid, fn entries -> Enum.reverse(entries) end)
  end

  @spec starts(pid()) :: [Shoestring.Harness.RunRequest.t()]
  def starts(pid) do
    pid
    |> all()
    |> Enum.flat_map(fn
      {:start, req} -> [req]
      _ -> []
    end)
  end

  @spec resumes(pid()) :: [Shoestring.Harness.RunRequest.t()]
  def resumes(pid) do
    pid
    |> all()
    |> Enum.flat_map(fn
      {:resume, req} -> [req]
      _ -> []
    end)
  end

  @spec cancels(pid()) :: [Shoestring.Harness.RunIdentity.t()]
  def cancels(pid) do
    pid
    |> all()
    |> Enum.flat_map(fn
      {:cancel, id} -> [id]
      _ -> []
    end)
  end

  @spec count(pid()) :: non_neg_integer()
  def count(pid), do: Agent.get(pid, &length/1)

  @spec clear(pid()) :: :ok
  def clear(pid), do: Agent.update(pid, fn _ -> [] end)
end
