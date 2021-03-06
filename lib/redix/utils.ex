defmodule Redix.Utils do
  @moduledoc false

  require Logger

  alias Redix.Auth

  @socket_opts [:binary, active: false]

  @redis_opts [:host, :port, :password, :database]
  @redis_default_opts [
    host: "localhost",
    port: 6379,
  ]

  @redix_behaviour_opts [:socket_opts, :sync_connect, :backoff_initial, :backoff_max, :log, :exit_on_disconnection]
  @redix_default_behaviour_opts [
    socket_opts: [],
    sync_connect: false,
    backoff_initial: 500,
    backoff_max: 30_000,
    log: [],
    exit_on_disconnection: false,
  ]

  @log_default_opts [
    disconnection: :error,
    failed_connection: :error,
    reconnection: :info,
  ]

  @default_timeout 5000

  @spec sanitize_starting_opts(Keyword.t, Keyword.t) :: {Keyword.t, Keyword.t}
  def sanitize_starting_opts(redis_opts, other_opts)
      when is_list(redis_opts) and is_list(other_opts) do
    check_redis_opts(redis_opts)

    # `connection_opts` are the opts to be passed to `Connection.start_link/3`.
    # `redix_behaviour_opts` are the other options to tweak the behaviour of
    # Redix (e.g., the backoff time).
    {redix_behaviour_opts, connection_opts} = Keyword.split(other_opts, @redix_behaviour_opts)

    redis_opts = Keyword.merge(@redis_default_opts, redis_opts)
    redix_behaviour_opts = Keyword.merge(@redix_default_behaviour_opts, redix_behaviour_opts)

    redix_behaviour_opts = Keyword.update!(redix_behaviour_opts, :log, fn(log_opts) ->
      unless Keyword.keyword?(log_opts) do
        raise ArgumentError,
          "the :log option must be a keyword list of {action, level}, got: #{inspect log_opts}"
      end

      Keyword.merge(@log_default_opts, log_opts)
    end)

    redix_opts = Keyword.merge(redix_behaviour_opts, redis_opts)

    {redix_opts, connection_opts}
  end

  @spec connect(Keyword.t) :: {:ok, :gen_tcp.socket} | {:error, term} | {:stop, term, %{}}
  def connect(opts) do
    host = opts |> Keyword.fetch!(:host) |> String.to_char_list()
    port = Keyword.fetch!(opts, :port)
    socket_opts = @socket_opts ++ Keyword.fetch!(opts, :socket_opts)
    timeout = opts[:timeout] || @default_timeout

    with {:ok, socket} <- :gen_tcp.connect(host, port, socket_opts, timeout),
         :ok <- setup_socket_buffers(socket) do
      case Auth.auth_and_select_db(socket, opts) do
        :ok -> {:ok, socket}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @spec format_host(Redix.Connection.state) :: String.t
  def format_host(%{opts: opts} = _state) do
    "#{opts[:host]}:#{opts[:port]}"
  end

  # Setups the `:buffer` option of the given socket.
  defp setup_socket_buffers(socket) do
    with {:ok, opts} <- :inet.getopts(socket, [:sndbuf, :recbuf, :buffer]) do
      [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer] = opts
      :inet.setopts(socket, buffer: buffer |> max(sndbuf) |> max(recbuf))
    end
  end

  defp check_redis_opts(opts) when is_list(opts) do
    Enum.each opts, fn {opt, _value} ->
      unless opt in @redis_opts do
        raise ArgumentError,
          "unknown Redis connection option: #{inspect opt}." <>
          " The first argument to start_link/1 should only" <>
          " contain Redis-specific options (host, port," <>
          " password, database)"
      end
    end

    case Keyword.get(opts, :port) do
      port when is_nil(port) or is_integer(port) ->
        :ok
      other ->
        raise ArgumentError, "expected an integer as the value of the :port option, got: #{inspect(other)}"
    end
  end
end
