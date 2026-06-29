#!/usr/bin/env node
/*
 * AI 提示词库 全量离线爬虫（礼貌型 / 可断点续传）
 * 数据源：https://form.hrflag.com/WxSpAPI/AIGCDataPort/*  （aicamp.hrflag.com 提示词库的后端 API，公开、无需鉴权，POST 空体）
 *
 * 三层结构：
 *   1) 分类         GetPagedCategoriesWithCount   -> data/prompts/categories.json
 *   2) 分类下列表   GetPagedPromptsByCategory     -> data/prompts/cat/<catId>/list.json
 *   3) 提示词详情   GetPromptDetailsById          -> data/prompts/det/<catId>/<promptId>.json
 *
 * 设计要点：
 *   - 低速礼貌：低并发 + 每请求随机延时 + 指数退避重试；遇 403/429/5xx 长时间冷却，避免风控封号。
 *   - 断点续传：详情文件存在即跳过；列表已完整即跳过。可随时 Ctrl+C 中断后重跑续传。
 *   - 增量落盘：每条详情即时写文件，进度写 data/prompts/progress.json 供前端展示。
 *
 * 环境变量（可选）：
 *   CONC=2            并发数（默认 2）
 *   DMIN=550 DMAX=1100  每个 worker 单请求后随机延时区间(ms)
 *   ONLY=3,6          只爬指定 categoryId（逗号分隔）
 *   REFRESH=1         强制重爬列表与详情（忽略已有文件）
 */
const fs = require("fs");
const path = require("path");

const BASE = "https://form.hrflag.com";
const ROOT = path.join(__dirname, "data", "prompts");
const CAT_DIR = path.join(ROOT, "cat");
const DET_DIR = path.join(ROOT, "det");
const HEADERS = {
  "Content-Type": "application/x-www-form-urlencoded",
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  "Referer": "https://aicamp.hrflag.com/personal/prompts/library",
  "Origin": "https://aicamp.hrflag.com",
  "Accept": "application/json, text/plain, */*",
  "Accept-Language": "zh-CN,zh;q=0.9",
};

const CONC = Math.max(1, parseInt(process.env.CONC || "2", 10));
const DMIN = parseInt(process.env.DMIN || "550", 10);
const DMAX = parseInt(process.env.DMAX || "1100", 10);
const ONLY = (process.env.ONLY || "").split(",").map(s => s.trim()).filter(Boolean);
const REFRESH = process.env.REFRESH === "1";

const sleep = ms => new Promise(r => setTimeout(r, ms));
const jitter = () => DMIN + Math.floor(Math.random() * Math.max(1, DMAX - DMIN));
function ensure(d) { fs.mkdirSync(d, { recursive: true }); }
function writeJson(p, obj) { ensure(path.dirname(p)); fs.writeFileSync(p, JSON.stringify(obj), "utf8"); }
function exists(p) { try { return fs.statSync(p).size > 2; } catch (e) { return false; } }

let consecutiveBlocks = 0;
async function apiPost(url, tries = 5) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(BASE + url, { method: "POST", headers: HEADERS, body: "" });
      if (r.status === 200) {
        consecutiveBlocks = 0;
        return await r.json();
      }
      if (r.status === 401 || r.status === 403 || r.status === 429 || r.status >= 500) {
        consecutiveBlocks++;
        const cool = (r.status === 429 || r.status === 403) ? Math.min(300000, 30000 * consecutiveBlocks) : (2000 * (i + 1) * (i + 1));
        log(`! HTTP ${r.status} on ${url} -> cooldown ${Math.round(cool / 1000)}s (try ${i + 1}/${tries})`);
        await sleep(cool + Math.floor(Math.random() * 2000));
        continue;
      }
      // 其它状态码：短退避重试
      await sleep(1500 * (i + 1));
    } catch (e) {
      lastErr = e;
      await sleep(2000 * (i + 1) + Math.floor(Math.random() * 1500));
    }
  }
  throw new Error("apiPost failed after retries: " + url + (lastErr ? " / " + lastErr.message : ""));
}

function log(...a) {
  const ts = new Date().toISOString().slice(11, 19);
  console.log("[" + ts + "]", ...a);
}

async function getCategories() {
  const j = await apiPost("/WxSpAPI/AIGCDataPort/GetPagedCategoriesWithCount?page=1&limit=200&sortOrder=ASC&Type=1&Inquire=");
  const cats = (j && j.data) || [];
  writeJson(path.join(ROOT, "categories.json"), { updatedAt: new Date().toISOString(), data: cats });
  return cats;
}

async function getCategoryList(cat) {
  const catId = cat.CategoryID;
  const listPath = path.join(CAT_DIR, String(catId), "list.json");
  if (!REFRESH && exists(listPath)) {
    try {
      const cur = JSON.parse(fs.readFileSync(listPath, "utf8"));
      if (cur && Array.isArray(cur.items) && cur.items.length >= (cur.total || 0) && cur.items.length > 0) return cur.items;
    } catch (e) {}
  }
  const limit = 100;
  let page = 1, total = Infinity, items = [], totalPages = Infinity;
  const seen = new Set();
  while (page <= totalPages) {
    const j = await apiPost(`/WxSpAPI/AIGCDataPort/GetPagedPromptsByCategory?page=${page}&limit=${limit}&categoryId=${catId}&searchKeyword=`);
    total = j.count || 0;
    totalPages = j.totalPages || Math.ceil(total / limit) || 1;
    const data = j.data || [];
    for (const it of data) {
      if (seen.has(it.PromptID)) continue;
      seen.add(it.PromptID);
      items.push({
        PromptID: it.PromptID,
        Title_CN: it.Title_CN, Title_EN: it.Title_EN,
        ValueProposition_CN: it.ValueProposition_CN, ValueProposition_EN: it.ValueProposition_EN,
        CopyNum: it.CopyNum, ViewsNum: it.ViewsNum, IsPremium: it.IsPremium,
      });
    }
    if (page === 1 || page % 5 === 0 || page === totalPages) log(`  [${cat.CategoryName_CN}] list page ${page}/${totalPages} (${items.length}/${total})`);
    if (data.length === 0) break;
    page++;
    await sleep(jitter());
  }
  writeJson(listPath, {
    categoryId: catId, name_cn: cat.CategoryName_CN, name_en: cat.CategoryName_EN,
    total: items.length, updatedAt: new Date().toISOString(), items,
  });
  return items;
}

