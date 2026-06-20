// extract_text.js <inputPath>
// 从 txt/md/csv/json/log/docx/xlsx/pptx 提取纯文本，输出 JSON {ok,text,chars} 到 stdout。零依赖（仅用 Node 内置 zlib）。
const fs = require("fs"), zlib = require("zlib");

function readZipEntries(buf) {
  let i = buf.length - 22;
  for (; i >= 0; i--) { if (buf.readUInt32LE(i) === 0x06054b50) break; }
  if (i < 0) throw new Error("not a zip");
  const cdCount = buf.readUInt16LE(i + 10);
  let off = buf.readUInt32LE(i + 16);
  const entries = {};
  for (let n = 0; n < cdCount; n++) {
    if (buf.readUInt32LE(off) !== 0x02014b50) break;
    const method = buf.readUInt16LE(off + 10);
    const compSize = buf.readUInt32LE(off + 20);
    const nameLen = buf.readUInt16LE(off + 28);
    const extraLen = buf.readUInt16LE(off + 30);
    const commentLen = buf.readUInt16LE(off + 32);
    const lhOff = buf.readUInt32LE(off + 42);
    const name = buf.toString("utf8", off + 46, off + 46 + nameLen);
    entries[name] = { method, compSize, lhOff };
    off += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}
function readEntry(buf, e) {
  const lh = e.lhOff;
  if (buf.readUInt32LE(lh) !== 0x04034b50) throw new Error("bad local header");
  const nameLen = buf.readUInt16LE(lh + 26);
  const extraLen = buf.readUInt16LE(lh + 28);
  const start = lh + 30 + nameLen + extraLen;
  const comp = buf.slice(start, start + e.compSize);
  if (e.method === 0) return comp;
  if (e.method === 8) return zlib.inflateRawSync(comp);
  throw new Error("unsupported compression " + e.method);
}
function decodeEntities(s) {
  return s.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&apos;/g, "'");
}
function between(xml, tag) {
  const re = new RegExp("<" + tag + "[ >][^]*?</" + tag + ">", "g");
  const out = []; let m;
  const re2 = new RegExp("<" + tag + "(?:\\s[^>]*)?>([\\s\\S]*?)</" + tag + ">", "g");
  while ((m = re2.exec(xml))) out.push(m[1]);
  return out;
}
function tTexts(xml, tag) {
  return between(xml, tag).map(function (s) { return decodeEntities(s.replace(/<[^>]+>/g, "")); });
}

const path = process.argv[2];
try {
  const buf = fs.readFileSync(path);
  const lower = (path || "").toLowerCase();
  let text = "";
  if (/\.(txt|md|markdown|csv|tsv|json|log|html?|xml|ya?ml|ini|conf|js|ts|py|java|c|cpp|cs|go|rb|php|sql)$/.test(lower)) {
    text = buf.toString("utf8");
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
  } else if (/\.docx$/.test(lower)) {
    const e = readZipEntries(buf);
    if (!e["word/document.xml"]) throw new Error("no document.xml");
    const doc = readEntry(buf, e["word/document.xml"]).toString("utf8");
    text = between(doc, "w:p").map(function (p) { return tTexts(p, "w:t").join(""); }).filter(function (x) { return x.length; }).join("\n");
  } else if (/\.xlsx$/.test(lower)) {
    const e = readZipEntries(buf);
    let shared = [];
    if (e["xl/sharedStrings.xml"]) {
      const ss = readEntry(buf, e["xl/sharedStrings.xml"]).toString("utf8");
      shared = between(ss, "si").map(function (si) { return tTexts(si, "t").join(""); });
    }
    const sheets = Object.keys(e).filter(function (k) { return /^xl\/worksheets\/sheet\d+\.xml$/.test(k); }).sort();
    const rows = [];
    sheets.slice(0, 5).forEach(function (sn) {
      const xml = readEntry(buf, e[sn]).toString("utf8");
      between(xml, "row").forEach(function (row) {
        const cells = []; let cm; const cre = /<c\b([^>]*)>([\s\S]*?)<\/c>/g;
        while ((cm = cre.exec(row))) {
          const attrs = cm[1], inner = cm[2];
          const tm = attrs.match(/t="([^"]*)"/); const t = tm ? tm[1] : "";
          let v = "";
          if (t === "s") { const vi = (inner.match(/<v>([\s\S]*?)<\/v>/) || [])[1]; v = shared[parseInt(vi, 10)] || ""; }
          else if (t === "inlineStr") { v = tTexts(inner, "t").join(""); }
          else { v = decodeEntities(((inner.match(/<v>([\s\S]*?)<\/v>/) || [])[1] || "").replace(/<[^>]+>/g, "")); }
          cells.push(v);
        }
        if (cells.some(function (x) { return x !== ""; })) rows.push(cells.join("\t"));
      });
    });
    text = rows.join("\n");
  } else if (/\.pptx$/.test(lower)) {
    const e = readZipEntries(buf);
    const slides = Object.keys(e).filter(function (k) { return /^ppt\/slides\/slide\d+\.xml$/.test(k); })
      .sort(function (a, b) { return parseInt(a.match(/slide(\d+)/)[1], 10) - parseInt(b.match(/slide(\d+)/)[1], 10); });
    const parts = [];
    slides.forEach(function (sn, i) {
      const xml = readEntry(buf, e[sn]).toString("utf8");
      const ts = tTexts(xml, "a:t").filter(function (x) { return x.trim().length; });
      if (ts.length) parts.push("【第" + (i + 1) + "页】\n" + ts.join("\n"));
    });
    text = parts.join("\n\n");
  } else {
    process.stdout.write(JSON.stringify({ ok: false, error: "unsupported", text: "" }));
    process.exit(0);
  }
  if (text.length > 20000) text = text.slice(0, 20000) + "\n…(已截断)";
  process.stdout.write(JSON.stringify({ ok: true, text: text, chars: text.length }));
} catch (err) {
  process.stdout.write(JSON.stringify({ ok: false, error: String((err && err.message) || err), text: "" }));
}
