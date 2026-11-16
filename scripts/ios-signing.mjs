// Signing for the cloud iOS build (.github/workflows/ios.yml), through the App Store Connect API.
//
//   node scripts/ios-signing.mjs setup           once, from the developer's PC: registers the
//                                                 com.useshrink.app App ID if it's missing and makes the
//                                                 "Shrink App Store" profile with the team's existing Apple
//                                                 Distribution certificate; the certificate's key goes to
//                                                 GitHub as IOS_DIST_KEY
//   node scripts/ios-signing.mjs create <dir>    in CI: that certificate + profile, ready for Xcode
//
// Shrink reuses the team's existing distribution certificate (its key is in APPLE_SECRETS_DIR, default
// ~/.secrets/apple, as ios-distribution-<certificate id>.key), because Apple allows only a few per team.
// Never revoke it after a build: a build Apple is still reviewing needs it (ITMS-90035). The certificate
// and profile last a year; `create` warns a month ahead.
//
// `setup` changes the Apple developer account (App ID, profile) and a GitHub secret: run it only with the owner's OK.
// When the Share Extension lands it needs its own App ID (com.useshrink.app.share) and profile here too.
//
// Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (the .p8 file's text): a Team key with Admin access.
// On the PC, setup falls back to the key file in APPLE_SECRETS_DIR.
import { execFileSync } from 'node:child_process'
import { randomBytes, sign } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'

const BUNDLE_ID = 'com.useshrink.app'
const APP_NAME = 'Shrink'
const PROFILE_NAME = 'Shrink App Store'
const REPO = process.env.SHRINK_REPO || 'ajejey/shrink'
const SECRETS_DIR = process.env.APPLE_SECRETS_DIR || join(homedir(), '.secrets', 'apple')
const API = 'https://api.appstoreconnect.apple.com/v1'
// macOS's own LibreSSL: its .p12 files use the older ciphers that `security import` can read.
const OPENSSL = process.platform === 'darwin' ? '/usr/bin/openssl' : 'openssl'
const GH = process.platform === 'win32' ? 'C:/Program Files/GitHub CLI/gh.exe' : 'gh'

const [command, dir] = process.argv.slice(2)
if (!(command === 'setup' || (command === 'create' && dir))) {
  console.error('usage: ios-signing.mjs setup | create <dir>')
  process.exit(2)
}
const ASC_KEY_ID = process.env.ASC_KEY_ID || (command === 'setup' ? 'L6DZA2X5G7' : '')
const ASC_ISSUER_ID = process.env.ASC_ISSUER_ID || (command === 'setup' ? 'ac13b2b6-5b4d-4aeb-95ee-cbba6eb6925f' : '')
const keyFile = `${SECRETS_DIR}/AuthKey_${ASC_KEY_ID}.p8`
const ASC_KEY_P8 = process.env.ASC_KEY_P8 || (command === 'setup' && existsSync(keyFile) ? readFileSync(keyFile, 'utf8') : '')
if (!ASC_KEY_ID || !ASC_ISSUER_ID || !ASC_KEY_P8) {
  console.error('::error::Missing ASC_KEY_ID, ASC_ISSUER_ID or ASC_KEY_P8. Add them under Settings > Secrets and variables > Actions.')
  process.exit(1)
}

const b64url = buf => Buffer.from(buf).toString('base64url')
function token() {
  const now = Math.floor(Date.now() / 1000)
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: ASC_KEY_ID, typ: 'JWT' }))
  const body = b64url(JSON.stringify({ iss: ASC_ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }))
  const sig = sign('sha256', Buffer.from(`${head}.${body}`), { key: ASC_KEY_P8, dsaEncoding: 'ieee-p1363' })
  return `${head}.${body}.${b64url(sig)}`
}

async function api(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (res.status === 204) return null
  const json = await res.json().catch(() => ({}))
  if (!res.ok) {
    const why = (json.errors || []).map(e => `${e.title}: ${e.detail}`).join('; ') || res.statusText
    throw new Error(`${method} ${path} -> ${res.status} ${why}`)
  }
  return json
}

async function findProfile() {
  const profiles = await api('GET', `/profiles?filter[name]=${encodeURIComponent(PROFILE_NAME)}&filter[profileType]=IOS_APP_STORE&limit=20`)
  return profiles.data.find(p => p.attributes.name === PROFILE_NAME && p.attributes.profileState === 'ACTIVE')
}

/** The team's distribution certificate whose private key we hold, valid for at least another 30 days. */
async function existingCertificate() {
  if (!existsSync(SECRETS_DIR)) return null
  const ids = readdirSync(SECRETS_DIR).map(f => f.match(/^ios-distribution-(\w+)\.key$/)?.[1]).filter(Boolean)
  for (const id of ids) {
    try {
      const cert = (await api('GET', `/certificates/${id}`)).data
      const days = (Date.parse(cert.attributes.expirationDate) - Date.now()) / 86400000
      if (days > 30) return { id, key: readFileSync(`${SECRETS_DIR}/ios-distribution-${id}.key`, 'utf8') }
    } catch (e) {
      console.log(`[signing] certificate ${id} is not usable: ${e.message}`)
    }
  }
  return null
}

