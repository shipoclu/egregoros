const addressPattern = /^0x[0-9a-fA-F]{40}$/
const dataPattern = /^0x(?:[0-9a-fA-F]{2})*$/
const quantityPattern = /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/
const decimalUnsignedPattern = /^(?:0|[1-9][0-9]*)$/
const decimalSignedPattern = /^(?:0|-?[1-9][0-9]*)$/
const identifierPattern = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/
const dangerousKeys = new Set(["__proto__", "constructor", "prototype"])
const textEncoder = new TextEncoder()

const maxTypedDataBytes = 65_536
const maxTypedDepth = 12
const maxTypedNodes = 4_096
const maxContainerEntries = 128
const maxTypedTypes = 32
const maxTypedFields = 32
const maxTypedStringBytes = 8_192
const maxCalldataBytes = 65_536
const maxAccessListEntries = 128
const maxStorageKeys = 256
const maxAccounts = 16

const methods = new Set([
  "eth_accounts",
  "eth_chainId",
  "eth_requestAccounts",
  "personal_sign",
  "eth_signTypedData_v4",
  "eth_sendTransaction",
])

const noParamMethods = new Set(["eth_accounts", "eth_chainId", "eth_requestAccounts"])
const privilegedMethods = new Set([
  "eth_requestAccounts",
  "personal_sign",
  "eth_signTypedData_v4",
  "eth_sendTransaction",
])

const transactionFields = [
  "from",
  "to",
  "data",
  "value",
  "gas",
  "gasPrice",
  "maxFeePerGas",
  "maxPriorityFeePerGas",
  "nonce",
  "chainId",
  "type",
  "accessList",
]
const transactionFieldSet = new Set(transactionFields)

const invalid = () => {
  throw new TypeError("Invalid wallet parameters")
}

const byteLength = value => textEncoder.encode(value).byteLength

const descriptorsForRecord = (value, {maxKeys = maxContainerEntries} = {}) => {
  try {
    if (!value || typeof value !== "object" || Array.isArray(value)) invalid()
    const prototype = Object.getPrototypeOf(value)
    if (prototype !== Object.prototype && prototype !== null) invalid()
    const keys = Reflect.ownKeys(value)
    if (keys.length > maxKeys || keys.some(key => typeof key !== "string")) invalid()
    const descriptors = Object.getOwnPropertyDescriptors(value)
    for (const key of keys) {
      const descriptor = descriptors[key]
      if (!descriptor?.enumerable || !("value" in descriptor)) invalid()
    }
    return {keys, descriptors}
  } catch (error) {
    if (error instanceof TypeError && error.message === "Invalid wallet parameters") throw error
    invalid()
  }
}

const valuesForArray = (value, {maxLength = maxContainerEntries} = {}) => {
  try {
    if (!Array.isArray(value) || Object.getPrototypeOf(value) !== Array.prototype) invalid()
    if (!Number.isSafeInteger(value.length) || value.length > maxLength) invalid()
    const keys = Reflect.ownKeys(value)
    if (keys.length !== value.length + 1 || keys.some(key => typeof key !== "string")) invalid()
    const descriptors = Object.getOwnPropertyDescriptors(value)
    if (!descriptors.length || descriptors.length.enumerable || !("value" in descriptors.length)) {
      invalid()
    }
    const result = []
    for (let index = 0; index < value.length; index++) {
      const descriptor = descriptors[String(index)]
      if (!descriptor?.enumerable || !("value" in descriptor)) invalid()
      result.push(descriptor.value)
    }
    return result
  } catch (error) {
    if (error instanceof TypeError && error.message === "Invalid wallet parameters") throw error
    invalid()
  }
}

const exactRecord = (value, allowed, required = allowed, options) => {
  const {keys, descriptors} = descriptorsForRecord(value, options)
  const allowedSet = allowed instanceof Set ? allowed : new Set(allowed)
  if (keys.some(key => !allowedSet.has(key))) invalid()
  if (required.some(key => !keys.includes(key))) invalid()
  return {keys, descriptors}
}

const valueFrom = (record, key) => record.descriptors[key]?.value

const sortedRecord = value => {
  const result = {}
  for (const key of Object.keys(value).sort()) result[key] = value[key]
  return result
}

const normalizeAddress = value => {
  if (typeof value !== "string" || !addressPattern.test(value)) invalid()
  return value.toLowerCase()
}

const normalizeData = (value, {bytes = maxCalldataBytes, exactBytes} = {}) => {
  if (typeof value !== "string" || !dataPattern.test(value)) invalid()
  const size = (value.length - 2) / 2
  if (size > bytes || (exactBytes !== undefined && size !== exactBytes)) invalid()
  return value.toLowerCase()
}

