defmodule Egregoros.ScheduledStatus do
  use Ecto.Schema

  import Ecto.Changeset

  @required_fields ~w(user_id scheduled_at params)a
  @optional_fields ~w(oban_job_id published_at)a

  @default_min_offset_seconds 5 * 60

  schema "scheduled_statuses" do
    belongs_to :user, Egregoros.User

    field :scheduled_at, :utc_datetime_usec
    field :params, :map, default: %{}
    field :oban_job_id, :integer
    field :published_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(%__MODULE__{} = scheduled_status, attrs) when is_map(attrs) do
    scheduled_status
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_scheduled_at()
  end

  def changeset(%__MODULE__{} = scheduled_status, attrs) do
    changeset(scheduled_status, Map.new(attrs))
  end

  def update_changeset(%__MODULE__{} = scheduled_status, attrs) when is_map(attrs) do
    scheduled_status
    |> cast(attrs, [:scheduled_at])
    |> validate_required([:scheduled_at])
    |> validate_scheduled_at()
  end

  def update_changeset(%__MODULE__{} = scheduled_status, attrs) do
    update_changeset(scheduled_status, Map.new(attrs))
  end

  defp validate_scheduled_at(%Ecto.Changeset{} = changeset) do
    validate_change(changeset, :scheduled_at, fn _, scheduled_at ->
      if far_enough?(scheduled_at) do
        []
      else
        [scheduled_at: "must be at least 5 minutes from now"]
      end
    end)
  end

  defp min_offset_seconds do
    case Application.get_env(:egregoros, :scheduled_status_min_offset_seconds) do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _ -> @default_min_offset_seconds
    end
  end

  defp far_enough?(%DateTime{} = scheduled_at) do
    DateTime.diff(scheduled_at, DateTime.utc_now(), :second) >= min_offset_seconds()
  end

  defp far_enough?(_scheduled_at), do: false
end
