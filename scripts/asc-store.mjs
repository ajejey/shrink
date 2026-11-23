// The App Store listing through the App Store Connect API, from the developer's PC.
//
//   node scripts/asc-store.mjs inspect        what App Store Connect has now (reads only)
//   node scripts/asc-store.mjs listing        name, subtitle, description, keywords, URLs, categories,
//                                             copyright, age rating, availability and a free price
//   node scripts/asc-store.mjs screenshots    the 6.9" iPhone set from store/framed (the "iOS store
//                                             screenshots" workflow's artifact)
//   node scripts/asc-store.mjs review         App Review contact and notes
//   node scripts/asc-store.mjs submit         attach the newest valid build and send the version for review
//                                             (a version with no in-app purchases waiting to go along with it:
//                                             the API can't put an app's first purchases in a submission, so the
//                                             first version went in from the website, each one's "Add for Review")
//
// Text comes from store/listing-data.mjs. The App Review contact and copyright line come from a private
// JSON file (SHRINK_STORE_PRIVATE, default notes/store-private.json):
//   { "copyright": "...", "firstName": "...", "lastName": "...", "email": "...", "phone": "+..." }
// listing, screenshots, review and submit change App Store Connect: run them only with the owner's OK.
// Every step can run again; it updates what's there.
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { all, api, findApp, maybe, upload } from './asc-api.mjs'

const data = await import('../store/listing-data.mjs')
const PRIVATE_FILE = process.env.SHRINK_STORE_PRIVATE || 'notes/store-private.json'
const privateData = () => {
  if (!existsSync(PRIVATE_FILE)) throw new Error(`No ${PRIVATE_FILE} (App Review contact and copyright).`)
  return JSON.parse(readFileSync(PRIVATE_FILE, 'utf8'))
}

const EDITABLE = 'PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED,INVALID_BINARY'

async function appAndVersion() {
  const app = await findApp()
  const versions = await api('GET', `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&filter[appStoreState]=${EDITABLE}`)
  const version = versions.data[0]
  if (!version) throw new Error('No version waiting for submission')
  const infos = (await api('GET', `/v1/apps/${app.id}/appInfos`)).data
  const info = infos.find(i => (i.attributes.appStoreState || i.attributes.state) !== 'READY_FOR_SALE') ?? infos[0]
  return { app, version, info }
}

const [command] = process.argv.slice(2)

