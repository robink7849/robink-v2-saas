/**
 * Robink V2 SaaS Backend
 * - Express + JWT + bcrypt
 * - DB: JSON dosya (lokal) VEYA PostgreSQL (DATABASE_URL set ise - Render/Supabase)
 * - Pairing codes for device registration
 * - Command queue: web -> DB -> agent -> result
 */

const express = require('express');
const http = require('http');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');

const app = express();
const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'robink-v2-dev-secret-please-change';
const USE_PG = !!process.env.DATABASE_URL;
const PUBLIC_DIR = path.join(__dirname, '..', 'web');
const AGENT_DIR  = path.join(__dirname, '..', 'agent');
const PAIRING_TTL_MS = 1000 * 60 * 10; // 10 minutes
const AGENT_OFFLINE_AFTER_MS = 1000 * 30; // 30 seconds without poll = offline

let db;   // db-pg veya db-json modulu

app.use(express.json({ limit: '1mb' }));

// ---------- DB INITIALIZATION ----------
function emptyDb() { return { users: [], devices: [], pairing_codes: [], commands: [] }; }
function dbRead() {
  try { return JSON.parse(fs.readFileSync(process.env.DATA_FILE || path.join(__dirname, 'data.json'), 'utf8')); }
  catch { return emptyDb(); }
}
function dbWrite(d) {
  const f = process.env.DATA_FILE || path.join(__dirname, 'data.json');
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, JSON.stringify(d, null, 2));
}
function dbMutate(fn) { const d = dbRead(); const r = fn(d); dbWrite(d); return r; }

function genId() { return crypto.randomBytes(16).toString('hex'); }
function genCode() {
  // 6 karakter, kolay okunur (0/O/1/I yok)
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let s = '';
  for (let i = 0; i < 6; i++) s += alphabet[Math.floor(Math.random() * alphabet.length)];
  return s;
}

// ============================================================
// DB MODULE: pg (Supabase / Render PG) VEYA json (legacy local)
// ============================================================
function makeJsonDb() {
  return {
    initSchema: async () => {},
    findUserByUsername: async (ul) => {
      const d = dbRead(); return d.users.find(u => u.username.toLowerCase() === ul) || null;
    },
    findUserById: async (id) => {
      const d = dbRead(); return d.users.find(u => u.id === id) || null;
    },
    insertUser: async (u) => dbMutate(d => d.users.push(u)),
    listDevicesByUser: async (uid) => dbRead().devices.filter(d => d.user_id === uid),
    findDeviceById: async (id) => dbRead().devices.find(d => d.id === id) || null,
    findDeviceByCredentials: async (did, tok) => {
      const d = dbRead(); return d.devices.find(x => x.id === did && x.token === tok) || null;
    },
    insertDevice: async (dev) => dbMutate(d => d.devices.push(dev)),
    updateDeviceLastSeen: async (id, ts) => dbMutate(d => { const x = d.devices.find(y => y.id === id); if (x) x.last_seen = ts; }),
    deleteDevice: async (id) => dbMutate(d => { d.devices = d.devices.filter(x => x.id !== id); }),
    pruneExpiredCodes: async (now) => dbMutate(d => { d.pairing_codes = d.pairing_codes.filter(c => c.expires_at > now && !c.used_at); }),
    insertPairingCode: async (p) => dbMutate(d => d.pairing_codes.push(p)),
    findPairingCode: async (code) => dbRead().pairing_codes.find(c => c.code === code) || null,
    markPairingUsed: async (code, usedAt, did) => dbMutate(d => {
      const p = d.pairing_codes.find(c => c.code === code);
      if (p) { p.used_at = usedAt; p.device_id = did; }
    }),
    listCommandsByUser: async (uid, did, limit = 50) => {
      let cmds = dbRead().commands.filter(c => c.user_id === uid);
      if (did) cmds = cmds.filter(c => c.device_id === did);
      return cmds.sort((a, b) => b.created_at - a.created_at).slice(0, limit);
    },
    findCommandById: async (id, uid) => dbRead().commands.find(c => c.id === id && c.user_id === uid) || null,
    insertCommand: async (c) => dbMutate(d => d.commands.push(c)),
    countCommandsByUser: async (uid) => dbRead().commands.filter(c => c.user_id === uid).length,
    listPendingByDevice: async (did) => dbRead().commands.filter(c => c.device_id === did && c.status === 'pending'),
    markCommandsRunning: async (ids, now) => dbMutate(d => {
      for (const cmd of d.commands) {
        if (ids.includes(cmd.id)) { cmd.status = 'running'; cmd.started_at = now; }
      }
    }),
    finishCommand: async (cid, fields) => dbMutate(d => {
      const c = d.commands.find(x => x.id === cid);
      if (c) Object.assign(c, fields);
    }),
    findCommandForDevice: async (cid, did) => dbRead().commands.find(c => c.id === cid && c.device_id === did) || null,
    cancelOpenForDevice: async (did, now) => dbMutate(d => {
      for (const c of d.commands) {
        if (c.device_id === did && (c.status === 'pending' || c.status === 'running')) {
          c.status = 'cancelled'; c.finished_at = now;
        }
      }
    }),
  };
}

