import { useCallback, useEffect, useRef, useState } from 'react'

const PHRASES = [
  'Anyone awake?',
  'Quick sync in five',
  'Deploy window is open',
  'Who has the logs?',
  'Coffee is ready',
  'Heads up: rollout starting',
]
const REPLIES = ['Got it', 'On it', 'Seen', 'Roger that', 'Received', 'Sounds good']

// Same name gives the same colour in every browser. The golden angle spreads
// consecutive pod numbers far apart on the colour wheel.
function colorOf(name) {
  const n = /-(\d+)$/.exec(name)
  const seed = n ? Number(n[1]) : [...name].reduce((a, c) => a * 31 + c.charCodeAt(0), 7)
  const hue = Math.round((seed * 137.508 + 25) % 360)
  return `hsl(${hue} 78% 62%)`
}

const ordinal = (name) => (/-(\d+)$/.exec(name) || [, '?'])[1]
const clock = (iso) => new Date(iso).toLocaleTimeString([], { hour12: false })
const pick = (list, key) => list[[...key].reduce((a, c) => a + c.charCodeAt(0), 0) % list.length]

function Avatar({ name, size = 34 }) {
  return (
    <span className="avatar" style={{ background: colorOf(name), width: size, height: size }}>
      {ordinal(name)}
    </span>
  )
}

function Typing({ name }) {
  const c = colorOf(name)
  return (
    <div className="reply typing" style={{ '--c': c }}>
      <Avatar name={name} size={26} />
      <span className="dots">
        <i /><i /><i />
      </span>
      <span className="meta">{name} is typing</span>
    </div>
  )
}

function Thread({ ev, acks, now }) {
  const replied = new Set(acks.map((a) => a.member))
  const waiting = ev.expected.filter((m) => !replied.has(m))
  const late = now > new Date(ev.deadline).getTime()
  let state = 'pending'
  if (waiting.length === 0) {
    const last = Math.max(...acks.map((a) => new Date(a.acked_at).getTime()))
    state = last <= new Date(ev.deadline).getTime() ? 'complete' : 'late'
  } else if (late) state = 'timeout'
  const label = { pending: 'waiting', complete: 'all replied', late: 'replied late', timeout: 'timed out' }[state]

  return (
    <section className="thread">
      <div className="bubble sender" style={{ '--c': colorOf(ev.origin) }}>
        <Avatar name={ev.origin} />
        <div className="body">
          <div className="head">
            <b style={{ color: colorOf(ev.origin) }}>{ev.origin}</b>
            <span className="meta">started a broadcast · {clock(ev.created_at)}</span>
            <span className={`badge ${state}`}>
              {label} {acks.length}/{ev.expected.length}
            </span>
          </div>
          <p>{ev.message}</p>
        </div>
      </div>
      <div className="replies">
        {[...acks]
          .sort((a, b) => a.acked_at.localeCompare(b.acked_at))
          .map((a) => {
            const secs = (new Date(a.acked_at) - new Date(ev.created_at)) / 1000
            return (
              <div className="reply" key={a.member} style={{ '--c': colorOf(a.member) }}>
                <Avatar name={a.member} size={26} />
                <div className="body">
                  <div className="head">
                    <b style={{ color: colorOf(a.member) }}>{a.member}</b>
                    <span className="meta">
                      {clock(a.acked_at)} · +{secs.toFixed(1)}s · pod {a.ip}
                    </span>
                  </div>
                  <p>{pick(REPLIES, a.member + ev.event_id)}</p>
                </div>
              </div>
            )
          })}
        {waiting.map((m) => (
          <Typing key={m} name={m} />
        ))}
      </div>
    </section>
  )
}

