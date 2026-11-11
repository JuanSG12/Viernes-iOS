'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { createCompanion, isPrivateAddress, sha256Hex } = require('../server.js');

// Certificado de prueba (solo para estas pruebas). Si no hay openssl, se omiten.
let tls = null;
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'viernes-companion-'));
try {
  const key = path.join(tmpRoot, 'k.pem');
  const cert = path.join(tmpRoot, 'c.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore' });
  tls = { key: fs.readFileSync(key), cert: fs.readFileSync(cert) };
} catch { /* sin openssl */ }
const skip = tls ? false : 'openssl no está disponible';

function request(port, method, route, { token, body, raw } = {}) {
  return new Promise((resolve, reject) => {
    const data = raw !== undefined ? raw : (body === undefined ? null : JSON.stringify(body));
    const req = https.request({ host: '127.0.0.1', port, method, path: route, rejectUnauthorized: false,
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}) } }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => { const text = Buffer.concat(chunks).toString('utf8'); let json = null; try { json = JSON.parse(text); } catch { /* texto */ } resolve({ status: res.statusCode, json, text }); });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function setup(extra = {}) {
  const dataDir = fs.mkdtempSync(path.join(tmpRoot, 'data-'));
  const calls = extra.calls || [];
  const clock = { value: 1_800_000_000_000 };
  const companion = createCompanion({
    dataDir, tls, now: () => clock.value, confirm: extra.confirm || (async () => false),
    config: { port: 0, folders: [], repos: [], scripts: {}, tokens: [], tls: null, fingerprint: 'AB:CD', ...(extra.config || {}) },
    run: extra.run || (async (file, args) => { calls.push({ file, args }); return { ok: true, stdout: '', stderr: '' }; })
  });
  const address = await companion.start({ port: 0, host: '127.0.0.1' });
  const pairToken = async () => {
    const { code } = companion.startPairing();
    const response = await request(address.port, 'POST', '/v1/pair', { body: { code, deviceName: 'iPhone de prueba' } });
    assert.equal(response.status, 200);
    return response.json.token;
  };
  return { companion, port: address.port, dataDir, calls, clock, pairToken, stop: () => companion.stop() };
}

test('solo se aceptan direcciones de la red local', () => {
  for (const ok of ['127.0.0.1', '10.1.2.3', '172.16.0.5', '172.31.255.1', '192.168.1.20', '169.254.3.4', '::1', '::ffff:192.168.0.9', 'fd12:3456::1', 'fe80::1']) assert.equal(isPrivateAddress(ok), true, ok);
  for (const bad of ['8.8.8.8', '172.32.0.1', '172.15.0.1', '192.169.0.1', '2001:4860:4860::8888', '', undefined, '::ffff:8.8.8.8']) assert.equal(isPrivateAddress(bad), false, String(bad));
});

test('el emparejamiento es de un solo uso, caduca y se bloquea con intentos fallidos', { skip }, async () => {
  const t = await setup();
  try {
    assert.equal((await request(t.port, 'POST', '/v1/pair', { body: { code: '12345678' } })).status, 403, 'sin emparejamiento abierto');
    const first = t.companion.startPairing();
    assert.match(first.code, /^\d{8}$/);
    const wrong = first.code === '00000000' ? '11111111' : '00000000';
    for (let i = 0; i < 5; i++) assert.equal((await request(t.port, 'POST', '/v1/pair', { body: { code: wrong } })).status, 403);
    assert.equal((await request(t.port, 'POST', '/v1/pair', { body: { code: first.code } })).status, 403, 'tras 5 fallos el código muere aunque sea el correcto');

    const second = t.companion.startPairing();
    const ok = await request(t.port, 'POST', '/v1/pair', { body: { code: second.code, deviceName: 'iPhone' } });
    assert.equal(ok.status, 200);
    assert.ok(ok.json.token.length >= 40);
    assert.equal(ok.json.fingerprint, 'AB:CD');
    assert.equal((await request(t.port, 'POST', '/v1/pair', { body: { code: second.code } })).status, 403, 'un código no se reutiliza');

    const third = t.companion.startPairing();
    t.clock.value += 121 * 1000;
    assert.equal((await request(t.port, 'POST', '/v1/pair', { body: { code: third.code } })).status, 403, 'caducó a los 2 minutos');
  } finally { await t.stop(); }
});

