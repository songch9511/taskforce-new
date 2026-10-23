// Taskforce relay mod (contract ch.25.4.2). It does three things and nothing else:
//   /tfping <nonce>        health check: answers one JSON line that carries the nonce back
//   /tfsend <uuid>\n<text> one $.session.send to a lowercase session UUID, answers { isDelivered, reason }
//   session.receive        every incoming message is consumed, so the relay never takes a model turn
// No other hook, tool, network, file write or log. The text and the id are never stored or printed by this mod.
const NAME = 'tf-relay'
const VERSION = '1'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const NONCE = /^[0-9a-f]{16,64}$/
const MAX_TEXT = 16000
const MAX_REASON = 300

function answer(fields) {
  return { text: JSON.stringify({ mod: NAME, version: VERSION, ...fields }) }
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'tfping', description: 'Taskforce relay health check', argumentHint: '<nonce>' })
    await $.command.register({ name: 'tfsend', description: 'Taskforce relay: send a message to a session', argumentHint: '<session-uuid> <text>' })
    return next(e)
  })

  on('command.run', { command: 'tfping' }, async ($, e) => {
    const nonce = String(e.args || '').trim()
    if (!NONCE.test(nonce)) return answer({ ok: false, error: 'bad_nonce' })
    return answer({ ok: true, nonce })
  })

  on('command.run', { command: 'tfsend' }, async ($, e) => {
    const match = /^\s*([0-9a-f-]{36})\n([\s\S]*)$/.exec(String(e.args || ''))
    if (!match || !UUID.test(match[1])) return answer({ ok: false, error: 'bad_args' })
    const text = match[2]
    if (text.length < 1 || text.length > MAX_TEXT) return answer({ ok: false, error: 'bad_text' })
    try {
      const sent = await $.session.send({ to: { sessionId: match[1] }, text })
      const reason = sent.isDelivered ? null : String(sent.reason || '').slice(0, MAX_REASON)
      return answer({ ok: true, isDelivered: sent.isDelivered === true, reason })
    } catch (error) {
      return answer({ ok: true, isDelivered: false, reason: 'send failed' })
    }
  })

  // Consumed without a model turn: the target may answer the relay, and the relay must never spend anything on it.
  // A failing hook must not let a message through either, so the error handler consumes too.
  on('session.receive', async () => ({ consumed: 'taskforce relay takes no replies' })).catch(() => ({ consumed: 'taskforce relay takes no replies' }))
}
