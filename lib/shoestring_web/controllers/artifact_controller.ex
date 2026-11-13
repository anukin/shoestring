defmodule ShoestringWeb.ArtifactController do
  @moduledoc """
  `GET /goals/:goal_id/artifacts/:artifact_id`: the bytes of one decision
  candidate (iteration 19), so a person can see what they are choosing.

  Served only from a loopback address to a local host name (no DNS
  rebinding), like `/mcp`, and only for an artifact that is a candidate of
  one of that goal's decisions: no other artifact (logs, transcripts,
  evidence) is ever served, and there is no listing. Bytes come through
  `Shoestring.Trajectory.ArtifactStore.read/2`, which verifies containment,
  hash and size. A redacted artifact is refused.

  Images (raster), video, audio and plain text are shown inline; anything
  else is a download. Every response carries `Content-Security-Policy:
  sandbox` and `X-Content-Type-Options: nosniff`, so a candidate can never
  run script on Shoestring's origin.
  """

  use ShoestringWeb, :controller

  import Ecto.Query

  alias Shoestring.Decisions.Decision
  alias Shoestring.Repo
  alias Shoestring.Trajectory.ArtifactStore

  @local_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]
  @inline ~r/\A(image\/(png|jpeg|gif|webp|avif)|video\/[a-z0-9.+-]+|audio\/[a-z0-9.+-]+|text\/plain)\z/

  def show(conn, %{"goal_id" => goal_id, "artifact_id" => artifact_id}) do
    with :ok <- local(conn),
         {:ok, goal_id} <- uuid(goal_id),
         {:ok, artifact_id} <- uuid(artifact_id),
         true <- visible_goal?(goal_id) || {:error, 404},
         true <- candidate?(goal_id, artifact_id) || {:error, 404},
         {:ok, %{artifact: artifact, bytes: bytes}} <- read(artifact_id),
         true <- artifact.goal_id == goal_id || {:error, 404},
         :ok <- if(artifact.redacted, do: {:error, 403}, else: :ok) do
      conn
      |> put_resp_content_type(artifact.media_type, nil)
      |> put_resp_header("content-disposition", disposition(artifact))
      |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, bytes)
    else
      {:error, status} -> send_resp(conn, status, "")
    end
  end

  defp local(conn) do
    if ShoestringWeb.TerminalBrowser.local?(conn.remote_ip) and conn.host in @local_hosts,
      do: :ok,
      else: {:error, 403}
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, 404}
    end
  end

  # The goal page's rule: an observatory goal is never shown.
  defp visible_goal?(goal_id) do
    case Repo.get(Shoestring.Trajectory.Goal, goal_id) do
      nil -> false
      goal -> not Shoestring.Trajectory.Goal.observatory?(goal)
    end
  end

  # The candidate must belong to a decision of this goal. Options are a
  # bounded JSON list per row, so the check reads that goal's decisions.
  defp candidate?(goal_id, artifact_id) do
    Repo.all(from d in Decision, where: d.goal_id == ^goal_id, select: d.options)
    |> Enum.any?(fn options -> Enum.any?(options, &(&1["artifact_id"] == artifact_id)) end)
  end

  defp read(artifact_id) do
    case ArtifactStore.read(artifact_id) do
      {:ok, result} -> {:ok, result}
      {:error, _} -> {:error, 404}
    end
  end

  defp disposition(artifact) do
    name = "candidate-#{String.slice(artifact.sha256, 0, 12)}"

    if Regex.match?(@inline, artifact.media_type),
      do: ~s(inline; filename="#{name}"),
      else: ~s(attachment; filename="#{name}")
  end
end
