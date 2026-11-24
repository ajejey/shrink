// Custom product pages: one App Store page per job ("Compress a video for Discord"), each with its own
// screenshots and promotional text, shown in search for the keywords given to it. Same app, same
// download button and reviews; only what the page shows changes.
//
//   node scripts/asc-pages.mjs inspect    what App Store Connect has now (reads only)
//   node scripts/asc-pages.mjs publish    make or update every page in store/pages.json: promotional
//                                         text, keywords, and screenshots from store/pages/<id>/
//                                         (the "iOS store screenshots" workflow's artifact)
//   node scripts/asc-pages.mjs add        add every page waiting for review to the app's open review
//                                         submission (made if there's none), without sending it, so
//                                         `asc-store.mjs submit` sends them with the next app version
//   node scripts/asc-pages.mjs submit     the same, then send it (pages on their own)
//
// Keywords must be in the app's latest approved keyword field (Apple refuses others). A page shows in
// search only once Apple approves it and it's visible. publish and submit change App Store Connect:
// run them only with the owner's OK. Every step can run again; it updates what's there.
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { all, api, findApp, upload } from './asc-api.mjs'

const SPEC = JSON.parse(readFileSync('store/pages.json', 'utf8'))
const FRAMED = 'store/pages'
const LOCALE = 'en-US'
const DISPLAY = 'APP_IPHONE_67' // the 6.9" slot, 1320 x 2868
const EDITABLE = ['PREPARE_FOR_SUBMISSION', 'REJECTED']

const [command] = process.argv.slice(2)

async function pages(app) {
  return all(`/v1/apps/${app.id}/appCustomProductPages?limit=50`)
}

async function versions(page) {
  return (await api('GET', `/v1/appCustomProductPages/${page.id}/appCustomProductPageVersions`)).data
}

async function localization(version) {
  const locs = (await api('GET', `/v1/appCustomProductPageVersions/${version.id}/appCustomProductPageLocalizations`)).data
  return locs.find(l => l.attributes.locale === LOCALE)
}

if (command === 'inspect') {
  const app = await findApp()
  const found = await pages(app)
  if (!found.length) console.log('no custom product pages')
  for (const page of found) {
    console.log(`page "${page.attributes.name}" | visible ${page.attributes.visible} | ${page.attributes.url}`)
    for (const v of await versions(page)) {
      console.log('  version', v.attributes.version, v.attributes.state)
      const loc = await localization(v)
      if (!loc) continue
      const words = (await api('GET', `/v1/appCustomProductPageLocalizations/${loc.id}/searchKeywords?limit=50`)).data.map(k => k.id)
      const sets = (await api('GET', `/v1/appCustomProductPageLocalizations/${loc.id}/appScreenshotSets`)).data
      let shots = 0
      for (const s of sets) shots += (await api('GET', `/v1/appScreenshotSets/${s.id}/appScreenshots`)).data.length
      console.log(`  ${LOCALE} | keywords ${words.join(', ') || 'none'} | screenshots ${shots} | promo ${(loc.attributes.promotionalText || '').length} chars`)
    }
  }
}

