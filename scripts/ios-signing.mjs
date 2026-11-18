// Signing for the cloud iOS build (.github/workflows/ios.yml), through the App Store Connect API.
//
//   node scripts/ios-signing.mjs setup           from the developer's PC: registers the app's and the share
//                                                 sheet's App IDs if they're missing, turns on App Groups for
//                                                 both, and makes an App Store profile for each with the team's
//                                                 existing Apple Distribution certificate. The certificate's key
//                                                 and the App Store Connect key go to GitHub as secrets.
//   node scripts/ios-signing.mjs create <dir>    in CI: that certificate + both profiles, ready for Xcode
//
// The app and the share sheet share settings through the App Group group.com.useshrink.app. The API can
// turn App Groups on for an App ID but can't create the group or attach it, so the first `setup` stops
// and prints the two-minute steps for developer.apple.com; run `setup` again after them. Every profile is
// checked for the group, so one without it never reaches a build (Xcode would fail at export instead).
//
// Shrink reuses the team's existing distribution certificate (its key is in APPLE_SECRETS_DIR, default
// ~/.secrets/apple, as ios-distribution-<certificate id>.key), because Apple allows only a few per team.
// Never revoke it after a build: a build Apple is still reviewing needs it (ITMS-90035). The certificate
// and profiles last a year; `create` warns a month ahead, and `setup` again makes fresh profiles.
//
// `setup` changes the Apple developer account (App IDs, profiles) and GitHub secrets: run it only with the
// owner's OK. It replaces its own profiles (by name) each run; App Store profiles aren't on any phone, so
// that never affects a build already uploaded.
//
// Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (the .p8 file's text): a Team key with Admin access.
// On the PC, setup falls back to the key file in APPLE_SECRETS_DIR.
import { execFileSync } from 'node:child_process'
import { randomBytes, sign } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'

const APP_GROUP = 'group.com.useshrink.app'
// key: the GitHub output prefix (app_profile_name, share_profile_uuid, …).
const TARGETS = [
  { key: 'app', bundleId: 'com.useshrink.app', name: 'Shrink', profile: 'Shrink App Store', file: 'App_Store.mobileprovision' },
  { key: 'share', bundleId: 'com.useshrink.app.share', name: 'Shrink Share', profile: 'Shrink Share App Store', file: 'Share_App_Store.mobileprovision' },
]
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

async function findProfile(name) {
  const profiles = await api('GET', `/profiles?filter[name]=${encodeURIComponent(name)}&filter[profileType]=IOS_APP_STORE&limit=20`)
  return profiles.data.find(p => p.attributes.name === name && p.attributes.profileState === 'ACTIVE')
}

/** The profile's entitlements are plain XML inside its signed envelope, so the group's name shows up as text. */
const hasGroup = profile => Buffer.from(profile.attributes.profileContent, 'base64').toString('latin1').includes(`<string>${APP_GROUP}</string>`)

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

async function bundleIdRecord(target) {
  const bundles = await api('GET', `/bundleIds?filter[identifier]=${target.bundleId}`)
  const found = bundles.data.find(b => b.attributes.identifier === target.bundleId)
  if (found) return found
  const made = await api('POST', '/bundleIds', {
    data: { type: 'bundleIds', attributes: { identifier: target.bundleId, name: target.name, platform: 'IOS' } },
  })
  console.log(`[signing] registered App ID ${target.bundleId}`)
  return made.data
}

async function turnOnAppGroups(bundle) {
  // This relationship takes no `limit`; an App ID has only a handful of capabilities anyway.
  const caps = await api('GET', `/bundleIds/${bundle.id}/bundleIdCapabilities`)
  if (caps.data.some(c => c.attributes.capabilityType === 'APP_GROUPS')) return
  await api('POST', '/bundleIdCapabilities', {
    data: {
      type: 'bundleIdCapabilities',
      attributes: { capabilityType: 'APP_GROUPS' },
      relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } },
    },
  })
  console.log(`[signing] turned on App Groups for ${bundle.attributes.identifier}`)
}

function setSecret(name, value) {
  execFileSync(GH, ['secret', 'set', name, '--repo', REPO], { input: value, stdio: ['pipe', 'pipe', 'pipe'] })
}

