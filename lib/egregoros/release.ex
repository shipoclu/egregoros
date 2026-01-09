defmodule Egregoros.Release do
  @moduledoc false

  @app :egregoros

  def healthcheck(opts \\ []) when is_list(opts) do
    host = Keyword.get(opts, :host, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, default_port())
    path = Keyword.get(opts, :path, "/health")
    timeout = Keyword.get(opts, :timeout, 1_000)

    case :gen_tcp.connect(host, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        result = check_socket(socket, path, timeout)
        _ = :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  def migrate do
    load_app()

    for repo <- repos() do
      case Ecto.Migrator.with_repo(repo, fn repo ->
             Ecto.Migrator.run(repo, :up, all: true)
           end) do
        {:ok, _migrations, _apps} -> :ok
        {:error, reason} -> raise "Migration failed: #{inspect(reason)}"
      end
    end
  end

  def rollback(repo, version) when is_atom(repo) and is_integer(version) do
    load_app()

    case Ecto.Migrator.with_repo(repo, fn repo ->
           Ecto.Migrator.run(repo, :down, to: version)
         end) do
      {:ok, _migrations, _apps} -> :ok
      {:error, reason} -> raise "Rollback failed: #{inspect(reason)}"
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp default_port do
    System.get_env("PORT", "4000")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> 4000
      value -> String.to_integer(value)
    end
  end

  defp check_socket(socket, path, timeout) do
    request = ["GET ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"]

    with :ok <- :gen_tcp.send(socket, request),
         {:ok, response} <- :gen_tcp.recv(socket, 0, timeout) do
      if String.starts_with?(response, "HTTP/1.1 200") or
           String.starts_with?(response, "HTTP/1.0 200") do
        :ok
      else
        {:error, :bad_status}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_app do
    Application.load(@app)
  end
end
