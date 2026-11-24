// How Shrink is doing on the App Store, from the developer's PC (reads only):
//
//   node scripts/asc-watch.mjs [days]     downloads and Pro sales per day (default the last 7 days),
//                                         then the newest ratings and reviews
//
// Apple's daily sales reports arrive the next day. They need the account's vendor number (App Store
// Connect > Payments and Financial Reports, top left), from SHRINK_VENDOR_NUMBER or "vendorNumber" in
// the private file (SHRINK_STORE_PRIVATE, default notes/store-private.json).
import { existsSync, readFileSync } from 'node:fs'
import { gunzipSync } from 'node:zlib'
import { api, file, findApp } from './asc-api.mjs'

const days = Number(process.argv[2] || 7)
const PRIVATE_FILE = process.env.SHRINK_STORE_PRIVATE || 'notes/store-private.json'
const vendor = process.env.SHRINK_VENDOR_NUMBER
  || (existsSync(PRIVATE_FILE) ? JSON.parse(readFileSync(PRIVATE_FILE, 'utf8')).vendorNumber : undefined)

const app = await findApp()

// Apple's product types: 1/1F/1T first downloads, 3/3F/3T downloads again, 7/7F/7T updates,
// IA1 one-time purchases (Pro Lifetime), IAY subscriptions (Pro Yearly, new and renewals).
const KIND = { 1: 'downloads', '1F': 'downloads', '1T': 'downloads', 3: 'again', '3F': 'again', '3T': 'again',
  7: 'updates', '7F': 'updates', '7T': 'updates', IA1: 'proLifetime', IAY: 'proYearly' }

if (!vendor) {
  console.log('Downloads: no vendor number yet (see the top of this file).')
} else {
  console.log('day         downloads  again  updates  Pro once  Pro yearly  proceeds')
  const total = { downloads: 0, again: 0, updates: 0, proLifetime: 0, proYearly: 0 }
  for (let back = days; back >= 1; back--) {
    const day = new Date(Date.now() - back * 86400000).toISOString().slice(0, 10)
    const gz = await file(`/v1/salesReports?filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY&filter[vendorNumber]=${vendor}&filter[reportDate]=${day}`)
      .catch(e => { if (e.status === 410 || /not available|no sales/i.test(e.message)) return null; throw e })
    if (!gz) { console.log(day, '  (no report: nothing sold or not out yet)'); continue }
    const [head, ...rows] = gunzipSync(gz).toString('utf8').trim().split('\n').map(l => l.split('\t'))
    const col = name => {
      const i = head.indexOf(name)
      // A renamed column would otherwise count as zero sales without a word.
      if (i < 0) throw new Error(`Apple's sales report has no "${name}" column any more`)
      return i
    }
    const count = { downloads: 0, again: 0, updates: 0, proLifetime: 0, proYearly: 0 }
    const proceeds = {}
    for (const r of rows) {
      // Only Shrink's rows (the account also sells the owner's other app): its Apple ID or its products.
      const ours = r[col('Apple Identifier')] === app.id || String(r[col('SKU')]).startsWith('com.useshrink.')
        || r[col('Parent Identifier')] === 'shrink-ios'
      if (!ours) continue
      const kind = KIND[r[col('Product Type Identifier')]]
      if (!kind) continue
      const units = Number(r[col('Units')]) || 0
      count[kind] += units
      total[kind] += units
      const money = (Number(r[col('Developer Proceeds')]) || 0) * units
      if (money) proceeds[r[col('Currency of Proceeds')]] = (proceeds[r[col('Currency of Proceeds')]] || 0) + money
    }
    const pay = Object.entries(proceeds).map(([c, v]) => `${v.toFixed(2)} ${c}`).join(', ') || '-'
    console.log(day, String(count.downloads).padStart(10), String(count.again).padStart(6), String(count.updates).padStart(8),
      String(count.proLifetime).padStart(9), String(count.proYearly).padStart(11), ' ', pay)
  }
  console.log('total      ', String(total.downloads).padStart(10), String(total.again).padStart(6), String(total.updates).padStart(8),
    String(total.proLifetime).padStart(9), String(total.proYearly).padStart(11))
}

const reviews = (await api('GET', `/v1/apps/${app.id}/customerReviews?sort=-createdDate&limit=20`)).data
console.log(`\nReviews: ${reviews.length ? reviews.length + ' newest' : 'none yet'}`)
for (const r of reviews) {
  const a = r.attributes
  console.log(`${a.createdDate.slice(0, 10)} ${'★'.repeat(a.rating)}${'☆'.repeat(5 - a.rating)} ${a.territory} | ${a.title ?? ''}${a.body ? ' | ' + a.body.replace(/\s+/g, ' ').slice(0, 300) : ''}`)
}
