// What the App Store shows for Shrink, read by scripts/asc-store.mjs. All of it is public once the app
// is live. The App Review contact and the copyright line are not here: asc-store.mjs reads them from a
// private file (SHRINK_STORE_PRIVATE, default notes/store-private.json).

export const PRIMARY_CATEGORY = 'PHOTO_AND_VIDEO'
export const SECONDARY_CATEGORY = 'UTILITIES'

// On sale everywhere except the 27 EU countries, where the EU trader rule would show the seller's
// address and phone publicly, and mainland China (needs a licence). Same as the owner's other app.
export const EXCLUDED_TERRITORIES = ['AUT', 'BEL', 'BGR', 'HRV', 'CYP', 'CZE', 'DNK', 'EST', 'FIN', 'FRA', 'DEU', 'GRC', 'HUN', 'IRL',
  'ITA', 'LVA', 'LTU', 'LUX', 'MLT', 'NLD', 'POL', 'PRT', 'ROU', 'SVK', 'SVN', 'ESP', 'SWE', 'CHN']

const SUPPORT_URL = 'https://ajejey.github.io/shrink/'
const PRIVACY_URL = 'https://ajejey.github.io/shrink/privacy/'
const TERMS_URL = 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'

const DESCRIPTION = `Shrink makes a video or photo small enough to send, and frees up space on your iPhone. Everything happens on your iPhone: your videos and photos are never uploaded.

SEND A VIDEO OR PHOTO
• Compress for Discord, Gmail, Outlook, WhatsApp, iMessage, Slack, Telegram, Messenger, Canvas or a Google Form
• Or type the size limit a form or website gives you
• Trim it first and see straight away whether it fits and stays sharp
• Plays everywhere: MP4 for videos, JPG for photos
• Never comes out bigger than the original
• Takes the location out before sharing (you can turn that off)
• Works from the share sheet in Photos, WhatsApp, Files and other apps
• Free, as many as you like

FREE UP SPACE
• See which videos take the most room, and how much each could free
• Shrink the ones you pick. Dates, places, favorites and albums stay the same
• Every copy is checked before its original goes to Recently Deleted, where it stays for 30 days
• Clean up photos: duplicates, similar shots, blurry shots, screenshots, bursts, and Live Photos turned into stills
• The first 5 GB you free is free

MORE WITH A VIDEO
• Make a GIF
• Get the sound as an audio file
• Mute a video
• Save a frame as a photo

SHRINK PRO
• Free up space with no limit
• Send several videos and photos at once. For Gmail and Outlook they fit in one email together
• Sending options: use the whole limit, HEVC, picture size, 60 fps, keep all the details
• Pay once, or yearly. No weekly plan, and no free trial that charges you later

PRIVATE BY DESIGN
• No account, no ads, no tracking
• Report a problem sends only what you write and the details the form shows you

Terms of Use: ${TERMS_URL}
Privacy Policy: ${PRIVACY_URL}`

export const LOCALES = {
  'en-US': {
    name: 'Shrink: Compress Video',
    subtitle: 'Free up storage, send anywhere',
    // The job words searchers type, apart from the name and subtitle's (Apple indexes those already).
    keywords: 'discord,whatsapp,email,gmail,mb,size,reduce,smaller,mp4,heic,jpg,cleaner,duplicate,photos,gif,resize',
    promotionalText: 'Make any video or photo fit Discord, email, WhatsApp or any size limit, and free up iPhone storage. Everything stays on your iPhone. No ads, no weekly plans.',
    description: DESCRIPTION,
    supportUrl: SUPPORT_URL,
    marketingUrl: SUPPORT_URL,
    privacyPolicyUrl: PRIVACY_URL,
  },
}

// No objectionable content, no chat, no user content, no web browsing: 4+.
export const AGE_RATING = {
  advertising: false,
  alcoholTobaccoOrDrugUseOrReferences: 'NONE',
  contests: 'NONE',
  gambling: false,
  gamblingSimulated: 'NONE',
  gunsOrOtherWeapons: 'NONE',
  healthOrWellnessTopics: false,
  lootBox: false,
  medicalOrTreatmentInformation: 'NONE',
  messagingAndChat: false,
  parentalControls: false,
  profanityOrCrudeHumor: 'NONE',
  socialMedia: false,
  ageAssurance: false,
  sexualContentGraphicAndNudity: 'NONE',
  sexualContentOrNudity: 'NONE',
  horrorOrFearThemes: 'NONE',
  matureOrSuggestiveThemes: 'NONE',
  unrestrictedWebAccess: false,
  userGeneratedContent: false,
  violenceCartoonOrFantasy: 'NONE',
  violenceRealisticProlongedGraphicOrSadistic: 'NONE',
  violenceRealistic: 'NONE',
}

// App Review's notes (limit 4000). Answers up front the questions App Review asks new apps (purpose,
// how to use it, purchases, outside services, regions).
export const REVIEW_NOTES = `1. PURPOSE AND AUDIENCE
Shrink is for anyone who needs a video or photo to fit somewhere (Discord, an email, WhatsApp, a form with a size limit) or whose iPhone storage is full. Everything runs on the iPhone; there is no account and no server.

2. HOW TO USE IT
No sign-in. Home has three parts:
- Send a video or photo: tap a place (Discord, Gmail, WhatsApp or All places), pick a video in the Photos picker (no permission needed), trim it, tap Shrink it, then Send it. "Type your own size limit" is under All places. Shrink is also in the share sheet.
- Free up space: asks for Photos access, lists the videos that would free the most, and makes smaller copies of the ones picked. Each copy is checked (it plays, has its picture and sound, same length) before iOS's own prompt moves the original to Recently Deleted. Clean up photos sorts photos into piles (duplicates, similar, screenshots, blurry, bursts, Live Photos) for the person to review.
- More with a video: make a GIF, get the sound, mute, save a frame.
Testing tip: Free up space needs videos in the Photos library to have something to show; with none it says so.

3. IN-APP PURCHASES
Shrink Pro, as a one-time purchase (non-consumable) or a yearly auto-renewable subscription. It removes the 5 GB limit on Free up space and adds Send several at once and Sending options. Find it in Settings (top right of Home) > Get Pro; it also appears before a Free up space batch that would go past the free 5 GB, when tapping Send several at once on Home, and from Sending options on the trim screen. Restore purchase is in Settings and on the Pro screen. Sending one file at a time is free.

4. DATA AND OUTSIDE SERVICES
Videos and photos never leave the iPhone. The only thing sent anywhere is a report from Report a problem, and only when the person taps Send: what they wrote, an optional email, app version, iPhone model, iOS version, the job and the error (after a crash, iOS's crash summary if they choose to send it). It goes to a Google Apps Script in the developer's support Google account, which emails the developer. No analytics, no ads, no AI services.

5. REGIONS
Offered in every App Store country except the EU and mainland China; works the same everywhere.

6. REGULATION
Not a regulated industry; no third-party content.`

// Upload order: 1320 x 2868 PNGs (6.9" iPhone), from the "iOS store screenshots" workflow
// (.github/workflows/ios-store.yml), which puts each real screen under the caption in screenshots.json.
export const SCREENSHOTS_DIR = 'store/framed'
