/**
 * Robink V2 — PostgreSQL veritabani katmani (Supabase / Render PostgreSQL)
 * - JSON DB ile ayni arayuzu saglar
 * - Baglanti havuzu (pg.Pool) + SSL
 * - IPv4 zorlamasi: DNS'i manuel cozip IPv4 adresini dogrudan kullanir
 *   (pg 8.x "family" parametresini tanimiyor; bu yuzden onceden cozumleyip IP veriyoruz)
 */

const { Pool } = require('pg');
const dns = require('dns');
const dnsLookup = require('util').promisify(dns.lookup);

let pool = null;
let initPromise = null;

async function resolveIPv4(host) {
  // once IPv4 dene
  try {
    const r = await dnsLookup(host, { family: 4 });
    return r.address;
  } catch (e4) {
    // IPv4 yoksa, hostname'in IPv6'sini logla ve fallback olarak IPv6 dene
    console.warn(`[Robink V2 PG] IPv4 cozumleme basarisiz: ${host} — IPv6 deneniyor`);
    try {
      const r = await dnsLookup(host, { family: 6 });
      return r.address; // Son care: IPv6 — calismazsa Render'da ENETUNREACH
    } catch (e6) {
      throw new Error(`DNS basarisiz (IPv4 ve IPv6): ${host} — ${e4.message}`);
    }
  }
}

async function getPool() {
  if (pool) return pool;
  const cs = process.env.DATABASE_URL;
  if (!cs) throw new Error('DATABASE_URL ayarli degil (PostgreSQL modu icin zorunlu)');
  const sslOn = /supabase|render|sslmode=require|ssl=true/i.test(cs);

  // Manuel URL parse
  let host, port, database, user, password;
  try {
    const u = new URL(cs);
    host = u.hostname;
    port = parseInt(u.port || '5432', 10);
    database = (u.pathname || '/postgres').replace(/^\//, '') || 'postgres';
    user = decodeURIComponent(u.username || '');
    password = decodeURIComponent(u.password || '');
  } catch (e) {
    throw new Error(`DATABASE_URL parse hatasi: ${e.message}`);
  }

  // IPv4 zorlamasi: DNS'i IPv4 ile coz ve IP'yi dogrudan host olarak kullan
  // (pg 8.x'in "family" parametresini tanimamasi nedeniyle)
  const ipv4 = await resolveIPv4(host);
  console.log(`[Robink V2 PG] DNS: ${host} -> ${ipv4} (IPv4 zorlandi)`);

  pool = new Pool({
    host: ipv4,
    port,
    database,
    user,
    password,
    ssl: sslOn ? { rejectUnauthorized: false } : false,
    max: 10,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 15000,
  });
  pool.on('error', (e) => console.error('[Robink V2 PG] Pool hatasi:', e.message));
  return pool;
}

async function initSchema() {
  if (initPromise) return initPromise;
  initPromise = (async () => {
    const fs = require('fs');
    const path = require('path');
    const sql = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
    const p = getPool();
    // Supabase / Cloud PG bazen ilk anda yavas cevap verir; 3 denemelik retry ekleyelim
    let lastErr = null;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        await p.query(sql);
        console.log(`[Robink V2 PG] Schema basariyla yuklendi (deneme ${attempt})`);
        return;
      } catch (e) {
        lastErr = e;
        console.error(`[Robink V2 PG] Schema yukleme hatasi (deneme ${attempt}/3):`, e.message);
        if (attempt < 3) {
          await new Promise(r => setTimeout(r, 1500 * attempt));
        }
      }
    }
    throw lastErr;
  })().catch(e => {
    initPromise = null;
    throw e;
  });
  return initPromise;
}

async function q(sql, params) {
  const p = getPool();
  return p.query(sql, params);
}

// ---------- USERS ----------
async function findUserByUsername(usernameLower) {
  const r = await q('SELECT id, username, password_hash, created_at FROM users WHERE LOWER(username) = $1', [usernameLower]);
  return r.rows[0] || null;
}
async function findUserById(id) {
  const r = await q('SELECT id, username, password_hash, created_at FROM users WHERE id = $1', [id]);
  return r.rows[0] || null;
}
async function insertUser(user) {
  await q('INSERT INTO users (id, username, password_hash, created_at) VALUES ($1, $2, $3, $4)',
    [user.id, user.username, user.password_hash, user.created_at]);
}

// ---------- DEVICES ----------
async function listDevicesByUser(userId) {
  const r = await q('SELECT id, user_id, name, token, last_seen, created_at FROM devices WHERE user_id = $1 ORDER BY created_at DESC', [userId]);
  return r.rows;
}
async function findDeviceById(id) {
  const r = await q('SELECT id, user_id, name, token, last_seen, created_at FROM devices WHERE id = $1', [id]);
  return r.rows[0] || null;
}
async function findDeviceByCredentials(deviceId, token) {
  const r = await q('SELECT id, user_id, name, token, last_seen, created_at FROM devices WHERE id = $1 AND token = $2', [deviceId, token]);
  return r.rows[0] || null;
}
async function insertDevice(d) {
  await q('INSERT INTO devices (id, user_id, name, token, last_seen, created_at) VALUES ($1,$2,$3,$4,$5,$6)',
    [d.id, d.user_id, d.name, d.token, d.last_seen, d.created_at]);
}
async function updateDeviceLastSeen(id, ts) {
  await q('UPDATE devices SET last_seen = $1 WHERE id = $2', [ts, id]);
}
async function deleteDevice(id) {
  await q('DELETE FROM devices WHERE id = $1', [id]);
}

