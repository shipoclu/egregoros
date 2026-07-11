const normalizeAccounts = values =>
  [...new Set(values.map(value => value.toLowerCase()))].sort()

export const walletContextMatches = async (adapter, expected) => {
  if (!expected || typeof expected.chainId !== "string" || !Array.isArray(expected.accounts)) {
    return false
  }

  const [chainId, accounts] = await Promise.all([
    adapter.request({method: "eth_chainId", params: []}),
    adapter.request({method: "eth_accounts", params: []}),
  ])

  if (
    typeof chainId !== "string" ||
    !Array.isArray(accounts) ||
    !accounts.every(value => typeof value === "string") ||
    !expected.accounts.every(value => typeof value === "string")
  ) {
    return false
  }

  return (
    chainId === expected.chainId &&
    JSON.stringify(normalizeAccounts(accounts)) ===
      JSON.stringify(normalizeAccounts(expected.accounts))
  )
}
