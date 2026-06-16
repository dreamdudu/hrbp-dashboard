// 人员成本分析 —— 解析国际运营成本费用明细 xlsx，预聚合并写缓存。
// 零依赖：用内置 zlib 解 xlsx(ZIP) 内 sheet1.xml，按 <row> 流式扫描聚合。
// 由 dws_server 在上传后后台触发，也可手动: node parse_personnel_cost.js
'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const HERE = __dirname;
const PROJ = process.env.OA_DASH_DIR || path.dirname(HERE);
const CAT = 'personnel-cost';
const CAT_DIR = path.join(PROJ, 'data', 'analytics', CAT);
const FILES_DIR = path.join(CAT_DIR, 'files');
const AGG_PATH = path.join(CAT_DIR, '_agg.json');
const DETAIL_PATH = path.join(CAT_DIR, '_detail.jsonl');
const STATUS_PATH = path.join(CAT_DIR, '_status.json');
const LOG_DIR = path.join(PROJ, 'logs');
const LOG = path.join(LOG_DIR, 'analytics.log');

function ensureDir(d) { try { fs.mkdirSync(d, { recursive: true }); } catch (e) {} }
function log(...a) {
  ensureDir(LOG_DIR);
  try { if (fs.existsSync(LOG) && fs.statSync(LOG).size > 5 * 1024 * 1024) fs.renameSync(LOG, LOG.replace(/\.log$/, '.' + Date.now() + '.log')); } catch (e) {}
  const line = '[' + new Date().toISOString() + '] ' + a.join(' ') + '\n';
  try { fs.appendFileSync(LOG, line); } catch (e) {}
}
function writeStatus(obj) { try { ensureDir(CAT_DIR); fs.writeFileSync(STATUS_PATH, JSON.stringify(obj)); } catch (e) {} }

// ---- ZIP：定位并解压指定条目 ----
function readZipEntry(buf, wantName) {
  // 找 End Of Central Directory (0x06054b50)
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0 && i >= buf.length - 22 - 65536; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('ZIP EOCD not found');
  const cdCount = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16); // central directory offset
  for (let n = 0; n < cdCount; n++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) break;
    const method = buf.readUInt16LE(p + 10);
    const compSize = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOff = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen);
    if (name === wantName) {
      // 到 local header 计算数据起点
      if (buf.readUInt32LE(localOff) !== 0x04034b50) throw new Error('bad local header');
      const lNameLen = buf.readUInt16LE(localOff + 26);
      const lExtraLen = buf.readUInt16LE(localOff + 28);
      const dataStart = localOff + 30 + lNameLen + lExtraLen;
      const comp = buf.slice(dataStart, dataStart + compSize);
      if (method === 0) return comp;                 // stored
      if (method === 8) return zlib.inflateRawSync(comp); // deflate
      throw new Error('unsupported zip method ' + method);
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  throw new Error('entry not found: ' + wantName);
}

// ---- XML 小工具 ----
function decodeXml(s) {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'").replace(/&#(\d+);/g, function (m, d) { return String.fromCharCode(+d); })
    .replace(/&amp;/g, '&');
}
function colLetters(ref) { let r = ''; for (let i = 0; i < ref.length; i++) { const c = ref[i]; if (c >= 'A' && c <= 'Z') r += c; else break; } return r; }
// Excel 日期序列号 -> {year, month}（账期 A 列存为日期序列，如 45962 = 2025-11）
function serialToYM(serial) {
  const d = new Date(Math.round((serial - 25569) * 86400000));
  return { year: String(d.getUTCFullYear()), month: String(d.getUTCMonth() + 1).padStart(2, '0') };
}
// 依据账期范围生成规范文件名：整年=国际交付三部YYYY年度成本；部分月=YYYY年MM月[-MM月]成本；跨年=YYYY年MM月-YYYY年MM月成本
function canonicalName(minYM, maxYM) {
  const y1 = minYM.slice(0, 4), m1 = minYM.slice(4, 6), y2 = maxYM.slice(0, 4), m2 = maxYM.slice(4, 6);
  let base;
  if (y1 === y2) {
    if (m1 === '01' && m2 === '12') base = '国际交付三部' + y1 + '年度成本';
    else if (m1 === m2) base = '国际交付三部' + y1 + '年' + m1 + '月成本';
    else base = '国际交付三部' + y1 + '年' + m1 + '月-' + m2 + '月成本';
  } else {
    base = '国际交付三部' + y1 + '年' + m1 + '月-' + y2 + '年' + m2 + '月成本';
  }
  return base + '.xlsx';
}

