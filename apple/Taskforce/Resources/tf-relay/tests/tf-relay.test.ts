import { expect, test } from 'claude-code/testing'

// Not shipped in the app bundle (project.yml copies only the three runtime files). Run: `claude plugin test` in this plugin's folder.

const TARGET = '5e5e5e5e-1111-4222-8333-444444444444'
const NONCE = '0123456789abcdef0123456789abcdef'

function startStubs(on, sent: Array<{ to: string, text: string }>, answer = { isDelivered: true }) {
  on('command.register', () => ({ value: undefined }))
  on('session.send', ($, e) => {
    sent.push({ to: e.to, text: e.text })
    return answer
  })
}

function parse(answer: { text: string }) {
  return JSON.parse(answer.text)
}

test('tfping answers the nonce back and nothing else', async ($, on) => {
  const sent = []
  startStubs(on, sent)
  const answer = parse(await $.command.run({ command: 'tfping', args: NONCE }))
  expect(answer).toEqual({ mod: 'tf-relay', version: '1', ok: true, nonce: NONCE })
  expect(sent.length).toBe(0)
})

test('tfping refuses a nonce that is not 16-64 lowercase hex', async ($, on) => {
  const sent = []
  startStubs(on, sent)
  for (const bad of ['', 'short', 'ZZZZZZZZZZZZZZZZZZZZ', NONCE.toUpperCase(), NONCE + '0'.repeat(40)]) {
    const answer = parse(await $.command.run({ command: 'tfping', args: bad }))
    expect(answer.ok).toBe(false)
    expect(answer.error).toBe('bad_nonce')
  }
})

test('tfsend passes the text through byte for byte, one send, and returns isDelivered', async ($, on) => {
  const sent = []
  startStubs(on, sent)
  const text = 'first line\n\n  indented  \nunicode 한글 😀\ttab'
  const answer = parse(await $.command.run({ command: 'tfsend', args: TARGET + '\n' + text }))
  expect(answer).toEqual({ mod: 'tf-relay', version: '1', ok: true, isDelivered: true, reason: null })
  expect(sent.length).toBe(1)
  expect(sent[0].to).toBe(TARGET)
  expect(sent[0].text).toBe(text)
})

test('tfsend returns isDelivered false with the reason as given', async ($, on) => {
  const sent = []
  startStubs(on, sent, { isDelivered: false, reason: 'no live session on this machine has id x' })
  const answer = parse(await $.command.run({ command: 'tfsend', args: TARGET + '\nhello' }))
  expect(answer.isDelivered).toBe(false)
  expect(answer.reason).toBe('no live session on this machine has id x')
})

test('tfsend refuses anything that is not a lowercase UUID, a newline and a text', async ($, on) => {
  const sent = []
  startStubs(on, sent)
  const bad = [
    'NOT-A-UUID\nhello',
    TARGET.toUpperCase() + '\nhello',
    TARGET + ' same line text',
    TARGET,
    TARGET + '\n',
    '\nhello',
    '',
    TARGET.slice(0, 35) + '\nhello',
  ]
  for (const args of bad) {
    const answer = parse(await $.command.run({ command: 'tfsend', args }))
    expect(answer.ok).toBe(false)
  }
  expect(sent.length).toBe(0)
})

test('tfsend takes 1 to 16000 characters of text', async ($, on) => {
  const sent = []
  startStubs(on, sent)
  const tooLong = parse(await $.command.run({ command: 'tfsend', args: TARGET + '\n' + 'x'.repeat(16001) }))
  expect(tooLong.error).toBe('bad_text')
  expect(sent.length).toBe(0)
  const longest = parse(await $.command.run({ command: 'tfsend', args: TARGET + '\n' + 'x'.repeat(16000) }))
  expect(longest.isDelivered).toBe(true)
  expect(sent.length).toBe(1)
})

test('a send that throws is reported as not delivered, not as a crash', async ($, on) => {
  // No session.send stub: the call rejects with "no implementation", which stands for any send that fails
  on('command.register', () => ({ value: undefined }))
  const answer = parse(await $.command.run({ command: 'tfsend', args: TARGET + '\nhello' }))
  expect(answer.isDelivered).toBe(false)
  expect(answer.reason).toBe('send failed')
})

test('every incoming message is consumed, whoever sends it', async ($, on) => {
  const sent = []
  startStubs(on, sent)
  for (const kind of ['peer', 'peer-send-message', 'task-notification', 'scheduled-trigger']) {
    const result = await $.session.receive({ origin: { kind }, text: 'reply from the target' })
    expect(result.consumed).toBeDefined()
  }
})

test('session.start registers exactly tfping and tfsend', async ($, on) => {
  const names = []
  on('session.start', () => ({ cwd: '/work' }))
  on('command.register', ($, e) => {
    names.push(e.name)
    return { value: undefined }
  })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  expect(names).toEqual(['tfping', 'tfsend'])
})