test('sin token válido no se entra y el token solo se guarda como huella', { skip }, async () => {
  const t = await setup();
  try {
    assert.equal((await request(t.port, 'GET', '/v1/status')).status, 401);
    assert.equal((await request(t.port, 'GET', '/v1/status', { token: 'inventado' })).status, 401);
    const token = await t.pairToken();
    const status = await request(t.port, 'GET', '/v1/status', { token });
    assert.equal(status.status, 200);
    assert.ok(status.json.tools.includes('files/search'));
    assert.ok(!status.json.tools.includes('shell'), 'no existe ejecutar comandos');
    const stored = JSON.stringify(t.companion.config.tokens);
    assert.ok(!stored.includes(token), 'el token no se guarda en claro');
    assert.equal(t.companion.config.tokens[0].hash, sha256Hex(token));
    assert.equal((await request(t.port, 'GET', '/v1/nada', { token })).status, 404);
  } finally { await t.stop(); }
});

test('los tokens se pueden revocar desde el iPhone y desde el PC', { skip }, async () => {
  const t = await setup();
  try {
    const one = await t.pairToken();
    assert.equal((await request(t.port, 'DELETE', '/v1/pair', { token: one })).status, 200);
    assert.equal((await request(t.port, 'GET', '/v1/status', { token: one })).status, 401);
    const two = await t.pairToken();
    const id = t.companion.config.tokens[0].id;
    assert.equal(t.companion.revoke(id), true);
    assert.equal((await request(t.port, 'GET', '/v1/status', { token: two })).status, 401);
    assert.equal(t.companion.revoke('noexiste'), false);
  } finally { await t.stop(); }
});

