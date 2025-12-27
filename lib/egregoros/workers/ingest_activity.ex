defmodule Egregoros.Workers.IngestActivity do
  use Oban.Worker, queue: :federation_incoming, max_attempts: 5

  alias Egregoros.Pipeline

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity" => activity} = args}) when is_map(activity) do
    inbox_user_ap_id = Map.get(args, "inbox_user_ap_id")

    opts =
      [local: false]
      |> maybe_put_inbox_user_ap_id(inbox_user_ap_id)

    case Pipeline.ingest(activity, opts) do
      {:ok, _object} -> :ok
      {:error, reason} -> {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_args}

  defp maybe_put_inbox_user_ap_id(opts, inbox_user_ap_id) when is_binary(inbox_user_ap_id) do
    inbox_user_ap_id = String.trim(inbox_user_ap_id)

    if inbox_user_ap_id == "",
      do: opts,
      else: Keyword.put(opts, :inbox_user_ap_id, inbox_user_ap_id)
  end

  defp maybe_put_inbox_user_ap_id(opts, _inbox_user_ap_id), do: opts
end
