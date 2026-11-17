// Shrink Pro's two App Store products, through the App Store Connect API, from the developer's PC.
// Needs the app record (the API can't make one: App Store Connect > Apps > + > New App) and the
// account's active Paid Apps Agreement. Every step can run again: it updates what's there.
//
//   node scripts/asc-pro.mjs inspect             what App Store Connect has now (reads only)
//   node scripts/asc-pro.mjs setup               both products: wording, availability and prices
//   node scripts/asc-pro.mjs screenshot <png>    the review screenshot (the Pro screen) on both
//
// "Pay once" is a non-consumable; "Yearly" is an auto-renewable subscription in the "Shrink Pro" group.
// The product IDs must match ios/Shrink/Store.swift. Both sell wherever the app does: the US price is
// the base and each other country gets Apple's matching price. A price is set here only when a product
// has none; change prices later in App Store Connect, which decides how existing subscribers are treated.
//
// `setup` and `screenshot` change App Store Connect: run them only with the owner's OK.
import { readFileSync } from 'node:fs'
import { basename } from 'node:path'
import { all, api, find, findApp, maybe, upload } from './asc-api.mjs'

const GROUP = 'Shrink Pro'
const DESCRIPTION = 'Free up space with no limit'
const REVIEW_NOTE = 'Shrink Pro removes the 5 GB limit on Free up space. To see it, tap the Settings button at the top of Home, then Get Pro. It also appears before a Free up space batch that would go past the free 5 GB. Sending videos and photos is free for everyone.'
const LIFETIME = { productId: 'com.useshrink.app.pro.lifetime', name: 'Pro Lifetime', display: 'Shrink Pro', price: '19.99' }
const YEARLY = { productId: 'com.useshrink.app.pro.yearly', name: 'Pro Yearly', display: 'Shrink Pro Yearly', price: '7.99', period: 'ONE_YEAR', level: 1 }

const rel = (type, id) => ({ data: { type, id } })

async function findLifetime(app) {
  const iaps = await all(`/v1/apps/${app.id}/inAppPurchasesV2?limit=200`)
  return iaps.find(i => i.attributes.productId === LIFETIME.productId) ?? null
}

async function findYearly(app) {
  const groups = await api('GET', `/v1/apps/${app.id}/subscriptionGroups?include=subscriptions&limit=50`)
  const group = groups.data.find(g => g.attributes.referenceName === GROUP) ?? null
  const sub = (groups.included ?? []).find(i => i.type === 'subscriptions' && i.attributes.productId === YEARLY.productId) ?? null
  return { group, sub }
}

const [command, arg] = process.argv.slice(2)
const app = await findApp()

if (command === 'inspect') {
  console.log('app', app.id, app.attributes.name)
  const lifetime = await findLifetime(app)
  if (lifetime) {
    console.log(LIFETIME.productId, lifetime.attributes.state, lifetime.id)
    const schedule = await maybe(`/v2/inAppPurchases/${lifetime.id}/iapPriceSchedule?include=manualPrices,baseTerritory`)
    console.log('  base territory', schedule?.data?.relationships?.baseTerritory?.data?.id ?? 'none', '| manual prices', (schedule?.included ?? []).filter(i => i.type === 'inAppPurchasePrices').length)
    const availability = await maybe(`/v2/inAppPurchases/${lifetime.id}/inAppPurchaseAvailability`)
    console.log('  availability', availability?.data ? `set, new territories ${availability.data.attributes.availableInNewTerritories}` : 'none')
    const shot = await maybe(`/v2/inAppPurchases/${lifetime.id}/appStoreReviewScreenshot`)
    console.log('  review screenshot', shot?.data?.attributes?.assetDeliveryState?.state ?? 'none')
  } else console.log(LIFETIME.productId, 'none')
  const { group, sub } = await findYearly(app)
  console.log('group', group?.id ?? 'none')
  if (sub) {
    console.log(YEARLY.productId, sub.attributes.state, sub.attributes.subscriptionPeriod, sub.id)
    const prices = await all(`/v1/subscriptions/${sub.id}/prices?limit=200`)
    console.log('  prices in', prices.length, 'countries')
    const availability = await maybe(`/v1/subscriptions/${sub.id}/subscriptionAvailability`)
    console.log('  availability', availability?.data ? `set, new territories ${availability.data.attributes.availableInNewTerritories}` : 'none')
    const shot = await maybe(`/v1/subscriptions/${sub.id}/appStoreReviewScreenshot`)
    console.log('  review screenshot', shot?.data?.attributes?.assetDeliveryState?.state ?? 'none')
  } else console.log(YEARLY.productId, 'none')
  process.exit(0)
}

