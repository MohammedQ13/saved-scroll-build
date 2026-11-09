// Saved Scroll core: the index of your saves, positions, days, pins, phases, re-saves and resume.
// Plain JavaScript: runs in Node (tests, simulation) and in Scriptable on the iPhone.
//
// Coordinates
//   "bottom" position: 1 = your OLDEST save. It never changes when you save new videos, so pins,
//   phases and learning all use it. "top" position: 1 = newest save = first tile of the Saved
//   grid. top = totalNow - bottom + 1, where totalNow = saves in the export + new saves since
//   (estimated from your saving rate). The final leg of every jump uses exact bottom positions
//   from "Where am I?", so the estimate only affects the first leg.

const DAY = 86400000;
const civilFormats = new Map(), civilStarts = new Map();

function civilDate(ts, timeZone) {
  if (!timeZone || timeZone === "UTC") {
    const d = new Date(ts);
    return [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()];
  }
  if (!civilFormats.has(timeZone)) {
    civilFormats.set(timeZone, new Intl.DateTimeFormat("en-CA", {
      timeZone, year: "numeric", month: "numeric", day: "numeric", calendar: "gregory",
    }));
  }
  const parts = Object.fromEntries(civilFormats.get(timeZone).formatToParts(ts).map(p => [p.type, +p.value]));
  return [parts.year, parts.month, parts.day];
}

const clockFormats = new Map();
function civilClock(ts, timeZone = "UTC") {
  if (timeZone === "UTC") {
    const d = new Date(ts);
    return [d.getUTCHours(), d.getUTCMinutes()];
  }
  if (!clockFormats.has(timeZone)) {
    clockFormats.set(timeZone, new Intl.DateTimeFormat("en-CA", { timeZone, hour: "numeric", minute: "numeric", hourCycle: "h23" }));
  }
  const parts = clockFormats.get(timeZone).formatToParts(ts);
  return [Number(parts.find(p => p.type === "hour").value), Number(parts.find(p => p.type === "minute").value)];
}

// Convert a local calendar boundary to an absolute instant. Search on civil
// dates so DST gaps, short days and long days preserve the right membership.
function civilStart(y, m, d, timeZone = "UTC") {
  const nominal = Date.UTC(y, m - 1, d);
  if (timeZone === "UTC") return nominal;
  const key = timeZone + "/" + nominal;
  if (!civilStarts.has(key)) {
    let lo = nominal - DAY, hi = nominal + DAY;
    while (hi - lo > 1) {
      const mid = lo + Math.floor((hi - lo) / 2);
      const [year, month, day] = civilDate(mid, timeZone);
      if (Date.UTC(year, month - 1, day) < nominal) lo = mid;
      else hi = mid;
    }
    civilStarts.set(key, hi);
  }
  return civilStarts.get(key);
}

// ---------- links ----------
function linkToId(text) {
  const m = String(text || "").match(/(?:\/video\/|\/v\/|item_id=|share_item_id=)(\d{15,21})/) || String(text || "").match(/(?<!\d)(\d{18,21})(?!\d)/);
  return m ? m[1] : null;
}
function isShortLink(text) { return /(?:vt|vm)\.tiktok\.com\/|tiktok\.com\/t\//.test(String(text || "")); }
function postedTs(id) { try { return Number(BigInt(id) >> 32n) * 1000; } catch { return null; } }

// ---------- export -> index ----------
function parseExport(text) {
  const pairs = [];
  let data = null;
  try { data = JSON.parse(text.replace(/^﻿/, "")); } catch { /* TXT export */ }
  if (data) {
    const found = [];
    const stack = [["", data]];
    while (stack.length) {
      const [key, node] = stack.pop();
      if (Array.isArray(node)) {
        const k = key.toLowerCase();
        if (node.length && node[0] && typeof node[0] === "object" && (k.includes("favorite") || k.includes("favourite")) && k.includes("video")) found.push(node);
        else node.forEach(x => x && typeof x === "object" && stack.push([key, x]));
      } else if (node && typeof node === "object") Object.entries(node).forEach(e => stack.push(e));
    }
    const rows = found.sort((a, b) => b.length - a.length)[0] || [];
    for (const r of rows) {
      const low = Object.fromEntries(Object.entries(r).map(([k, v]) => [k.toLowerCase(), v]));
      pairs.push([low.date || low.time, low.link || low.videolink || low.url]);
    }
  } else {
    let date = null;
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim(), low = line.toLowerCase();
      if (low.startsWith("date:")) date = line.slice(5).trim();
      else if (low.startsWith("link:") || low.startsWith("video link:")) { pairs.push([date, line.slice(line.indexOf(":") + 1).trim()]); date = null; }
    }
  }
  return pairs;
}

