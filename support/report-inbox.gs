// Shrink's "Report a problem" inbox, a Google Apps Script. The app posts each report here as JSON;
// this adds a row to the Google Sheet the script belongs to and emails the Google account that owns it
// (Reply goes to the person, when they gave an email). No server of Shrink's: Google runs this.
//
// Set up once, signed in to the support Google account:
//   1. Make a Google Sheet called "Shrink reports". Extensions > Apps Script. Replace Code.gs with this file.
//   2. Deploy > New deployment > Select type: Web app. Execute as: Me. Who has access: Anyone. Deploy,
//      then allow what it asks for (send email as you, edit this sheet).
//   3. Put the Web app URL (https://script.google.com/macros/s/…/exec) in the GitHub secret
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

  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0]
  if (sheet.getLastRow() === 0) sheet.appendRow(HEADERS)
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

// A cell starting with = + - or @ would run as a formula; a leading ' keeps it as plain text.
function asText(value) {
  return /^[=+\-@]/.test(value) ? "'" + value : value
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