async function getDetail(catId, promptId) {
  const p = path.join(DET_DIR, String(catId), promptId + ".json");
  if (!REFRESH && exists(p)) return false; // already have it
  const j = await apiPost(`/WxSpAPI/AIGCDataPort/GetPromptDetailsById?promptId=${promptId}`);
  const info = (j && j.dataInfo) || null;
  if (!info) throw new Error("no dataInfo for " + promptId);
  writeJson(p, info);
  return true;
}

// 简单并发池
async function runPool(jobs, conc, worker) {
  let idx = 0, active = 0;
  return new Promise((resolve) => {
    function next() {
      if (idx >= jobs.length && active === 0) return resolve();
      while (active < conc && idx < jobs.length) {
        const job = jobs[idx++]; active++;
        worker(job).catch(() => {}).then(async () => {
          await sleep(jitter());
          active--; next();
        });
      }
    }
    next();
  });
}

async function main() {
  ensure(ROOT);
  log("== AI 提示词库爬虫启动 == 并发", CONC, "延时", DMIN + "-" + DMAX + "ms", REFRESH ? "[REFRESH]" : "", ONLY.length ? "ONLY=" + ONLY.join(",") : "");
  let cats = await getCategories();
  if (ONLY.length) cats = cats.filter(c => ONLY.includes(String(c.CategoryID)));
  log("分类数:", cats.length, "声明总条数:", cats.reduce((s, c) => s + (parseInt(String(c.PromptCount).replace(/,/g, ""), 10) || 0), 0));

  // 进度统计
  const prog = { updatedAt: "", categories: [], totalListed: 0, totalDetails: 0 };
  function countDetails(catId) {
    const d = path.join(DET_DIR, String(catId));
    try { return fs.readdirSync(d).filter(f => f.endsWith(".json")).length; } catch (e) { return 0; }
  }
  function saveProgress(cats, listsLen) {
    prog.updatedAt = new Date().toISOString();
    prog.categories = cats.map(c => ({
      id: c.CategoryID, name_cn: c.CategoryName_CN, name_en: c.CategoryName_EN,
      icon: c.IconCode, claimed: c.PromptCount,
      listed: listsLen[c.CategoryID] || 0, details: countDetails(c.CategoryID),
    }));
    prog.totalListed = prog.categories.reduce((s, c) => s + c.listed, 0);
    prog.totalDetails = prog.categories.reduce((s, c) => s + c.details, 0);
    writeJson(path.join(ROOT, "progress.json"), prog);
  }

  const listsLen = {};
  // 阶段一：所有分类的列表（先把"构架/目录"全量拿到）
  for (const cat of cats) {
    try {
      const items = await getCategoryList(cat);
      listsLen[cat.CategoryID] = items.length;
      log(`✓ 列表完成 [${cat.CategoryName_CN}] ${items.length} 条`);
    } catch (e) {
      log("✗ 列表失败", cat.CategoryName_CN, e.message);
      listsLen[cat.CategoryID] = 0;
    }
    saveProgress(cats, listsLen);
    await sleep(jitter());
  }

  // 阶段二：逐条详情（断点续传）
  for (const cat of cats) {
    const listPath = path.join(CAT_DIR, String(cat.CategoryID), "list.json");
    let items = [];
    try { items = JSON.parse(fs.readFileSync(listPath, "utf8")).items || []; } catch (e) {}
    const pending = items.filter(it => REFRESH || !exists(path.join(DET_DIR, String(cat.CategoryID), it.PromptID + ".json")));
    log(`→ 详情 [${cat.CategoryName_CN}] 待抓 ${pending.length}/${items.length}`);
    let done = 0, fetched = 0, n = 0;
    await runPool(pending, CONC, async (it) => {
      try {
        const got = await getDetail(cat.CategoryID, it.PromptID);
        if (got) fetched++;
      } catch (e) {
        log("  ✗ 详情失败", it.PromptID, e.message);
      }
      done++; n++;
      if (n % 50 === 0) { log(`  [${cat.CategoryName_CN}] 详情进度 ${done}/${pending.length}（本轮新增 ${fetched}）`); saveProgress(cats, listsLen); }
    });
    saveProgress(cats, listsLen);
    log(`✓ 详情完成 [${cat.CategoryName_CN}] 本轮新增 ${fetched}，累计本地 ${countDetails(cat.CategoryID)}/${items.length}`);
  }

  saveProgress(cats, listsLen);
  log("== 全部完成 == 本地列表合计", prog.totalListed, "详情合计", prog.totalDetails);
}

main().catch(e => { log("FATAL", e.stack || e.message); process.exit(1); });