if (command === 'inspect') {
  const app = await findApp()
  console.log('app', app.id, app.attributes.name, '| locale', app.attributes.primaryLocale, '| content rights', app.attributes.contentRightsDeclaration)
  const versions = await api('GET', `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS`)
  for (const v of versions.data) console.log('version', v.id, v.attributes.versionString, v.attributes.appStoreState, '| copyright', v.attributes.copyright)
  const version = versions.data[0]
  const vlocs = await api('GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)
  for (const l of vlocs.data) {
    console.log('version loc', l.attributes.locale, '| desc', (l.attributes.description || '').length, 'chars | keywords', (l.attributes.keywords || '').length, '| support', l.attributes.supportUrl)
    const sets = await api('GET', `/v1/appStoreVersionLocalizations/${l.id}/appScreenshotSets`)
    for (const s of sets.data) {
      const shots = await api('GET', `/v1/appScreenshotSets/${s.id}/appScreenshots`)
      console.log('  screenshots', s.attributes.screenshotDisplayType, shots.data.length)
    }
  }
  for (const i of (await api('GET', `/v1/apps/${app.id}/appInfos`)).data) {
    console.log('appInfo', i.id, i.attributes.appStoreState || i.attributes.state, '| age', i.attributes.appStoreAgeRating)
    for (const l of (await api('GET', `/v1/appInfos/${i.id}/appInfoLocalizations`)).data) {
      console.log('  info loc', l.attributes.locale, '|', l.attributes.name, '|', l.attributes.subtitle, '|', l.attributes.privacyPolicyUrl)
    }
    const primary = await maybe(`/v1/appInfos/${i.id}/primaryCategory`)
    console.log('  primary category', primary?.data?.id ?? 'none')
  }
  const review = await maybe(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)
  console.log('review detail', review?.data ? `contact ${review.data.attributes.contactEmail ? 'set' : 'missing'}, notes ${(review.data.attributes.notes || '').length} chars` : 'none')
  const builds = await api('GET', `/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=5`)
  for (const b of builds.data) console.log('build', b.attributes.version, b.attributes.processingState, '| uploaded', b.attributes.uploadedDate)
  const attached = await maybe(`/v1/appStoreVersions/${version.id}/build`)
  console.log('attached build', attached?.data?.attributes?.version ?? 'none')
  const availability = await maybe(`/v1/apps/${app.id}/appAvailabilityV2`)
  console.log('availability', availability?.data ? 'set' : 'not set')
  const schedule = await maybe(`/v1/apps/${app.id}/appPriceSchedule`)
  const prices = schedule?.data ? await maybe(`/v1/appPriceSchedules/${schedule.data.id}/manualPrices`) : null
  console.log('price', prices?.data?.length ? 'set' : 'not set')
}

if (command === 'listing') {
  const { app, version, info } = await appAndVersion()
  const { copyright } = privateData()

  await api('PATCH', `/v1/apps/${app.id}`, { data: { type: 'apps', id: app.id, attributes: { contentRightsDeclaration: 'DOES_NOT_USE_THIRD_PARTY_CONTENT' } } })
  console.log('content rights: no third-party content')

  await api('PATCH', `/v1/appInfos/${info.id}`, { data: { type: 'appInfos', id: info.id, relationships: {
    primaryCategory: { data: { type: 'appCategories', id: data.PRIMARY_CATEGORY } },
    secondaryCategory: { data: { type: 'appCategories', id: data.SECONDARY_CATEGORY } },
  } } })
  console.log('categories', data.PRIMARY_CATEGORY, '/', data.SECONDARY_CATEGORY)

  await api('PATCH', `/v1/appStoreVersions/${version.id}`, { data: { type: 'appStoreVersions', id: version.id, attributes: { copyright } } })
  console.log('copyright set')

  const infoLocs = (await api('GET', `/v1/appInfos/${info.id}/appInfoLocalizations`)).data
  for (const [locale, l] of Object.entries(data.LOCALES)) {
    const infoAttrs = { name: l.name, subtitle: l.subtitle, privacyPolicyUrl: l.privacyPolicyUrl }
    const existingInfo = infoLocs.find(x => x.attributes.locale === locale)
    if (existingInfo) await api('PATCH', `/v1/appInfoLocalizations/${existingInfo.id}`, { data: { type: 'appInfoLocalizations', id: existingInfo.id, attributes: infoAttrs } })
    else await api('POST', '/v1/appInfoLocalizations', { data: { type: 'appInfoLocalizations', attributes: { locale, ...infoAttrs }, relationships: { appInfo: { data: { type: 'appInfos', id: info.id } } } } })
    const versionAttrs = { description: l.description, keywords: l.keywords, promotionalText: l.promotionalText, supportUrl: l.supportUrl, marketingUrl: l.marketingUrl }
    const existingVersion = (await api('GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).data.find(x => x.attributes.locale === locale)
    if (existingVersion) await api('PATCH', `/v1/appStoreVersionLocalizations/${existingVersion.id}`, { data: { type: 'appStoreVersionLocalizations', id: existingVersion.id, attributes: versionAttrs } })
    else await api('POST', '/v1/appStoreVersionLocalizations', { data: { type: 'appStoreVersionLocalizations', attributes: { locale, ...versionAttrs }, relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } } } })
    console.log('listing', locale, '|', l.name, '|', l.subtitle)
  }

  const age = (await api('GET', `/v1/appInfos/${info.id}/ageRatingDeclaration`)).data
  await api('PATCH', `/v1/ageRatingDeclarations/${age.id}`, { data: { type: 'ageRatingDeclarations', id: age.id, attributes: data.AGE_RATING } })
  console.log('age rating answers set')

  if (!(await maybe(`/v1/apps/${app.id}/appAvailabilityV2`))) {
    // Apple wants every country listed, each on or off.
    const territories = (await all('/v1/territories?limit=200')).map(t => t.id)
    await api('POST', '/v2/appAvailabilities', {
      data: { type: 'appAvailabilities', attributes: { availableInNewTerritories: false }, relationships: {
        app: { data: { type: 'apps', id: app.id } },
        territoryAvailabilities: { data: territories.map((t, i) => ({ type: 'territoryAvailabilities', id: `\${t${i}}` })) },
      } },
      included: territories.map((t, i) => ({ type: 'territoryAvailabilities', id: `\${t${i}}`, attributes: { available: !data.EXCLUDED_TERRITORIES.includes(t) }, relationships: { territory: { data: { type: 'territories', id: t } } } })),
    })
    console.log('available everywhere except', data.EXCLUDED_TERRITORIES.join(', '), '(new countries: off)')
  } else console.log('availability already set; change it in App Store Connect if needed')

  // App Store Connect makes an empty price schedule with the app; it's "set" once it has a price.
  const schedule = await maybe(`/v1/apps/${app.id}/appPriceSchedule`)
  const prices = schedule?.data ? await maybe(`/v1/appPriceSchedules/${schedule.data.id}/manualPrices`) : null
  if (!prices?.data?.length) {
    const points = await all(`/v1/apps/${app.id}/appPricePoints?filter[territory]=USA&limit=200`)
    const free = points.find(p => Number(p.attributes.customerPrice) === 0)
    if (!free) throw new Error('No $0 price point found')
    await api('POST', '/v1/appPriceSchedules', {
      data: { type: 'appPriceSchedules', relationships: {
        app: { data: { type: 'apps', id: app.id } },
        baseTerritory: { data: { type: 'territories', id: 'USA' } },
        manualPrices: { data: [{ type: 'appPrices', id: '${price0}' }] },
      } },
      included: [{ type: 'appPrices', id: '${price0}', attributes: { startDate: null }, relationships: { appPricePoint: { data: { type: 'appPricePoints', id: free.id } } } }],
    })
    console.log('price: free (Pro is sold in the app)')
  } else console.log('price already set')
}

if (command === 'screenshots') {
  const dir = data.SCREENSHOTS_DIR
  const order = JSON.parse(readFileSync('store/screenshots.json', 'utf8')).map(s => s.file)
  const present = new Set(existsSync(dir) ? readdirSync(dir) : [])
  const missing = order.filter(f => !present.has(f))
  if (missing.length) throw new Error(`Missing in ${dir}: ${missing.join(', ')}`)
  const { version } = await appAndVersion()
  // English only: other languages show these until they have their own.
  const loc = (await api('GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).data.find(l => l.attributes.locale === 'en-US')
  // The 6.9" slot (1320 x 2868) is APP_IPHONE_67 in the API.
  let set = (await api('GET', `/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`)).data.find(s => s.attributes.screenshotDisplayType === 'APP_IPHONE_67')
  if (!set) set = (await api('POST', '/v1/appScreenshotSets', { data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: 'APP_IPHONE_67' }, relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc.id } } } } })).data
  // Start from an empty set, so a rerun replaces rather than adds.
  for (const old of (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data) await api('DELETE', `/v1/appScreenshots/${old.id}`)
  for (const name of order) {
    const bytes = readFileSync(join(dir, name))
    const shot = (await api('POST', '/v1/appScreenshots', { data: { type: 'appScreenshots', attributes: { fileName: name, fileSize: bytes.length }, relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } } } })).data
    await upload(shot.attributes.uploadOperations, bytes)
    await api('PATCH', `/v1/appScreenshots/${shot.id}`, { data: { type: 'appScreenshots', id: shot.id, attributes: { uploaded: true, sourceFileChecksum: createHash('md5').update(bytes).digest('hex') } } })
    console.log('uploaded', name)
  }
  // Apple checks each one (size, format) after the upload.
  for (let i = 0; i < 30; i++) {
    const shots = (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data
    const states = shots.map(s => s.attributes.assetDeliveryState?.state)
    if (states.every(s => s === 'COMPLETE' || s === 'FAILED')) {
      for (const s of shots) console.log(s.attributes.fileName, s.attributes.assetDeliveryState.state, (s.attributes.assetDeliveryState.errors || []).map(e => e.description).join('; '))
      break
    }
    await new Promise(r => setTimeout(r, 4000))
  }
}