if (command === 'setup') {
  const territories = (await all('/v1/territories?limit=200')).map(t => t.id)

  // Pay once: a non-consumable.
  let lifetime = await findLifetime(app)
  if (lifetime) {
    await api('PATCH', `/v2/inAppPurchases/${lifetime.id}`, { data: { type: 'inAppPurchases', id: lifetime.id, attributes: { name: LIFETIME.name, reviewNote: REVIEW_NOTE } } })
  } else {
    lifetime = (await api('POST', '/v2/inAppPurchases', { data: {
      type: 'inAppPurchases',
      attributes: { name: LIFETIME.name, productId: LIFETIME.productId, inAppPurchaseType: 'NON_CONSUMABLE', reviewNote: REVIEW_NOTE, familySharable: false },
      relationships: { app: rel('apps', app.id) },
    } })).data
    console.log('created', LIFETIME.productId, lifetime.id)
  }
  const iapLocales = await all(`/v2/inAppPurchases/${lifetime.id}/inAppPurchaseLocalizations?limit=50`)
  const iapLocale = iapLocales.find(l => l.attributes.locale === 'en-US')
  const iapWords = { name: LIFETIME.display, description: DESCRIPTION }
  if (iapLocale) await api('PATCH', `/v1/inAppPurchaseLocalizations/${iapLocale.id}`, { data: { type: 'inAppPurchaseLocalizations', id: iapLocale.id, attributes: iapWords } })
  else await api('POST', '/v1/inAppPurchaseLocalizations', { data: { type: 'inAppPurchaseLocalizations', attributes: { ...iapWords, locale: 'en-US' }, relationships: { inAppPurchaseV2: rel('inAppPurchases', lifetime.id) } } })

  if (!(await maybe(`/v2/inAppPurchases/${lifetime.id}/inAppPurchaseAvailability`))?.data) {
    await api('POST', '/v1/inAppPurchaseAvailabilities', { data: {
      type: 'inAppPurchaseAvailabilities',
      attributes: { availableInNewTerritories: true },
      relationships: { inAppPurchase: rel('inAppPurchases', lifetime.id), availableTerritories: { data: territories.map(id => ({ type: 'territories', id })) } },
    } })
    console.log('  available in', territories.length, 'countries')
  }

  const schedule = await maybe(`/v2/inAppPurchases/${lifetime.id}/iapPriceSchedule?include=manualPrices`)
  if ((schedule?.included ?? []).some(i => i.type === 'inAppPurchasePrices')) {
    console.log('  price already set, left alone')
  } else {
    const point = await find(`/v2/inAppPurchases/${lifetime.id}/pricePoints?filter[territory]=USA&limit=200`, p => p.attributes.customerPrice === LIFETIME.price)
    if (!point) throw new Error(`No US $${LIFETIME.price} price point for ${LIFETIME.productId}`)
    // '${price}' is App Store Connect's placeholder for a resource made in the same request.
    await api('POST', '/v1/inAppPurchasePriceSchedules', {
      data: {
        type: 'inAppPurchasePriceSchedules',
        relationships: {
          inAppPurchase: rel('inAppPurchases', lifetime.id),
          baseTerritory: rel('territories', 'USA'),
          manualPrices: { data: [{ type: 'inAppPurchasePrices', id: '${price}' }] },
        },
      },
      included: [{
        type: 'inAppPurchasePrices',
        id: '${price}',
        attributes: { startDate: null },
        relationships: { inAppPurchaseV2: rel('inAppPurchases', lifetime.id), inAppPurchasePricePoint: rel('inAppPurchasePricePoints', point.id) },
      }],
    })
    console.log('  price', LIFETIME.price, 'US, matching prices elsewhere')
  }

  // Yearly: an auto-renewable subscription in its own group.
  let { group, sub } = await findYearly(app)
  if (!group) {
    group = (await api('POST', '/v1/subscriptionGroups', { data: { type: 'subscriptionGroups', attributes: { referenceName: GROUP }, relationships: { app: rel('apps', app.id) } } })).data
    console.log('group created', group.id)
  }
  const groupLocales = await all(`/v1/subscriptionGroups/${group.id}/subscriptionGroupLocalizations?limit=50`)
  if (!groupLocales.some(l => l.attributes.locale === 'en-US')) {
    await api('POST', '/v1/subscriptionGroupLocalizations', { data: { type: 'subscriptionGroupLocalizations', attributes: { name: GROUP, locale: 'en-US' }, relationships: { subscriptionGroup: rel('subscriptionGroups', group.id) } } })
  }

  const subAttributes = { name: YEARLY.name, reviewNote: REVIEW_NOTE, familySharable: false }
  if (sub) {
    await api('PATCH', `/v1/subscriptions/${sub.id}`, { data: { type: 'subscriptions', id: sub.id, attributes: subAttributes } })
  } else {
    sub = (await api('POST', '/v1/subscriptions', { data: {
      type: 'subscriptions',
      attributes: { ...subAttributes, productId: YEARLY.productId, subscriptionPeriod: YEARLY.period, groupLevel: YEARLY.level },
      relationships: { group: rel('subscriptionGroups', group.id) },
    } })).data
    console.log('created', YEARLY.productId, sub.id)
  }
  const subLocales = await all(`/v1/subscriptions/${sub.id}/subscriptionLocalizations?limit=50`)
  const subLocale = subLocales.find(l => l.attributes.locale === 'en-US')
  const subWords = { name: YEARLY.display, description: DESCRIPTION }
  if (subLocale) await api('PATCH', `/v1/subscriptionLocalizations/${subLocale.id}`, { data: { type: 'subscriptionLocalizations', id: subLocale.id, attributes: subWords } })
  else await api('POST', '/v1/subscriptionLocalizations', { data: { type: 'subscriptionLocalizations', attributes: { ...subWords, locale: 'en-US' }, relationships: { subscription: rel('subscriptions', sub.id) } } })

  if (!(await maybe(`/v1/subscriptions/${sub.id}/subscriptionAvailability`))?.data) {
    await api('POST', '/v1/subscriptionAvailabilities', { data: {
      type: 'subscriptionAvailabilities',
      attributes: { availableInNewTerritories: true },
      relationships: { subscription: rel('subscriptions', sub.id), availableTerritories: { data: territories.map(id => ({ type: 'territories', id })) } },
    } })
    console.log('  available in', territories.length, 'countries')
  }

  // A subscription takes one price per country: the US price point plus Apple's equal ones elsewhere.
  if ((await api('GET', `/v1/subscriptions/${sub.id}/prices?limit=1`)).data.length) {
    console.log('  price already set, left alone')
  } else {
    const point = await find(`/v1/subscriptions/${sub.id}/pricePoints?filter[territory]=USA&limit=200`, p => p.attributes.customerPrice === YEARLY.price)
    if (!point) throw new Error(`No US $${YEARLY.price} price point for ${YEARLY.productId}`)
    const equal = await all(`/v1/subscriptionPricePoints/${point.id}/equalizations?include=territory&limit=200`)
    const points = [{ id: point.id, territory: 'USA' }, ...equal.map(p => ({ id: p.id, territory: p.relationships?.territory?.data?.id })).filter(p => p.territory && p.territory !== 'USA')]
    const failed = []
    for (const p of points) {
      try {
        await api('POST', '/v1/subscriptionPrices', { data: {
          type: 'subscriptionPrices',
          attributes: { preserveCurrentPrice: false },
          relationships: { subscription: rel('subscriptions', sub.id), subscriptionPricePoint: rel('subscriptionPricePoints', p.id), territory: rel('territories', p.territory) },
        } })
      } catch (e) {
        failed.push(`${p.territory}: ${e.message}`)
      }
    }
    console.log('  price', YEARLY.price, `US, matching prices in ${points.length - failed.length - 1} more countries`)
    if (failed.length) console.log(`  ${failed.length} countries failed:\n    ${failed.join('\n    ')}`)
  }
  process.exit(0)
}