async function initDb() {
  if (USE_PG) {
    db = require('./db-pg');
    await db.initSchema();
    console.log('[Robink V2] PostgreSQL modu aktif');
  } else {
    db = makeJsonDb();
    console.log('[Robink V2] JSON modu aktif (lokal)');
  }
}

// ---------- AUTH ----------
function signToken(user) {
  return jwt.sign({ uid: user.id, username: user.username }, JWT_SECRET, { expiresIn: '30d' });
}
async function webAuth(req, res, next) {
  const h = req.headers.authorization;
  if (!h || !h.startsWith('Bearer ')) return res.status(401).json({ ok: false, error: 'Yetkisiz' });
  try {
    const payload = jwt.verify(h.slice(7), JWT_SECRET);
    const user = await db.findUserById(payload.uid);
    if (!user) return res.status(401).json({ ok: false, error: 'Kullanici bulunamadi' });
    req.user = user;
    next();
  } catch {
    return res.status(401).json({ ok: false, error: 'Token gecersiz' });
  }
}

// ---------- ROUTES ----------

// Health
app.get('/api/health', (req, res) => res.json({ ok: true, ts: Date.now(), mode: USE_PG ? 'postgres' : 'json' }));

// Signup
app.post('/api/signup', async (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) return res.status(400).json({ ok: false, error: 'Kullanici adi ve sifre gerekli' });
  if (username.length < 3 || password.length < 4) return res.status(400).json({ ok: false, error: 'Kullanici adi en az 3, sifre en az 4 karakter' });
  const usernameLower = username.toLowerCase();
  const existing = await db.findUserByUsername(usernameLower);
  if (existing) return res.status(400).json({ ok: false, error: 'Bu kullanici adi alinmis' });
  const hash = await bcrypt.hash(password, 8);
  const user = { id: genId(), username, password_hash: hash, created_at: Date.now() };
  await db.insertUser(user);
  const token = signToken(user);
  res.json({ ok: true, token, user: { id: user.id, username: user.username } });
});

// Login
app.post('/api/login', async (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) return res.status(400).json({ ok: false, error: 'Kullanici adi ve sifre gerekli' });
  const user = await db.findUserByUsername(username.toLowerCase());
  if (!user) return res.status(401).json({ ok: false, error: 'Kullanici adi veya sifre yanlis' });
  const ok = await bcrypt.compare(password, user.password_hash);
  if (!ok) return res.status(401).json({ ok: false, error: 'Kullanici adi veya sifre yanlis' });
  const token = signToken(user);
  res.json({ ok: true, token, user: { id: user.id, username: user.username } });
});

// State (auth info)
app.get('/api/state', webAuth, async (req, res) => {
  const devices = (await db.listDevicesByUser(req.user.id)).map(d => ({
    id: d.id,
    name: d.name,
    lastSeen: d.last_seen,
    isOnline: Date.now() - d.last_seen < AGENT_OFFLINE_AFTER_MS,
    createdAt: d.created_at,
  }));
  const totalCommands = await db.countCommandsByUser(req.user.id);
  res.json({ ok: true, username: req.user.username, devices, totalCommands });
});

// Generate pairing code
app.post('/api/pairing/generate', webAuth, async (req, res) => {
  const now = Date.now();
  await db.pruneExpiredCodes(now);
  const code = genCode();
  const pair = {
    code,
    created_by: req.user.id,
    created_at: now,
    expires_at: now + PAIRING_TTL_MS,
    used_at: null,
    device_id: null,
  };
  await db.insertPairingCode(pair);
  res.json({ ok: true, code, expiresAt: pair.expires_at });
});

// Pair: ajan bu endpoint'i cagirarak kayit olur
app.post('/api/agent/pair', async (req, res) => {
  const { code, name } = req.body || {};
  if (!code || !name) return res.status(400).json({ ok: false, error: 'Code ve cihaz adi gerekli' });
  const pair = await db.findPairingCode(code.toUpperCase());
  if (!pair) return res.status(404).json({ ok: false, error: 'Gecersiz veya kullanilmis kod' });
  if (pair.expires_at < Date.now()) return res.status(410).json({ ok: false, error: 'Kodun suresi dolmus' });
  if (pair.used_at) return res.status(410).json({ ok: false, error: 'Bu kod zaten kullanilmis' });

  const device = {
    id: genId(),
    user_id: pair.created_by,
    name: String(name).slice(0, 40),
    token: genId(),
    last_seen: Date.now(),
    created_at: Date.now(),
  };
  await db.insertDevice(device);
  await db.markPairingUsed(pair.code, Date.now(), device.id);
  res.json({ ok: true, deviceId: device.id, deviceToken: device.token });
});

