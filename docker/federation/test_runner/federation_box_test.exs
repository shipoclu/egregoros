defmodule FederationBoxTest do
  @moduledoc false

  alias Egregoros.Federation
  alias Egregoros.Federation.WebFinger
  alias Egregoros.Relationships
  alias Egregoros.User
  alias Egregoros.Users

  @timeout_ms 120_000
  @poll_interval_ms 1_000

  def run do
    IO.puts("[fedbox] starting")

    {:ok, alice} = Users.get_or_create_local_user("alice")

    follow_and_wait(alice, "@bob@pleroma.test")
    follow_and_wait(alice, "@carol@mastodon.test")

    IO.puts("[fedbox] ok")
    System.halt(0)
  rescue
    exception ->
      IO.puts("[fedbox] failure: #{Exception.format(:error, exception, __STACKTRACE__)}")
      System.halt(1)
  catch
    kind, value ->
      IO.puts("[fedbox] failure: #{Exception.format(kind, value, __STACKTRACE__)}")
      System.halt(1)
  end

  defp follow_and_wait(%User{} = local_user, handle) when is_binary(handle) do
    wait_until(
      fn -> match?({:ok, _actor_url}, WebFinger.lookup(handle)) end,
      "webfinger ready #{handle}"
    )

    remote_user =
      case Federation.follow_remote(local_user, handle) do
        {:ok, %User{} = user} -> user
        {:error, reason} -> raise("follow_remote failed for #{handle}: #{inspect(reason)}")
        other -> raise("follow_remote failed for #{handle}: #{inspect(other)}")
      end

    wait_until(
      fn ->
        Relationships.get_by_type_actor_object("Follow", local_user.ap_id, remote_user.ap_id) != nil
      end,
      "follow accepted #{local_user.nickname} -> #{handle}"
    )

    :ok
  end

  defp wait_until(check_fun, label) when is_function(check_fun, 0) and is_binary(label) do
    deadline = System.monotonic_time(:millisecond) + @timeout_ms
    do_wait_until(check_fun, label, deadline)
  end

  defp do_wait_until(check_fun, label, deadline_ms)
       when is_function(check_fun, 0) and is_binary(label) and is_integer(deadline_ms) do
    if check_fun.() do
      IO.puts("[fedbox] ✓ #{label}")
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        raise("timeout waiting for #{label}")
      else
        Process.sleep(@poll_interval_ms)
        do_wait_until(check_fun, label, deadline_ms)
      end
    end
  end
end
