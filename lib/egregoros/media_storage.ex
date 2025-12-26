defmodule Egregoros.MediaStorage do
  @callback store_media(Egregoros.User.t(), Plug.Upload.t()) ::
              {:ok, String.t()} | {:error, term()}

  def store_media(user, upload) do
    impl().store_media(user, upload)
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, Egregoros.MediaStorage.Local)
  end
end