// Ajan: komutlari al
app.post('/api/agent/poll', async (req, res) => {
  const { deviceId, deviceToken } = req.body || {};
  if (!deviceId || !deviceToken) return res.status(401).json({ ok: false, error: 'Cihaz kimligi gerekli' });
  const device = await db.findDeviceByCredentials(deviceId, deviceToken);
  if (!device) return res.status(401).json({ ok: false, error: 'Gecersiz cihaz' });
  const now = Date.now();
  await db.updateDeviceLastSeen(deviceId, now);
  const pending = await db.listPendingByDevice(deviceId);
  await db.markCommandsRunning(pending.map(c => c.id), now);
  res.json({
    ok: true,
    isOnline: true,
    commands: pending.map(c => ({ id: c.id, itemN: c.item_n })),
  });
});

// Ajan: sonucu gonder
app.post('/api/agent/result', async (req, res) => {
  const { deviceId, deviceToken, commandId, ok, output, error, exitCode, durationMs, cancelled } = req.body || {};
  if (!deviceId || !deviceToken || !commandId) return res.status(400).json({ ok: false, error: 'Eksik parametre' });
  const device = await db.findDeviceByCredentials(deviceId, deviceToken);
  if (!device) return res.status(401).json({ ok: false, error: 'Gecersiz cihaz' });
  const cmd = await db.findCommandForDevice(commandId, deviceId);
  if (!cmd) return res.status(404).json({ ok: false, error: 'Komut bulunamadi' });
  await db.finishCommand(commandId, {
    status: cancelled ? 'cancelled' : (ok ? 'done' : 'failed'),
    output: output || '',
    error: error || null,
    exit_code: exitCode ?? null,
    duration_ms: durationMs ?? null,
    finished_at: Date.now(),
  });
  res.json({ ok: true });
});

// Web: yeni komut olustur
app.post('/api/commands', webAuth, async (req, res) => {
  const { deviceId, itemN } = req.body || {};
  if (!deviceId || !itemN) return res.status(400).json({ ok: false, error: 'Cihaz ve oge no gerekli' });
  const device = await db.findDeviceById(deviceId);
  if (!device || device.user_id !== req.user.id) return res.status(404).json({ ok: false, error: 'Cihaz bulunamadi veya size ait degil' });
  const cmd = {
    id: genId(),
    device_id: deviceId,
    user_id: req.user.id,
    item_n: parseInt(itemN, 10),
    status: 'pending',
    output: null,
    error: null,
    exit_code: null,
    duration_ms: null,
    created_at: Date.now(),
    started_at: null,
    finished_at: null,
  };
  await db.insertCommand(cmd);
  res.json({ ok: true, commandId: cmd.id });
});

// Web: tek bir komutun durumunu getir
app.get('/api/commands/:id', webAuth, async (req, res) => {
  const cmd = await db.findCommandById(req.params.id, req.user.id);
  if (!cmd) return res.status(404).json({ ok: false, error: 'Komut bulunamadi' });
  res.json({ ok: true, command: serializeCmd(cmd) });
});

// Web: son komutlar
app.get('/api/commands', webAuth, async (req, res) => {
  const deviceId = req.query.deviceId;
  const cmds = await db.listCommandsByUser(req.user.id, deviceId || null, 50);
  res.json({ ok: true, commands: cmds.map(serializeCmd) });
});

// Cihaz sil
app.delete('/api/devices/:id', webAuth, async (req, res) => {
  const now = Date.now();
  await db.cancelOpenForDevice(req.params.id, now);
  await db.deleteDevice(req.params.id);
  res.json({ ok: true });
});

function serializeCmd(cmd) {
  return {
    id: cmd.id,
    deviceId: cmd.device_id,
    itemN: cmd.item_n,
    status: cmd.status,
    output: cmd.output,
    error: cmd.error,
    exitCode: cmd.exit_code,
    durationMs: cmd.duration_ms,
    createdAt: cmd.created_at,
    startedAt: cmd.started_at,
    finishedAt: cmd.finished_at,
  };
}

// ---------- START ----------
// Static frontend (sona koy ki API routes oncelikli olsun)
app.use(express.static(PUBLIC_DIR));

// Ajan dosyalarini serve et — kullanicilar tek satir komutla indirebilsin
app.use('/agent', express.static(AGENT_DIR, {
  setHeaders: (res, p) => {
    if (p.endsWith('.ps1')) res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  },
  fallthrough: true,
}));

(async () => {
  try {
    await initDb();
    const server = http.createServer(app);
    server.listen(PORT, () => {
      console.log(`[Robink V2] API + frontend serving on http://localhost:${PORT}  (mode: ${USE_PG ? 'postgres' : 'json'})`);
    });
  } catch (e) {
    console.error('[Robink V2] Baslatma hatasi:', e);
    process.exit(1);
  }
})();
