#!/usr/bin/env node
// Checks the simulator's Photos library after the Free up space end-to-end test
// (ios/ShrinkUITests/FreeUpSpaceE2ETests.swift). Reads the app's e2e-before.json and e2e-after.json
// (written by ios/Shrink/E2EHooks.swift) from the folder given, and fails unless every original was
// replaced by a smaller copy that kept what makes it the person's own video.
//
//   node scripts/check-freeup-e2e.mjs <folder>
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const folder = process.argv[2] || '.'
const before = JSON.parse(readFileSync(join(folder, 'e2e-before.json'), 'utf8'))
const after = JSON.parse(readFileSync(join(folder, 'e2e-after.json'), 'utf8'))

const results = []
const check = (video, what, ok, detail = '') => results.push({ video, what, ok: Boolean(ok), detail })
const mb = (bytes) => `${(bytes / 1e6).toFixed(1)} MB`
const shape = (v) => `${v.uprightWidth}x${v.uprightHeight}`
const isPortrait = (v) => v.uprightHeight > v.uprightWidth

check('library', 'had videos to start with', before.length >= 3, `${before.length} before`)
check('library', 'same number of videos afterwards (each original replaced by one copy)',
  after.length === before.length, `${before.length} before, ${after.length} after`)

const afterIds = new Set(after.map((v) => v.id))
for (const original of before) {
  const name = `${shape(original)} ${original.codec ?? ''} ${mb(original.bytes)}`.trim()
  check(name, 'original left the library (iOS delete prompt, to Recently Deleted)', !afterIds.has(original.id))

  const copy = after.find((v) => !before.some((b) => b.id === v.id) && Math.abs(v.created - original.created) < 1)
  check(name, 'has a copy with the same date', copy, copy ? new Date(copy.created * 1000).toISOString() : 'none')
  if (!copy) continue

  check(name, 'copy is much smaller', copy.bytes > 0 && copy.bytes < original.bytes * 0.7,
    `${mb(original.bytes)} → ${mb(copy.bytes)}`)
  check(name, 'copy is no bigger than 1080p', Math.max(copy.uprightWidth, copy.uprightHeight) <= 1920, shape(copy))
  check(name, 'copy is upright the same way', isPortrait(copy) === isPortrait(original),
    `${shape(original)} → ${shape(copy)}`)
  check(name, 'same length', Math.abs(copy.duration - original.duration) <= 0.5,
    `${original.duration.toFixed(2)} s → ${copy.duration.toFixed(2)} s`)
  check(name, 'sound kept', copy.hasAudio === original.hasAudio, `${original.hasAudio} → ${copy.hasAudio}`)
  if (original.hdr) check(name, 'HDR kept', copy.hdr === true, `${original.codec} → ${copy.codec}`)
  if (original.latitude !== undefined) {
    const same = copy.latitude !== undefined &&
      Math.abs(copy.latitude - original.latitude) < 1e-4 && Math.abs(copy.longitude - original.longitude) < 1e-4
    check(name, 'place kept', same, `${original.latitude},${original.longitude} → ${copy.latitude},${copy.longitude}`)
  }
  check(name, 'favorite kept', copy.favorite === original.favorite, `${original.favorite} → ${copy.favorite}`)
  check(name, 'hidden state kept', copy.hidden === original.hidden)
  check(name, 'albums kept', JSON.stringify(copy.albums) === JSON.stringify(original.albums),
    `${JSON.stringify(original.albums)} → ${JSON.stringify(copy.albums)}`)
}

check('library', 'the test covered a favorite in an album', before.some((v) => v.favorite && v.albums.length > 0))
check('library', 'the test covered a video with a place', before.some((v) => v.latitude !== undefined))

let failed = 0
for (const r of results) {
  if (!r.ok) failed++
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.video}: ${r.what}${r.detail ? ` (${r.detail})` : ''}`)
}
console.log(`\n${results.length - failed} passed, ${failed} failed`)
if (!before.some((v) => v.hdr)) console.log('Note: no HDR video in the test library, so HDR wasn\'t checked.')
process.exit(failed ? 1 : 0)
