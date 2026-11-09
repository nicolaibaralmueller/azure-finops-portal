// Static server for the portal on App Service (Linux, Node LTS). Zero dependencies.
//
// Replaces `pm2 serve --spa`, which cannot set response headers. The portal's JavaScript and
// CSS are content-hashed by Vite (assets/index-3f9a1c.js), so they can be cached for a year and
// never revalidated: a new build has new file names. The few files WITHOUT a hash — index.html,
// which names the current bundles, and config.json, which deploy.ps1 rewrites — must be
// revalidated on every load, or a browser keeps running last week's portal against this
// week's API.
//
//   /assets/*                 Cache-Control: public, max-age=31536000, immutable
//   index.html, config.json   Cache-Control: no-cache (+ ETag, so a revalidation is a 304)
//   anything else             Cache-Control: public, max-age=3600
//   unknown paths             index.html (single-page app fallback)
//
// Text responses are served brotli- or gzip-compressed when the browser accepts it. Compressed
// bodies are built once per file and kept in memory — the build output is a few MB at most — and
// rebuilt if the file changes on disk (a zip deploy replaces files under a running process).
//
// App Service fronts this with EasyAuth, so /.auth/* never reaches it. The server itself only
// ever reads from its own directory: paths are normalised and anything resolving outside it,
// plus this file, is refused.

import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(process.env.STATIC_ROOT || path.dirname(fileURLToPath(import.meta.url)))
const PORT = Number(process.env.PORT || 8080)
const SELF = path.basename(fileURLToPath(import.meta.url))

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
}
const COMPRESSIBLE = new Set(['.html', '.js', '.mjs', '.css', '.json', '.svg', '.txt', '.map', '.webmanifest'])
// Below this, compression costs more than it saves.
const MIN_COMPRESS_BYTES = 1024
const NO_CACHE = new Set(['index.html', 'config.json'])

/** Map a request path to a file inside ROOT, or null. Never leaves ROOT. */
export function resolveFile(root, urlPath) {
  let decoded
  try {
    decoded = decodeURIComponent(urlPath.split('?')[0])
  } catch {
    return null   // malformed escape
  }
  if (decoded.includes('\0')) return null
  const rel = path.normalize(decoded).replace(/^([/\\])+/, '')
  const full = path.resolve(root, rel)
  if (full !== root && !full.startsWith(root + path.sep)) return null
  if (path.basename(full) === SELF) return null
  return full
}

/** Cache-Control for a file path relative to ROOT. */
export function cacheControl(relPath) {
  const p = relPath.split(path.sep).join('/')
  if (p.startsWith('assets/')) return 'public, max-age=31536000, immutable'
  if (NO_CACHE.has(p)) return 'no-cache'
  return 'public, max-age=3600'
}

/** The best encoding the client accepts, among the ones we produce. */
export function pickEncoding(acceptEncoding) {
  const accepted = new Map()
  for (const part of String(acceptEncoding || '').split(',')) {
    const [name, ...params] = part.trim().toLowerCase().split(';')
    if (!name) continue
    const q = params.map((x) => x.trim()).find((x) => x.startsWith('q='))
    accepted.set(name, q ? Number(q.slice(2)) : 1)
  }
  const ok = (n) => (accepted.get(n) ?? accepted.get('*') ?? 0) > 0
  if (ok('br')) return 'br'
  if (ok('gzip')) return 'gzip'
  return null
}

// file -> { mtimeMs, size, etag, raw, br?, gzip? }
const cache = new Map()

function load(file) {
  const st = fs.statSync(file)
  const hit = cache.get(file)
  if (hit && hit.mtimeMs === st.mtimeMs && hit.size === st.size) return hit
  const entry = {
    mtimeMs: st.mtimeMs,
    size: st.size,
    etag: `"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`,
    raw: fs.readFileSync(file),
  }
  cache.set(file, entry)
  return entry
}

function body(entry, encoding) {
  if (!encoding) return entry.raw
  if (!entry[encoding]) {
    entry[encoding] = encoding === 'br'
      ? zlib.brotliCompressSync(entry.raw, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 10 } })
      : zlib.gzipSync(entry.raw, { level: 9 })
  }
  return entry[encoding]
}

export function handler(root = ROOT) {
  const indexFile = path.join(root, 'index.html')
  return (req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { Allow: 'GET, HEAD' })
      res.end()
      return
    }
    const url = req.url || '/'
    let file = resolveFile(root, url)
    if (file === null) {
      res.writeHead(400)
      res.end()
      return
    }
    let exists = false
    try { exists = fs.statSync(file).isFile() } catch { exists = false }
    if (!exists) {
      // A missing hashed asset is a real 404 (an old tab asking for a replaced bundle) — serving
      // index.html there would hand the browser HTML where it expects JavaScript.
      const rel = path.relative(root, file).split(path.sep).join('/')
      if (rel.startsWith('assets/') || path.extname(rel) !== '') {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-cache' })
        res.end('Not found')
        return
      }
      file = indexFile   // single-page app fallback
    }

    let entry
    try {
      entry = load(file)
    } catch {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('Not found')
      return
    }

    const rel = path.relative(root, file)
    const ext = path.extname(file).toLowerCase()
    const headers = {
      'Content-Type': TYPES[ext] || 'application/octet-stream',
      'Cache-Control': cacheControl(rel),
      ETag: entry.etag,
      Vary: 'Accept-Encoding',
    }

    if (req.headers['if-none-match'] === entry.etag) {
      res.writeHead(304, headers)
      res.end()
      return
    }

    const encoding = COMPRESSIBLE.has(ext) && entry.size >= MIN_COMPRESS_BYTES
      ? pickEncoding(req.headers['accept-encoding'])
      : null
    const payload = body(entry, encoding)
    if (encoding) headers['Content-Encoding'] = encoding
    headers['Content-Length'] = payload.length
    res.writeHead(200, headers)
    res.end(req.method === 'HEAD' ? undefined : payload)
  }
}

// Start only when run directly (the tests import the functions above).
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  http.createServer(handler()).listen(PORT, () => {
    console.log(`portal static server on :${PORT}, serving ${ROOT}`)
  })
}
