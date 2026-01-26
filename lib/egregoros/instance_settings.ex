defmodule Egregoros.InstanceSettings do
  import Ecto.Query, only: [from: 2]

  alias Egregoros.InstanceSetting
  alias Egregoros.Repo

  def get do
    case Repo.one(from(s in InstanceSetting, limit: 1)) do
      %InstanceSetting{} = setting ->
        setting

      nil ->
        {:ok, %InstanceSetting{} = setting} =
          Repo.insert(%InstanceSetting{registrations_open: true})

        setting
    end
  end

  def registrations_open? do
    case get() do
      %InstanceSetting{registrations_open: open} -> open == true
      _ -> true
    end
  end

  def set_registrations_open(open) when is_boolean(open) do
    setting = get()

    setting
    |> InstanceSetting.changeset(%{registrations_open: open})
    |> Repo.update()
  end

  def set_registrations_open(_open), do: {:error, :invalid_value}
end
