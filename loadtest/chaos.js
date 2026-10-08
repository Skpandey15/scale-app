import http from 'k6/http'
import { check, sleep } from 'k6'

const BASE = __ENV.BASE || 'http://localhost:8088'
const DURATION = __ENV.DURATION || '360s'
const VUS = parseInt(__ENV.VUS || '80')
const json = { headers: { 'Content-Type': 'application/json' } }

export const options = {
  scenarios: {
    steady: { executor: 'constant-vus', vus: VUS, duration: DURATION },
  },
}

export function setup() {
  const run = Date.now()
  const users = []
  for (let i = 0; i < 5; i++) {
    const username = `ch${run}_${i}`
    const r = http.post(`${BASE}/api/auth/register`, JSON.stringify({ username, password: `pw-${run}-${i}-xxxxxxxx` }), json)
    if (r.status === 200) users.push({ token: r.json('token') })
  }
  for (const u of users) {
    for (let i = 0; i < 20; i++) {
      http.post(`${BASE}/api/posts`, JSON.stringify({ content: `chaos seed ${i}` }), {
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${u.token}` },
      })
    }
  }
  const first = http.get(`${BASE}/api/posts?size=50`).json()
  return { users, maxId: first.items.length ? first.items[0].id : 1 }
}

export default function (data) {
  const roll = Math.random()
  let res
  if (roll < 0.7) {
    res = http.get(`${BASE}/api/posts?size=20`)
  } else if (roll < 0.95) {
    res = http.get(`${BASE}/api/posts?size=20&before=${1 + Math.floor(Math.random() * data.maxId)}`)
  } else {
    const u = data.users[Math.floor(Math.random() * data.users.length)]
    res = http.post(`${BASE}/api/posts`, JSON.stringify({ content: 'chaos post' }), {
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${u.token}` },
    })
  }
  check(res, { ok: (r) => r.status >= 200 && r.status < 300 })
  sleep(0.2 + Math.random() * 0.3)
}
