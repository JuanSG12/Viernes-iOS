#!/usr/bin/env node
'use strict';
/*
 * Viernes Companion para Windows — prueba de concepto SEGURA y de solo lectura por defecto.
 *
 * - Servicio local con API HTTPS (certificado propio; el iPhone fija su huella SHA-256 al emparejarse).
 * - Solo acepta conexiones de la red local (nunca de internet) y no abre puertos públicos.
 * - Emparejamiento con un código de 8 dígitos de un solo uso (2 minutos); tokens revocables; solo se guarda su hash.
 * - Lista BLANCA de herramientas: buscar y leer archivos de carpetas autorizadas, listar procesos, ver ejecuciones de GitHub
 *   de repositorios autorizados, ejecutar scripts aprobados (con su hash fijado y confirmación en ESTE equipo) y una bandeja
 *   de mensajes hacia el iPhone. No existe «ejecutar un comando»: nada de lo que mande el iPhone llega a un intérprete.
 * - Registro de auditoría de cada petición (nunca el contenido de los archivos).
 * Sin dependencias: solo módulos incluidos en Node.
 */
const https = require('https');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const readline = require('readline');
const { execFile } = require('child_process');

const VERSION = '0.1.0';
const MAX_BODY = 8 * 1024;
const MAX_READ_BYTES = 20 * 1024;
const MAX_SEARCH_VISITS = 5000;
const MAX_DEPTH = 6;
const PAIR_TTL_MS = 120 * 1000;
const PAIR_MAX_FAILS = 5;
const RATE_LIMIT = 120; // peticiones por minuto y por dirección
const TEXT_EXT = new Set(['.txt', '.md', '.json', '.csv', '.log', '.js', '.ts', '.py', '.cs', '.swift', '.yml', '.yaml', '.xml', '.html', '.css', '.sql', '.ps1', '.sh', '.toml', '.ini']);
const DENY_NAME = /(^\.env|\.pem$|\.pfx$|\.p12$|\.key$|id_rsa|id_ed25519|\.kdbx$|secret|password|passwd|credential|token|\.npmrc$|\.netrc$)/i;
const DENY_DIR = new Set(['.git', '.ssh', 'node_modules', '.aws', '.azure', '.gnupg']);

const sha256Hex = (value) => crypto.createHash('sha256').update(value).digest('hex');

function isPrivateAddress(raw) {
  if (!raw) return false;
  const address = raw.replace(/^::ffff:/i, '');
  if (address === '::1') return true;
  if (/^f[cd][0-9a-f]{2}:/i.test(address) || /^fe[89ab][0-9a-f]:/i.test(address)) return true; // ULA y link-local IPv6
  const m = address.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
}

function defaultDataDir() {
  return process.env.VIERNES_COMPANION_DIR || path.join(process.env.APPDATA || path.join(os.homedir(), '.config'), 'ViernesCompanion');
}

function loadConfig(dataDir) {
  const file = path.join(dataDir, 'config.json');
  const base = { port: 8443, folders: [], repos: [], scripts: {}, tokens: [], tls: null, fingerprint: null };
  try { return { ...base, ...JSON.parse(fs.readFileSync(file, 'utf8')) }; } catch { return base; }
}

function saveConfig(dataDir, config) {
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, 'config.json');
  fs.writeFileSync(file + '.tmp', JSON.stringify(config, null, 2));
  fs.renameSync(file + '.tmp', file);
}

const defaultRun = (file, args, options) => new Promise((resolve) => {
  execFile(file, args, { windowsHide: true, timeout: 60000, maxBuffer: 256 * 1024, ...options }, (error, stdout, stderr) => {
    resolve({ ok: !error, code: error && error.code, stdout: String(stdout || ''), stderr: String(stderr || '') });
  });
});

