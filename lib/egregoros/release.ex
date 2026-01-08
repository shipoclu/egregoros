defmodule Egregoros.Release do
  @moduledoc false

  @app :egregoros

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  def rollback(repo, version) when is_atom(repo) and is_integer(version) do
    load_app()

    {:ok, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, :down, to: version)
      end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
