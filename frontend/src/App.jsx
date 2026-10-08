import { useCallback, useEffect, useRef, useState } from 'react'
import { auth, createPost, fetchFeed, getToken, setToken } from './api.js'

function AuthForm({ onDone }) {
  const [mode, setMode] = useState('login')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')

  const submit = async (e) => {
    e.preventDefault()
    try {
      const r = await auth(mode, username, password)
      setToken(r.token)
      localStorage.setItem('username', r.username)
      onDone()
    } catch (err) {
      setError(err.message)
    }
  }

  return (
    <form className="card" onSubmit={submit}>
      <h2>{mode === 'login' ? 'Log in' : 'Create account'}</h2>
      <input placeholder="username" value={username} onChange={(e) => setUsername(e.target.value)} />
      <input type="password" placeholder="password (min 8)" value={password} onChange={(e) => setPassword(e.target.value)} />
      {error && <p className="error">{error}</p>}
      <button>{mode === 'login' ? 'Log in' : 'Sign up'}</button>
      <a href="#" onClick={(e) => { e.preventDefault(); setMode(mode === 'login' ? 'register' : 'login') }}>
        {mode === 'login' ? 'Need an account?' : 'Have an account?'}
      </a>
    </form>
  )
}

function Feed() {
  const [items, setItems] = useState([])
  const [cursor, setCursor] = useState(null)
  const [done, setDone] = useState(false)
  const [text, setText] = useState('')
  const loading = useRef(false)
  const sentinel = useRef(null)

  const load = useCallback(async (before) => {
    if (loading.current) return
    loading.current = true
    try {
      const page = await fetchFeed(before)
      setItems((prev) => (before ? [...prev, ...page.items] : page.items))
      setCursor(page.nextCursor)
      if (page.nextCursor == null) setDone(true)
    } finally {
      loading.current = false
    }
  }, [])

  useEffect(() => { load(null) }, [load])

  // Infinite scroll: fetch the next cursor page when the sentinel becomes visible.
  useEffect(() => {
    if (done || !sentinel.current) return
    const io = new IntersectionObserver(([e]) => e.isIntersecting && cursor && load(cursor))
    io.observe(sentinel.current)
    return () => io.disconnect()
  }, [cursor, done, load])

  const post = async (e) => {
    e.preventDefault()
    if (!text.trim()) return
    const p = await createPost(text)
    setItems((prev) => [p, ...prev])
    setText('')
  }

  return (
    <>
      {getToken() && (
        <form className="card" onSubmit={post}>
          <textarea maxLength={500} placeholder="What's happening?" value={text} onChange={(e) => setText(e.target.value)} />
          <button>Post</button>
        </form>
      )}
      {items.map((p) => (
        <article className="card" key={p.id}>
          <strong>@{p.author}</strong> <small>{new Date(p.createdAt).toLocaleString()}</small>
          <p>{p.content}</p>
        </article>
      ))}
      {!done && <div ref={sentinel} className="sentinel">Loading…</div>}
    </>
  )
}

export default function App() {
  const [authed, setAuthed] = useState(!!getToken())
  const logout = () => { setToken(null); setAuthed(false) }
  return (
    <main>
      <header>
        <h1>Scale App</h1>
        {authed && <button onClick={logout}>Log out</button>}
      </header>
      {!authed && <AuthForm onDone={() => setAuthed(true)} />}
      <Feed key={String(authed)} />
    </main>
  )
}
