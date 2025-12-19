defmodule PleromaReduxWeb.MastodonAPI.AccountRenderer do
  alias PleromaRedux.User
  alias PleromaReduxWeb.URL

  def render_account(%User{} = user) do
    avatar_url = URL.absolute(user.avatar_url) || ""

    %{
      "id" => Integer.to_string(user.id),
      "username" => user.nickname,
      "acct" => user.nickname,
      "display_name" => user.name || user.nickname,
      "note" => user.bio || "",
      "avatar" => avatar_url,
      "avatar_static" => avatar_url,
      "url" => user.ap_id
    }
  end

  def render_account(%{ap_id: ap_id, nickname: nickname}) do
    %{
      "id" => ap_id,
      "username" => nickname,
      "acct" => nickname,
      "display_name" => nickname,
      "url" => ap_id
    }
  end

  def render_account(_), do: %{"id" => "unknown", "username" => "unknown", "acct" => "unknown"}
end
