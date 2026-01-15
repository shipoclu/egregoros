defmodule Egregoros.Repo.Migrations.AddObjectsObjectIndexes do
  use Ecto.Migration

  def change do
    create index(:objects, [:object],
             name: :objects_object_index,
             where: "object IS NOT NULL"
           )

    create index(:objects, [:type, :object, :id],
             name: :objects_type_object_id_index,
             where: "object IS NOT NULL"
           )
  end
end