/** Crea el compañero. `options` permite probarlo sin tocar el sistema real (carpeta de datos, TLS, confirmación, ejecución). */
function createCompanion(options = {}) {
  const dataDir = options.dataDir || defaultDataDir();
  const now = options.now || (() => Date.now());
  const run = options.run || defaultRun;
  const confirm = options.confirm || (async () => false);
  let config = options.config || loadConfig(dataDir);
  let pairing = null;
  const rates = new Map();
  let server = null;

  const persist = () => { if (!options.config) saveConfig(dataDir, config); };

  function audit(tokenId, route, status, detail = '') {
    const line = JSON.stringify({ t: new Date(now()).toISOString(), token: tokenId || null, route, status, detail: String(detail).slice(0, 160) });
    try { fs.mkdirSync(dataDir, { recursive: true }); fs.appendFileSync(path.join(dataDir, 'audit.log'), line + '\n'); } catch { /* el registro nunca debe tumbar el servicio */ }
  }

  function send(res, status, body) {
    const data = JSON.stringify(body);
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Content-Length': Buffer.byteLength(data), ...(status === 413 ? { Connection: 'close' } : {}) });
    res.end(data);
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      let size = 0;
      let tooBig = false;
      const chunks = [];
      req.on('data', (chunk) => {
        if (tooBig) return;
        size += chunk.length;
        if (size > MAX_BODY) { tooBig = true; reject(Object.assign(new Error('cuerpo demasiado grande'), { status: 413 })); return; }
        chunks.push(chunk);
      });
      req.on('end', () => {
        if (chunks.length === 0) { resolve({}); return; }
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch { reject(Object.assign(new Error('JSON no válido'), { status: 400 })); }
      });
      req.on('error', reject);
    });
  }

  function limited(address) {
    const minute = Math.floor(now() / 60000);
    const entry = rates.get(address);
    if (!entry || entry.minute !== minute) { rates.set(address, { minute, count: 1 }); return false; }
    entry.count += 1;
    return entry.count > RATE_LIMIT;
  }

  // ---- Emparejamiento ----
  function startPairing() {
    pairing = { code: String(crypto.randomInt(0, 100000000)).padStart(8, '0'), expires: now() + PAIR_TTL_MS, fails: 0 };
    return { code: pairing.code, expiresInSeconds: PAIR_TTL_MS / 1000 };
  }

  function pair(body) {
    if (!pairing || now() > pairing.expires) { pairing = null; return { status: 403, body: { error: 'No hay un emparejamiento abierto. Ejecuta «pair» en el PC.' } }; }
    const given = String(body.code || '');
    const a = Buffer.from(given.padEnd(8).slice(0, 8));
    const b = Buffer.from(pairing.code);
    if (given.length !== 8 || !crypto.timingSafeEqual(a, b)) {
      pairing.fails += 1;
      if (pairing.fails >= PAIR_MAX_FAILS) pairing = null; // demasiados intentos: el código muere
      return { status: 403, body: { error: 'Código incorrecto.' } };
    }
    pairing = null; // un solo uso
    const token = crypto.randomBytes(32).toString('base64url');
    const entry = { id: crypto.randomBytes(4).toString('hex'), name: String(body.deviceName || 'iPhone').slice(0, 40), hash: sha256Hex(token), createdAt: new Date(now()).toISOString(), lastUsed: null };
    config.tokens.push(entry);
    persist();
    return { status: 200, body: { token, tokenId: entry.id, fingerprint: config.fingerprint, name: os.hostname() }, tokenId: entry.id };
  }

  function authenticate(req) {
    const header = req.headers.authorization || '';
    const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    if (!token) return null;
    const hash = Buffer.from(sha256Hex(token));
    for (const entry of config.tokens) {
      const known = Buffer.from(entry.hash);
      if (known.length === hash.length && crypto.timingSafeEqual(known, hash)) return entry;
    }
    return null;
  }

  // ---- Archivos (solo carpetas autorizadas) ----
  async function realRoot(folder) { return fsp.realpath(folder.path); }

  async function walk(folderLabel, root, query, limit, withContent) {
    const needle = query.toLowerCase();
    const results = [];
    let visits = 0;
    const queue = [{ dir: root, depth: 0 }];
    while (queue.length > 0 && results.length < limit && visits < MAX_SEARCH_VISITS) {
      const { dir, depth } = queue.shift();
      let entries;
      try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { continue; }
      for (const entry of entries) {
        if (results.length >= limit || visits >= MAX_SEARCH_VISITS) break;
        visits += 1;
        if (entry.isSymbolicLink()) continue; // nunca se siguen enlaces: no pueden sacar la búsqueda de la carpeta
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (!DENY_DIR.has(entry.name) && !entry.name.startsWith('.') && depth < MAX_DEPTH) queue.push({ dir: full, depth: depth + 1 });
          continue;
        }
        if (!entry.isFile() || DENY_NAME.test(entry.name)) continue;
        let matched = entry.name.toLowerCase().includes(needle);
        let stat = null;
        if (!matched && withContent && TEXT_EXT.has(path.extname(entry.name).toLowerCase())) {
          try {
            stat = await fsp.stat(full);
            if (stat.size <= 512 * 1024) matched = (await fsp.readFile(full, 'utf8')).toLowerCase().includes(needle);
          } catch { /* ilegible: se omite */ }
        }
        if (!matched) continue;
        try { stat = stat || await fsp.stat(full); } catch { continue; }
        results.push({ folder: folderLabel, path: path.relative(root, full).split(path.sep).join('/'), size: stat.size, modified: stat.mtime.toISOString() });
      }
    }
    return results;
  }

  async function searchFiles(body) {
    const query = String(body.query || '').trim();
    if (query.length < 2 || query.length > 100) return { status: 400, body: { error: '«query» debe tener entre 2 y 100 caracteres.' } };
    if (config.folders.length === 0) return { status: 200, body: { results: [], note: 'No hay carpetas autorizadas: añade una con «allow-folder».' } };
    const limit = Math.min(Math.max(Number(body.limit) || 20, 1), 50);
    let results = [];
    for (const folder of config.folders) {
      let root;
      try { root = await realRoot(folder); } catch { continue; }
      results = results.concat(await walk(folder.label, root, query, limit - results.length, body.content === true));
      if (results.length >= limit) break;
    }
    return { status: 200, body: { results } };
  }

  async function readFile(body) {
    const folder = config.folders.find((f) => f.label === body.folder);
    const relative = String(body.path || '');
    if (!folder || !relative || relative.includes('\0') || path.isAbsolute(relative)) return { status: 400, body: { error: 'Carpeta o ruta no válida.' } };
    let root;
    try { root = await realRoot(folder); } catch { return { status: 404, body: { error: 'La carpeta ya no existe.' } }; }
    const target = path.resolve(root, relative);
    if (target !== root && !target.startsWith(root + path.sep)) return { status: 403, body: { error: 'Esa ruta está fuera de la carpeta autorizada.' } };
    const parts = path.relative(root, target).split(path.sep);
    if (parts.some((part) => DENY_DIR.has(part) || part.startsWith('.')) || DENY_NAME.test(path.basename(target))) {
      return { status: 403, body: { error: 'Ese archivo no se comparte (puede contener secretos).' } };
    }
    if (!TEXT_EXT.has(path.extname(target).toLowerCase())) return { status: 415, body: { error: 'Solo se leen archivos de texto.' } };
    try {
      const link = await fsp.lstat(target);
      if (link.isSymbolicLink() || !link.isFile()) return { status: 403, body: { error: 'Solo se leen archivos normales.' } };
      const real = await fsp.realpath(target);
      if (real !== root && !real.startsWith(root + path.sep)) return { status: 403, body: { error: 'Esa ruta está fuera de la carpeta autorizada.' } };
      const handle = await fsp.open(real, 'r');
      try {
        const buffer = Buffer.alloc(MAX_READ_BYTES);
        const { bytesRead } = await handle.read(buffer, 0, MAX_READ_BYTES, 0);
        return { status: 200, body: { path: parts.join('/'), truncated: link.size > MAX_READ_BYTES, text: buffer.subarray(0, bytesRead).toString('utf8') } };
      } finally { await handle.close(); }
    } catch { return { status: 404, body: { error: 'No existe o no se puede leer.' } }; }
  }

  // ---- Procesos, GitHub, scripts, bandeja ----
  async function processes(url) {
    const filter = (url.searchParams.get('name') || '').toLowerCase().slice(0, 60);
    const result = process.platform === 'win32'
      ? await run('tasklist', ['/FO', 'CSV', '/NH'])
      : await run('ps', ['-eo', 'pid=,comm=,rss=']);
    if (!result.ok) return { status: 500, body: { error: 'No pude listar los procesos.' } };
    const list = [];
    for (const line of result.stdout.split(/\r?\n/)) {
      if (!line.trim()) continue;
      let name; let pid; let memory;
      if (process.platform === 'win32') {
        const cells = line.match(/"([^"]*)"/g);
        if (!cells || cells.length < 5) continue;
        [name, pid] = [cells[0].slice(1, -1), Number(cells[1].slice(1, -1))];
        memory = cells[4].slice(1, -1);
      } else {
        const m = line.trim().match(/^(\d+)\s+(\S+)\s+(\d+)$/);
        if (!m) continue;
        [pid, name, memory] = [Number(m[1]), m[2], `${m[3]} K`];
      }
      if (!filter || name.toLowerCase().includes(filter)) list.push({ name, pid, memory });
      if (list.length >= 200) break;
    }
    return { status: 200, body: { processes: list } };
  }

  async function githubRuns(body) {
    const repo = String(body.repo || '');
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo) || !config.repos.includes(repo)) return { status: 403, body: { error: 'Ese repositorio no está autorizado.' } };
    const result = await run('gh', ['run', 'list', '--repo', repo, '--limit', '5', '--json', 'databaseId,headSha,status,conclusion,workflowName,displayTitle']);
    if (!result.ok) return { status: 502, body: { error: 'No pude consultar GitHub (¿está instalado «gh» y con sesión?).' } };
    try { return { status: 200, body: { runs: JSON.parse(result.stdout) } }; } catch { return { status: 502, body: { error: 'Respuesta inesperada de GitHub.' } }; }
  }

  async function runScript(body, entry) {
    const name = String(body.name || '');
    const script = Object.prototype.hasOwnProperty.call(config.scripts, name) ? config.scripts[name] : null;
    if (!script) return { status: 403, body: { error: 'Ese script no está aprobado.' } };
    let actual;
    try { actual = sha256Hex(await fsp.readFile(script.path)); } catch { return { status: 404, body: { error: 'El script ya no existe.' } }; }
    if (actual !== script.sha256) return { status: 409, body: { error: 'El script cambió desde que se aprobó: vuelve a aprobarlo en el PC.' } };
    const allowed = await confirm(`El dispositivo «${entry.name}» pide ejecutar el script aprobado «${name}». ¿Permitir? (s/n)`);
    if (!allowed) return { status: 403, body: { error: 'El PC no confirmó la ejecución.' } };
    const result = await run('pwsh', ['-NoProfile', '-NonInteractive', '-File', script.path], { timeout: 60000 });
    return { status: 200, body: { ok: result.ok, output: (result.stdout + result.stderr).slice(0, MAX_READ_BYTES) } };
  }

  function outbox() {
    const file = path.join(dataDir, 'outbox.json');
    let messages = [];
    try { messages = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* vacía */ }
    if (messages.length > 0) fs.writeFileSync(file, '[]');
    return { status: 200, body: { messages } };
  }

  function addToOutbox(text) {
    fs.mkdirSync(dataDir, { recursive: true });
    const file = path.join(dataDir, 'outbox.json');
    let messages = [];
    try { messages = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* vacía */ }
    messages.push({ id: crypto.randomBytes(4).toString('hex'), time: new Date(now()).toISOString(), text: String(text).slice(0, 4000) });
    fs.writeFileSync(file, JSON.stringify(messages.slice(-50)));
  }

  // ---- Servidor ----
  async function handle(req, res) {
    const remote = req.socket.remoteAddress;
    if (!isPrivateAddress(remote)) { audit(null, 'conexión', 403, 'dirección no local'); send(res, 403, { error: 'Solo se aceptan conexiones de la red local.' }); return; }
    if (limited(remote)) { send(res, 429, { error: 'Demasiadas peticiones.' }); return; }
    const url = new URL(req.url, 'https://companion.local');
    const route = `${req.method} ${url.pathname}`;
    try {
      const body = req.method === 'POST' ? await readBody(req) : {};
      if (route === 'POST /v1/pair') {
        const outcome = pair(body);
        audit(outcome.tokenId, route, outcome.status);
        send(res, outcome.status, outcome.body);
        return;
      }
      const entry = authenticate(req);
      if (!entry) { audit(null, route, 401); send(res, 401, { error: 'Falta el token o no es válido.' }); return; }
      entry.lastUsed = new Date(now()).toISOString();
      let outcome;
      switch (route) {
        case 'GET /v1/status': outcome = { status: 200, body: { name: os.hostname(), version: VERSION, tools: ['files/search', 'files/read', 'processes', 'github/runs', 'scripts/run', 'outbox'], folders: config.folders.map((f) => f.label) } }; break;
        case 'POST /v1/files/search': outcome = await searchFiles(body); break;
        case 'POST /v1/files/read': outcome = await readFile(body); break;
        case 'GET /v1/processes': outcome = await processes(url); break;
        case 'POST /v1/github/runs': outcome = await githubRuns(body); break;
        case 'POST /v1/scripts/run': outcome = await runScript(body, entry); break;
        case 'GET /v1/outbox': outcome = outbox(); break;
        case 'DELETE /v1/pair': config.tokens = config.tokens.filter((t) => t.id !== entry.id); persist(); outcome = { status: 200, body: { revoked: true } }; break;
        default: outcome = { status: 404, body: { error: 'Esa herramienta no existe.' } };
      }
      audit(entry.id, route, outcome.status);
      send(res, outcome.status, outcome.body);
    } catch (error) {
      const status = error.status || 500;
      audit(null, route, status, error.message);
      send(res, status, { error: status === 500 ? 'Error interno.' : error.message });
    }
  }

  function start(listenOptions = {}) {
    const tlsOptions = options.tls || (config.tls && config.tls.pfx ? { pfx: fs.readFileSync(config.tls.pfx), passphrase: config.tls.passphrase } : null);
    if (!tlsOptions) throw new Error('Falta el certificado TLS: ejecuta setup.ps1 primero.');
    server = https.createServer({ ...tlsOptions, minVersion: 'TLSv1.2' }, (req, res) => { handle(req, res); });
    server.requestTimeout = 30000;
    server.headersTimeout = 10000;
    return new Promise((resolve) => {
      server.listen(listenOptions.port ?? config.port, listenOptions.host || '0.0.0.0', () => resolve(server.address()));
    });
  }

  function stop() { return new Promise((resolve) => (server ? server.close(() => resolve()) : resolve())); }

  return {
    get config() { return config; },
    set config(value) { config = value; },
    start, stop, startPairing, addToOutbox, persist,
    revoke(id) { const before = config.tokens.length; config.tokens = config.tokens.filter((t) => t.id === id ? false : true); persist(); return before !== config.tokens.length; },
    audit
  };
}