if (command === 'review') {
  const contact = privateData()
  for (const key of ['firstName', 'lastName', 'email', 'phone']) {
    if (!contact[key]) throw new Error(`${PRIVATE_FILE} needs "${key}"`)
  }
  const { version } = await appAndVersion()
  const attributes = {
    contactFirstName: contact.firstName, contactLastName: contact.lastName, contactEmail: contact.email, contactPhone: contact.phone,
    demoAccountRequired: false, notes: data.REVIEW_NOTES,
  }
  const existing = await maybe(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)
  if (existing?.data) await api('PATCH', `/v1/appStoreReviewDetails/${existing.data.id}`, { data: { type: 'appStoreReviewDetails', id: existing.data.id, attributes } })
  else await api('POST', '/v1/appStoreReviewDetails', { data: { type: 'appStoreReviewDetails', attributes, relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } } } })
  console.log('review contact and notes set (no demo account: Shrink has no sign-in)')
}

if (command === 'submit') {
  const { app, version } = await appAndVersion()
  const build = (await api('GET', `/v1/builds?filter[app]=${app.id}&filter[processingState]=VALID&sort=-uploadedDate&limit=1`)).data[0]
  if (!build) throw new Error('No valid build')
  await api('PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: 'builds', id: build.id } })
  console.log('build attached', build.attributes.version)
  const open = (await api('GET', `/v1/reviewSubmissions?filter[app]=${app.id}&filter[state]=READY_FOR_REVIEW`)).data[0]
  const submission = open ?? (await api('POST', '/v1/reviewSubmissions', { data: { type: 'reviewSubmissions', attributes: { platform: 'IOS' }, relationships: { app: { data: { type: 'apps', id: app.id } } } } })).data
  const items = await api('GET', `/v1/reviewSubmissions/${submission.id}/items`)
  if (!items.data.length) await api('POST', '/v1/reviewSubmissionItems', { data: { type: 'reviewSubmissionItems', relationships: { reviewSubmission: { data: { type: 'reviewSubmissions', id: submission.id } }, appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } } } })
  const sent = await api('PATCH', `/v1/reviewSubmissions/${submission.id}`, { data: { type: 'reviewSubmissions', id: submission.id, attributes: { submitted: true } } })
  console.log('submitted for review:', sent.data.attributes.state)
}

if (!['inspect', 'listing', 'screenshots', 'review', 'submit'].includes(command)) {
  console.error('usage: node scripts/asc-store.mjs inspect|listing|screenshots|review|submit')
  process.exit(2)
}
