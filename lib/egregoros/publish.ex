defmodule Egregoros.Publish do
  @moduledoc """
  Publish operations for creating and interacting with ActivityPub objects.

  This module provides the public API for publish operations. Type-specific
  implementations are delegated to submodules:

  - `Publish.Notes` - Note posting operations
  - `Publish.Polls` - Poll voting operations
  """

  alias Egregoros.Publish.Notes
  alias Egregoros.Publish.Polls

  # Poll operations
  defdelegate vote_on_poll(user, question, choices), to: Polls
  defdelegate post_poll(user, content, poll_params), to: Polls
  defdelegate post_poll(user, content, poll_params, opts), to: Polls

  # Note operations
  defdelegate post_note(user, content), to: Notes
  defdelegate post_note(user, content, opts), to: Notes
end
