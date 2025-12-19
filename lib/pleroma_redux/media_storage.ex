defmodule PleromaRedux.MediaStorage do
  @callback store_media(PleromaRedux.User.t(), Plug.Upload.t()) ::
              {:ok, String.t()} | {:error, term()}

  def store_media(user, upload) do
    impl().store_media(user, upload)
  end

  defp impl do
    Application.get_env(:pleroma_redux, __MODULE__, PleromaRedux.MediaStorage.Local)
  end
end
