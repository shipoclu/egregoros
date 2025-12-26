defmodule Egregoros.TestSupport.Fixtures do
  @base Path.expand("../fixtures", __DIR__)

  def path!(name) when is_binary(name) do
    Path.join(@base, name)
  end

  def json!(name) when is_binary(name) do
    name
    |> path!()
    |> File.read!()
    |> Jason.decode!()
  end
end