const quantityValue = (value, bits) => {
  if (typeof value !== "string" || !quantityPattern.test(value)) invalid()
  if (value.length - 2 > Math.ceil(bits / 4)) invalid()
  const parsed = BigInt(value)
  if (parsed >= 1n << BigInt(bits)) invalid()
  return {normalized: value.toLowerCase(), parsed}
}

export const normalizeEvmQuantity = (value, bits = 256) => quantityValue(value, bits).normalized

const normalizeAccessList = value =>
  valuesForArray(value, {maxLength: maxAccessListEntries}).map(entry => {
    const record = exactRecord(entry, ["address", "storageKeys"])
    return {
      address: normalizeAddress(valueFrom(record, "address")),
      storageKeys: valuesForArray(valueFrom(record, "storageKeys"), {
        maxLength: maxStorageKeys,
      }).map(key => normalizeData(key, {exactBytes: 32})),
    }
  })

const normalizeTransaction = value => {
  const record = exactRecord(value, transactionFieldSet, ["from"], {
    maxKeys: transactionFields.length,
  })
  const normalized = {from: normalizeAddress(valueFrom(record, "from"))}

  if (record.keys.includes("to")) normalized.to = normalizeAddress(valueFrom(record, "to"))
  if (record.keys.includes("data")) {
    normalized.data = normalizeData(valueFrom(record, "data"), {bytes: maxCalldataBytes})
  }

  for (const [field, bits] of [
    ["value", 256],
    ["gas", 64],
    ["gasPrice", 256],
    ["maxFeePerGas", 256],
    ["maxPriorityFeePerGas", 256],
    ["nonce", 64],
    ["chainId", 256],
    ["type", 8],
  ]) {
    if (record.keys.includes(field)) normalized[field] = normalizeEvmQuantity(valueFrom(record, field), bits)
  }

  if (record.keys.includes("accessList")) {
    normalized.accessList = normalizeAccessList(valueFrom(record, "accessList"))
  }

  if (!record.keys.includes("to") && (!record.keys.includes("data") || normalized.data === "0x")) {
    invalid()
  }
  if (record.keys.includes("gasPrice") &&
      (record.keys.includes("maxFeePerGas") || record.keys.includes("maxPriorityFeePerGas"))) {
    invalid()
  }
  if (
    record.keys.includes("maxFeePerGas") &&
    record.keys.includes("maxPriorityFeePerGas") &&
    BigInt(normalized.maxPriorityFeePerGas) > BigInt(normalized.maxFeePerGas)
  ) {
    invalid()
  }

  return sortedRecord(normalized)
}

const parseStrictJson = encoded => {
  if (typeof encoded !== "string" || byteLength(encoded) > maxTypedDataBytes) invalid()
  let index = 0
  let nodes = 0

  const whitespace = () => {
    while (index < encoded.length && /[\u0009\u000a\u000d\u0020]/.test(encoded[index])) index++
  }

  const parseString = () => {
    if (encoded[index] !== '"') invalid()
    const start = index++
    while (index < encoded.length) {
      const code = encoded.charCodeAt(index)
      if (code === 0x22) {
        index++
        try {
          const decoded = JSON.parse(encoded.slice(start, index))
          if (byteLength(decoded) > maxTypedStringBytes) invalid()
          return decoded
        } catch (_error) {
          invalid()
        }
      }
      if (code < 0x20) invalid()
      if (code === 0x5c) {
        index++
        if (index >= encoded.length) invalid()
        if (encoded[index] === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(encoded.slice(index + 1, index + 5))) invalid()
          index += 5
          continue
        }
        if (!'["\\/bfnrt]'.includes(encoded[index])) invalid()
      }
      index++
    }
    invalid()
  }

  const parseValue = depth => {
    if (++nodes > maxTypedNodes || depth > maxTypedDepth) invalid()
    whitespace()
    const token = encoded[index]
    if (token === '"') return parseString()
    if (token === "{") return parseObject(depth + 1)
    if (token === "[") return parseArray(depth + 1)
    for (const [literal, value] of [["true", true], ["false", false], ["null", null]]) {
      if (encoded.startsWith(literal, index)) {
        index += literal.length
        return value
      }
    }
    const match = encoded.slice(index).match(/^-?(?:0|[1-9][0-9]*)/)
    if (!match) invalid()
    if (match[0] === "-0") invalid()
    index += match[0].length
    if (/[.eE0-9]/.test(encoded[index] || "")) invalid()
    const number = Number(match[0])
    if (!Number.isSafeInteger(number)) invalid()
    return number
  }

  const parseArray = depth => {
    index++
    whitespace()
    const result = []
    if (encoded[index] === "]") {
      index++
      return result
    }
    while (result.length < maxContainerEntries) {
      result.push(parseValue(depth))
      whitespace()
      if (encoded[index] === "]") {
        index++
        return result
      }
      if (encoded[index++] !== ",") invalid()
      whitespace()
    }
    invalid()
  }

  const parseObject = depth => {
    index++
    whitespace()
    const result = Object.create(null)
    const seen = new Set()
    if (encoded[index] === "}") {
      index++
      return result
    }
    while (seen.size < maxContainerEntries) {
      const key = parseString()
      if (seen.has(key)) invalid()
      seen.add(key)
      whitespace()
      if (encoded[index++] !== ":") invalid()
      result[key] = parseValue(depth)
      whitespace()
      if (encoded[index] === "}") {
        index++
        return result
      }
      if (encoded[index++] !== ",") invalid()
      whitespace()
    }
    invalid()
  }

  const result = parseValue(0)
  whitespace()
  if (index !== encoded.length) invalid()
  return result
}

