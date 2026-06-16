// Silent sync (drill + LLM): connect to the persistent logged-in OA Edge -> read 我的待办 categories ->
// drill into each category for the real item content -> LLM extract & summarize -> write into 智能分析 (source 【鲸+】).
const fs = require('fs');
const path = require('path');
const HERE = __dirname;
const PORT = process.env.OA_PORT || 9333;
const CDP = 'http://127.0.0.1:' + PORT;
const PROJ = process.env.OA_DASH_DIR || path.dirname(HERE);
const NEWZMP = 'https://zmp.iwhalecloud.com/newZmp';
const TODO_JSP = 'https://zmp.iwhalecloud.com/fish-zmp/modules/todoItem/index.jsp';
const LOG = path.join(PROJ, 'logs', 'oa-sync.log');
const MAX_LOG_BYTES = 5 * 1024 * 1024;
const sleep = ms => new Promise(r => setTimeout(r, ms));
function log(...a) {
  const line = '[' + new Date().toISOString() + '] ' + a.join(' ');
  console.log(line);
  try {
    const dir = path.dirname(LOG);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    if (fs.existsSync(LOG) && fs.statSync(LOG).size > MAX_LOG_BYTES) {
      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15);
      fs.renameSync(LOG, LOG.replace(/\.log$/, '.' + stamp + '.log'));
    }
    fs.appendFileSync(LOG, line + '\n');
  } catch (e) {}
}
const TD = () => { const d = new Date(); const p = n => String(n).padStart(2, '0'); return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()); };
const rid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
// 稳定去重 key：优先用业务编号(bizId)，否则取 detail 中较长数字串(单号/工号)作指纹，再退化为标题；不依赖大模型每次的措辞
function oaKey(b) {
  const it = b.it || {};
  let sig = String(it.bizId || '').replace(/[^0-9A-Za-z]/g, '');
  if (!sig) { const nums = (String(it.detail || '').match(/\d{4,}/g) || []).join('-'); sig = nums || String(it.title || '').replace(/\s+/g, ''); }
  return ('oa|' + b.cat + '|' + sig).toLowerCase();
}

async function writeStatus(ok, message, analyzed) {
  try {
    const port = fs.readFileSync(path.join(PROJ, '.port.txt'), 'utf8').trim();
    const DASH = 'http://127.0.0.1:' + port;
    const raw = await (await fetch(DASH + '/api/state')).text();
    const st = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
    st.settings = st.settings || {};
    st.settings['oa_last_status'] = { at: new Date().toISOString(), ok: ok, message: message };
    if (analyzed) st.settings['oa_last_analyzed'] = new Date().toISOString();
    st.updatedAt = new Date().toISOString();
    const payload = Buffer.from(JSON.stringify(st), 'utf8').toString('base64');
    await fetch(DASH + '/api/state', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ payload }) });
  } catch (e) {}
}
let ws, sendRaw; let id = 0; const pend = new Map();
function send(m, p = {}) { return new Promise((res, rej) => { const i = ++id; pend.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method: m, params: p })); }); }

async function connect() {
  let list; try { list = await (await fetch(CDP + '/json')).json(); } catch (e) { log('OA browser not running on ' + PORT + ' -> run oa-start.bat'); await writeStatus(false, '常驻 OA 浏览器未运行（请运行 oa-start.bat 或重启看板）'); process.exit(4); }
  const p = list.filter(t => t.type === 'page');
  const pg = p.find(x => (x.url || '').includes('zmp.iwhalecloud.com')) || p.find(x => (x.url || '').includes('iwhalecloud')) || p[0];
  if (!pg) { log('no OA tab'); await writeStatus(false, '未找到 OA 标签页'); process.exit(4); }
  ws = new WebSocket(pg.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  ws.onmessage = async ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { const q = pend.get(m.id); pend.delete(m.id); m.error ? q.rej(new Error(JSON.stringify(m.error))) : q.res(m.result); return; }
    if (onEvent) onEvent(m);
  };
  await send('Page.enable'); await send('Network.enable'); await send('Runtime.enable');
}
let onEvent = null;

async function evalJs(expression) { const r = await send('Runtime.evaluate', { expression, returnByValue: true }); return r.result.value; }

