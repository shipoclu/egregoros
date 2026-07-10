defmodule Egregoros.CredentialProofVerifier do
  @callback verify(map(), map()) :: :ok | {:error, term()}

  @impl_key {__MODULE__, :impl}

  def verify(credential, context) when is_map(credential) and is_map(context) do
    impl().verify(credential, context)
  end

  @doc false
  def put_impl(impl) when is_atom(impl), do: Process.put(@impl_key, impl)

  @doc false
  def clear_impl, do: Process.delete(@impl_key)

  defp impl do
    Process.get(@impl_key) ||
      Egregoros.Config.get(__MODULE__, Egregoros.VerifiableCredentials.ProofVerifier)
  end
end