// ---- Línea de comandos ----
async function main(argv) {
  const [command, ...rest] = argv;
  const dataDir = defaultDataDir();
  let rl = null;
  const ask = (question) => new Promise((resolve) => {
    if (!rl) { resolve(false); return; }
    const timer = setTimeout(() => resolve(false), 60000);
    rl.question(`
${question} `, (answer) => { clearTimeout(timer); resolve(/^(s|si|sí|y|yes)$/i.test(answer.trim())); });
  });
  const companion = createCompanion({ dataDir, confirm: ask });
  const config = companion.config;
  switch (command) {
    case "start": {
      const address = await companion.start();
      console.log(`Viernes Companion ${VERSION} escuchando en el puerto ${address.port} (solo red local).`);
      console.log(`Huella del certificado (SHA-256): ${config.fingerprint || "ejecuta setup.ps1"}`);
      const open = () => {
        const pairing = companion.startPairing();
        console.log(`
Código de emparejamiento: ${pairing.code}  (vale ${pairing.expiresInSeconds} s y se usa una sola vez)`);
      };
      rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      if (rest.includes("--pair")) open();
      console.log("Escribe «pair» + Enter para abrir un emparejamiento nuevo, o «salir» para terminar.");
      rl.on("line", (line) => {
        const text = line.trim().toLowerCase();
        if (text === "pair") open();
        if (text === "salir") { rl.close(); companion.stop().then(() => process.exit(0)); }
      });
      break;
    }
    case "list": config.tokens.forEach((t) => console.log(`${t.id}  ${t.name}  creado ${t.createdAt}  último uso ${t.lastUsed || "nunca"}`)); break;
    case "revoke": console.log(companion.revoke(rest[0]) ? "Token revocado." : "No existe ese token."); break;
    case "allow-folder": {
      const [label, folder] = rest;
      if (!label || !folder || !fs.existsSync(folder)) { console.error("Uso: allow-folder <nombre> <carpeta existente>"); process.exit(1); }
      config.folders = config.folders.filter((f) => f.label !== label).concat({ label, path: path.resolve(folder) });
      companion.persist();
      console.log(`Carpeta «${label}» autorizada (solo lectura, sin secretos).`);
      break;
    }
    case "allow-repo": {
      if (!/^[\w.-]+\/[\w.-]+$/.test(rest[0] || "")) { console.error("Uso: allow-repo propietario/repositorio"); process.exit(1); }
      if (!config.repos.includes(rest[0])) config.repos.push(rest[0]);
      companion.persist();
      console.log(`Repositorio ${rest[0]} autorizado (solo consultar ejecuciones).`);
      break;
    }
    case "allow-script": {
      const [name, file] = rest;
      if (!name || !file || !fs.existsSync(file)) { console.error("Uso: allow-script <nombre> <archivo.ps1>"); process.exit(1); }
      config.scripts[name] = { path: path.resolve(file), sha256: sha256Hex(fs.readFileSync(file)) };
      companion.persist();
      console.log(`Script «${name}» aprobado con su huella actual. Si el archivo cambia, hay que aprobarlo otra vez.`);
      break;
    }
    case "send": companion.addToOutbox(rest.join(" ")); console.log("Mensaje en la bandeja: el iPhone lo recibirá la próxima vez que consulte."); break;
    default:
      console.log("Uso: node server.js <start [--pair]|list|revoke <id>|allow-folder <nombre> <carpeta>|allow-repo <o/r>|allow-script <nombre> <archivo>|send <texto>>");
  }
}

module.exports = { createCompanion, isPrivateAddress, sha256Hex, loadConfig, saveConfig, defaultDataDir, VERSION };

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => { console.error(error.message); process.exit(1); });
}
