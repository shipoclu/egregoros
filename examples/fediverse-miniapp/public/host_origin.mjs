/** Returns whether a value is one exact canonical HTTPS host origin. */
export const isCanonicalHttpsHostOrigin = value => {
  if (typeof value !== "string") return false

  try {
    const origin = new URL(value)
    return (
      origin.protocol === "https:" &&
      origin.origin === value &&
      !origin.username &&
      !origin.password
    )
  } catch {
    return false
  }
}
