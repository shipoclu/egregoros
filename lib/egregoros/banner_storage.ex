defmodule Egregoros.BannerStorage do
  @callback store_banner(Egregoros.User.t(), Plug.Upload.t()) ::
              {:ok, String.t()} | {:error, term()}

  def store_banner(user, upload) do
    impl().store_banner(user, upload)
  end

  defp impl do
    Application.get_env(:egregoros, __MODULE__, Egregoros.BannerStorage.Local)
  end
end