async function newCertificate() {
  const work = mkdtempSync(join(tmpdir(), 'shrink-signing-'))
  try {
    const keyPath = join(work, 'dist.key')
    const csrPath = join(work, 'dist.csr')
    execFileSync(OPENSSL, ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', csrPath, '-subj', '/CN=Shrink'], { stdio: 'pipe' })
    const cert = await api('POST', '/certificates', {
      data: { type: 'certificates', attributes: { certificateType: 'DISTRIBUTION', csrContent: readFileSync(csrPath, 'utf8') } },
    })
    const key = readFileSync(keyPath, 'utf8')
    mkdirSync(SECRETS_DIR, { recursive: true })
    writeFileSync(join(SECRETS_DIR, `ios-distribution-${cert.data.id}.key`), key)
    return { id: cert.data.id, key }
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
}

async function bundleIdRecord() {
  const bundles = await api('GET', `/bundleIds?filter[identifier]=${BUNDLE_ID}`)
  const found = bundles.data.find(b => b.attributes.identifier === BUNDLE_ID)
  if (found) return found
  const made = await api('POST', '/bundleIds', {
    data: { type: 'bundleIds', attributes: { identifier: BUNDLE_ID, name: APP_NAME, platform: 'IOS' } },
  })
  console.log(`[signing] registered App ID ${BUNDLE_ID}`)
  return made.data
}

if (command === 'setup') {
  if (await findProfile()) {
    console.error(`"${PROFILE_NAME}" already exists. Delete it in the developer site first to make a new one.`)
    process.exit(1)
  }
  const cert = (await existingCertificate()) || (await newCertificate())
  const bundle = await bundleIdRecord()
  const profile = await api('POST', '/profiles', {
    data: {
      type: 'profiles',
      attributes: { name: PROFILE_NAME, profileType: 'IOS_APP_STORE' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: bundle.id } },
        certificates: { data: [{ type: 'certificates', id: cert.id }] },
      },
    },
  })
  execFileSync(GH, ['secret', 'set', 'IOS_DIST_KEY', '--repo', REPO], { input: cert.key, stdio: ['pipe', 'pipe', 'pipe'] })
  console.log(`[signing] profile "${PROFILE_NAME}" (expires ${profile.data.attributes.expirationDate}) made with certificate ${cert.id}; its key is GitHub secret IOS_DIST_KEY on ${REPO}`)
} else {
  const key = process.env.IOS_DIST_KEY
  if (!key) {
    console.error('::error::Missing IOS_DIST_KEY. Run `node scripts/ios-signing.mjs setup` once from the PC.')
    process.exit(1)
  }
  const profile = await findProfile()
  if (!profile) {
    console.error(`::error::No active "${PROFILE_NAME}" profile. Run \`node scripts/ios-signing.mjs setup\` from the PC.`)
    process.exit(1)
  }
  const certs = await api('GET', `/profiles/${profile.id}/certificates`)
  const cert = certs.data[0]
  if (!cert) throw new Error(`"${PROFILE_NAME}" has no certificate`)
  for (const [what, at] of [['certificate', cert.attributes.expirationDate], ['profile', profile.attributes.expirationDate]]) {
    const days = Math.floor((Date.parse(at) - Date.now()) / 86400000)
    if (days < 30) console.log(`::warning::The signing ${what} expires in ${days} days (${at}). Run \`node scripts/ios-signing.mjs setup\` again after deleting the old profile.`)
  }

  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'dist.key'), key)
  writeFileSync(join(dir, 'dist.cer'), Buffer.from(cert.attributes.certificateContent, 'base64'))
  execFileSync(OPENSSL, ['x509', '-inform', 'DER', '-in', join(dir, 'dist.cer'), '-out', join(dir, 'dist.pem')])
  const p12Password = randomBytes(16).toString('hex')
  execFileSync(OPENSSL, ['pkcs12', '-export', '-inkey', join(dir, 'dist.key'), '-in', join(dir, 'dist.pem'), '-out', join(dir, 'dist.p12'), '-passout', `pass:${p12Password}`])
  writeFileSync(join(dir, 'p12-password'), p12Password)
  writeFileSync(join(dir, 'App_Store.mobileprovision'), Buffer.from(profile.attributes.profileContent, 'base64'))

  const out = `profile_name=${PROFILE_NAME}\nprofile_uuid=${profile.attributes.uuid}\n`
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, out)
  console.log(`[signing] certificate ${cert.id} and profile "${PROFILE_NAME}" ready`)
}
