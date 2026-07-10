defmodule Egregoros.TestSupport.CredentialProof do
  @moduledoc false

  def allow_valid do
    Egregoros.CredentialProofVerifier.put_impl(Egregoros.CredentialProofVerifier.Mock)
    Mox.stub(Egregoros.CredentialProofVerifier.Mock, :verify, fn _credential, _context -> :ok end)
    :ok
  end
end