test('los archivos solo se ven dentro de carpetas autorizadas y sin secretos', { skip }, async () => {
  const root = fs.mkdtempSync(path.join(tmpRoot, 'docs-'));
  const outside = fs.mkdtempSync(path.join(tmpRoot, 'fuera-'));
  fs.writeFileSync(path.join(outside, 'secreto.txt'), 'FUERA');
  fs.mkdirSync(path.join(root, 'proyectos', 'aurora'), { recursive: true });
  fs.mkdirSync(path.join(root, 'node_modules', 'x'), { recursive: true });
  fs.mkdirSync(path.join(root, '.git'));
  fs.writeFileSync(path.join(root, 'proyectos', 'aurora', 'propuesta.md'), 'La propuesta de Aurora cuesta 2.800.000 pesos.');
  fs.writeFileSync(path.join(root, 'proyectos', 'aurora', 'notas.txt'), 'Notas con la palabra ULTRASECRETO adentro');
  fs.writeFileSync(path.join(root, 'node_modules', 'x', 'propuesta.js'), 'no');
  fs.writeFileSync(path.join(root, '.env'), 'API_KEY=abc');
  fs.writeFileSync(path.join(root, 'passwords.txt'), 'propuesta clave 1234');
  fs.writeFileSync(path.join(root, 'id_rsa'), 'propuesta');
  fs.writeFileSync(path.join(root, 'imagen.png'), 'png');
  fs.writeFileSync(path.join(root, 'grande.txt'), 'x'.repeat(50_000));
  try { fs.symlinkSync(outside, path.join(root, 'enlace'), 'junction'); } catch { /* sin permiso para enlaces: se omite esa parte */ }
  const t = await setup({ config: { folders: [{ label: 'docs', path: root }] } });
  try {
    const token = await t.pairToken();
    const byName = await request(t.port, 'POST', '/v1/files/search', { token, body: { query: 'propuesta' } });
    assert.equal(byName.status, 200);
    assert.deepEqual(byName.json.results.map((r) => r.path), ['proyectos/aurora/propuesta.md'], 'ni node_modules, ni secretos, ni .env, ni claves');
    const byContent = await request(t.port, 'POST', '/v1/files/search', { token, body: { query: 'ultrasecreto', content: true } });
    assert.deepEqual(byContent.json.results.map((r) => r.path), ['proyectos/aurora/notas.txt']);
    assert.equal((await request(t.port, 'POST', '/v1/files/search', { token, body: { query: 'a' } })).status, 400);
    assert.ok(!(await request(t.port, 'POST', '/v1/files/search', { token, body: { query: 'secreto' } })).json.results.some((r) => r.path.includes('enlace')), 'no se siguen enlaces');

    const read = await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'docs', path: 'proyectos/aurora/propuesta.md' } });
    assert.equal(read.status, 200);
    assert.match(read.json.text, /2\.800\.000/);
    const big = await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'docs', path: 'grande.txt' } });
    assert.equal(big.json.truncated, true);
    assert.equal(big.json.text.length, 20 * 1024);
    for (const evil of ['../fuera/secreto.txt', '..\\..\\Windows\\win.ini', 'proyectos/../../x.txt', 'enlace/secreto.txt']) {
      const response = await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'docs', path: evil } });
      assert.ok([400, 403, 404, 415].includes(response.status), `${evil} → ${response.status}`);
      assert.ok(!(response.text || '').includes('FUERA'));
    }
    assert.equal((await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'docs', path: path.join(root, 'passwords.txt') } })).status, 400, 'ruta absoluta');
    assert.equal((await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'docs', path: '.env' } })).status, 403);
    assert.equal((await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'docs', path: 'passwords.txt' } })).status, 403);
    assert.equal((await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'docs', path: 'imagen.png' } })).status, 415);
    assert.equal((await request(t.port, 'POST', '/v1/files/read', { token, body: { folder: 'otra', path: 'a.txt' } })).status, 400);

    const log = fs.readFileSync(path.join(t.dataDir, 'audit.log'), 'utf8');
    assert.match(log, /files\/read/);
    assert.ok(!log.includes('2.800.000') && !log.includes('ULTRASECRETO'), 'el registro nunca guarda contenido de archivos');
  } finally { await t.stop(); }
});

