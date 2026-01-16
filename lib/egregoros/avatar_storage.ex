defmodule Egregoros.AvatarStorage do
  @callback store_avatar(Egregoros.User.t(), Plug.Upload.t()) ::
              {:ok, String.t()} | {:error, term()}

  def store_avatar(user, upload) do
    impl().store_avatar(user, upload)
  end

  defp impl do
    Egregoros.Config.get(__MODULE__, Egregoros.AvatarStorage.Local)
  end
end
