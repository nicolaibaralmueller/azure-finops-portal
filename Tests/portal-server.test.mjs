// Offline tests for the portal's static server (src/web-app/public/server.mjs).
// Run: node --test Tests/portal-server.test.mjs  (Tests/Invoke-OfflineTests.ps1 does this)

import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import zlib from 'node:zlib'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const serverPath = path.resolve(here, '../src/web-app/public/server.mjs')
const { handler, resolveFile, cacheControl, pickEncoding } = await import(pathToFileURL(serverPath).href)

let root, server, base
const bigJs = 'console.log("portal");\n'.repeat(400)

before(async () => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'portal-'))
  fs.mkdirSync(path.join(root, 'assets'))
  fs.writeFileSync(path.join(root, 'index.html'), '<!doctype html><title>x</title><div id="root"></div>')
  fs.writeFileSync(path.join(root, 'config.json'), '{"apiBaseUrl":"/api"}')
  fs.writeFileSync(path.join(root, 'assets', 'index-abc123.js'), bigJs)
  fs.writeFileSync(path.join(root, 'assets', 'logo-9f.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47]))
  fs.writeFileSync(path.join(root, 'server.mjs'), '// must never be served')
  fs.writeFileSync(path.join(os.tmpdir(), 'portal-secret.txt'), 'secret')
  server = http.createServer(handler(root))
  await new Promise((r) => server.listen(0, r))
  base = `http://127.0.0.1:${server.address().port}`
})

after(() => {
  server.close()
  fs.rmSync(root, { recursive: true, force: true })
})

function get(p, headers = {}, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = http.request(`${base}${p}`, { method, headers }, (res) => {
      const chunks = []
      res.on('data', (c) => chunks.push(c))
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }))
    })
    req.on('error', reject)
    req.end()
  })
}

test('hashed assets are cached for a year, immutable', async () => {
  const r = await get('/assets/index-abc123.js')
  assert.equal(r.status, 200)
  assert.equal(r.headers['cache-control'], 'public, max-age=31536000, immutable')
  assert.match(r.headers['content-type'], /javascript/)
})

test('index.html and config.json must be revalidated', async () => {
  for (const p of ['/', '/index.html', '/config.json']) {
    const r = await get(p)
    assert.equal(r.status, 200, p)
    assert.equal(r.headers['cache-control'], 'no-cache', p)
    assert.ok(r.headers.etag, p)
  }
})

test('a matching ETag is a 304 with no body', async () => {
  const first = await get('/config.json')
  const again = await get('/config.json', { 'If-None-Match': first.headers.etag })
  assert.equal(again.status, 304)
  assert.equal(again.body.length, 0)
})

test('brotli preferred, gzip next, identity otherwise — bodies decode to the original', async () => {
  const br = await get('/assets/index-abc123.js', { 'Accept-Encoding': 'gzip, deflate, br' })
  assert.equal(br.headers['content-encoding'], 'br')
  assert.equal(zlib.brotliDecompressSync(br.body).toString(), bigJs)
  assert.ok(br.body.length < bigJs.length / 5, 'actually compressed')

  const gz = await get('/assets/index-abc123.js', { 'Accept-Encoding': 'gzip' })
  assert.equal(gz.headers['content-encoding'], 'gzip')
  assert.equal(zlib.gunzipSync(gz.body).toString(), bigJs)

  const plain = await get('/assets/index-abc123.js', { 'Accept-Encoding': 'identity' })
  assert.equal(plain.headers['content-encoding'], undefined)
  assert.equal(plain.body.toString(), bigJs)
  assert.equal(br.headers.vary, 'Accept-Encoding')
})

test('small files and binaries are not compressed', async () => {
  const cfg = await get('/config.json', { 'Accept-Encoding': 'br' })
  assert.equal(cfg.headers['content-encoding'], undefined)
  const png = await get('/assets/logo-9f.png', { 'Accept-Encoding': 'br' })
  assert.equal(png.headers['content-encoding'], undefined)
  assert.equal(png.headers['content-type'], 'image/png')
})

test('unknown extensionless paths fall back to index.html; a missing asset is a real 404', async () => {
  const deep = await get('/savings/some/view')
  assert.equal(deep.status, 200)
  assert.match(deep.body.toString(), /id="root"/)
  const missing = await get('/assets/index-old999.js')
  assert.equal(missing.status, 404)
  const missingFile = await get('/favicon.ico')
  assert.equal(missingFile.status, 404)
})

test('path traversal and the server file itself are refused', async () => {
  for (const p of ['/../portal-secret.txt', '/%2e%2e/portal-secret.txt', '/assets/..%2f..%2fportal-secret.txt']) {
    const r = await get(p)
    assert.notEqual(r.body.toString(), 'secret', p)
  }
  const self = await get('/server.mjs')
  assert.notEqual(self.body.toString(), '// must never be served')
  const bad = await get('/%E0%A4%A')
  assert.equal(bad.status, 400)
  assert.equal(resolveFile(root, '/a\0b'), null)
})

test('only GET and HEAD; HEAD has headers and no body', async () => {
  const post = await get('/', {}, 'POST')
  assert.equal(post.status, 405)
  const head = await get('/assets/index-abc123.js', {}, 'HEAD')
  assert.equal(head.status, 200)
  assert.equal(head.body.length, 0)
  assert.ok(Number(head.headers['content-length']) > 0)
})

test('a file replaced under the running server is served fresh', async () => {
  const before = await get('/config.json')
  fs.writeFileSync(path.join(root, 'config.json'), '{"apiBaseUrl":"/api","productName":"Changed portal name"}')
  const future = new Date(Date.now() + 5000)
  fs.utimesSync(path.join(root, 'config.json'), future, future)
  const after = await get('/config.json')
  assert.match(after.body.toString(), /Changed portal name/)
  assert.notEqual(after.headers.etag, before.headers.etag)
})

test('helpers', () => {
  assert.equal(cacheControl(path.join('assets', 'x.js')), 'public, max-age=31536000, immutable')
  assert.equal(cacheControl('robots.txt'), 'public, max-age=3600')
  assert.equal(pickEncoding('gzip;q=1, br;q=0'), 'gzip')
  assert.equal(pickEncoding('*'), 'br')
  assert.equal(pickEncoding(''), null)
})
