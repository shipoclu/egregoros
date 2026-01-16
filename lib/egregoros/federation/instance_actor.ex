defmodule Egregoros.Federation.InstanceActor do
  alias Egregoros.Users
  alias EgregorosWeb.Endpoint

  @nickname "instance.actor"

  def nickname, do: @nickname

  def ap_id, do: Endpoint.url()

  def get_actor do
    Users.get_or_create_instance_actor(@nickname, ap_id())
  end
end
