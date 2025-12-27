defmodule Mix.Tasks.Egregoros.Admin do
  use Mix.Task

  @shortdoc "Promote or demote local users to admin"

  @moduledoc """
  Manage admin users.

  Usage:

      mix egregoros.admin promote <nickname>
      mix egregoros.admin demote <nickname>
  """

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    case argv do
      ["promote", nickname] ->
        set_admin(nickname, true)

      ["demote", nickname] ->
        set_admin(nickname, false)

      _ ->
        Mix.raise("""
        invalid arguments

        Usage:
          mix egregoros.admin promote <nickname>
          mix egregoros.admin demote <nickname>
        """)
    end
  end

  defp set_admin(nickname, admin) when is_binary(nickname) and is_boolean(admin) do
    nickname = String.trim(nickname)

    case Egregoros.Users.get_by_nickname(nickname) do
      nil ->
        Mix.raise("user not found: #{nickname}")

      user ->
        case Egregoros.Users.set_admin(user, admin) do
          {:ok, _user} ->
            verb = if admin, do: "promoted", else: "demoted"
            Mix.shell().info("#{verb} #{nickname} to admin=#{admin}")

          {:error, reason} ->
            Mix.raise("could not update admin flag: #{inspect(reason)}")
        end
    end
  end
end

