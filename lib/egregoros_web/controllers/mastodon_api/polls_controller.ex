defmodule EgregorosWeb.MastodonAPI.PollsController do
  @moduledoc """
  Mastodon API controller for poll operations.

  ## Routes (add to router.ex)

      # In the `pipe_through [:api, :api_optional_auth]` scope:
      get "/polls/:id", PollsController, :show

      # In the `pipe_through [:api, :api_auth, :oauth_write]` scope:
      post "/polls/:id/votes", PollsController, :vote

  ## Endpoints

  ### GET /api/v1/polls/:id
  View a poll.

  Returns: Poll entity
  OAuth: Public for public polls, user token + read:statuses for private polls

  ### POST /api/v1/polls/:id/votes
  Vote on a poll.

  Request body:
  - `choices` (required): Array of integers (0-indexed option indices)

  Returns: Poll entity
  OAuth: User token + write:statuses
  """
  use EgregorosWeb, :controller

  alias Egregoros.Objects
  alias Egregoros.Publish
  alias Egregoros.Workers.RefreshPoll
  alias EgregorosWeb.MastodonAPI.PollRenderer

  @doc """
  GET /api/v1/polls/:id

  View a poll. Returns the Poll entity for the given Question object.
  """
  def show(conn, %{"id" => id}) do
    current_user = conn.assigns[:current_user]

    case Objects.get(id) do
      %{type: "Question"} = object ->
        if Objects.visible_to?(object, current_user) do
          _ = RefreshPoll.maybe_enqueue(object)
          json(conn, PollRenderer.render(object, current_user))
        else
          send_resp(conn, 404, "Not Found")
        end

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  @doc """
  POST /api/v1/polls/:id/votes

  Vote on a poll. The `choices` parameter should be an array of 0-indexed
  option indices. For single-choice polls, only one choice is allowed.
  For multiple-choice polls, multiple choices can be submitted.

  Returns the updated Poll entity.
  """
  def vote(conn, %{"id" => id, "choices" => choices}) when is_list(choices) do
    user = conn.assigns.current_user

    case Objects.get(id) do
      %{type: "Question"} = object ->
        if Objects.visible_to?(object, user) do
          case Publish.vote_on_poll(user, object, choices) do
            {:ok, updated_object} ->
              json(conn, PollRenderer.render(updated_object, user))

            {:error, :already_voted} ->
              conn
              |> put_status(422)
              |> json(%{"error" => "You have already voted on this poll"})

            {:error, :poll_expired} ->
              conn
              |> put_status(422)
              |> json(%{"error" => "This poll has ended"})

            {:error, :invalid_choice} ->
              conn
              |> put_status(422)
              |> json(%{"error" => "Invalid poll option"})

            {:error, :own_poll} ->
              conn
              |> put_status(422)
              |> json(%{"error" => "You cannot vote on your own poll"})

            {:error, :multiple_choices_not_allowed} ->
              conn
              |> put_status(422)
              |> json(%{"error" => "This poll only allows a single choice"})

            {:error, _reason} ->
              send_resp(conn, 422, "Unprocessable Entity")
          end
        else
          send_resp(conn, 404, "Not Found")
        end

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  def vote(conn, %{"id" => _id, "choices" => _choices}) do
    conn
    |> put_status(422)
    |> json(%{"error" => "Invalid poll option"})
  end

  def vote(conn, %{"id" => _id}) do
    conn
    |> put_status(422)
    |> json(%{"error" => "Missing required parameter: choices"})
  end
end