// 解析一行的单元格 -> {列字母: 值}
const CELL_RE = /<c r="([A-Z]+)\d+"[^>]*?>(?:<is><t[^>]*>([\s\S]*?)<\/t><\/is>|<v>([\s\S]*?)<\/v>)?<\/c>/g;
function parseRow(rowXml) {
  const cells = {};
  let m;
  CELL_RE.lastIndex = 0;
  while ((m = CELL_RE.exec(rowXml))) {
    const col = m[1];
    if (m[2] !== undefined) cells[col] = decodeXml(m[2]);
    else if (m[3] !== undefined) cells[col] = m[3];
  }
  return cells;
}

// ---- 聚合容器 ----
function newYear() {
  return {
    total: 0, rows: 0, hrTotal: 0,
    byFeeCat: {}, byFeeType: {}, byMonth: {}, byMonthHr: {}, hrByType: {},
    byEmpType: {}, byDept: {}, byDeliveryLine: {}, byProductLine: {}, byProject: {}, byCompany: {}
  };
}
function add(map, key, amt) { if (!key) key = '(空)'; map[key] = (map[key] || 0) + amt; }
function topN(map, n) {
  const arr = Object.keys(map).map(function (k) { return { name: k, value: map[k] }; }).sort(function (a, b) { return b.value - a.value; });
  if (arr.length <= n) return arr;
  const head = arr.slice(0, n);
  const rest = arr.slice(n).reduce(function (s, x) { return s + x.value; }, 0);
  if (rest > 0) head.push({ name: '其他', value: rest });
  return head;
}
function round2(x) { return Math.round(x * 100) / 100; }
function roundMap(map) { const o = {}; Object.keys(map).forEach(function (k) { o[k] = round2(map[k]); }); return o; }
function roundArr(arr) { return arr.map(function (x) { return { name: x.name, value: round2(x.value) }; }); }

const HR_CAT = '人力薪资';

