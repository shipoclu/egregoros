defmodule EgregorosWeb.Live.Uploads do
  @moduledoc false

  def cancel_all(socket, upload_name) when is_atom(upload_name) do
    case socket.assigns.uploads |> Map.get(upload_name) do
      %{entries: entries} when is_list(entries) ->
        Enum.reduce(entries, socket, fn entry, socket ->
          Phoenix.LiveView.cancel_upload(socket, upload_name, entry.ref)
        end)

      _ ->
        socket
    end
  end
end
