defmodule PleromaRedux.Publish do
  alias PleromaRedux.Activities.Create
  alias PleromaRedux.Activities.Note
  alias PleromaRedux.Pipeline
  alias PleromaRedux.User

  def post_note(%User{} = user, content) when is_binary(content) do
    content = String.trim(content)

    if content == "" do
      {:error, :empty}
    else
      note = Note.build(user, content)
      create = Create.build(user, note)

      Pipeline.ingest(create, local: true)
    end
  end
end