function main() {
  const startedAt = new Date().toISOString();
  ensureDir(CAT_DIR);
  let files = [];
  try { files = fs.readdirSync(FILES_DIR).filter(function (f) { return /\.xlsx$/i.test(f); }); } catch (e) {}
  writeStatus({ state: 'parsing', files: files, rows: 0, years: [], startedAt: startedAt });
  log('parse start, files=' + files.length);

  if (!files.length) {
    writeStatus({ state: 'done', files: [], rows: 0, years: [], startedAt: startedAt, finishedAt: new Date().toISOString(), empty: true });
    try { fs.writeFileSync(AGG_PATH, JSON.stringify({ meta: { files: [], rowCount: 0, years: [], periods: [], generatedAt: new Date().toISOString() }, byYear: {} })); } catch (e) {}
    try { fs.writeFileSync(DETAIL_PATH, ''); } catch (e) {}
    log('no files, wrote empty');
    return;
  }

  const byYear = {};
  const periods = {};
  const outFiles = [];
  let totalRows = 0;
  const detailFd = fs.openSync(DETAIL_PATH, 'w');
  const ROW_END = Buffer.from('</row>');

  for (let fi = 0; fi < files.length; fi++) {
    let fname = files[fi];
    const fpath = path.join(FILES_DIR, fname);
    log('reading ' + fname);
    const buf = fs.readFileSync(fpath);
    let xml;
    try { xml = readZipEntry(buf, 'xl/worksheets/sheet1.xml'); } catch (e) { log('unzip fail ' + fname + ': ' + e.message); outFiles.push(fname); continue; }
    // 按 </row> 字节边界逐行切，避免整体字符串化
    let pos = 0, fileRows = 0, fMin = null, fMax = null;
    while (true) {
      const end = xml.indexOf(ROW_END, pos);
      if (end < 0) break;
      const rowXml = xml.toString('utf8', pos, end + ROW_END.length);
      pos = end + ROW_END.length;
      // 快速预筛：含数值单元格(t="n")的行才可能是数据行
      if (rowXml.indexOf('t="n"') < 0) continue;
      const cells = parseRow(rowXml);
      const aNum = parseFloat(cells['A']);
      if (!isFinite(aNum) || aNum < 40000 || aNum > 60000) continue; // A=账期(Excel日期序列号)
      const amt = parseFloat(cells['BG']);
      if (!isFinite(amt)) continue;
      const ym = serialToYM(aNum);
      const year = ym.year, month = ym.month, account = year + month;
      if (!fMin || account < fMin) fMin = account;
      if (!fMax || account > fMax) fMax = account;
      const feeCat = (cells['Z'] || '').trim();
      const feeType = (cells['AA'] || '').trim();
      const empType = (cells['C'] || '').trim();
      const dept = (cells['AH'] || '').trim();
      const deliveryLine = (cells['AV'] || '').trim();
      const productLine = (cells['AW'] || '').trim();
      const projName = (cells['Y'] || '').trim();
      const projCode = (cells['X'] || '').trim();
      const company = (cells['D'] || '').trim();
      const orgAttr = (cells['BF'] || '').trim();

      if (!byYear[year]) byYear[year] = newYear();
      const y = byYear[year];
      y.total += amt; y.rows++;
      add(y.byFeeCat, feeCat, amt);
      add(y.byFeeType, feeType, amt);
      add(y.byMonth, month, amt);
      add(y.byEmpType, empType, amt);
      add(y.byDept, dept, amt);
      add(y.byDeliveryLine, deliveryLine, amt);
      add(y.byProductLine, productLine, amt);
      add(y.byProject, projName, amt);
      add(y.byCompany, company, amt);
      if (feeCat === HR_CAT) { y.hrTotal += amt; add(y.byMonthHr, month, amt); add(y.hrByType, feeType, amt); }
      periods[account] = 1;
      totalRows++; fileRows++;

      // 精简明细
      fs.writeSync(detailFd, JSON.stringify({ a: account, y: year, m: month, et: empType, dp: dept, dl: deliveryLine, pc: projCode, pn: projName, fc: feeCat, ft: feeType, oa: orgAttr, amt: round2(amt) }) + '\n');
      if (totalRows % 5000 === 0) { writeStatus({ state: 'parsing', files: files, rows: totalRows, years: Object.keys(byYear).sort(), startedAt: startedAt }); }
    }
    // 依据账期范围重命名文件
    if (fMin && fMax) {
      const want = canonicalName(fMin, fMax);
      if (want !== fname) {
        let finalName = want, dst = path.join(FILES_DIR, want);
        if (fs.existsSync(dst)) {
          const stem = want.replace(/\.xlsx$/i, ''); let k = 2;
          while (fs.existsSync(path.join(FILES_DIR, stem + '(' + k + ').xlsx'))) k++;
          finalName = stem + '(' + k + ').xlsx'; dst = path.join(FILES_DIR, finalName);
        }
        try { fs.renameSync(fpath, dst); log('rename ' + fname + ' -> ' + finalName); fname = finalName; } catch (e) { log('rename fail ' + e.message); }
      }
    }
    outFiles.push(fname);
    log('file ' + fname + ' rows=' + fileRows);
  }
  fs.closeSync(detailFd);

  // 输出聚合（TopN + 取整）
  const TOPN = 30;
  const outYear = {};
  Object.keys(byYear).forEach(function (yr) {
    const y = byYear[yr];
    outYear[yr] = {
      total: round2(y.total), rows: y.rows, hrTotal: round2(y.hrTotal),
      hrRatio: y.total ? round2(y.hrTotal / y.total * 100) : 0,
      byFeeCat: roundMap(y.byFeeCat),
      byFeeType: roundArr(topN(y.byFeeType, TOPN)),
      hrByType: roundArr(topN(y.hrByType, TOPN)),
      byMonth: roundMap(y.byMonth),
      byMonthHr: roundMap(y.byMonthHr),
      byEmpType: roundArr(topN(y.byEmpType, TOPN)),
      byDept: roundArr(topN(y.byDept, TOPN)),
      byDeliveryLine: roundArr(topN(y.byDeliveryLine, TOPN)),
      byProductLine: roundArr(topN(y.byProductLine, TOPN)),
      byProject: roundArr(topN(y.byProject, TOPN)),
      byCompany: roundArr(topN(y.byCompany, TOPN))
    };
  });
  const years = Object.keys(byYear).sort();
  const agg = {
    meta: { files: outFiles, rowCount: totalRows, years: years, periods: Object.keys(periods).sort(), generatedAt: new Date().toISOString() },
    byYear: outYear
  };
  fs.writeFileSync(AGG_PATH, JSON.stringify(agg));
  writeStatus({ state: 'done', files: outFiles, rows: totalRows, years: years, startedAt: startedAt, finishedAt: new Date().toISOString() });
  log('parse done, rows=' + totalRows + ' years=' + years.join(','));
}

try { main(); } catch (e) {
  log('FATAL ' + (e && e.stack ? e.stack : e));
  writeStatus({ state: 'error', error: String(e && e.message ? e.message : e), finishedAt: new Date().toISOString() });
  process.exit(1);
}