function parseDate(s) {
  const m = String(s || "").match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?/);
  return m ? Date.UTC(+m[1], m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0)) : null;
}

// Newest first, one entry per video (a re-saved video keeps its newest save, like the grid).
function buildIndex(text) {
  const pairs = parseExport(text);
  const byId = new Map();
  let bad = 0, dupes = 0;
  pairs.forEach(([d, link], order) => {
    const id = linkToId(link), ts = parseDate(d);
    if (!id || ts == null) { bad++; return; }
    const prev = byId.get(id);
    if (prev) { dupes++; if (ts > prev.ts) byId.set(id, { id, ts, order }); return; }
    byId.set(id, { id, ts, order });
  });
  const saves = [...byId.values()].sort((a, b) => b.ts - a.ts || a.order - b.order).map(s => ({ id: s.id, ts: s.ts }));
  saves.forEach((s, i) => (s.bottom = saves.length - i));
  const newest = saves.length ? saves[0].ts : 0;
  const recent = saves.filter(s => s.ts >= newest - 60 * DAY).length;
  return { saves, meta: { total: saves.length, newest, oldest: saves.length ? saves[saves.length - 1].ts : 0, perDay: recent / 60, bad, dupes } };
}

function serializeIndex(ix) { return JSON.stringify(ix.meta) + "\n" + ix.saves.map(s => `${s.id}|${s.bottom}|${s.ts}`).join("\n"); }
function loadIndex(text) {
  const [head, ...lines] = text.split("\n");
  const saves = lines.filter(Boolean).map(l => { const [id, b, t] = l.split("|"); return { id, bottom: +b, ts: +t }; });
  return { meta: JSON.parse(head), saves };
}

function resaveEvidence(older, newer) {
  const evidence = [];
  for (const save of newer) {
    const before = older.get(save.id);
    if (before && save.ts > before.ts + 60000) {
      evidence.push({ id: save.id, firstSaved: before.ts, resavedAt: save.ts });
    }
  }
  return evidence;
}

function mergeResaves(existing, observed) {
  const key = r => r.id + "/" + r.firstSaved + "/" + r.resavedAt;
  const unique = new Map(existing.map(r => [key(r), r]));
  for (const r of observed) {
    unique.set(key(r), r);
  }
  return [...unique.values()];
}

// ---------- library ----------
class Library {
  constructor(index, store = {}) {
    this.saves = index.saves;            // newest first
    this.meta = index.meta;
    this.byId = index.byId || new Map(this.saves.map(s => [s.id, s]));
    this.store = Object.assign({ pins: [], phases: [], resaves: [], extraSaves: 0, session: null, survival: {} }, store);
  }

  // estimated saves now = export total + new since export (learned rate) + manual corrections
  totalNow(now = Date.now()) {
    const days = Math.max(0, (now - this.meta.newest) / DAY);
    return this.meta.total + Math.round(days * this.meta.perDay) + this.store.extraSaves;
  }
  top(bottom, now) { return this.totalNow(now) - bottom + 1; }

  // binary search: index of first save with ts < t (saves are newest first)
  _firstOlder(t) { let lo = 0, hi = this.saves.length; while (lo < hi) { const m = (lo + hi) >> 1; if (this.saves[m].ts >= t) lo = m + 1; else hi = m; } return lo; }