if (command === 'publish') {
  const app = await findApp()
  // Apple's list of words a page may use: the approved version's keyword field.
  const allowed = new Set((await api('GET', `/v1/apps/${app.id}/searchKeywords?filter[platform]=IOS&filter[locale]=${LOCALE}&limit=50`)).data.map(k => k.id))
  for (const spec of SPEC.pages) {
    const bad = spec.keywords.filter(k => !allowed.has(k))
    if (bad.length) throw new Error(`${spec.id}: not in the approved keyword field: ${bad.join(', ')}`)
    const dir = join(FRAMED, spec.id)
    const missing = spec.screenshots.map(s => s.file).filter(f => !existsSync(join(dir, f)))
    if (missing.length) throw new Error(`Missing in ${dir}: ${missing.join(', ')}`)
  }

  const existing = await pages(app)
  for (const spec of SPEC.pages) {
    let page = existing.find(p => p.attributes.name === spec.name)
    if (!page) {
      page = (await api('POST', '/v1/appCustomProductPages', {
        data: { type: 'appCustomProductPages', attributes: { name: spec.name }, relationships: {
          app: { data: { type: 'apps', id: app.id } },
          appCustomProductPageVersions: { data: [{ type: 'appCustomProductPageVersions', id: '${version}' }] },
        } },
        included: [
          { type: 'appCustomProductPageVersions', id: '${version}', relationships: {
            appCustomProductPageLocalizations: { data: [{ type: 'appCustomProductPageLocalizations', id: '${loc}' }] },
          } },
          { type: 'appCustomProductPageLocalizations', id: '${loc}', attributes: { locale: LOCALE, promotionalText: spec.promotionalText } },
        ],
      })).data
      console.log(`made "${spec.name}"`)
    }
    let version = (await versions(page)).find(v => EDITABLE.includes(v.attributes.state))
    if (!version) {
      version = (await api('POST', '/v1/appCustomProductPageVersions', { data: { type: 'appCustomProductPageVersions',
        relationships: { appCustomProductPage: { data: { type: 'appCustomProductPages', id: page.id } } } } })).data
    }
    let loc = await localization(version)
    if (!loc) {
      loc = (await api('POST', '/v1/appCustomProductPageLocalizations', { data: { type: 'appCustomProductPageLocalizations',
        attributes: { locale: LOCALE, promotionalText: spec.promotionalText },
        relationships: { appCustomProductPageVersion: { data: { type: 'appCustomProductPageVersions', id: version.id } } } } })).data
    } else {
      await api('PATCH', `/v1/appCustomProductPageLocalizations/${loc.id}`, { data: { type: 'appCustomProductPageLocalizations', id: loc.id,
        attributes: { promotionalText: spec.promotionalText } } })
    }

    // Keywords: exactly the ones in pages.json.
    const had = (await api('GET', `/v1/appCustomProductPageLocalizations/${loc.id}/searchKeywords?limit=50`)).data.map(k => k.id)
    const drop = had.filter(k => !spec.keywords.includes(k))
    const add = spec.keywords.filter(k => !had.includes(k))
    const ref = ids => ({ data: ids.map(id => ({ type: 'appKeywords', id })) })
    if (drop.length) await api('DELETE', `/v1/appCustomProductPageLocalizations/${loc.id}/relationships/searchKeywords`, ref(drop))
    if (add.length) await api('POST', `/v1/appCustomProductPageLocalizations/${loc.id}/relationships/searchKeywords`, ref(add))

    // Screenshots: start from an empty set, so a rerun replaces rather than adds.
    let set = (await api('GET', `/v1/appCustomProductPageLocalizations/${loc.id}/appScreenshotSets`)).data.find(s => s.attributes.screenshotDisplayType === DISPLAY)
    if (!set) set = (await api('POST', '/v1/appScreenshotSets', { data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: DISPLAY },
      relationships: { appCustomProductPageLocalization: { data: { type: 'appCustomProductPageLocalizations', id: loc.id } } } } })).data
    for (const old of (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data) await api('DELETE', `/v1/appScreenshots/${old.id}`)
    for (const { file } of spec.screenshots) {
      const bytes = readFileSync(join(FRAMED, spec.id, file))
      const shot = (await api('POST', '/v1/appScreenshots', { data: { type: 'appScreenshots', attributes: { fileName: file, fileSize: bytes.length },
        relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } } } })).data
      await upload(shot.attributes.uploadOperations, bytes)
      await api('PATCH', `/v1/appScreenshots/${shot.id}`, { data: { type: 'appScreenshots', id: shot.id,
        attributes: { uploaded: true, sourceFileChecksum: createHash('md5').update(bytes).digest('hex') } } })
    }
    // Apple checks each one (size, format) after the upload.
    let states = []
    for (let i = 0; i < 30; i++) {
      states = (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data.map(s => s.attributes.assetDeliveryState?.state)
      if (states.every(s => s === 'COMPLETE' || s === 'FAILED')) break
      await new Promise(r => setTimeout(r, 4000))
    }
    console.log(`"${spec.name}" | keywords ${spec.keywords.join(', ')} | screenshots ${states.join(' ')} | ${page.attributes.url}`)
  }
}

if (command === 'add' || command === 'submit') {
  const app = await findApp()
  const waiting = []
  for (const page of await pages(app)) {
    const v = (await versions(page)).find(x => EDITABLE.includes(x.attributes.state))
    if (v) waiting.push({ page, version: v })
  }
  if (!waiting.length) throw new Error('No custom product page waiting for review')
  const open = (await api('GET', `/v1/reviewSubmissions?filter[app]=${app.id}&filter[state]=READY_FOR_REVIEW`)).data[0]
  const submission = open ?? (await api('POST', '/v1/reviewSubmissions', { data: { type: 'reviewSubmissions', attributes: { platform: 'IOS' },
    relationships: { app: { data: { type: 'apps', id: app.id } } } } })).data
  const items = (await api('GET', `/v1/reviewSubmissions/${submission.id}/items?include=appCustomProductPageVersion`)).data
  const inIt = new Set(items.map(i => i.relationships?.appCustomProductPageVersion?.data?.id).filter(Boolean))
  for (const { page, version } of waiting) {
    if (!inIt.has(version.id)) {
      await api('POST', '/v1/reviewSubmissionItems', { data: { type: 'reviewSubmissionItems', relationships: {
        reviewSubmission: { data: { type: 'reviewSubmissions', id: submission.id } },
        appCustomProductPageVersion: { data: { type: 'appCustomProductPageVersions', id: version.id } },
      } } })
    }
    console.log('in the submission:', page.attributes.name)
  }
  if (command === 'submit') {
    const sent = await api('PATCH', `/v1/reviewSubmissions/${submission.id}`, { data: { type: 'reviewSubmissions', id: submission.id, attributes: { submitted: true } } })
    console.log('submitted for review:', sent.data.attributes.state)
  } else console.log('not sent yet: `node scripts/asc-store.mjs submit` adds the app version and sends them together')
}

if (!['inspect', 'publish', 'add', 'submit'].includes(command)) {
  console.error('usage: node scripts/asc-pages.mjs inspect|publish|add|submit')
  process.exit(2)
}
