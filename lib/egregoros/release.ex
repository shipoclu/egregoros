defmodule Egregoros.Release do
  @moduledoc false

  @app :egregoros

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

  defp load_app do
    Application.load(@app)
  end
end
