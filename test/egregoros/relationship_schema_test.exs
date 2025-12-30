defmodule Egregoros.RelationshipSchemaTest do
  use ExUnit.Case, async: true

  test "relationships timestamps use microsecond precision" do
    assert :utc_datetime_usec == Egregoros.Relationship.__schema__(:type, :inserted_at)
    assert :utc_datetime_usec == Egregoros.Relationship.__schema__(:type, :updated_at)
  end
end