if (command === 'setup') {
  const cert = (await existingCertificate()) || (await newCertificate())
  const withoutGroup = []
  for (const target of TARGETS) {
    const bundle = await bundleIdRecord(target)
    await turnOnAppGroups(bundle)
    const old = await findProfile(target.profile)
    if (old) await api('DELETE', `/profiles/${old.id}`)
    const profile = (await api('POST', '/profiles', {
      data: {
        type: 'profiles',
        attributes: { name: target.profile, profileType: 'IOS_APP_STORE' },
        relationships: {
          bundleId: { data: { type: 'bundleIds', id: bundle.id } },
          certificates: { data: [{ type: 'certificates', id: cert.id }] },
        },
      },
    })).data
    if (!hasGroup(profile)) {
      await api('DELETE', `/profiles/${profile.id}`)
      withoutGroup.push(target.bundleId)
      continue
    }
    console.log(`[signing] profile "${target.profile}" (expires ${profile.attributes.expirationDate}) made with certificate ${cert.id}`)
  }
  if (withoutGroup.length) {
    console.error(`
The App Group isn't attached to ${withoutGroup.join(' and ')} yet; Apple's API can't do this part.
On developer.apple.com > Account > Certificates, Identifiers & Profiles > Identifiers:
  1. If "${APP_GROUP}" isn't there yet: + > App Groups > Continue, description "Shrink",
     identifier ${APP_GROUP} > Continue > Register.
  2. For each of ${withoutGroup.join(', ')}: open it, tick App Groups if it isn't ticked, click its
     Configure (or Edit) button, tick ${APP_GROUP}, Continue, then Save.
Then run \`node scripts/ios-signing.mjs setup\` again.`)
    process.exit(1)
  }
  setSecret('IOS_DIST_KEY', cert.key)
  setSecret('ASC_KEY_ID', ASC_KEY_ID)
  setSecret('ASC_ISSUER_ID', ASC_ISSUER_ID)
  setSecret('ASC_KEY_P8', ASC_KEY_P8)
  console.log(`[signing] secrets IOS_DIST_KEY, ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 set on ${REPO}`)
} else {
  const key = process.env.IOS_DIST_KEY
  if (!key) {
    console.error('::error::Missing IOS_DIST_KEY. Run `node scripts/ios-signing.mjs setup` once from the PC.')
    process.exit(1)
  }
  mkdirSync(dir, { recursive: true })
  let cert = null
  let out = ''
  for (const target of TARGETS) {
    const profile = await findProfile(target.profile)
    if (!profile) {
      console.error(`::error::No active "${target.profile}" profile. Run \`node scripts/ios-signing.mjs setup\` from the PC.`)
      process.exit(1)
    }
    if (!hasGroup(profile)) {
      console.error(`::error::"${target.profile}" doesn't include ${APP_GROUP}. Run \`node scripts/ios-signing.mjs setup\` from the PC.`)
      process.exit(1)
    }
    const certs = await api('GET', `/profiles/${profile.id}/certificates`)
    const profileCert = certs.data[0]
    if (!profileCert) throw new Error(`"${target.profile}" has no certificate`)
    if (cert && profileCert.id !== cert.id) throw new Error(`"${target.profile}" uses a different certificate; run setup again`)
    cert = profileCert
    const days = Math.floor((Date.parse(profile.attributes.expirationDate) - Date.now()) / 86400000)
    if (days < 30) console.log(`::warning::"${target.profile}" expires in ${days} days. Run \`node scripts/ios-signing.mjs setup\` again.`)
    writeFileSync(join(dir, target.file), Buffer.from(profile.attributes.profileContent, 'base64'))
    out += `${target.key}_profile_name=${target.profile}\n${target.key}_profile_uuid=${profile.attributes.uuid}\n${target.key}_profile_file=${target.file}\n`
  }
  const certDays = Math.floor((Date.parse(cert.attributes.expirationDate) - Date.now()) / 86400000)
  if (certDays < 30) console.log(`::warning::The signing certificate expires in ${certDays} days (${cert.attributes.expirationDate}).`)

  writeFileSync(join(dir, 'dist.key'), key)
  writeFileSync(join(dir, 'dist.cer'), Buffer.from(cert.attributes.certificateContent, 'base64'))
  execFileSync(OPENSSL, ['x509', '-inform', 'DER', '-in', join(dir, 'dist.cer'), '-out', join(dir, 'dist.pem')])
  const p12Password = randomBytes(16).toString('hex')
  execFileSync(OPENSSL, ['pkcs12', '-export', '-inkey', join(dir, 'dist.key'), '-in', join(dir, 'dist.pem'), '-out', join(dir, 'dist.p12'), '-passout', `pass:${p12Password}`])
  writeFileSync(join(dir, 'p12-password'), p12Password)

  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, out)
  console.log(`[signing] certificate ${cert.id} and profiles ${TARGETS.map(t => `"${t.profile}"`).join(', ')} ready`)
}
