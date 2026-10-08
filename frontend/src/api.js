const tokenKey = 'token'
export const getToken = () => localStorage.getItem(tokenKey)
export const setToken = (t) => (t ? localStorage.setItem(tokenKey, t) : localStorage.removeItem(tokenKey))

async function request(path, opts = {}) {
  const headers = { 'Content-Type': 'application/json', ...opts.headers }
  const t = getToken()
  if (t) headers.Authorization = `Bearer ${t}`
  const res = await fetch(path, { ...opts, headers })
  if (res.status === 401) setToken(null)
  if (!res.ok) throw new Error((await res.text()) || res.statusText)
  return res.json()
}

export const auth = (mode, username, password) =>
  request(`/api/auth/${mode}`, { method: 'POST', body: JSON.stringify({ username, password }) })

export const fetchFeed = (before) =>
  request(`/api/posts?size=20${before ? `&before=${before}` : ''}`)

export const createPost = (content) =>
  request('/api/posts', { method: 'POST', body: JSON.stringify({ content }) })