const parseEip712Type = encoded => {
  if (typeof encoded !== "string" || encoded.length > 96) invalid()
  const match = encoded.match(/^([A-Za-z_][A-Za-z0-9_]{0,63}|address|bool|string|bytes(?:[1-9]|[12][0-9]|3[0-2])?|u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?)((?:\[(?:[1-9][0-9]{0,2})?\]){0,4})$/)
  if (!match) invalid()
  const dimensions = [...match[2].matchAll(/\[([0-9]*)\]/g)].map(item =>
    item[1] === "" ? null : Number(item[1])
  )
  if (dimensions.some(size => size !== null && size > maxContainerEntries)) invalid()
  return {base: match[1], dimensions}
}

const numericBits = base => {
  const match = base.match(/^(u?int)([0-9]*)$/)
  if (!match) return null
  return {signed: match[1] === "int", bits: match[2] === "" ? 256 : Number(match[2])}
}

const normalizeTypedInteger = (value, {signed, bits}) => {
  let parsed
  let normalized
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) invalid()
    parsed = BigInt(value)
    normalized = String(value)
  } else if (typeof value === "string" && quantityPattern.test(value)) {
    parsed = BigInt(value)
    normalized = value.toLowerCase()
  } else if (
    typeof value === "string" &&
    (signed ? decimalSignedPattern : decimalUnsignedPattern).test(value)
  ) {
    parsed = BigInt(value)
    normalized = value
  } else {
    invalid()
  }

  const minimum = signed ? -(1n << BigInt(bits - 1)) : 0n
  const maximum = signed ? (1n << BigInt(bits - 1)) - 1n : (1n << BigInt(bits)) - 1n
  if (parsed < minimum || parsed > maximum) invalid()
  return normalized
}

const normalizeTypedData = encoded => {
  const parsed = parseStrictJson(encoded)
  const top = exactRecord(parsed, ["types", "primaryType", "domain", "message"])
  const typesRecord = descriptorsForRecord(valueFrom(top, "types"), {maxKeys: maxTypedTypes})
  if (typesRecord.keys.length === 0) invalid()

  const definitions = new Map()
  for (const typeName of typesRecord.keys) {
    if (!identifierPattern.test(typeName) || dangerousKeys.has(typeName)) invalid()
    const fields = valuesForArray(valueFrom(typesRecord, typeName), {maxLength: maxTypedFields})
    const names = new Set()
    const normalizedFields = fields.map(field => {
      const record = exactRecord(field, ["name", "type"])
      const name = valueFrom(record, "name")
      const type = valueFrom(record, "type")
      if (
        typeof name !== "string" ||
        !identifierPattern.test(name) ||
        dangerousKeys.has(name) ||
        names.has(name)
      ) {
        invalid()
      }
      names.add(name)
      const parsedType = parseEip712Type(type)
      return {name, type, parsedType}
    })
    definitions.set(typeName, normalizedFields)
  }

  if (!definitions.has("EIP712Domain")) invalid()
  const primaryType = valueFrom(top, "primaryType")
  if (
    typeof primaryType !== "string" ||
    primaryType === "EIP712Domain" ||
    !definitions.has(primaryType)
  ) {
    invalid()
  }

  for (const fields of definitions.values()) {
    for (const field of fields) {
      const {base} = field.parsedType
      if (!numericBits(base) &&
          !["address", "bool", "string", "bytes"].includes(base) &&
          !/^bytes(?:[1-9]|[12][0-9]|3[0-2])$/.test(base) &&
          !definitions.has(base)) {
        invalid()
      }
    }
  }

  const allowedDomain = new Map([
    ["name", "string"],
    ["version", "string"],
    ["chainId", "uint256"],
    ["verifyingContract", "address"],
    ["salt", "bytes32"],
  ])
  for (const field of definitions.get("EIP712Domain")) {
    if (allowedDomain.get(field.name) !== field.type) invalid()
  }

  const normalizeValue = (value, parsedType, depth) => {
    if (depth > maxTypedDepth) invalid()
    if (parsedType.dimensions.length > 0) {
      const outer = parsedType.dimensions[parsedType.dimensions.length - 1]
      const values = valuesForArray(value, {maxLength: maxContainerEntries})
      if (outer !== null && values.length !== outer) invalid()
      return values.map(item =>
        normalizeValue(item, {...parsedType, dimensions: parsedType.dimensions.slice(0, -1)}, depth + 1)
      )
    }

    const numeric = numericBits(parsedType.base)
    if (numeric) return normalizeTypedInteger(value, numeric)
    if (parsedType.base === "address") return normalizeAddress(value)
    if (parsedType.base === "bool") {
      if (typeof value !== "boolean") invalid()
      return value
    }
    if (parsedType.base === "string") {
      if (typeof value !== "string" || byteLength(value) > maxTypedStringBytes) invalid()
      return value
    }
    if (parsedType.base === "bytes") return normalizeData(value, {bytes: 32_768})
    const fixedBytes = parsedType.base.match(/^bytes([0-9]+)$/)
    if (fixedBytes) return normalizeData(value, {exactBytes: Number(fixedBytes[1])})
    return normalizeStruct(value, parsedType.base, depth + 1)
  }

  const normalizeStruct = (value, typeName, depth) => {
    const fields = definitions.get(typeName)
    if (!fields) invalid()
    const record = exactRecord(value, fields.map(field => field.name))
    const normalized = Object.create(null)
    for (const field of fields) {
      normalized[field.name] = normalizeValue(valueFrom(record, field.name), field.parsedType, depth)
    }
    return sortedRecord(normalized)
  }

  const normalizedTypes = Object.create(null)
  for (const typeName of [...definitions.keys()].sort()) {
    normalizedTypes[typeName] = definitions.get(typeName).map(({name, type}) => ({name, type}))
  }

  const normalized = {
    domain: normalizeStruct(valueFrom(top, "domain"), "EIP712Domain", 0),
    message: normalizeStruct(valueFrom(top, "message"), primaryType, 0),
    primaryType,
    types: normalizedTypes,
  }
  const result = JSON.stringify(normalized)
  if (byteLength(result) > maxTypedDataBytes) invalid()
  return result
}

