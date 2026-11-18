#!/usr/bin/env node
// Checks the simulator's Photos library after the Clean up photos end-to-end test
// (ios/ShrinkUITests/PhotoCleanupE2ETests.swift). Reads e2e-photos-before.json and e2e-photos-after.json
// (written by ios/Shrink/E2EPhotos.swift) from the folder given. Fails unless exactly the picked things
// changed: the duplicate went (and the copy that stayed took over its album), the Live Photo became a
// still that kept its date, place, favorite and album, and nothing else in the library was touched.
//
//   node scripts/check-cleanup-e2e.mjs <folder>
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const folder = process.argv[2] || '.'
const before = JSON.parse(readFileSync(join(folder, 'e2e-photos-before.json'), 'utf8'))
const after = JSON.parse(readFileSync(join(folder, 'e2e-photos-after.json'), 'utf8'))

const results = []
const check = (what, ok, detail = '') => results.push({ what, ok: Boolean(ok), detail })
const DAY = 86400
const FIRST = 1740826800 // 1 March 2025, 11:00 UTC (E2EPhotos.firstDay)
const on = (list, day) => list.filter((p) => Math.abs(p.created - (FIRST + day * DAY)) < 1)
const byId = new Map(after.map((p) => [p.id, p]))
const kb = (bytes) => `${Math.round(bytes / 1000)} KB`

const [camera] = on(before, 0)
const [download] = on(before, 1)
const copies = on(before, 2)
const [live] = on(before, 3)
check('the hook added a camera photo', camera)
check('the hook added a picture saved from a chat', download)
check('the hook added the same picture twice', copies.length === 2, `${copies.length} found`)
check('the hook made a real Live Photo', live?.live === true, live ? `live=${live.live}, resources ${live.resources}` : 'none')
if (!camera || !download || copies.length !== 2 || !live) report()

const keeper = copies.find((p) => p.favorite)
const extra = copies.find((p) => p.albums.includes('Wedding'))
check('one copy is the favorite, the other is in "Wedding"', keeper && extra && keeper.id !== extra.id)

// Nothing that wasn't picked changed.
check('the camera photo is untouched', byId.has(camera.id))
check('the picture from a chat is untouched', byId.has(download.id))
const others = before.filter((p) => ![extra?.id, live.id].includes(p.id))
const missing = others.filter((p) => !byId.has(p.id))
check('every other photo is still there', missing.length === 0, missing.length ? `${missing.length} missing` : `${others.length} kept`)
check('one photo fewer in all (a duplicate went; a Live Photo became a still)', after.length === before.length - 1,
  `${before.length} before, ${after.length} after`)

// The duplicate.
if (keeper && extra) {
  check('the duplicate went to Recently Deleted', !byId.has(extra.id))
  const stayed = byId.get(keeper.id)
  check('the copy that stays is still there', stayed)
  if (stayed) {
    check('the copy that stays joined the album "Wedding"', stayed.albums.includes('Wedding'), JSON.stringify(stayed.albums))
    check('the copy that stays is still a favorite', stayed.favorite)
  }
}

// The Live Photo.
check('the Live Photo went to Recently Deleted', !byId.has(live.id))
const still = after.find((p) => !before.some((b) => b.id === p.id) && Math.abs(p.created - live.created) < 1)
check('a still photo with the same date is in the library', still, still ? new Date(still.created * 1000).toISOString() : 'none')
if (still) {
  check('the still is not a Live Photo', still.live === false, `resources ${still.resources}`)
  const sameSize = (still.pixelWidth === live.pixelWidth && still.pixelHeight === live.pixelHeight) ||
    (still.pixelWidth === live.pixelHeight && still.pixelHeight === live.pixelWidth)
  check('the still is the same size', sameSize, `${live.pixelWidth}x${live.pixelHeight} → ${still.pixelWidth}x${still.pixelHeight}`)
  check('the still is smaller (the moving part is gone)', still.bytes > 0 && still.bytes < live.bytes, `${kb(live.bytes)} → ${kb(still.bytes)}`)
  check('the still is a favorite', still.favorite === live.favorite)
  check('the still kept the album', JSON.stringify(still.albums) === JSON.stringify(live.albums),
    `${JSON.stringify(live.albums)} → ${JSON.stringify(still.albums)}`)
  const samePlace = live.latitude !== undefined && still.latitude !== undefined &&
    Math.abs(still.latitude - live.latitude) < 1e-4 && Math.abs(still.longitude - live.longitude) < 1e-4
  check('the still kept the place', samePlace, `${live.latitude},${live.longitude} → ${still.latitude},${still.longitude}`)
  check('the still kept the hidden state', still.hidden === live.hidden)
}

report()

function report () {
  let failed = 0
  for (const r of results) {
    if (!r.ok) failed++
    console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.what}${r.detail ? ` (${r.detail})` : ''}`)
  }
  console.log(`\n${results.length - failed} passed, ${failed} failed`)
  process.exit(failed ? 1 : 0)
}