  day(y, m, d, timeZone = "UTC") {
    const start = civilStart(y, m, d, timeZone), end = civilStart(y, m, d + 1, timeZone);
    const i0 = this._firstOlder(end), i1 = this._firstOlder(start);
    if (i1 > i0) return { start, end, count: i1 - i0, newest: this.saves[i0], oldest: this.saves[i1 - 1], exact: true };
    // empty day: nearest days with saves on each side
    const newer = i0 > 0 ? this.saves[i0 - 1] : null, older = i0 < this.saves.length ? this.saves[i0] : null;
    return { start, end, count: 0, exact: false, newer, older };
  }
  range(fromTs, toTs) {
    const i0 = this._firstOlder(toTs), i1 = this._firstOlder(fromTs);
    return { count: Math.max(0, i1 - i0), newest: this.saves[i0], oldest: this.saves[i1 - 1] };
  }

  nearestToRange(start, end) {
    const boundary = this._firstOlder(end);
    const newer = this.saves[boundary - 1], older = this.saves[boundary];
    if (!newer || !older) return newer || older;
    return newer.ts - end <= start - older.ts ? newer : older;
  }

  savedTimes(y, m, d, timeZone = "UTC") {
    const day = this.day(y, m, d, timeZone);
    if (!day.count) return [];
    const start = this.meta.total - day.newest.bottom;
    return this.saves.slice(start, start + day.count).map(save => {
      const [hour, minute] = civilClock(save.ts, timeZone);
      return { save, hour, minute };
    });
  }

  whereAmI(linkOrId, now = Date.now()) {
    const id = linkToId(linkOrId) || linkOrId;
    const s = this.byId.get(id);
    const posted = postedTs(id);
    if (!s) {
      const re = this.store.resaves.find(r => r.id === id);
      return { id, inIndex: false, posted, note: re ? "older save history exists; current position unknown" : "not in the latest export; current save date unknown" };
    }
    const re = this.store.resaves.filter(r => r.id === id).sort((a, b) => a.firstSaved - b.firstSaved)[0];
    return { id, inIndex: true, bottom: s.bottom, top: this.top(s.bottom, now), total: this.totalNow(now), saved: s.ts, posted,
             firstSaved: re ? re.firstSaved : s.ts, note: re ? `re-saved; first saved ${new Date(re.firstSaved).toISOString().slice(0, 10)}` : undefined,
             phases: this.store.phases.filter(p => s.ts >= p.from && s.ts < p.to).map(p => ({ name: p.name, dayOf: Math.floor((s.ts - p.from) / DAY) + 1, days: Math.ceil((p.to - p.from) / DAY), pct: Math.round(100 * (p.to - s.ts) / (p.to - p.from)) })) };
  }

  // ---------- pins ----------
  pin(linkOrId, note = "", at = Date.now()) {
    const w = this.whereAmI(linkOrId, at);
    const p = { id: w.id, bottom: w.bottom ?? null, saved: w.saved ?? null, note, at };
    this.store.pins.unshift(p);
    return p;
  }
  lastPin() { return this.store.pins[0] || null; }

  // ---------- phases ----------
  addPhase(name, fromTs, toTs, extra = {}) {
    const p = Object.assign({ name, from: Math.min(fromTs, toTs), to: Math.max(fromTs, toTs), created: Date.now() }, extra);
    this.store.phases.push(p);
    return Object.assign({}, p, this.range(p.from, p.to));
  }
  // Bursts of saving: days well above your usual rate, merged into runs.
  suggestPhases({ minRatio = 2.5, minDays = 2, minCount = 60 } = {}) {
    const counts = new Map();
    for (const s of this.saves) { const d = Math.floor(s.ts / DAY); counts.set(d, (counts.get(d) || 0) + 1); }
    const days = [...counts.keys()].sort((a, b) => a - b);
    if (!days.length) return [];
    const series = [];
    for (let d = days[0]; d <= days[days.length - 1]; d++) series.push([d, counts.get(d) || 0]);
    const out = [];
    let run = null;
    series.forEach(([d, c], i) => {
      const win = series.slice(Math.max(0, i - 30), i + 31).map(x => x[1]).sort((a, b) => a - b);
      const base = Math.max(3, win[Math.floor(win.length / 2)]);
      const hot = c >= minRatio * base;
      if (hot) { if (!run) run = { from: d, to: d, count: 0, base }; run.to = d; run.count += c; }
      else if (run && d - run.to > 1) { out.push(run); run = null; }
    });
    if (run) out.push(run);
    return out.filter(r => r.to - r.from + 1 >= minDays && r.count >= minCount)
      .map(r => ({ from: r.from * DAY, to: (r.to + 1) * DAY, days: r.to - r.from + 1, count: r.count, ratio: +(r.count / ((r.to - r.from + 1) * r.base)).toFixed(1) }))
      .sort((a, b) => b.ratio - a.ratio);
  }