async function getCategories() {
  await send('Page.navigate', { url: TODO_JSP }); await sleep(9000);
  const href = await evalJs('location.href');
  if (/jinglian|\/login|oauth2|passport/i.test(href)) { log('SESSION EXPIRED -> re-login (oa-start.bat)'); await writeStatus(false, 'OA 登录已过期，请重新登录（还原 OA 窗口或运行 oa-start.bat 完成飞连登录）'); process.exit(3); }
  const expr = `(()=>{const pick=[];document.querySelectorAll('.list-group-item, li, [orderCode]').forEach(el=>{const text=(el.innerText||'').replace(/\\s+/g,' ').trim();if(!text)return;if(!/待办|待处理|待审|待提交|你有|审批|流程|事务|未读/i.test(text))return;const a=el.querySelector('a');pick.push({text,order:el.getAttribute('orderCode')||'',href:a?(a.getAttribute('href')||''):''});});const seen=new Set(),out=[];pick.forEach(x=>{if(!seen.has(x.text)){seen.add(x.text);out.push(x);}});return JSON.stringify(out);})()`;
  return JSON.parse(await evalJs(expr));
}

// drill into a category menuLink, return concise visible content of the item list
async function drill(cat) {
  const url = NEWZMP + (cat.href.startsWith('#') ? cat.href : ('#' + cat.href));
  let cap = []; const reqs = new Map();
  onEvent = async m => {
    if (m.method === 'Network.responseReceived') { const { requestId, response, type } = m.params; reqs.set(requestId, { url: response.url, mime: response.mimeType, type }); }
    if (m.method === 'Network.loadingFinished') { const info = reqs.get(m.params.requestId); if (info && /callQueryService|queryService|\.do/.test(info.url) && (info.type === 'XHR' || info.type === 'Fetch' || /json/i.test(info.mime || ''))) { try { const b = await send('Network.getResponseBody', { requestId: m.params.requestId }); let body = b.base64Encoded ? Buffer.from(b.body, 'base64').toString('utf8') : b.body; if (body && body.length < 400000) cap.push({ url: info.url, len: body.length, body }); } catch (e) {} } }
  };
  await send('Page.navigate', { url: 'about:blank' }); await sleep(800);
  await send('Page.navigate', { url }); await sleep(13000);
  onEvent = null;
  // visible list text from the module iframe (strip the staff sidebar)
  let iframeText = '';
  try { iframeText = await evalJs(`(()=>{try{const f=document.querySelector('iframe');const d=f&&f.contentDocument;if(!d)return '';let t=(d.body.innerText||'').replace(/\\s+/g,' ');const i=t.indexOf('等待处理');return (i>=0?t.slice(i):t).slice(0,6000);}catch(e){return ''}})()`) || ''; } catch (e) {}
  const data = cap.sort((a, b) => b.len - a.len)[0];
  return { iframeText, dataSample: data ? data.body.slice(0, 12000) : '' };
}

function llmCfg(state) { const s = state.settings || {}; return { url: (s.llm_url || '').replace(/\/+$/, ''), key: s.llm_key, model: s.llm_model }; }
async function llmExtract(cfg, catName, content) {
  const sys = '你是HRBP工作助手。下面是我在OA系统【鲸+】中"' + catName + '"的待办列表页面内容（可能含表格行、字段、状态）。请提取每一条【实际待处理事项】，忽略员工筛选侧栏、菜单、按钮、表头。只输出严格的JSON数组，每个元素：{"bizId":"该事项的唯一业务标识，优先取单号/工单号/工号/申请编号等数字编号(原样保留数字)，没有则留空","title":"简短标题(20字内)","summary":"一句话总结该事项(30字内)","detail":"该事项的关键实际内容，原文摘录(申请人/单号/日期/金额/事由/状态等)"}。没有可提取事项时输出 []。';
  const r = await fetch(cfg.url + '/chat/completions', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + cfg.key }, body: JSON.stringify({ model: cfg.model, messages: [{ role: 'system', content: sys }, { role: 'user', content: content.slice(0, 9000) }], max_tokens: 1800, temperature: 0.2 }) });
  if (!r.ok) throw new Error('LLM HTTP ' + r.status);
  const d = await r.json();
  const txt = (d.choices && d.choices[0] && d.choices[0].message && d.choices[0].message.content) || '';
  const m = txt.match(/\[[\s\S]*\]/); if (!m) return [];
  try { const arr = JSON.parse(m[0]); return Array.isArray(arr) ? arr : []; } catch (e) { return []; }
}

