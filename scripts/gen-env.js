#!/usr/bin/env node
// Generate the environment file for a Hostinger deployment.
//
//   node gen-env.js <app-dir> > /tmp/APP-ENV.txt
//
// Reads which variables the app actually uses out of its source — a template
// listing variables the code does not read (and missing ones it does) is how
// deploys end up half-configured. Secrets are generated here; database values
// are placeholders, because only the panel knows them.
//
// The output is a secret. Send it privately, never commit it.
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, extname } from 'node:path';
import { randomBytes } from 'node:crypto';

const APP = process.argv[2] || '.';
const SKIP = new Set(['node_modules', '.git', 'dist', 'build', '.next', 'venv', 'coverage']);

/** Every process.env.X the app's own source mentions. */
function scan(dir, found = new Set(), depth = 0) {
  if (depth > 4) return found;
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name) || name.startsWith('.')) continue;
    const p = join(dir, name);
    let st;
    try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) { scan(p, found, depth + 1); continue; }
    if (!['.js', '.ts', '.mjs', '.cjs', '.tsx'].includes(extname(name))) continue;
    const src = readFileSync(p, 'utf8');
    for (const m of src.matchAll(/process\.env\.([A-Z][A-Z0-9_]*)/g)) found.add(m[1]);
    for (const m of src.matchAll(/process\.env\[['"]([A-Z][A-Z0-9_]*)['"]\]/g)) found.add(m[1]);
  }
  return found;
}

const hex = () => randomBytes(32).toString('hex');
const password = () => randomBytes(18).toString('base64').replace(/[^a-zA-Z0-9]/g, '').slice(0, 20);

// Variables whose value we can safely generate, and what they are for.
const GENERATED = {
  EVENT_TICKET_MASTER_KEY: [hex, 'กุญแจสำหรับสร้าง Ticket ID — เปลี่ยนแล้ว Ticket ID เดิมยืนยันไม่ได้'],
  LOG_HMAC_SECRET:         [hex, 'กุญแจเซ็น Audit Log — เปลี่ยนแล้วสายประวัติเดิมตรวจไม่ผ่านทั้งเส้น'],
  AUDIT_KEY:               [hex, 'กุญแจเซ็นสายประวัติ — ตั้งครั้งเดียวก่อนใช้จริง'],
  SESSION_SECRET:          [hex, 'กุญแจเซสชัน'],
  ADMIN_PASSWORD:          [password, 'รหัสผ่านผู้ดูแล — ไม่ตั้ง = ใช้ค่าตั้งต้นที่อยู่ในซอร์สโค้ด'],
  INTEGRATION_API_KEY:     [hex, 'กุญแจให้ระบบอื่นเรียก API'],
};

// Variables the deployer must fill in, with the value they should carry.
const PLACEHOLDER = {
  DATABASE_URL:   ['mysql://USER:PASSWORD@localhost:3306/DATABASE', 'ระวังอักขระพิเศษในรหัสผ่าน — ถ้ามี ใช้ DB_* แยกตัวแทน'],
  DB_HOST:        ['localhost', ''],
  DB_PORT:        ['3306', ''],
  DB_USER:        ['uXXXXXXXX_app', 'ชื่อเต็มพร้อม prefix จาก hPanel'],
  DB_PASSWORD:    ['<รหัสผ่านจาก hPanel>', ''],
  DB_NAME:        ['uXXXXXXXX_app', 'ชื่อเต็มพร้อม prefix จาก hPanel'],
  PORT:           ['3000', 'ใส่เฉพาะกรณีโฮสต์ไม่ inject ให้เอง'],
  ALLOWED_ORIGIN: ['https://app.example.com', 'โดเมนที่เรียก API ได้'],
  ALLOWED_ORIGINS:['https://app.example.com', 'คั่นด้วยจุลภาคถ้ามีหลายโดเมน'],
  BASE_PATH:      ['/app', 'เฉพาะกรณีติดตั้งใต้โฟลเดอร์ย่อย — ต้องตั้งทั้งตอน build และตอน run'],
  AUDIT_ANCHOR_WEBHOOK_URL: ['https://…', 'ส่ง hash ปลายสาย audit ออกนอกเครื่อง — ไม่ตั้ง = เขียนสายใหม่ทั้งเส้นแล้วตรวจไม่พบ'],
};

const used = scan(APP);
const out = [];
out.push(`# Environment — ${APP}`);
out.push('# ตั้งใน panel ของแอป ก่อน deploy รอบแรก');
out.push('# ส่งไฟล์นี้ทางช่องทางส่วนตัว อย่า commit ลง git');
out.push(`# สร้างเมื่อ ${new Date().toISOString()}`);
out.push('');

const emit = (title, names, table, optional = false) => {
  const present = names.filter((n) => used.has(n));
  if (!present.length) return;
  out.push(`# --- ${title} ---`);
  for (const n of present) {
    const [v, note] = table[n];
    if (note) out.push(`# ${note}`);
    const value = typeof v === 'function' ? v() : v;
    out.push(`${optional ? '# ' : ''}${n}=${value}`);
  }
  out.push('');
};

emit('ฐานข้อมูล: กรอกจาก hPanel', ['DATABASE_URL', 'DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASSWORD', 'DB_NAME'], PLACEHOLDER);
emit('กุญแจและรหัสผ่าน: สุ่มมาให้แล้ว ใช้ได้ทันที', Object.keys(GENERATED), GENERATED);
emit('การเข้าถึงและที่อยู่', ['PORT', 'ALLOWED_ORIGIN', 'ALLOWED_ORIGINS'], PLACEHOLDER);
emit('ไม่บังคับ — เอาเครื่องหมาย # ออกถ้าจะใช้', ['BASE_PATH', 'AUDIT_ANCHOR_WEBHOOK_URL'], PLACEHOLDER, true);

const known = new Set([...Object.keys(GENERATED), ...Object.keys(PLACEHOLDER)]);
const ignore = new Set(['NODE_ENV', 'HOST', 'PWD', 'HOME', 'TMPDIR', 'npm_config_prefix']);
const rest = [...used].filter((n) => !known.has(n) && !ignore.has(n)).sort();
if (rest.length) {
  out.push('# --- ตัวแปรอื่นที่โค้ดอ่าน (ตรวจว่าต้องตั้งไหม) ---');
  for (const n of rest) out.push(`# ${n}=`);
  out.push('');
}

out.push('# หมายเหตุ: อย่าใส่เครื่องหมายคำพูดคร่อมค่า และอย่าให้มีช่องว่างติดท้าย');
out.push('# ค่าที่แก้แล้วยังไม่เข้า ให้ลบตัวแปรทิ้งแล้วสร้างใหม่ แทนการแก้ทับ');
console.log(out.join('\n'));