export default function App() {
  const [events, setEvents] = useState([])
  const [acks, setAcks] = useState({}) // event_id -> [ack]
  const [members, setMembers] = useState([])
  const [servedBy, setServedBy] = useState('')
  const [online, setOnline] = useState(false)
  const [text, setText] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [now, setNow] = useState(Date.now())
  const end = useRef(null)

  const addEvent = useCallback((ev) => {
    setEvents((cur) => (cur.some((e) => e.event_id === ev.event_id) ? cur : [...cur, ev]))
  }, [])
  const addAck = useCallback((a) => {
    setAcks((cur) => {
      const list = cur[a.event_id] || []
      if (list.some((x) => x.member === a.member)) return cur
      return { ...cur, [a.event_id]: [...list, a] }
    })
  }, [])

  // Live feed over a websocket; reconnects with a growing pause.
  useEffect(() => {
    let ws
    let stop = false
    let retry = 500
    let timer
    const open = () => {
      const proto = location.protocol === 'https:' ? 'wss' : 'ws'
      ws = new WebSocket(`${proto}://${location.host}/ws`)
      ws.onopen = () => {
        setOnline(true)
        retry = 500
      }
      ws.onmessage = (m) => {
        const msg = JSON.parse(m.data)
        if (msg.type === 'hello') setServedBy(msg.served_by.pod_name)
        if (msg.type === 'event') addEvent(msg)
        if (msg.type === 'ack') addAck(msg)
      }
      ws.onclose = () => {
        setOnline(false)
        if (!stop) {
          timer = setTimeout(open, retry)
          retry = Math.min(retry * 2, 8000)
        }
      }
    }
    open()
    return () => {
      stop = true
      clearTimeout(timer)
      ws && ws.close()
    }
  }, [addEvent, addAck])

  useEffect(() => {
    let live = true
    const load = () =>
      fetch('/members')
        .then((r) => (r.ok ? r.json() : { members: [] }))
        .then((d) => live && setMembers(d.members.map((m) => m.name).sort()))
        .catch(() => {})
    load()
    const id = setInterval(load, 3000)
    return () => {
      live = false
      clearInterval(id)
    }
  }, [])

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    end.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
  }, [events.length, acks])

  const start = async () => {
    setBusy(true)
    setError('')
    const message = text.trim() || pick(PHRASES, String(Date.now()))
    try {
      const r = await fetch('/broadcast', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Idempotency-Key': crypto.randomUUID() },
        body: JSON.stringify({ message }),
      })
      const body = await r.json()
      if (!r.ok) {
        setError(body.error === 'no_peers' ? 'No other pods are online to answer.' : `Request failed (${body.error || r.status})`)
      } else {
        addEvent({
          event_id: body.event_id,
          origin: body.origin.name,
          message: body.message,
          created_at: body.created_at,
          deadline: new Date(new Date(body.created_at).getTime() + 10000).toISOString(),
          expected: body.expected_recipients,
        })
        setText('')
      }
    } catch {
      setError('Could not reach the app.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="app">
      <header>
        <div className="title">
          <span className={`dot ${online ? 'on' : ''}`} title={online ? 'live' : 'reconnecting'} />
          <h1>messenger</h1>
          <span className="meta">{servedBy ? `connected to ${servedBy}` : 'connecting'}</span>
        </div>
        <div className="members">
          {members.map((m) => (
            <span key={m} className="chip" style={{ '--c': colorOf(m) }}>
              <i /> {m}
            </span>
          ))}
        </div>
      </header>

      <main>
        {events.length === 0 && (
          <div className="empty">
            <p>No broadcasts yet.</p>
            <p className="meta">Press the button. One pod sends, the others answer after a short random pause.</p>
          </div>
        )}
        {events.map((ev) => (
          <Thread key={ev.event_id} ev={ev} acks={acks[ev.event_id] || []} now={now} />
        ))}
        <div ref={end} />
      </main>

      <footer>
        {error && <div className="error">{error}</div>}
        <form
          onSubmit={(e) => {
            e.preventDefault()
            start()
          }}
        >
          <input
            value={text}
            maxLength={512}
            onChange={(e) => setText(e.target.value)}
            placeholder="Message (optional)"
          />
          <button type="submit" disabled={busy || !online}>
            Start broadcast
          </button>
        </form>
      </footer>
    </div>
  )
}