// ---------- PAIRING CODES ----------
async function pruneExpiredCodes(now) {
  await q('DELETE FROM pairing_codes WHERE expires_at < $1', [now]);
}
async function insertPairingCode(p) {
  await q('INSERT INTO pairing_codes (code, created_by, created_at, expires_at, used_at, device_id) VALUES ($1,$2,$3,$4,$5,$6)',
    [p.code, p.created_by, p.created_at, p.expires_at, p.used_at, p.device_id]);
}
async function findPairingCode(code) {
  const r = await q('SELECT code, created_by, created_at, expires_at, used_at, device_id FROM pairing_codes WHERE code = $1', [code]);
  return r.rows[0] || null;
}
async function markPairingUsed(code, usedAt, deviceId) {
  await q('UPDATE pairing_codes SET used_at = $1, device_id = $2 WHERE code = $3', [usedAt, deviceId, code]);
}

// ---------- COMMANDS ----------
async function listCommandsByUser(userId, deviceId, limit = 50) {
  let sql, params;
  if (deviceId) {
    sql = `SELECT id, device_id, user_id, item_n, status, output, error, exit_code, duration_ms,
                  created_at, started_at, finished_at
           FROM commands WHERE user_id = $1 AND device_id = $2
           ORDER BY created_at DESC LIMIT $3`;
    params = [userId, deviceId, limit];
  } else {
    sql = `SELECT id, device_id, user_id, item_n, status, output, error, exit_code, duration_ms,
                  created_at, started_at, finished_at
           FROM commands WHERE user_id = $1
           ORDER BY created_at DESC LIMIT $2`;
    params = [userId, limit];
  }
  const r = await q(sql, params);
  return r.rows;
}
async function findCommandById(id, userId) {
  const r = await q('SELECT id, device_id, user_id, item_n, status, output, error, exit_code, duration_ms, created_at, started_at, finished_at FROM commands WHERE id = $1 AND user_id = $2', [id, userId]);
  return r.rows[0] || null;
}
async function insertCommand(c) {
  await q(`INSERT INTO commands (id, device_id, user_id, item_n, status, output, error, exit_code, duration_ms, created_at, started_at, finished_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
    [c.id, c.device_id, c.user_id, c.item_n, c.status, c.output, c.error, c.exit_code, c.duration_ms, c.created_at, c.started_at, c.finished_at]);
}
async function countCommandsByUser(userId) {
  const r = await q('SELECT COUNT(*)::int AS c FROM commands WHERE user_id = $1', [userId]);
  return r.rows[0].c;
}
async function listPendingByDevice(deviceId) {
  const r = await q(`SELECT id, device_id, user_id, item_n, status, output, error, exit_code, duration_ms,
                          created_at, started_at, finished_at
                   FROM commands WHERE device_id = $1 AND status = 'pending' ORDER BY created_at ASC`, [deviceId]);
  return r.rows;
}
async function markCommandsRunning(ids, now) {
  if (ids.length === 0) return;
  await q(`UPDATE commands SET status = 'running', started_at = $1 WHERE id = ANY($2::text[])`, [now, ids]);
}
async function finishCommand(commandId, fields) {
  await q(`UPDATE commands
           SET status = $1, output = $2, error = $3, exit_code = $4, duration_ms = $5, finished_at = $6
           WHERE id = $7`,
    [fields.status, fields.output, fields.error, fields.exit_code, fields.duration_ms, fields.finished_at, commandId]);
}
async function findCommandForDevice(commandId, deviceId) {
  const r = await q('SELECT id FROM commands WHERE id = $1 AND device_id = $2', [commandId, deviceId]);
  return r.rows[0] || null;
}
async function cancelOpenForDevice(deviceId, now) {
  await q(`UPDATE commands SET status = 'cancelled', finished_at = $1
           WHERE device_id = $2 AND status IN ('pending', 'running')`, [now, deviceId]);
}

module.exports = {
  initSchema,
  findUserByUsername, findUserById, insertUser,
  listDevicesByUser, findDeviceById, findDeviceByCredentials,
  insertDevice, updateDeviceLastSeen, deleteDevice,
  pruneExpiredCodes, insertPairingCode, findPairingCode, markPairingUsed,
  listCommandsByUser, findCommandById, insertCommand, countCommandsByUser,
  listPendingByDevice, markCommandsRunning, finishCommand,
  findCommandForDevice, cancelOpenForDevice,
};
