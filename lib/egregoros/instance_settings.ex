defmodule Egregoros.InstanceSettings do
  alias Egregoros.InstanceSetting
  alias Egregoros.Repo

  @singleton_id 1

  def get do
    case Repo.get(InstanceSetting, @singleton_id) do
      %InstanceSetting{} = setting ->
        setting

      nil ->
        _ =
          Repo.insert(
            %InstanceSetting{id: @singleton_id, registrations_open: true},
            on_conflict: :nothing,
            conflict_target: :id
          )

        Repo.get!(InstanceSetting, @singleton_id)
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

