defmodule EgregorosWeb.ViewModels.Status do
  @moduledoc false

  alias Egregoros.Objects
  alias Egregoros.Relationships
  alias Egregoros.User
  alias EgregorosWeb.SafeMediaURL
  alias EgregorosWeb.ViewModels.Actor

  @reaction_emojis ["🔥", "👍", "❤️"]
  @recipient_fields ~w(to cc bto bcc audience)

  def decorate(%{type: "Note"} = object, current_user) do
    decorate_one(object, current_user)
  end

  def decorate(%{type: "Announce", object: object_ap_id} = announce, current_user)
      when is_binary(object_ap_id) do
    decorate_one(announce, current_user)
  end

  def decorate(object, current_user) when is_map(object) do
    %{
      feed_id: Map.get(object, :id) || Map.get(object, "id"),
      object: object,
      actor: Actor.card(Map.get(object, :actor)),
      attachments: [],
      likes_count: 0,
      liked?: false,
      reposts_count: 0,
      reposted?: false,
      bookmarked?: false,
      reactions: reactions_for_object(object, current_user)
    }
  end

  def decorate_many(objects, current_user) when is_list(objects) do
    ctx = decoration_context(objects, current_user)

    objects
    |> Enum.map(&decorate_with_context(&1, current_user, ctx))
    |> Enum.reject(&is_nil/1)
  end

  def reaction_emojis, do: @reaction_emojis

  defp decorate_one(object, current_user) do
    case decorate_many([object], current_user) do
      [entry] -> entry
      _ -> nil
    end
  end

  defp reactions_for_object(%{ap_id: ap_id}, current_user) when is_binary(ap_id) do
    counts =
      ap_id
      |> Relationships.emoji_reaction_counts()
      |> Enum.reduce(%{}, fn {type, emoji_url, count}, acc ->
        emoji = String.replace_prefix(type, "EmojiReact:", "")

        if emoji == "" do
          acc
        else
          emoji_url = SafeMediaURL.safe(emoji_url)

          Map.update(
            acc,
            emoji,
            %{count: count, url: emoji_url},
            fn existing ->
              %{
                count: (existing.count || 0) + count,
                url: existing.url || emoji_url
              }
            end
          )
        end
      end)

    emojis =
      @reaction_emojis
      |> Kernel.++(Map.keys(counts))
      |> Enum.uniq()

    for emoji <- emojis, into: %{} do
      relationship_type = "EmojiReact:" <> emoji
      info = Map.get(counts, emoji, %{count: 0, url: nil})

      {emoji,
       %{
         count: info.count || 0,
         url: info.url,
         reacted?: reacted_by_user?(ap_id, current_user, relationship_type, info.url)
       }}
    end
  end

  defp reactions_for_object(_object, _current_user) do
    for emoji <- @reaction_emojis, into: %{} do
      {emoji, %{count: 0, reacted?: false, url: nil}}
    end
  end

  defp reacted_by_user?(_object_ap_id, nil, _relationship_type, _emoji_url), do: false

  defp reacted_by_user?(object_ap_id, %User{} = current_user, relationship_type, emoji_url)
       when is_binary(object_ap_id) and is_binary(relationship_type) do
    emoji_url = SafeMediaURL.safe(emoji_url)

    case Relationships.get_by_type_actor_object(
           relationship_type,
           current_user.ap_id,
           object_ap_id
         ) do
      %{emoji_url: existing_url} -> SafeMediaURL.safe(existing_url) == emoji_url
      _ -> false
    end
  end

  defp attachments_for_object(%{data: %{} = data}) do
    data
    |> Map.get("attachment")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&attachment_view_model/1)
    |> Enum.reject(&is_nil/1)
  end

  defp attachments_for_object(_object), do: []

  defp attachment_view_model(%{} = attachment) do
    href =
      attachment
      |> Map.get("url")
      |> List.wrap()
      |> Enum.find_value(&attachment_href/1)
      |> SafeMediaURL.safe()

    preview_href =
      attachment
      |> Map.get("icon")
      |> preview_href_from_icon()
      |> SafeMediaURL.safe()

    media_type =
      cond do
        is_binary(Map.get(attachment, "mediaType")) ->
          Map.get(attachment, "mediaType")

        true ->
          attachment
          |> Map.get("url")
          |> List.wrap()
          |> Enum.find_value(&attachment_media_type/1)
      end

    description =
      attachment
      |> Map.get("name", "")
      |> to_string()
      |> String.trim()

    if is_binary(href) and href != "" do
      %{
        href: href,
        preview_href: preview_href,
        media_type: media_type,
        description: description
      }
    else
      nil
    end
  end

  defp attachment_href(%{"href" => href}) when is_binary(href), do: href
  defp attachment_href(%{"url" => href}) when is_binary(href), do: href
  defp attachment_href(href) when is_binary(href), do: href
  defp attachment_href(_), do: nil

  defp preview_href_from_icon(%{"url" => urls}) do
    urls
    |> List.wrap()
    |> Enum.find_value(&attachment_href/1)
  end

  defp preview_href_from_icon(_icon), do: nil

  defp attachment_media_type(%{"mediaType" => media_type}) when is_binary(media_type),
    do: media_type

  defp attachment_media_type(_), do: nil

  defp decoration_context(objects, current_user) when is_list(objects) do
    reblog_ap_ids =
      objects
      |> Enum.filter(&match?(%{type: "Announce"}, &1))
      |> Enum.map(&Map.get(&1, :object))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    reblogs_by_ap_id =
      reblog_ap_ids
      |> Objects.list_by_ap_ids()
      |> Map.new(&{&1.ap_id, &1})

    note_objects =
      objects
      |> Enum.filter(&match?(%{type: "Note"}, &1))
      |> Kernel.++(Map.values(reblogs_by_ap_id))
      |> Enum.filter(&match?(%{type: "Note"}, &1))
      |> Enum.uniq_by(& &1.ap_id)

    object_ap_ids =
      note_objects
      |> Enum.map(& &1.ap_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    actor_ap_ids =
      note_objects
      |> Enum.map(& &1.actor)
      |> Kernel.++(
        objects
        |> Enum.filter(&match?(%{type: "Announce"}, &1))
        |> Enum.map(&Map.get(&1, :actor))
      )
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    actor_cards = Actor.cards_by_ap_id(actor_ap_ids)

    status_counts = Relationships.count_by_types_objects(["Like", "Announce"], object_ap_ids)

    me_relationships =
      case current_user do
        %User{ap_id: ap_id} when is_binary(ap_id) ->
          Relationships.list_by_types_actor_objects(
            ["Like", "Announce", "Bookmark"],
            ap_id,
            object_ap_ids
          )

        ap_id when is_binary(ap_id) ->
          Relationships.list_by_types_actor_objects(
            ["Like", "Announce", "Bookmark"],
            ap_id,
            object_ap_ids
          )

        _ ->
          MapSet.new()
      end

    emoji_counts = Relationships.emoji_reaction_counts_for_objects(object_ap_ids)

    emoji_me_relationships =
      case current_user do
        %User{ap_id: ap_id} when is_binary(ap_id) ->
          ap_id
          |> Relationships.emoji_reactions_by_actor_for_objects(object_ap_ids)
          |> Enum.map(fn {type, emoji_url, object_ap_id} ->
            {type, SafeMediaURL.safe(emoji_url), object_ap_id}
          end)
          |> MapSet.new()

        ap_id when is_binary(ap_id) ->
          ap_id
          |> Relationships.emoji_reactions_by_actor_for_objects(object_ap_ids)
          |> Enum.map(fn {type, emoji_url, object_ap_id} ->
            {type, SafeMediaURL.safe(emoji_url), object_ap_id}
          end)
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    needs_followed_actors? = map_size(reblogs_by_ap_id) > 0

    followed_actors =
      case current_user do
        %User{ap_id: ap_id} when needs_followed_actors? and is_binary(ap_id) ->
          ap_id
          |> Relationships.list_follows_by_actor_for_objects(actor_ap_ids)
          |> Enum.map(& &1.object)
          |> MapSet.new()

        ap_id when needs_followed_actors? and is_binary(ap_id) ->
          ap_id
          |> Relationships.list_follows_by_actor_for_objects(actor_ap_ids)
          |> Enum.map(& &1.object)
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    %{
      reblogs_by_ap_id: reblogs_by_ap_id,
      actor_cards: actor_cards,
      status_counts: status_counts,
      me_relationships: me_relationships,
      emoji_counts: emoji_counts,
      emoji_me_relationships: emoji_me_relationships,
      followed_actors: followed_actors
    }
  end

  defp decorate_with_context(
         %{type: "Announce", object: object_ap_id} = announce,
         current_user,
         ctx
       )
       when is_binary(object_ap_id) do
    object_ap_id = String.trim(object_ap_id)

    with true <- object_ap_id != "",
         %{type: "Note"} = object <- Map.get(ctx.reblogs_by_ap_id, object_ap_id),
         true <- visible_to_cached?(object, current_user, ctx.followed_actors) do
      decorate_note_with_context(object, current_user, ctx,
        feed_id: announce.id,
        reposted_by: actor_card(announce.actor, ctx.actor_cards)
      )
    else
      _ -> nil
    end
  end

  defp decorate_with_context(%{type: "Note"} = object, current_user, ctx) do
    decorate_note_with_context(object, current_user, ctx, feed_id: object.id)
  end

  defp decorate_with_context(other, current_user, _ctx) do
    decorate(other, current_user)
  end

  defp decorate_note_with_context(%{type: "Note"} = object, current_user, ctx, opts) do
    feed_id = Keyword.get(opts, :feed_id, object.id)
    reposted_by = Keyword.get(opts, :reposted_by)

    counts = Map.get(ctx.status_counts, object.ap_id, %{})
    likes_count = Map.get(counts, "Like", 0)
    reposts_count = Map.get(counts, "Announce", 0)

    liked? =
      match?(%User{}, current_user) and
        MapSet.member?(ctx.me_relationships, {"Like", object.ap_id})

    reposted? =
      match?(%User{}, current_user) and
        MapSet.member?(ctx.me_relationships, {"Announce", object.ap_id})

    bookmarked? =
      match?(%User{}, current_user) and
        MapSet.member?(ctx.me_relationships, {"Bookmark", object.ap_id})

    decorated = %{
      feed_id: feed_id,
      object: object,
      actor: actor_card(object.actor, ctx.actor_cards),
      attachments: attachments_for_object(object),
      likes_count: likes_count,
      liked?: liked?,
      reposts_count: reposts_count,
      reposted?: reposted?,
      bookmarked?: bookmarked?,
      reactions: reactions_for_object_with_context(object.ap_id, current_user, ctx)
    }

    case reposted_by do
      %{} -> Map.put(decorated, :reposted_by, reposted_by)
      _ -> decorated
    end
  end

  defp decorate_note_with_context(_object, _current_user, _ctx, _opts), do: nil

  defp reactions_for_object_with_context(object_ap_id, current_user, ctx)
       when is_binary(object_ap_id) do
    counts =
      ctx.emoji_counts
      |> Map.get(object_ap_id, [])
      |> List.wrap()
      |> Enum.reduce(%{}, fn
        {type, emoji_url, count}, acc ->
          emoji = String.replace_prefix(type, "EmojiReact:", "")

          if emoji == "" do
            acc
          else
            emoji_url = SafeMediaURL.safe(emoji_url)

            Map.update(
              acc,
              emoji,
              %{count: count, url: emoji_url},
              fn existing ->
                %{
                  count: (existing.count || 0) + count,
                  url: existing.url || emoji_url
                }
              end
            )
          end

        _other, acc ->
          acc
      end)

    emojis =
      @reaction_emojis
      |> Kernel.++(Map.keys(counts))
      |> Enum.uniq()

    for emoji <- emojis, into: %{} do
      relationship_type = "EmojiReact:" <> emoji
      info = Map.get(counts, emoji, %{count: 0, url: nil})

      reacted? =
        match?(%User{}, current_user) and
          MapSet.member?(ctx.emoji_me_relationships, {relationship_type, info.url, object_ap_id})

      {emoji, %{count: info.count || 0, url: info.url, reacted?: reacted?}}
    end
  end

  defp reactions_for_object_with_context(_object_ap_id, _current_user, _ctx) do
    for emoji <- @reaction_emojis, into: %{} do
      {emoji, %{count: 0, reacted?: false, url: nil}}
    end
  end

  defp actor_card(actor_ap_id, cards_by_ap_id) when is_map(cards_by_ap_id) do
    case Map.get(cards_by_ap_id, actor_ap_id) do
      %{} = card -> card
      _ -> Actor.card(actor_ap_id)
    end
  end

  defp actor_card(actor_ap_id, _cards_by_ap_id), do: Actor.card(actor_ap_id)

  defp visible_to_cached?(object, nil, _followed_actors) do
    Objects.publicly_visible?(object)
  end

  defp visible_to_cached?(object, %User{ap_id: ap_id}, followed_actors) when is_binary(ap_id) do
    visible_to_cached?(object, ap_id, followed_actors)
  end

  defp visible_to_cached?(%{actor: actor} = object, user_ap_id, followed_actors)
       when is_binary(actor) and is_binary(user_ap_id) do
    cond do
      actor == user_ap_id -> true
      Objects.publicly_visible?(object) -> true
      addressed_to?(object, user_ap_id) -> true
      followers_addressed?(object) and MapSet.member?(followed_actors, actor) -> true
      true -> false
    end
  end

  defp visible_to_cached?(_object, _user_ap_id, _followed_actors), do: false

  defp addressed_to?(%{data: %{} = data}, user_ap_id) when is_binary(user_ap_id) do
    user_ap_id = String.trim(user_ap_id)

    if user_ap_id == "" do
      false
    else
      Enum.any?(@recipient_fields, fn field ->
        data
        |> Map.get(field)
        |> List.wrap()
        |> Enum.any?(fn
          %{"id" => id} when is_binary(id) -> String.trim(id) == user_ap_id
          %{id: id} when is_binary(id) -> String.trim(id) == user_ap_id
          id when is_binary(id) -> String.trim(id) == user_ap_id
          _ -> false
        end)
      end)
    end
  end

  defp addressed_to?(_object, _user_ap_id), do: false

  defp followers_addressed?(%{actor: actor, data: %{} = data})
       when is_binary(actor) and actor != "" do
    followers = actor <> "/followers"
    to = data |> Map.get("to", []) |> List.wrap()
    cc = data |> Map.get("cc", []) |> List.wrap()
    followers in to or followers in cc
  end

  defp followers_addressed?(_object), do: false
end