export const supportedEvmWalletMethod = method => typeof method === "string" && methods.has(method)
export const privilegedEvmWalletMethod = method => privilegedMethods.has(method)

export const normalizeEvmWalletPayload = payload => {
  const envelope = exactRecord(payload, ["method", "params"], ["method"], {maxKeys: 2})
  const method = valueFrom(envelope, "method")
  if (!supportedEvmWalletMethod(method)) invalid()
  const params = envelope.keys.includes("params") ? valueFrom(envelope, "params") : []

  if (noParamMethods.has(method)) {
    if (valuesForArray(params, {maxLength: 0}).length !== 0) invalid()
    return {method, params: []}
  }

  const values = valuesForArray(params, {maxLength: 2})
  if (method === "personal_sign") {
    if (values.length !== 2) invalid()
    return {
      method,
      params: [normalizeData(values[0], {bytes: maxTypedDataBytes}), normalizeAddress(values[1])],
    }
  }
  if (method === "eth_signTypedData_v4") {
    if (values.length !== 2) invalid()
    return {method, params: [normalizeAddress(values[0]), normalizeTypedData(values[1])]}
  }
  if (method === "eth_sendTransaction") {
    if (values.length !== 1) invalid()
    return {method, params: [normalizeTransaction(values[0])]}
  }
  invalid()
}

export const validEvmWalletPayload = payload => {
  try {
    normalizeEvmWalletPayload(payload)
    return true
  } catch (_error) {
    return false
  }
}

export const normalizeEvmWalletResult = (method, result) => {
  if (method === "eth_chainId") return normalizeEvmQuantity(result, 256)
  if (method === "eth_accounts" || method === "eth_requestAccounts") {
    const accounts = valuesForArray(result, {maxLength: maxAccounts}).map(normalizeAddress)
    if (
      new Set(accounts).size !== accounts.length ||
      (method === "eth_requestAccounts" && accounts.length === 0)
    ) {
      invalid()
    }
    return accounts
  }
  if (method === "personal_sign" || method === "eth_signTypedData_v4") {
    return normalizeData(result, {exactBytes: 65})
  }
  if (method === "eth_sendTransaction") return normalizeData(result, {exactBytes: 32})
  invalid()
}

export const normalizeEvmWalletErrorCode = value =>
  Number.isInteger(value) && value >= -32_768 && value <= 49_999 ? value : 4001

export const evmWalletErrorCode = error => {
  try {
    const descriptor = Object.getOwnPropertyDescriptor(error, "code")
    return descriptor && "value" in descriptor
      ? normalizeEvmWalletErrorCode(descriptor.value)
      : 4001
  } catch (_error) {
    return 4001
  }
}
