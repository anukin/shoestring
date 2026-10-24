defmodule Shoestring.CLI.Refusal do
  @moduledoc """
  An expected refusal from a `shoestring` command: one line for stderr and an
  exit status (1 for a refusal, 2 for invalid arguments). Never a stack trace.
  """

  defexception message: "Refused.", exit_status: 1

  @doc "Raises a refusal with `message`."
  @spec refuse!(String.t(), keyword()) :: no_return()
  def refuse!(message, opts \\ []) do
    raise __MODULE__, message: message, exit_status: Keyword.get(opts, :exit_status, 1)
  end

  @doc "Raises the invalid-arguments refusal for `command`."
  @spec usage!(String.t()) :: no_return()
  def usage!(command),
    do: refuse!("Invalid arguments. See shoestring #{command} --help", exit_status: 2)
end
