defmodule Redix.Auth do
  @moduledoc false

  # This module is responsible for providing functions to perform authentication
  # and db selection on Redis (AUTH and SELECT).

  alias Redix.Protocol

  @doc """
  Authenticates and selects the right database based on the state `state`.

  This function checks the given options to see if a password and/or a database
  are specified. If a password is specified, then this function will send the
  appropriate `AUTH` command to the Redis connection in `state.socket`. If a
  database is specified, then the appropriate `SELECT` command will be issued.

  The socket is expected to be in passive mode, and will be returned in passive
  mode to the caller.
  """
  @spec auth_and_select_db(:gen_tcp.socket, Keyword.t) :: {:ok, binary} | {:error, term}
  def auth_and_select_db(socket, opts) when is_list(opts) do
    with {:ok, tail} <- auth(socket, opts[:password]),
         {:ok, tail} <- select_db(socket, opts[:database], tail) do
      case tail do
        "" ->
          :ok
        other when byte_size(other) > 0 ->
          {:error, :unexpected_tail_after_auth}
      end
    end
  end

  defp auth(_socket, nil) do
    {:ok, ""}
  end

  defp auth(socket, password) when is_binary(password) do
    with :ok <- :gen_tcp.send(socket, Protocol.pack(["AUTH", password])) do
      case blocking_recv(socket, "") do
        {:ok, "OK", tail} ->
          {:ok, tail}
        {:ok, error, _tail} ->
          {:error, error}
        {:error, _reason} = error ->
          error
      end
    end
  end

  defp select_db(_socket, nil, tail) do
    {:ok, tail}
  end

  defp select_db(socket, db, tail) do
    with :ok <- :gen_tcp.send(socket, Protocol.pack(["SELECT", db])) do
      case blocking_recv(socket, tail) do
        {:ok, "OK", tail} ->
          {:ok, tail}
        {:ok, error, _tail} ->
          {:error, error}
        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec blocking_recv(:gen_tcp.socket, binary, nil | (binary -> term)) :: {:ok, term, binary} | {:error, term}
  defp blocking_recv(socket, tail, continuation \\ nil) do
    with {:ok, data} <- :gen_tcp.recv(socket, 0) do
      parser = continuation || &Protocol.parse/1
      case parser.(tail <> data) do
        {:ok, _resp, _rest} = result ->
          result
        {:continuation, continuation} ->
          blocking_recv(socket, "", continuation)
      end
    end
  end
end
