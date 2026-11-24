// Shrink's "Report a problem" inbox, a Google Apps Script. The app posts each report here as JSON;
// this adds a row to the Google Sheet the script belongs to and emails the Google account that owns it
// (Reply goes to the person, when they gave an email). No server of Shrink's: Google runs this.
//
// Set up once, signed in to the support Google account:
//   1. Make a Google Sheet called "Shrink reports". Extensions > Apps Script. Replace Code.gs with this file.
//      (With several Google accounts in one browser that menu can fail. Then make the project at
//      script.google.com/u/<n>/home instead and add the sheet's ID as the Script Property SHEET_ID.)
//   2. Run setup() once from the editor and allow what it asks for (send email as you, edit the sheet).
//   3. Deploy > New deployment > Select type: Web app. Execute as: Me. Who has access: Anyone. Deploy.
//   4. Put the Web app URL (https://script.google.com/macros/s/…/exec) in the GitHub secret
//      SHRINK_REPORT_URL. Release builds read it from there, so the URL isn't in the public code.
// After changing this file: Deploy > Manage deployments > Edit > Version: New version. The URL stays the same.
// Opening the URL in a browser shows {"ok":true} when it's live.

const MAX_EMAILS_PER_HOUR = 30 // past this, reports still land in the sheet; only the emails pause
const HEADERS = ['Received', 'What happened', 'Reply to', 'App', 'iPhone', 'iOS', 'Job', 'Error']

function doPost(e) {
  let report
  try {
    report = JSON.parse(e.postData.contents)
  } catch (err) {
    return reply(false)
  }
  const text = (value, max) => String(value == null ? '' : value).slice(0, max).trim()
  const r = {
    message: text(report.message, 5000),
    replyTo: text(report.replyTo, 200),
    version: text(report.version, 40),
    device: text(report.device, 60),
    ios: text(report.ios, 20),
    job: text(report.job, 200),
    error: text(report.error, 1000),
  }
  if (report.app !== 'Shrink' || !r.message) return reply(false)

  const sheet = reportSheet()
  sheet.appendRow([new Date()].concat([r.message, r.replyTo, r.version, r.device, r.ios, r.job, r.error].map(asText)))

  if (allowEmail()) {
    const email = {
      to: Session.getEffectiveUser().getEmail(),
      name: 'Shrink reports',
      subject: 'Shrink report: ' + r.message.replace(/\s+/g, ' ').slice(0, 60),
      body: [
        r.message,
        '',
        'Reply to: ' + (r.replyTo || 'not given'),
        'App: Shrink ' + r.version,
        'iPhone: ' + r.device + ', iOS ' + r.ios,
        'Job: ' + (r.job || '-'),
        'Error: ' + (r.error || '-'),
      ].join('\n'),
    }
    if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(r.replyTo)) email.replyTo = r.replyTo
    MailApp.sendEmail(email)
  }
  return reply(true)
}

function doGet() {
  return reply(true)
}

// The privacy policy says reports are kept for up to 12 months. Run by a daily time-driven trigger
// (Triggers > Add trigger > deleteOldReports, Time-driven, Day timer): removes sheet rows and report
// emails older than that. Run it once from the editor first to allow Gmail access.
const KEEP_MONTHS = 12

function deleteOldReports() {
  const cutoff = new Date()
  cutoff.setMonth(cutoff.getMonth() - KEEP_MONTHS)

  // Rows are added in order, so the old ones are the first rows after the headers.
  const sheet = reportSheet()
  const last = sheet.getLastRow()
  let old = 0
  if (last > 1) {
    const received = sheet.getRange(2, 1, last - 1, 1).getValues()
    while (old < received.length && received[old][0] instanceof Date && received[old][0] < cutoff) old++
    if (old > 0) sheet.deleteRows(2, old)
  }

  // The report emails, with any replies in their threads.
  let threads = 0
  const query = 'subject:"Shrink report:" older_than:' + KEEP_MONTHS + 'm'
  // Trashed threads drop out of the search, so each pass gets the next 100 (capped, to never spin).
  for (let pass = 0, batch = GmailApp.search(query, 0, 100); batch.length && pass < 50; pass++, batch = GmailApp.search(query, 0, 100)) {
    GmailApp.moveThreadsToTrash(batch)
    threads += batch.length
  }
  Logger.log('Deleted ' + old + ' rows and ' + threads + ' email threads from before ' + cutoff.toISOString())
}

// Run once from the editor: checks the sheet, writes its headers and asks for the permissions.
function setup() {
  Logger.log('Reports go to ' + reportSheet().getParent().getUrl())
}

// The sheet in the Script Property SHEET_ID, or else the sheet this script is attached to.
function reportSheet() {
  const id = PropertiesService.getScriptProperties().getProperty('SHEET_ID')
  const book = id ? SpreadsheetApp.openById(id) : SpreadsheetApp.getActiveSpreadsheet()
  if (!book) throw new Error('No sheet: add its ID as the Script Property SHEET_ID')
  const sheet = book.getSheets()[0]
  if (sheet.getLastRow() === 0) sheet.appendRow(HEADERS)
  return sheet
}

// Every cell goes in as plain text: a leading ' stops Sheets turning "18.10" into 18.1 or running "=…"
// as a formula. Sheets hides the ' itself.
function asText(value) {
  return value ? "'" + value : value
}

function allowEmail() {
  const cache = CacheService.getScriptCache()
  const key = 'emails-' + Math.floor(Date.now() / 3600000)
  const sent = Number(cache.get(key) || 0)
  if (sent >= MAX_EMAILS_PER_HOUR) return false
  cache.put(key, String(sent + 1), 3700)
  return true
}

function reply(ok) {
  return ContentService.createTextOutput(JSON.stringify({ ok: ok })).setMimeType(ContentService.MimeType.JSON)
}