if (command === 'screenshot') {
  if (!arg) throw new Error('Give the PNG to upload (the Pro screen, from CI screenshots)')
  const bytes = readFileSync(arg)
  const file = { fileName: basename(arg), fileSize: bytes.length }

  const lifetime = await findLifetime(app)
  if (!lifetime) throw new Error('Run setup first')
  const oldIap = await maybe(`/v2/inAppPurchases/${lifetime.id}/appStoreReviewScreenshot`)
  if (oldIap?.data) await api('DELETE', `/v1/inAppPurchaseAppStoreReviewScreenshots/${oldIap.data.id}`)
  const iapShot = (await api('POST', '/v1/inAppPurchaseAppStoreReviewScreenshots', { data: { type: 'inAppPurchaseAppStoreReviewScreenshots', attributes: file, relationships: { inAppPurchaseV2: rel('inAppPurchases', lifetime.id) } } })).data
  const iapSum = await upload(iapShot.attributes.uploadOperations, bytes)
  await api('PATCH', `/v1/inAppPurchaseAppStoreReviewScreenshots/${iapShot.id}`, { data: { type: 'inAppPurchaseAppStoreReviewScreenshots', id: iapShot.id, attributes: { uploaded: true, sourceFileChecksum: iapSum } } })
  console.log('screenshot', LIFETIME.productId)

  const { sub } = await findYearly(app)
  if (!sub) throw new Error('Run setup first')
  const oldSub = await maybe(`/v1/subscriptions/${sub.id}/appStoreReviewScreenshot`)
  if (oldSub?.data) await api('DELETE', `/v1/subscriptionAppStoreReviewScreenshots/${oldSub.data.id}`)
  const subShot = (await api('POST', '/v1/subscriptionAppStoreReviewScreenshots', { data: { type: 'subscriptionAppStoreReviewScreenshots', attributes: file, relationships: { subscription: rel('subscriptions', sub.id) } } })).data
  const subSum = await upload(subShot.attributes.uploadOperations, bytes)
  await api('PATCH', `/v1/subscriptionAppStoreReviewScreenshots/${subShot.id}`, { data: { type: 'subscriptionAppStoreReviewScreenshots', id: subShot.id, attributes: { uploaded: true, sourceFileChecksum: subSum } } })
  console.log('screenshot', YEARLY.productId)
  process.exit(0)
}

console.error('usage: asc-pro.mjs inspect | setup | screenshot <png>')
process.exit(2)