test('procesos, GitHub y scripts solo con lista blanca y confirmación', { skip }, async () => {
  const script = path.join(tmpRoot, 'aprobado.ps1');
  fs.writeFileSync(script, 'Write-Output "hola"');
  const decisions = [];
  const calls = [];
  const t = await setup({
    calls,
    config: { repos: ['JuanSG12/Viernes-iOS'], scripts: { saludo: { path: script, sha256: sha256Hex(fs.readFileSync(script)) } } },
    confirm: async (question) => { decisions.push(question); return decisions.length > 1; },
    run: async (file, args) => {
      calls.push({ file, args });
      if (file === 'tasklist') return { ok: true, stdout: '"node.exe","1234","Console","1","50,000 K"\r\n"Code.exe","99","Console","1","120,000 K"\r\n', stderr: '' };
      if (file === 'ps') return { ok: true, stdout: '1234 node 50000\n99 Code 120000\n', stderr: '' };
      if (file === 'gh') return { ok: true, stdout: JSON.stringify([{ databaseId: 1, status: 'completed', conclusion: 'success' }]), stderr: '' };
      return { ok: true, stdout: 'hola\n', stderr: '' };
    }
  });
  try {
    const token = await t.pairToken();
    const list = await request(t.port, 'GET', '/v1/processes?name=node', { token });
    assert.equal(list.status, 200);
    assert.deepEqual(list.json.processes.map((p) => p.name.toLowerCase()), process.platform === 'win32' ? ['node.exe'] : ['node']);

    assert.equal((await request(t.port, 'POST', '/v1/github/runs', { token, body: { repo: 'otro/repositorio' } })).status, 403);
    assert.equal((await request(t.port, 'POST', '/v1/github/runs', { token, body: { repo: 'x; rm -rf /' } })).status, 403);
    const runs = await request(t.port, 'POST', '/v1/github/runs', { token, body: { repo: 'JuanSG12/Viernes-iOS' } });
    assert.equal(runs.status, 200);
    assert.equal(runs.json.runs[0].conclusion, 'success');

    assert.equal((await request(t.port, 'POST', '/v1/scripts/run', { token, body: { name: 'otro' } })).status, 403);
    assert.equal((await request(t.port, 'POST', '/v1/scripts/run', { token, body: { name: '__proto__' } })).status, 403);
    assert.equal((await request(t.port, 'POST', '/v1/scripts/run', { token, body: { name: 'constructor' } })).status, 403);
    const denied = await request(t.port, 'POST', '/v1/scripts/run', { token, body: { name: 'saludo' } });
    assert.equal(denied.status, 403, 'el PC no confirmó');
    assert.ok(!t.calls.some((c) => c.file === 'pwsh'), 'sin confirmación no se ejecuta');
    const allowed = await request(t.port, 'POST', '/v1/scripts/run', { token, body: { name: 'saludo', args: ['--malo'], command: 'calc' } });
    assert.equal(allowed.status, 200);
    assert.deepEqual(t.calls.find((c) => c.file === 'pwsh').args, ['-NoProfile', '-NonInteractive', '-File', script], 'el iPhone no puede añadir argumentos ni comandos');
    assert.match(decisions[0], /iPhone de prueba/);

    fs.writeFileSync(script, 'Write-Output "cambiado"');
    assert.equal((await request(t.port, 'POST', '/v1/scripts/run', { token, body: { name: 'saludo' } })).status, 409, 'si el script cambia hay que aprobarlo otra vez');
  } finally { await t.stop(); }
});

test('la bandeja entrega los mensajes una sola vez', { skip }, async () => {
  const t = await setup();
  try {
    const token = await t.pairToken();
    t.companion.addToOutbox('Terminó la compilación');
    const first = await request(t.port, 'GET', '/v1/outbox', { token });
    assert.deepEqual(first.json.messages.map((m) => m.text), ['Terminó la compilación']);
    assert.deepEqual((await request(t.port, 'GET', '/v1/outbox', { token })).json.messages, []);
  } finally { await t.stop(); }
});

test('cuerpos enormes o inválidos se rechazan y hay límite de peticiones', { skip }, async () => {
  const t = await setup();
  try {
    const token = await t.pairToken();
    assert.equal((await request(t.port, 'POST', '/v1/files/search', { token, body: { query: 'x'.repeat(20_000) } })).status, 413);
    assert.equal((await request(t.port, 'POST', '/v1/files/search', { token, raw: '{no es json' })).status, 400);
    let limited = 0;
    for (let i = 0; i < 130; i++) if ((await request(t.port, 'GET', '/v1/status', { token })).status === 429) limited += 1;
    assert.ok(limited > 0, 'tras 120 peticiones por minuto se frena');
  } finally { await t.stop(); }
});

test('el registro de auditoría anota cada petición con su resultado', { skip }, async () => {
  const t = await setup();
  try {
    const token = await t.pairToken();
    await request(t.port, 'GET', '/v1/status', { token });
    await request(t.port, 'GET', '/v1/status');
    const lines = fs.readFileSync(path.join(t.dataDir, 'audit.log'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    assert.ok(lines.some((l) => l.route === 'POST /v1/pair' && l.status === 200));
    assert.ok(lines.some((l) => l.route === 'GET /v1/status' && l.status === 200 && l.token));
    assert.ok(lines.some((l) => l.route === 'GET /v1/status' && l.status === 401 && l.token === null));
    assert.ok(!JSON.stringify(lines).includes(token), 'el token nunca se escribe en el registro');
  } finally { await t.stop(); }
});

test.after(() => { fs.rmSync(tmpRoot, { recursive: true, force: true }); });
