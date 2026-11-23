// The App Store Connect API for the scripts run from the developer's PC (asc-pro.mjs, later the listing).
// Key: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 like CI, or else the key file in APPLE_SECRETS_DIR
// (default ~/.secrets/apple). The key is never printed.
import { createHash, sign } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const BUNDLE_ID = 'com.useshrink.app'
const API = 'https://api.appstoreconnect.apple.com'
const SECRETS_DIR = process.env.APPLE_SECRETS_DIR || join(homedir(), '.secrets', 'apple')
const KEY_ID = process.env.ASC_KEY_ID || 'L6DZA2X5G7'
const ISSUER_ID = process.env.ASC_ISSUER_ID || 'ac13b2b6-5b4d-4aeb-95ee-cbba6eb6925f'
const keyFile = join(SECRETS_DIR, `AuthKey_${KEY_ID}.p8`)
const KEY_P8 = process.env.ASC_KEY_P8 || (existsSync(keyFile) ? readFileSync(keyFile, 'utf8') : '')
if (!KEY_P8) {
  console.error('No App Store Connect key: set ASC_KEY_P8 or put the .p8 file in APPLE_SECRETS_DIR.')
  process.exit(1)
}

const b64url = buf => Buffer.from(buf).toString('base64url')
function token() {
  const now = Math.floor(Date.now() / 1000)
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }))
  const body = b64url(JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }))
  const sig = sign('sha256', Buffer.from(`${head}.${body}`), { key: KEY_P8, dsaEncoding: 'ieee-p1363' })
  return `${head}.${body}.${b64url(sig)}`
}

export async function api(method, path, body) {
  const res = await fetch(path.startsWith('http') ? path : `${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (res.status === 204) return null
  const json = await res.json().catch(() => ({}))
  if (!res.ok) {
    // A 409 often says only "please check associated errors": they're in meta, keyed by what they're about.
    const why = (json.errors || []).map(e => {
      const more = Object.values(e.meta?.associatedErrors ?? {}).flat().map(a => [a.code, a.detail ?? a.title].filter(Boolean).join(': '))
      return [`${e.title}: ${e.detail}`, ...more].join(' | ')
    }).join('; ') || res.statusText
    const error = new Error(`${method} ${path} -> ${res.status} ${why}`)
    error.status = res.status
    throw error
  }
  return json
}

/** A GET that's allowed to find nothing: null on 404. */
export async function maybe(path) {
  try {
    return await api('GET', path)
  } catch (e) {
    if (e.status === 404) return null
    throw e
  }
}

/** Every page of a list. */
export async function all(path) {
  const items = []
  let url = path
  while (url) {
    const page = await api('GET', url)
    items.push(...page.data)
    url = page.links?.next
  }
  return items
}

/** The first item on any page that matches, without reading the pages after it. */
export async function find(path, match) {
  let url = path
  while (url) {
    const page = await api('GET', url)
    const hit = page.data.find(match)
    if (hit) return hit
    url = page.links?.next
  }
  return null
}

/** Shrink's app record. The API can't create one: App Store Connect > Apps > + > New App. */
export async function findApp() {
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)
  const app = apps.data.find(a => a.attributes.bundleId === BUNDLE_ID)
  if (!app) {
    console.error(`No app record for ${BUNDLE_ID} yet. Create it in App Store Connect > Apps > + > New App first.`)
    process.exit(1)
  }
  return app
}

/** Uploads a file to the parts App Store Connect asked for, and returns its MD5 for the "uploaded" PATCH. */
export async function upload(operations, bytes) {
  for (const part of operations) {
    const res = await fetch(part.url, {
      method: part.method,
      headers: Object.fromEntries(part.requestHeaders.map(h => [h.name, h.value])),
      body: bytes.subarray(part.offset, part.offset + part.length),
    })
    if (!res.ok) throw new Error(`Upload failed: ${res.status}`)
  }
  return createHash('md5').update(bytes).digest('hex')
}