async function main() {
  await connect();
  const port = fs.readFileSync(path.join(PROJ, '.port.txt'), 'utf8').trim();
  const DASH = 'http://127.0.0.1:' + port;
  const raw = await (await fetch(DASH + '/api/state')).text();
  const state = JSON.parse(raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw);
  state.settings = state.settings || {};
  const cfg = llmCfg(state);
  const cats = await getCategories();
  log('categories:', cats.length, '|', cats.map(c => c.text).join(' / '));

  const built = [];
  for (const cat of cats) {
    if (!cat.href) continue;
    const mb = cat.text.match(/【(.+?)】/);
    let catName = mb ? mb[1] : cat.text.replace(/(待我处理|待您处理|有待您处理|有待我处理|待处理|待审批|待审核).*$/, '').replace(/\s*\d+\s*条.*$/, '').trim();
    if (!catName) catName = cat.text.replace(/\s*\d+\s*条.*$/, '').trim();
    let content = '';
    try { const d = await drill(cat); content = (d.iframeText || '') + '\n' + (d.dataSample || ''); } catch (e) { log('drill fail', catName, e.message); }
    let items = [];
    if (cfg.url && cfg.key && cfg.model && content.trim().length > 40) {
      try { items = await llmExtract(cfg, catName, content); log('LLM', catName, '->', items.length, 'items'); } catch (e) { log('LLM fail', catName, e.message); }
    }
    if (!items.length) { items = [{ title: cat.text, summary: cat.text, detail: (content || cat.text).slice(0, 500) }]; }
    items.forEach(it => built.push({ cat: catName, href: cat.href, it }));
  }

  // re-fetch latest state right before writing, so concurrent settings/suggestion changes during the long
  // drill+LLM are NOT clobbered (we only touch _aiSugs + oa_last_*).
  let fresh = state;
  try { const raw2 = await (await fetch(DASH + '/api/state')).text(); fresh = JSON.parse(raw2.charCodeAt(0) === 0xFEFF ? raw2.slice(1) : raw2); } catch (e) {}
  fresh.settings = fresh.settings || {};
  // 增量同步：本次抓取的每条算稳定 key；已存在的(任意状态)跳过不重复，OA端已消失的未处理项清理
  const curr = built.map(b => ({ key: oaKey(b), b }));
  const currKeys = new Set(curr.map(x => x.key));
  let sugs = fresh.settings['_aiSugs'] || [];
  const beforeLen = sugs.length;
  // 清理：鲸+ 且仍未处理(pending)、但本次 OA 已不存在的 → 删除；已采纳/已忽略一律保留
  sugs = sugs.filter(s => !(s.sourceKind === 'oa' && s.state === 'pending' && !currKeys.has(s.key)));
  const removed = beforeLen - sugs.length;
  // 已存在的 key（无论 pending/已采纳/已忽略）→ 不重复新增
  const existing = new Set(sugs.filter(s => s.sourceKind === 'oa').map(s => s.key));
  let added = 0; const today = TD();
  for (const x of curr) {
    if (existing.has(x.key)) continue;
    existing.add(x.key);
    const b = x.b, it = b.it;
    const title = String(it.title || b.cat).slice(0, 60);
    const link = b.href ? ('https://zmp.iwhalecloud.com/newZmp' + (b.href.startsWith('#') ? b.href : '#' + b.href)) : NEWZMP;
    const detail = String(it.detail || '').trim() + '\n来源类别：' + b.cat + '\n链接：' + link;
    sugs.push({ id: rid(), key: x.key, type: 'todo', direction: 'to_me', title, person: { name: '', jobNumber: '', ext: true }, date: today, start: '', end: '', deadlineAt: '', priority: 'medium', summary: String(it.summary || title).slice(0, 120), conv: b.cat, convType: 'oa', sourceKind: 'oa', detail, createdAt: new Date().toISOString(), state: 'pending' });
    added++;
  }
  if (sugs.length > 200) sugs = sugs.slice(-200);
  fresh.settings['_aiSugs'] = sugs;
  fresh.settings['oa_last_analyzed'] = new Date().toISOString();
  fresh.settings['oa_last_status'] = { at: new Date().toISOString(), ok: true, message: (added > 0 ? ('同步完成，新增 ' + added + ' 条待办') : '同步完成，无新增待办') + (removed > 0 ? ('，清理 ' + removed + ' 条已不存在') : '') };
  fresh.updatedAt = new Date().toISOString();
  const payload = Buffer.from(JSON.stringify(fresh), 'utf8').toString('base64');
  const r = await fetch(DASH + '/api/state', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ payload }) });
  log('dashboard sync status', r.status, '| items added', added);
  try { ws.close(); } catch (e) {}
}
main().then(() => process.exit(0)).catch(async e => { const msg = (e && e.message) || String(e); log('ERR', msg); try { ws && ws.close(); } catch (x) {} try { await writeStatus(false, '同步异常：' + msg); } catch (x) {} process.exit(2); });
