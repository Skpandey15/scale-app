import http from 'k6/http'
import { check, sleep } from 'k6'
import { Counter } from 'k6/metrics'

const BASE = __ENV.BASE || 'http://localhost:8088'
const rateLimited = new Counter('rate_limited_429')
const json = { headers: { 'Content-Type': 'application/json' } }

export const options = {
  stages: [
    { duration: '30s', target: 50 },
    { duration: '45s', target: 100 },
    { duration: '45s', target: 200 },
    { duration: '60s', target: 300 },
    { duration: '15s', target: 0 },
  ],
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '20s' }],
    http_req_duration: [{ threshold: 'p(95)<2500', abortOnFail: true, delayAbortEval: '30s' }],
  },
}

// Create a few users and seed posts so cursor paging has real depth.
export function setup() {
  const run = Date.now()
  const users = []
  for (let i = 0; i < 10; i++) {
    const username = `lt${run}_${i}`
    const password = `pw-${run}-${i}-xxxxxxxx`
    const r = http.post(`${BASE}/api/auth/register`, JSON.stringify({ username, password }), json)
    if (r.status === 200) users.push({ username, password, token: r.json('token') })
  }
  const auth = (u) => ({ headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${u.token}` } })
  for (const u of users) {
    for (let i = 0; i < 30; i++) {
      http.post(`${BASE}/api/posts`, JSON.stringify({ content: `seed post ${i} by ${u.username}` }), auth(u))
    }
  }
  const first = http.get(`${BASE}/api/posts?size=50`).json()
  const maxId = first.items.length ? first.items[0].id : 1
  return { users, maxId }
}

export default function (data) {
  const roll = Math.random()
  let res
  if (roll < 0.70) {
    res = http.get(`${BASE}/api/posts?size=20`, { tags: { name: 'feed_first' } })
  } else if (roll < 0.95) {
    const before = 1 + Math.floor(Math.random() * data.maxId)
    res = http.get(`${BASE}/api/posts?size=20&before=${before}`, { tags: { name: 'feed_deep' } })
  } else if (roll < 0.99) {
    const u = data.users[Math.floor(Math.random() * data.users.length)]
    res = http.post(`${BASE}/api/posts`, JSON.stringify({ content: 'load test post' }), {
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${u.token}` },
      tags: { name: 'create_post' },
    })
  } else {
    const u = data.users[Math.floor(Math.random() * data.users.length)]
    res = http.post(`${BASE}/api/auth/login`, JSON.stringify({ username: u.username, password: u.password }), {
      ...json, tags: { name: 'login' },
    })
  }
  if (res.status === 429) rateLimited.add(1)
  check(res, { 'status 2xx': (r) => r.status >= 200 && r.status < 300 })
  sleep(0.2 + Math.random() * 0.3)
}
