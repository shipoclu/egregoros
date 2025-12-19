defmodule PleromaReduxWeb.RegistrationController do
  use PleromaReduxWeb, :controller

  alias PleromaRedux.User
  alias PleromaRedux.Users

  def new(conn, _params) do
    form =
      Phoenix.Component.to_form(
        %{"nickname" => "", "email" => "", "password" => ""},
        as: :registration
      )

    render(conn, :new, form: form, error: nil)
  end

  def create(conn, %{"registration" => %{} = params}) do
    nickname = params |> Map.get("nickname", "") |> to_string() |> String.trim()
    email = params |> Map.get("email", "") |> to_string() |> String.trim()
    password = params |> Map.get("password", "") |> to_string()

    form =
      Phoenix.Component.to_form(%{"nickname" => nickname, "email" => email, "password" => ""}, as: :registration)

    cond do
      nickname == "" ->
        render(conn, :new, form: form, error: "Nickname can't be empty.")

      email == "" ->
        render(conn, :new, form: form, error: "Email can't be empty.")

      password == "" ->
        render(conn, :new, form: form, error: "Password can't be empty.")

      Users.get_by_nickname(nickname) ->
        render(conn, :new, form: form, error: "Nickname is already registered.")

      Users.get_by_email(email) ->
        render(conn, :new, form: form, error: "Email is already registered.")

      true ->
        case Users.register_local_user(%{nickname: nickname, email: email, password: password}) do
          {:ok, %User{} = user} ->
            conn
            |> put_session(:user_id, user.id)
            |> redirect(to: ~p"/")

          {:error, :invalid_email} ->
            render(conn, :new, form: form, error: "Email is invalid.")

          {:error, :invalid_password} ->
            render(conn, :new, form: form, error: "Password is invalid.")

          {:error, _changeset} ->
            render(conn, :new, form: form, error: "Could not register.")
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> text("Unprocessable Entity")
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: ~p"/")
  end
end