  // ---------- monthly re-index: detect re-saves, keep pins valid ----------
  reindex(newIndex) {
    const resaves = resaveEvidence(this.byId, newIndex.saves);
    const lib = new Library(newIndex, Object.assign({}, this.store, { resaves: mergeResaves(this.store.resaves, resaves), extraSaves: 0 }));
    // Pins: re-anchor by video; if the video moved (re-saved) or is gone, anchor to the same save time.
    lib.store.pins = this.store.pins.map(p => {
      const s = lib.byId.get(p.id);
      if (s && (p.saved == null || Math.abs(s.ts - p.saved) < 60000)) return Object.assign({}, p, { bottom: s.bottom });
      if (p.saved == null) return Object.assign({}, p, { stale: true });
      const i = Math.min(lib._firstOlder(p.saved + 1), lib.saves.length - 1);
      return Object.assign({}, p, { bottom: lib.saves[i].bottom, movedFrom: p.id, note: (p.note + " (video moved or unsaved; pinned the spot instead)").trim() });
    });
    return { lib, resaves };
  }
  rememberOlder(index) {
    const evidence = resaveEvidence(new Map(index.saves.map(s => [s.id, s])), this.saves);
    this.store.resaves = mergeResaves(this.store.resaves, evidence);
    return evidence.length;
  }
  // Videos previously observed in a time range that were saved again later.
  resavedFrom(fromTs, toTs) {
    return [...new Map(this.store.resaves.filter(r => r.firstSaved >= fromTs && r.firstSaved < toTs).map(r => [r.id, r])).values()];
  }

  observedSaveTimes(id) {
    const times = new Set();
    const current = this.byId.get(id);
    if (current) times.add(current.ts);
    for (const record of this.store.resaves) {
      if (record.id === id) {
        times.add(record.firstSaved);
        times.add(record.resavedAt);
      }
    }
    return [...times].sort((a, b) => a - b);
  }
}

// ---------- resume after leaving TikTok ----------
// Learns the chance the loaded grid is still there, by what happened and how long you were away.
const AWAY_BINS = [2, 10, 30, 120, Infinity];          // minutes
function survivalKey(kind, minutes) { return `${kind}|${AWAY_BINS.findIndex(b => minutes < b)}`; }
function survivalOdds(store, kind, minutes) {
  if (kind === "saved-a-video") kind = "saved-a-video";  // grid jumps to top; are pages kept?
  const prior = minutes < 10 ? { a: 1.6, b: 0.4 } : minutes < 120 ? { a: 1.2, b: 0.8 } : { a: 0.6, b: 1.4 };
  const s = store.survival[survivalKey(kind, minutes)] || prior;
  return s.a / (s.a + s.b);
}
function learnSurvival(store, kind, minutes, survived) {
  const k = survivalKey(kind, minutes);
  const prior = minutes < 10 ? { a: 1.6, b: 0.4 } : minutes < 120 ? { a: 1.2, b: 0.8 } : { a: 0.6, b: 1.4 };
  const s = store.survival[k] || (store.survival[k] = Object.assign({}, prior));
  survived ? s.a++ : s.b++;
}
// Decide what Resume should do. Returns whether to ask the one Yes/No question.
function resumeDecision(store, kind, minutes) {
  const p = survivalOdds(store, kind, minutes);
  return { pWarm: p, ask: p > 0.2 && p < 0.8, assume: p >= 0.8 ? "warm" : p <= 0.2 ? "cold" : null };
}

const api = { DAY, civilDate, civilStart, civilClock, linkToId, isShortLink, postedTs, parseExport, parseDate, buildIndex, serializeIndex, loadIndex, Library, survivalOdds, learnSurvival, resumeDecision };
if (typeof module !== "undefined") module.exports = api;
