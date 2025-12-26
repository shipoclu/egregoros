defmodule Egregoros.Repo.Migrations.AddCompositeIndexes do
  use Ecto.Migration

  def change do
    create index(:objects, [:type, :id], name: :objects_type_id_index)
    create index(:objects, [:actor, :type, :id], name: :objects_actor_type_id_index)

    create index(:relationships, [:object, :type], name: :relationships_object_type_index)
  end
end
