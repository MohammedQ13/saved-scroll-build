// Saved Scroll: the on-phone brain. Lives in Scriptable (iCloud Drive/Scriptable/), next to
// core.js and navigator.js. Every Shortcut calls it with "Run Script" and a JSON command; it
// answers with a short JSON (text to show + numbers for the Shortcut).
//
// Commands  { cmd: ... }
//   import                       read the newest TikTok export in iCloud Drive/Scriptable/SavedScroll
//   where    { link }            "Save #13,950 of 36,412 · saved 3 Oct 2024 · Summer grind day 3/10"
//   pin      { link, note }      checkpoint
//   plan     { target, net }     target: "2024-10-03" | "2024-10" | "pin" | "pin:<n>" | "phase:<name>" | <video link>
//   pattern  { recipe }          which Switch Control recipe is active; suggests a faster one
//   arrived  { link }            after a dive: learn + next leg (if still far)
//   event    { kind }            tiktok-opened | tiktok-closed | saved-a-video | tiktok-restarted
//   phase    { name, from, to }  add a phase (dates or links)
//   phases                       list + suggestions
//   status

const DAY = 86400000;
const DEFAULT_RECIPE = "10x1s";   // 10 long swipes, about one per second (Switch Control keeps max 10 strokes)
const DEFAULT_RUN_SEC = 10;       // seconds one tap plays
const MAX_DIVE_SEC = 2400;        // longest single leg (40 min); longer trips get a position check in between
const REMOTE_MAX_LEGS = 8;       // Remote: more, shorter legs + automatic back-up (twin: lands within ~15-36 videos)
const BATCH_TAPS = 12;            // default most taps queued at once (~2 min): queued swipes can't be stopped (user-tested)

async function main(input, env) {
  const { core, nav, store: io, resolveLink, now = Date.now() } = env;
  const cmd = typeof input === "string" ? safeJson(input) || { cmd: input } : input || {};
  const state = io.loadState();
  if (state.remote && /^phone/.test(state.remote.version || "")) state.remote.app = true;   // paired before the flag existed
  const indexText = io.read("index.txt");
  let lib = indexText ? new core.Library(core.loadIndex(indexText), state.lib) : null;
  const brain = state.brain || nav.newState();
  const out = r => { state.lib = lib ? lib.store : state.lib; state.brain = brain; io.saveState(state); return r; };
  const fmtDate = ts => new Date(ts).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
  const n = x => Number(x).toLocaleString("en-US");

  // SS Remote (optional ESP32 Bluetooth mouse, remote/firmware): when paired and reachable, dives go to it
  // (no screen taps, no Switch Control, instant stop). Otherwise everything falls back to Switch Control.
  const remote = env.remote || null;
  const remoteStatus = async () => (remote && state.remote && state.remote.paired ? await remote.status() : null);
  // Ready = it answers and can touch: the board needs its Bluetooth link; the app ("kind: phone") connects to
  // the phone on the first dive, so it counts as ready as soon as it answers (it reported ble:false before that).
  const remoteReady = async () => { const st = await remoteStatus(); return st && st.ok && (st.ble || st.kind === "phone") ? st : null; };
  async function deliver(r, pre = 0) {               // hand a planned dive to the Remote if possible
    if (!r || !r.runs || !state.pending) return r;
    const st = await remoteReady();
    // With the Saved Scroll app connected there's no Switch Control fallback (the user removes that setup):
    // say what to fix instead of starting an unstoppable Switch Control dive.
    if (state.remote && state.remote.app && (!st || st.busy)) { state.pending = null; return appProblem(st); }
    if (!st || st.busy) return r;
    state.remote.autoCheck = !!(st.autoCheck && st.hasCheckMacro);
    const pl = state.pending.pl, iv = pl.interval || 1;
    const nSw = Math.max(1, Math.round(pl.seconds / iv)), preSec = pre * 0.7;
    const res = await remote.dive({ n: nSw, iv: Math.round(iv * 1000), dy: (state.remote && state.remote.dy) || 400, dur: 180, pn: pre, piv: 700, pdy: -400 });
    if (!res || !res.ok) { if (state.remote.app) { state.pending = null; return appProblem(st, res); } return r; }
    state.pending.remote = { n: nSw, iv, pre, at: now };
    const eta = Math.round(pl.seconds + preSec + 3), mins = Math.max(1, Math.round(eta / 60));
    return { ok: true, remote: true, eta, seconds: pl.seconds,
      text: `${state.pending.label}\n🤖 ${state.remote.app ? "Saved Scroll" : "The Remote"} is scrolling${pre ? " (up to the top first)" : ""}: ~${mins} min. Put the phone down.\nStop any time: ${state.remote.app ? "⏸ in the floating window" : "button › ⏹ Stop"}.${r.final ? "" : state.remote.autoCheck ? "\nIt checks where it landed by itself and carries on." : "\n(When it's done: Copy link on a top video › button › Check where I landed)"}`,
      alerts: state.remote.autoCheck ? [] : [{ inSec: eta + 3, text: r.final ? "Dive done: you should be there. Scroll a little to fine-tune." : "Dive done. Copy link on a top video, then button › Check where I landed." }] };
  }

  function appProblem(st, res) {                      // the app is the engine but can't take this dive
    if (st && st.busy) return { ok: false, text: "Saved Scroll is already scrolling. Stop it first (⏸ in the floating window), then try again." };
    const why = (res && res.error) || (st && st.error) || "";
    return { ok: false, text: `Saved Scroll couldn't start scrolling${why ? ` (${why})` : ""}.
Fix: open LocalDevVPN and make sure it says Connected, then open the Saved Scroll app once and try again.` };
  }

  if (cmd.cmd === "remote-pair") {
    if (!remote) return out({ ok: false, text: "This needs the SS Remote code on the phone (run SS Install)." });
    const res = await remote.pair();
    if (!res || !res.ok) return out({ ok: false, text: (res && res.error) || "Couldn't reach the Saved Scroll app. Open the Saved Scroll app for a second (it accepts a connection for 3 minutes after opening), check LocalDevVPN is connected, then try again." });
    state.remote = { paired: true, version: res.version, at: now, app: /^phone/.test(res.version || "") };
    return out({ ok: true, text: res.kind === "phone" || /^phone/.test(res.version || "") ? `Saved Scroll app connected ✓ (${res.version}). Dives now go to the app: no Switch Control, and ⏸ in the floating window stops instantly.` : `SS Remote connected ✓ (v${res.version}). Dives now go to the Remote: no screen taps, and ⏹ Stop works instantly.` });
  }
  if (cmd.cmd === "remote-forget") { state.remote = null; return out({ ok: true, text: "SS Remote forgotten. Dives use Switch Control again." }); }
  if (cmd.cmd === "remote-stop") {
    if (!remote) return out({ ok: false, text: "No SS Remote." });
    const res = await remote.stop(), st = await remote.status();
    if (state.pending && state.pending.remote && st) state.pending.remote.stoppedAt = st.done;
    return out({ ok: !!res, text: res ? `Stopped${st ? ` after ${st.done} of ${st.planned} swipes` : ""}. Copy link on a top video › button › Check where I landed, to see where you are.` : "Couldn't reach the Remote. Triple-click isn't needed: it stops by itself when its swipes are done." });
  }

  if (cmd.cmd === "test-dive") {                     // practice / device test, no index needed
    const st = await remoteReady();                    // the app (or a Remote) when connected: 20 real swipes, stoppable
    if (!st && state.remote && state.remote.app) return out(appProblem(null));
    if (st) {
      if (st.busy) return out({ ok: false, text: "It's already scrolling. Stop it first: floating window ⏸, or button › ⏹ Stop." });
      const res = await remote.dive({ n: 20, iv: 1000, dy: (state.remote && state.remote.dy) || 400, dur: 180, pn: 0, check: 0 });
      if (res && res.ok) return out({ ok: true, remote: true, text: "Test dive: 20 swipes down Saved, one per second (~20 s). Don't touch the screen.\nStop any time: floating window ⏸, or button › ⏹ Stop." });
      return out({ ok: false, text: `The app didn't start scrolling: ${(res && res.error) || "no answer"}.\nCheck LocalDevVPN is connected and the Saved Scroll app is open in the background.` });
    }
    return out({ ok: true, runs: 6, nudges: 0, presses: 6, seconds: 60, eta: 100,
      text: "Test dive (2 min): tap the screen 6 times. To test stopping: after ~5 s, triple-click the side button once and time how long it keeps scrolling." });
  }

  if (cmd.cmd === "menu-info") {                       // what the one-button menu should offer right now
    const armed = state.armed && now - state.armed.at < 15 * 60000 ? state.armed.label : null;
    const rs = await remoteStatus();
    if (rs && rs.ok && state.remote) state.remote.autoCheck = !!(rs.autoCheck && rs.hasCheckMacro);
    return out({ ok: true, indexed: !!lib, pending: !!state.pending, armed,
      remote: state.remote && state.remote.paired ? { reachable: !!(rs && rs.ok), ble: !!(rs && rs.ble), app: !!state.remote.app,
        ready: !!(rs && rs.ok && (rs.ble || rs.kind === "phone")), busy: !!(rs && rs.busy), done: rs ? rs.done : 0, planned: rs ? rs.planned : 0 } : null,
      pins: lib ? lib.store.pins.slice(0, 8).map((p, i) => ({ i, label: `${p.note ? "“" + p.note + "” · " : ""}${p.saved ? "saved " + fmtDate(p.saved) : "recent save"} · pinned ${fmtDate(p.at)}` })) : [],
      phases: lib ? lib.store.phases.map(p => p.name) : [] });
  }
  if (cmd.cmd === "calendar" && lib) {                  // years, months of a year, or days of a month, with save counts
    const y = +cmd.year, m = +cmd.month;
    if (!y) {
      const first = new Date(lib.meta.oldest).getUTCFullYear(), last = new Date(lib.meta.newest).getUTCFullYear();
      const years = [];
      for (let k = last; k >= first; k--) { const c = lib.range(Date.UTC(k, 0, 1), Date.UTC(k + 1, 0, 1)).count; if (c) years.push({ year: k, count: c }); }
      return out({ ok: true, years });
    }
    if (!m) {
      const months = [];
      for (let k = 12; k >= 1; k--) { const c = lib.range(Date.UTC(y, k - 1, 1), Date.UTC(y, k, 1)).count; if (c) months.push({ month: k, count: c }); }
      return out({ ok: true, months });
    }
    const days = [], dim = new Date(Date.UTC(y, m, 0)).getUTCDate();
    for (let d = dim; d >= 1; d--) { const c = lib.day(y, m, d).count; if (c) days.push({ day: d, count: c }); }
    return out({ ok: true, days });
  }

  if (cmd.cmd === "import") {
    const file = io.newestExport();
    if (!file) return out({ ok: false, text: "No TikTok export found. Put user_data.json (or .txt) in iCloud Drive › Scriptable › SavedScroll." });
    const ix = core.buildIndex(io.read(file, true));
    if (!ix.saves.length) return out({ ok: false, text: "That file has no favourite videos. Is it the TikTok data export?" });
    let resaves = [];
    if (lib) ({ lib, resaves } = lib.reindex(ix)); else lib = new core.Library(ix, state.lib);
    io.write("index.txt", core.serializeIndex(ix));
    state.importedAt = now;
    return out({ ok: true, total: ix.meta.total, text: `Imported ${n(ix.meta.total)} saves (${fmtDate(ix.meta.oldest)} – ${fmtDate(ix.meta.newest)}). ${resaves.length ? resaves.length + " re-saved videos detected. " : ""}${ix.meta.dupes ? ix.meta.dupes + " duplicates merged. " : ""}` });
  }
  if (!lib) return out({ ok: false, text: "Import your TikTok export first (tap the button › Import my TikTok export)." });

  const where = async link => {
    let id = core.linkToId(link);
    if (!id && core.isShortLink(link)) id = core.linkToId(await resolveLink(link));
    if (!id) return null;
    return lib.whereAmI(id, now);
  };
  const describe = w => {
    if (!w.inIndex) return `Not in your last export (${w.note}).`;
    const ph = w.phases.length ? ` · ${w.phases.map(p => `${p.name} day ${p.dayOf}/${p.days}`).join(", ")}` : "";
    const re = w.note ? ` · ${w.note}` : "";
    return `Save #${n(w.top)} of ~${n(w.total)} · saved ${fmtDate(w.saved)} · posted ${fmtDate(w.posted)}${ph}${re}`;
  };

  if (cmd.cmd === "where") {
    const w = await where(cmd.link);
    if (!w) return out({ ok: false, text: "Couldn't read a TikTok video link. In TikTok tap Share › Copy link, then try again." });
    if (w.inIndex) state.knownEst = { top: w.top, at: now };
    return out({ ok: true, top: w.top, text: describe(w) });
  }

  if (cmd.cmd === "pin") {
    const w = await where(cmd.link);
    if (!w) return out({ ok: false, text: "Copy a video link first (Share › Copy link)." });
    lib.pin(w.id, cmd.note || "", now);
    return out({ ok: true, text: `Pinned${cmd.note ? " “" + cmd.note + "”" : ""}: ${describe(w)}` });
  }

  if (cmd.cmd === "event") {
    state.session = state.session || {};
    if (cmd.kind === "tiktok-closed") state.session.closedAt = now;
    if (cmd.kind === "tiktok-opened" && state.session.closedAt) state.session.awayMin = (now - state.session.closedAt) / 60000;
    if (cmd.kind === "tiktok-restarted") { nav.sessionReset(brain, "restarted"); state.knownEst = null; if (state.session.awayMin != null) core.learnSurvival(lib.store, "app", state.session.awayMin, false); }
    if (cmd.kind === "grid-kept" && state.session.awayMin != null) core.learnSurvival(lib.store, "app", state.session.awayMin, true);
    if (cmd.kind === "saved-a-video") { state.knownEst = null; nav.sessionReset(brain, "saved a video"); }   // Saved jumps to the top and reloads (user-tested)
    return out({ ok: true });
  }

  if (cmd.cmd === "phase") {
    const toTs = async v => { if (/^\d{4}-\d{2}-\d{2}/.test(v)) return core.parseDate(v); const w = await where(v); return w && w.inIndex ? w.saved : null; };
    const a = await toTs(cmd.from), b = await toTs(cmd.to);
    if (a == null || b == null) return out({ ok: false, text: "Give the phase two dates (YYYY-MM-DD) or two copied video links." });
    const p = lib.addPhase(cmd.name || "Untitled phase", Math.min(a, b), Math.max(a, b) + (/^\d{4}-\d{2}-\d{2}$/.test(String(cmd.to)) ? DAY : 1), { emoji: cmd.emoji || "" });
    return out({ ok: true, text: `Phase “${p.name}”: ${fmtDate(p.from)} – ${fmtDate(p.to - 1)} · ${n(p.count)} saves` });
  }
  if (cmd.cmd === "phases") {
    const list = lib.store.phases.map(p => `${p.emoji || "•"} ${p.name}: ${fmtDate(p.from)} – ${fmtDate(p.to - 1)} (${n(lib.range(p.from, p.to).count)})`);
    const sug = lib.suggestPhases().slice(0, 5).map(s => `${fmtDate(s.from)} – ${fmtDate(s.to - 1)}: ${n(s.count)} saves, ${s.ratio}× your usual`);
    return out({ ok: true, phases: list, suggestions: sug, text: [...list, ...(sug.length ? ["Suggested:", ...sug] : [])].join("\n") || "No phases yet." });
  }

  if (cmd.cmd === "plan") {
    const t = String(cmd.target || "");
    let targetSave = null, label = "";
    if (/^\d{4}-\d{2}(-\d{2})?$/.test(t)) {
      const [y, m, d] = t.split("-").map(Number);
      if (d) {
        const day = lib.day(y, m, d);
        targetSave = day.count ? day.newest : (day.newer || day.older);
        label = day.count ? `${fmtDate(day.start)} (${n(day.count)} saves)` : `nearest saves to ${fmtDate(day.start)}`;
        const re = lib.resavedFrom(day.start, day.start + DAY).length;
        if (re) label += ` · ${re} re-saved since, now near the top`;
      } else {
        const start = Date.UTC(y, m - 1, 1), end = Date.UTC(y, m, 1), r = lib.range(start, end);
        targetSave = r.count ? r.newest : lib.day(y, m, 1).older; label = `${new Date(start).toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" })} (${n(r.count)} saves)`;
      }
    } else if (/tiktok\.com|^\d{18,21}$/.test(t)) {          // a copied video link (e.g. from Watch history)
      const w = await where(t);
      if (!w || !w.inIndex) return out({ ok: false, text: "That video isn't in your last export, so it's near the top of Saved: just scroll." });
      targetSave = lib.byId.get(w.id); label = `that video (saved ${fmtDate(w.saved)})`;
    } else if (t === "pin" || t.startsWith("pin:")) {
      const p = lib.store.pins[t === "pin" ? 0 : +t.slice(4)];
      if (!p) return out({ ok: false, text: "No checkpoints yet. Use Pin here first." });
      targetSave = lib.saves.find(s => s.bottom === p.bottom); label = `checkpoint${p.note ? " “" + p.note + "”" : ""}`;
    } else if (t.startsWith("phase:")) {
      const p = lib.store.phases.find(x => x.name.toLowerCase() === t.slice(6).toLowerCase());
      if (!p) return out({ ok: false, text: "No phase with that name." });
      targetSave = lib.range(p.from, p.to).newest; label = `start of “${p.name}”`;
    }
    if (!targetSave) return out({ ok: false, text: "Couldn't find that spot in your saves." });
    const targetTop = lib.top(targetSave.bottom, now);
    // A remembered position goes stale fast: people scroll and reopen Saved at the top (device 2026-11-06: a
    // 25-min-old reading made a fresh jump say "above you"). Trust it for 5 minutes.
    const from = state.knownEst && now - state.knownEst.at < 5 * 60000 ? state.knownEst.top : 1;
    return out(await deliver(planLeg(from, targetTop, label, cmd.net || "wifi-good", false, cmd.clip || "")));
  }

  function planLeg(from, targetTop, label, net, startNow = false, clipAtArm = "") {
    const remaining = targetTop - from;
    if (Math.abs(remaining) < 30) { state.pending = null; return { ok: true, done: true, text: `You're there: ${label}.` }; }
    if (remaining < 0) {
      state.pending = null;
      // Still offer the normal starts (e.g. Saved was reopened at the top since that reading).
      state.armed = { targetTop, label, net, at: now, clip: clipAtArm || "" };
      return { ok: true, up: true, armed: true, text: `${label} is above you (~${n(-remaining)} saves up). Scroll up: it's already loaded, so it's quick. If Saved is back at the top, start from there.` };
    }
    // Position unknown: the brain needs one reading first. TikTok has no scroll-to-top (tapping the clock does
    // nothing, user-tested), so you copy the link of any video you can see. This must happen before the dive:
    // during a dive every screen tap queues more swipes. So: arm now, start on the next button tap.
    if (from === 1 && !startNow) {
      state.armed = { targetTop, label, net, at: now, clip: clipAtArm || "" };
      return { ok: true, armed: true, text: `${label}\nFirst show me where you are:\n• Saved just opened at the very top? Tap the button › ▶️ Start\n• Anywhere else: open any video you can see › Share › Copy link › go back, then button › ▶️ Start` };
    }
    state.armed = null;
    // Policy: with the Remote's hands-free check, many short legs land closest (twin, fresh seeds: miss 15/36
    // videos); otherwise each check costs the user effort, so fewer, longer legs (docs/knowledge/04).
    const auto = !!(state.remote && state.remote.paired && state.remote.autoCheck);
    const P = auto ? { frac: 0.9, lastAt: 400, aimMid: 0.5, aimLast: 0.4 } : { frac: 0.92, lastAt: 1500, aimMid: 0.5, aimLast: 0.6 };
    const last = remaining < P.lastAt;
    let to = last ? targetTop : Math.round(from + P.frac * remaining);
    const opts = { from, net, allowed: [state.activeRecipe || DEFAULT_RECIPE], runSec: state.runSec || DEFAULT_RUN_SEC, nudgeSec: null };
    let pl = nav.plan(brain, { ...opts, to, aim: last ? P.aimLast : P.aimMid });
    const maxPresses = Math.max(1, Math.floor(MAX_DIVE_SEC / opts.runSec));
    for (let k = 0; k < 3 && pl.presses > maxPresses; k++) {          // keep each dive short enough to wait out
      to = Math.round(from + (to - from) * maxPresses / pl.presses * 0.95);
      pl = nav.plan(brain, { ...opts, to, aim: 0.5 });
    }
    const final = to === targetTop;
    state.pending = { pl, targetTop, label, net, startedAt: now, legs: (state.pending && state.pending.targetTop === targetTop ? state.pending.legs : 0) + 1 };
    const mins = Math.max(1, Math.round(pl.eta / 60));
    // Queued taps can't be cancelled (not by triple-click, not by locking: user-tested), so never queue more
    // than one batch (~1.5 min). To stop, just don't tap the next batch; then triple-click turns it all off.
    const B = state.batchTaps || BATCH_TAPS;
    const taps = pl.presses, batches = Math.ceil(taps / B), lastBatch = taps - B * (batches - 1);
    const tapText = batches === 1
      ? `Tap the screen ${taps} time${taps > 1 ? "s" : ""}`
      : `Tap the screen ${B} times. The phone buzzes when it's time for the next ${B}: ${batches} batches in all${lastBatch < B ? ` (the last one is ${lastBatch})` : ""}`;
    return { ok: true, final, runs: pl.runs, nudges: pl.nudges, presses: taps, batches, batchTaps: B, lastBatch, runSec: opts.runSec, seconds: pl.seconds, eta: pl.eta, recipe: pl.recipe, fromTop: from === 1,
             text: `${label}\n1. ${tapText}\n2. ~${mins} min · "Dive done" when finished · to stop early, don't tap the next batch${final ? "" : "\n(Then: Copy link on a top video › button › Check where I landed)"}` };
  }

  if (cmd.cmd === "start") {                         // second half of a jump: a fresh copied link says where you are
    const a = state.armed;
    if (!a || now - a.at > 15 * 60000) return out({ ok: false, text: "Nothing to start. Choose where to go first." });
    let from = 1, pre = 0;
    if (!cmd.top && !cmd.viaTop && cmd.clip && (cmd.fromClip || cmd.clip !== a.clip)) {
      const w = await where(cmd.clip);
      if (w && w.inIndex) { from = w.top; state.knownEst = { top: from, at: now }; }
    }
    if (cmd.viaTop) {                                 // the Remote scrolls back up to the top first (loaded grid: fast)
      const loaded = brain.frontier && brain.frontier.pos ? brain.frontier.pos : 0;
      pre = Math.min(400, Math.ceil((loaded + 600) / 150) + 8);
    }
    return out(await deliver(planLeg(from, a.targetTop, a.label, cmd.net || a.net, true), pre));
  }

  if (cmd.cmd === "arrived") {
    const p = state.pending;
    if (p && p.remote) {
      const st = await remoteStatus();
      if (st && st.busy) return out({ ok: false, text: `The Remote is still scrolling (${st.done}/${st.planned} swipes). Wait for "Dive done", or button › ⏹ Stop.` });
      const done = st && st.planned === p.remote.n ? st.done : p.remote.stoppedAt;
      if (done != null && done < p.remote.n) p.pl.seconds = Math.max(1, done * p.remote.iv);   // stopped early: learn from what really ran
    }
    const w = await where(cmd.link);
    if (!w || !w.inIndex) return out({ ok: false, text: "Copy the link of a video near the top of the screen (not one you saved recently), then button › Check where I landed." });
    if (!p) { state.knownEst = { top: w.top, at: now }; return out({ ok: true, text: describe(w) }); }
    // After a back-up leg there's nothing to learn (it went up through loaded grid); just carry on from here.
    const ob = p.backing ? { outlier: false } : nav.observe(brain, p.pl, { landed: w.top, mistap: !!cmd.openedVideo, at: now });
    p.backing = false;
    let here = w.top;
    if (ob.outlier) {
      p.rechecks = (p.rechecks || 0) + 1;
      if (p.rechecks === 1) return out({ ok: false, recheck: true, text: "That reading doesn't fit (maybe a video you re-saved recently). Copy the link of a video one row lower then button › Check where I landed again." });
      here = Math.round(ob.expected);                        // second odd reading: carry on from the planned spot
    }
    p.rechecks = 0;
    state.knownEst = { top: here, at: now };
    const remaining = p.targetTop - here;
    // Remote overshot: send it back up through the loaded grid (twin: miss p90 558 -> 36 videos with this
    // plus more, shorter legs; docs/knowledge/04, "back-up legs").
    if (remaining < -30 && p.legs < REMOTE_MAX_LEGS) {
      const st = await remoteReady();
      if (st && !st.busy) {
        const r10 = nav.RECIPES.find(r => r.id === DEFAULT_RECIPE);
        const per = Math.max(10, Math.exp(nav.warmLogPerStroke(brain, r10)));
        const nUp = Math.max(1, Math.round(-remaining / per));
        const res = await remote.dive({ n: nUp, iv: 1000, dy: -((state.remote && state.remote.dy) || 400), dur: 180, pn: 0 });
        if (res && res.ok) {
          Object.assign(p, { legs: p.legs + 1, backing: true, remote: { n: nUp, iv: 1, pre: 0, at: now } });
          return out({ ok: true, remote: true, text: `${describe(w)}\n🤖 That's ${n(-remaining)} past it: the Remote is scrolling back up (${nUp} swipes, ~${nUp + 3} s). Then: Copy link › button › Check where I landed.`,
            alerts: [{ inSec: nUp + 4, text: "Back-up done. Copy link on a top video, then button › Check where I landed." }] });
        }
      }
    }
    const maxLegs = p.remote ? REMOTE_MAX_LEGS : 4;
    if (remaining < 30 || p.legs >= maxLegs) { state.pending = null; return out({ ok: true, done: true, text: `${describe(w)}\n${remaining > 0 ? `About ${n(remaining)} saves further down: a few swipes.` : remaining < -30 ? `${n(-remaining)} past it: scroll up a little.` : "You're there."}` }); }
    // Say where the check found you before the next leg's message (device 2026-11-06: it only said "scrolling").
    const next = await deliver(planLeg(here, p.targetTop, p.label, p.net));
    if (next && next.text) next.text = `${describe(w)}\n${remaining > 0 ? `${n(remaining)} to go.` : ""}\n${next.text}`.replace(/\n\n/, "\n");
    return out(next);
  }

  if (cmd.cmd === "batch") {                         // most taps queued at once = longest wait if you want to stop
    state.batchTaps = Math.max(1, Math.min(60, +cmd.taps || BATCH_TAPS));
    return out({ ok: true, text: `Dives now queue at most ${state.batchTaps} taps at a time (about ${Math.round(state.batchTaps * (state.runSec || DEFAULT_RUN_SEC) / 6) / 10} min). If you want to stop, you wait at most that long.` });
  }

  if (cmd.cmd === "pattern") {                       // which Switch Control recipe is set as Launch Recipe
    if (cmd.recipe) { state.activeRecipe = cmd.recipe; const r = nav.RECIPES.find(x => x.id === cmd.recipe); if (r) state.runSec = r.runSec; }
    if (cmd.runSec) state.runSec = +cmd.runSec;          // measured length of one tap's playback, if different
    const sug = nav.suggest(brain, { active: state.activeRecipe || DEFAULT_RECIPE, net: cmd.net || "wifi-good" });
    return out({ ok: true, active: state.activeRecipe || DEFAULT_RECIPE, suggestion: sug,
      text: `Active pattern: ${state.activeRecipe || DEFAULT_RECIPE}.` + (sug ? ` ${sug.recipe} looks ${Math.round(sug.gain * 100)}% faster here${sug.tried < 3 ? " (only tried a little)" : ""}: switch Launch Recipe in Settings › Accessibility › Switch Control › Recipes.` : " It's the best known pattern for this network.") });
  }

  if (cmd.cmd === "status") {
    const post = nav.posterior(brain);
    const speeds = nav.RECIPES.map((r, i) => `${r.id}: ${Math.exp(nav.features(i, "wifi-good", 15000).reduce((a, v, k) => a + v * post.mu[k], 0)).toFixed(1)} saves/s`);
    return out({ ok: true, total: lib.meta.total, totalNow: lib.totalNow(now), pins: lib.store.pins.length, phases: lib.store.phases.length, learned: brain.history.length,
      oldest: lib.meta.oldest, newest: lib.meta.newest, text: `${n(lib.meta.total)} saves indexed · ~${n(lib.totalNow(now))} now · ${lib.store.pins.length} pins · ${lib.store.phases.length} phases · ${brain.history.length} jumps learned\n${speeds.join("\n")}` });
  }
  return out({ ok: false, text: `Unknown command ${cmd.cmd}` });
}

// ---------- One-button menu ----------
// The single "Saved Scroll" Shortcut calls ui() in a loop. Each round returns what to ask next:
//   { ask: "list", prompt, items }  → Shortcut shows Choose from List, sends the picked item back as `reply`
//   { ask: "text", prompt }         → Shortcut shows Ask for Input, sends the text back as `reply`
//   { ask: "dive", dive, notify }   → finished; the Shortcut runs "SS Dive" for `dive` seconds
//   { ask: "none", notify }         → finished, nothing to run
// Input each round: { cmd: "ui", step, reply, wifi, rssi, clip }. step 1 always starts at the main menu.
// All menus live here, so new features arrive with SS Install and the Shortcut never needs rebuilding.
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

async function ui(input, env) {
  const { core, nav, store: io, now = Date.now() } = env;
  const inp = typeof input === "string" ? safeJson(input) || {} : input || {};
  const net = !String(inp.wifi || "").trim() ? "cell" : Number(inp.rssi) < -70 ? "wifi-weak" : "wifi-good";
  const clip = String(inp.clip || "").trim();
  const clipIsVideo = !!(core.linkToId(clip) || core.isShortLink(clip));
  const reply = inp.reply == null ? "" : String(inp.reply).trim();
  const run = c => main(c, env);
  const n = x => Number(x).toLocaleString("en-US");

  const saved = io.loadState().ui;
  const fresh = +inp.step === 1 || !saved || now - saved.at > 10 * 60000;
  if (fresh) {                                    // a video link copied since the last menu = probably "where I am now"
    const s0 = io.loadState();
    s0.clipFresh = clipIsVideo && clip !== s0.lastClip;
    s0.lastClip = clip;
    io.saveState(s0);
  }
  const clipFresh = !!io.loadState().clipFresh;
  const setUi = v => { const s = io.loadState(); s.ui = v; io.saveState(s); };
  const list = (prompt, options, ctx = {}) => { setUi({ kind: "list", options, ctx, at: now }); return { ask: "list", prompt, items: options.map(o => o.label) }; };
  const text = (prompt, then, ctx = {}) => { setUi({ kind: "text", then, ctx, at: now }); return { ask: "text", prompt }; };
  const finish = r => {
    setUi(null);
    const dive = r.runs || r.nudges ? Math.round(r.eta + 15 + 0.5 * (r.runs + r.nudges) + 10 * ((r.batches || 1) - 1)) : 0;   // + tapping, + a pause per batch
    // Buzz when each batch should be finished, so you don't have to watch the screen. ~8 s to tap the first batch.
    const reminders = (r.alerts || []).slice();         // Remote dives: one "Dive done" buzz
    for (let i = 1; dive && i < (r.batches || 1); i++) {
      const n = i === r.batches - 1 ? r.lastBatch : r.batchTaps;
      reminders.push({ inSec: Math.round(8 + i * r.batchTaps * r.runSec + 4 * (i - 1)), text: `Tap the screen ${n} more times (batch ${i + 1} of ${r.batches}). Skip it to stop the dive.` });
    }
    return { ask: dive ? "dive" : "none", done: true, ok: r.ok !== false, dive, runs: r.runs || 0, nudges: r.nudges || 0, notify: r.text || "", reminders };
  };

  async function screen(name, ctx = {}) {
    if (name === "top") {
      const info = await run({ cmd: "menu-info" });
      if (!info.indexed) {
        const o = [];
        if (info.remote && info.remote.busy) o.push({ label: `⏹ Stop (${info.remote.done}/${info.remote.planned} swipes)`, cmd: { cmd: "remote-stop" } });
        if (info.remote) o.push({ label: "🧪 Test a dive with the app (20 swipes)", cmd: { cmd: "test-dive" } });
        else o.push({ label: "📡 Connect the Saved Scroll app", cmd: { cmd: "remote-pair" } });
        o.push({ label: "📥 Import my TikTok export", cmd: { cmd: "import" } });
        o.push({ label: "❓ How do I get my export?", say: "TikTok › Profile › ☰ › Settings and privacy › Account › Download your data › JSON › Request. When it's ready, put user_data_tiktok.json in Files › iCloud Drive › Scriptable › SavedScroll, then choose Import." });
        if (!info.remote) o.push({ label: "🧪 Old test dive (Switch Control, can't stop)", cmd: { cmd: "test-dive" } });
        return list("Saved Scroll", o);
      }
      const o = [];
      if (info.remote && info.remote.busy) o.push({ label: `⏹ Stop the Remote (${info.remote.done}/${info.remote.planned} swipes)`, cmd: { cmd: "remote-stop" } });
      if (info.armed) o.push({ label: `▶️ Start: ${info.armed.split("\n")[0]}`, cmd: { cmd: "start" } });
      if (info.pending) o.push({ label: "✅ Check where I landed (copied link)", cmd: { cmd: "arrived", link: clip } });
      o.push({ label: "🗓 Go to a month…", go: "years", ctx: { mode: "month" } });
      o.push({ label: "📅 Go to a day…", go: "years", ctx: { mode: "day" } });
      if (clipIsVideo) {
        o.push({ label: "🎯 Go to the copied video", cmd: { cmd: "plan", target: clip } });
        o.push({ label: "📌 Pin the copied video", cmd: { cmd: "pin", link: clip } });
        o.push({ label: "📍 Where is the copied video?", cmd: { cmd: "where", link: clip } });
      }
      if (info.pins.length) o.push({ label: `↩️ Last checkpoint: ${info.pins[0].label}`, cmd: { cmd: "plan", target: "pin" } });
      if (info.pins.length > 1) o.push({ label: "↩️ Other checkpoints…", go: "pins" });
      if (info.phases.length) o.push({ label: "🏷 Go to a phase…", go: "phases" });
      o.push({ label: "🔁 TikTok restarted or jumped to the top…", go: "resume" });
      o.push({ label: "⚙️ More…", go: "more", ctx: { remotePaired: !!info.remote } });
      return list("Saved Scroll", o);
    }
    if (name === "years") {
      const { years = [] } = await run({ cmd: "calendar" });
      return list(ctx.mode === "day" ? "Which year? (day)" : "Which year?", years.map(y => ({ label: `${y.year} · ${n(y.count)} saves`, go: "months", ctx: { ...ctx, year: y.year } })));
    }
    if (name === "months") {
      const { months = [] } = await run({ cmd: "calendar", year: ctx.year });
      return list(`${ctx.year}: which month?`, months.map(m => {
        const label = `${MONTHS[m.month - 1]} ${ctx.year} · ${n(m.count)} saves`;
        const ym = `${ctx.year}-${String(m.month).padStart(2, "0")}`;
        return ctx.mode === "day" ? { label, go: "days", ctx: { ...ctx, month: m.month } } : { label, cmd: { cmd: "plan", target: ym } };
      }));
    }
    if (name === "days") {
      const { days = [] } = await run({ cmd: "calendar", year: ctx.year, month: ctx.month });
      return list(`${MONTHS[ctx.month - 1]} ${ctx.year}: which day?`, days.map(d => {
        const date = `${ctx.year}-${String(ctx.month).padStart(2, "0")}-${String(d.day).padStart(2, "0")}`;
        return { label: `${WEEKDAYS[new Date(Date.UTC(ctx.year, ctx.month - 1, d.day)).getUTCDay()]} ${d.day} ${MONTHS[ctx.month - 1].slice(0, 3)} · ${n(d.count)} saves`, cmd: { cmd: "plan", target: date } };
      }));
    }
    if (name === "pins") {
      const info = await run({ cmd: "menu-info" });
      return list("Which checkpoint?", info.pins.map(p => ({ label: p.label, cmd: { cmd: "plan", target: `pin:${p.i}` } })));
    }
    if (name === "phases") {
      const info = await run({ cmd: "menu-info" });
      return list("Which phase?", info.phases.map(p => ({ label: p, cmd: { cmd: "plan", target: `phase:${p}` } })));
    }
    if (name === "resume") return list("What happened?", [
      { label: "TikTok restarted (Saved is back at the top, slow to load)", cmd: { cmd: "event", kind: "tiktok-restarted" }, say: "Got it. Open Profile › ☰ › Watch history, Copy link on the last video you watched, then tap the button › Go to the copied video." },
      { label: "Saving a video jumped Saved to the top", cmd: { cmd: "event", kind: "saved-a-video" }, say: "Got it. TikTok reloads Saved after a save, so the way back is a normal dive. Tip: before saving from For You, Copy link on your spot in Saved › button › Pin, then button › Last checkpoint to return." },
      { label: "Saved is still where I left it", cmd: { cmd: "event", kind: "grid-kept" }, say: "Nice: nothing to do. The brain learns how long TikTok keeps your place." },
    ]);
    if (name === "more") return list("More", [
      { label: "📥 Import a new TikTok export", cmd: { cmd: "import" } },
      { label: "🏷 Save a new phase…", go: "phase-name" },
      { label: "📋 My phases and suggestions", cmd: { cmd: "phases" } },
      { label: "🎚 Which swipe pattern I recorded…", go: "pattern" },
      { label: "⏱ Most swipes queued at once…", go: "batch" },
      { label: "ℹ️ Status", cmd: { cmd: "status" } },
      { label: "🧪 Test a dive (2 min)", cmd: { cmd: "test-dive" } },
      ctx.remotePaired ? { label: "📡 Forget the SS Remote", cmd: { cmd: "remote-forget" } } : { label: "📡 Connect the Saved Scroll app (or an SS Remote)", cmd: { cmd: "remote-pair" } },
    ]);
    if (name === "pattern") return list("How did you record your swipes?", nav.RECIPES.map(r => ({ label: `${r.id}: ${r.strokes} long swipes, one every ${r.interval} s (${r.runSec} s per tap)`, cmd: { cmd: "pattern", recipe: r.id } })));
    if (name === "batch") return list("Most taps queued at once (= the longest you'd wait to stop a dive)", [6, 12, 18, 30].map(t => ({ label: `${t} taps · stop within ~${Math.round(t * 10 / 6) / 10} min${t === 12 ? " (default)" : ""}`, cmd: { cmd: "batch", taps: t } })));
    if (name === "phase-name") return text("Name the phase (e.g. Japan trip)", "phase-from");
    return finish({ ok: false, text: "Something went wrong with the menu. Tap the button again." });
  }

  async function act(opt) {
    if (opt.go) return screen(opt.go, opt.ctx || {});
    if (opt.cmd) {
      const c = { ...opt.cmd };
      if (c.cmd === "plan" || c.cmd === "pattern" || c.cmd === "start") c.net = net;
      if (c.cmd === "plan" || c.cmd === "start") c.clip = clip;
      if ((c.cmd === "arrived" || c.cmd === "pin" || c.cmd === "where") && !clipIsVideo) return finish({ ok: false, text: "First copy a video's link in TikTok (Share › Copy link), then tap the button again." });
      if (c.cmd === "start" && c.top) delete c.clip;
      const r = await run(c);
      if (r.armed) {                              // position unknown: ask now instead of ending the menu
        const o = [], info = await run({ cmd: "menu-info" });
        if (info.remote && info.remote.ready && !info.remote.busy) o.push({ label: `🤖 Start from wherever I am (${info.remote.app ? "Saved Scroll" : "the Remote"} goes up to the top first)`, cmd: { cmd: "start", viaTop: true } });
        if (clipFresh && !(c.cmd === "plan" && c.target === clip)) o.push({ label: "▶️ Start from the video I just copied", cmd: { cmd: "start", fromClip: true } });
        o.push({ label: "▶️ Start: Saved is at the very top", cmd: { cmd: "start", top: true } });
        o.push({ label: "📋 I'm further down: I'll copy a video link first", say: r.text });
        return list("Where are you in Saved right now?", o);
      }
      return finish(opt.say ? { ...r, text: opt.say } : r);
    }
    return finish({ ok: true, text: opt.say || "" });
  }

  if (fresh) return screen("top");
  if (saved.kind === "list") {
    const opt = saved.options.find(o => o.label === reply);
    if (!opt) return finish({ ok: false, text: "Nothing chosen." });
    return act(opt);
  }
  // text answers: the phase wizard (name → start → end)
  const ctx = saved.ctx || {};
  if (!reply) return finish({ ok: false, text: "Cancelled." });
  if (saved.then === "phase-from") return text(`“${reply}” starts on? (YYYY-MM-DD, or type copied for the copied video)`, "phase-to", { name: reply });
  if (saved.then === "phase-to") {
    const from = /^copied$/i.test(reply) ? clip : reply;
    return text(`…and ends on? (YYYY-MM-DD, or copied)`, "phase-save", { ...ctx, from });
  }
  if (saved.then === "phase-save") {
    const to = /^copied$/i.test(reply) ? clip : reply;
    return finish(await run({ cmd: "phase", name: ctx.name, from: ctx.from, to }));
  }
  return finish({ ok: false, text: "Cancelled." });
}

function safeJson(s) { try { return JSON.parse(s); } catch { return null; } }

// ---------- Scriptable glue (skipped when tested in Node) ----------
if (typeof Script !== "undefined" && typeof importModule !== "undefined") {
  (async () => {
    const fm = FileManager.iCloud();
    const dir = fm.joinPath(fm.documentsDirectory(), "SavedScroll");
    if (!fm.fileExists(dir)) fm.createDirectory(dir, true);
    const path = f => fm.joinPath(dir, f);
    const ensure = async p => { if (fm.fileExists(p) && !fm.isFileDownloaded(p)) await fm.downloadFileFromiCloud(p); return fm.fileExists(p); };
    for (const f of ["index.txt", "state.json"]) await ensure(path(f));
    const exports = fm.listContents(dir).filter(f => /\.(json|txt)$/i.test(f) && !["index.txt", "state.json"].includes(f));
    for (const f of exports) await ensure(path(f));
    const io = {
      read: (f) => (fm.fileExists(path(f)) ? fm.readString(path(f)) : null),
      write: (f, s) => fm.writeString(path(f), s),
      loadState: () => safeJson(fm.fileExists(path("state.json")) ? fm.readString(path("state.json")) : "{}") || {},
      saveState: s => fm.writeString(path("state.json"), JSON.stringify(s)),
      newestExport: () => exports.sort((a, b) => fm.modificationDate(path(b)) - fm.modificationDate(path(a)))[0] || null,
    };
    const resolveLink = async url => { const r = new Request(url); r.method = "HEAD"; try { await r.load(); } catch (e) {} return (r.response && r.response.url) || url; };
    const input = args.shortcutParameter || args.plainTexts[0] || (config.runsInApp ? "status" : { cmd: "ui", step: 1 });
    const cmdObj = typeof input === "string" ? safeJson(input) || { cmd: input } : input;
    // Remote engines, in order: the Saved Scroll app on this iPhone (app/engine), the laptop (lab/home_remote.py),
    // an ESP32 board on home Wi-Fi, the board's own network. Each has its own key, saved when it's connected.
    const REMOTE_URLS = ["http://127.0.0.1:8787", "http://savedscroll.local:8787", "http://savedscroll.local", "http://192.168.4.1"];
    const tokenKey = base => `ss-remote-token:${base}`;
    const remoteCall = async (path, params = {}, auth = true, timeout = 1.5) => {
      const qs = Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
      for (const base of REMOTE_URLS) {
        if (auth && !Keychain.contains(tokenKey(base))) continue;          // only engines we've connected
        try {
          const r = new Request(`${base}${path}${qs ? "?" + qs : ""}`);
          r.timeoutInterval = base.includes("127.0.0.1") ? 0.8 : timeout;
          if (auth) r.headers = { "X-Token": Keychain.get(tokenKey(base)) };
          let j = await r.loadJSON();
          // The app restarted with a new key (reinstall, weekly renewal, iOS closed it): reconnect by itself
          // (its connect window is open for 3 minutes after the app is opened), then retry once.
          if (j && j.error === "bad token" && auth) {
            const p = new Request(`${base}/pair`); p.timeoutInterval = 1.5;
            const pj = await p.loadJSON();
            if (pj && pj.ok && pj.token) {
              Keychain.set(tokenKey(base), pj.token);
              const r2 = new Request(`${base}${path}${qs ? "?" + qs : ""}`);
              r2.timeoutInterval = r.timeoutInterval;
              r2.headers = { "X-Token": pj.token };
              j = await r2.loadJSON();
            }
          }
          if (j && typeof j === "object" && j.error !== "bad token") return { ...j, base };
        } catch (e) {}
      }
      return null;
    };
    const remote = {
      status: () => remoteCall("/status"),
      dive: p => remoteCall("/dive", p, true, 3),
      stop: () => remoteCall("/stop", {}, true, 3),
      pair: async () => {
        for (const base of REMOTE_URLS) {
          try {
            const r = new Request(`${base}/pair`); r.timeoutInterval = base.includes("127.0.0.1") ? 0.8 : 4;
            const j = await r.loadJSON();
            if (j && j.ok && j.token) { Keychain.set(tokenKey(base), j.token); return { ...j, base }; }
          } catch (e) {}
        }
        return null;
      },
    };
    const env = { core: importModule("core"), nav: importModule("navigator"), store: io, resolveLink, remote };
    // Opening the menu means no dive is running (the button is hidden during dives): drop leftover batch reminders.
    const reminderIds = Array.from({ length: 60 }, (_, i) => `ss-batch-${i + 1}`);
    if (cmdObj.cmd === "ui" && +cmdObj.step === 1) { try { await Notification.removePending(reminderIds); } catch (e) {} }
    const res = cmdObj.cmd === "ui" ? await ui(cmdObj, env) : await main(cmdObj, env);
    for (const [i, rm] of (res.reminders || []).entries()) {
      const note = new Notification();
      note.identifier = reminderIds[i];
      note.title = "Saved Scroll";
      note.body = rm.text;
      note.setTriggerDate(new Date(Date.now() + rm.inSec * 1000));
      try { await note.schedule(); } catch (e) {}
    }
    Script.setShortcutOutput(cmdObj.cmd === "ui" ? res : JSON.stringify(res));
    // Automatic updates: at most every 6 h, only when a menu ends without a dive (never delays a dive).
    if (cmdObj.cmd === "ui" && res.ask === "none") {
      try {
        const stamp = path("update-check.txt"), last = fm.fileExists(stamp) ? Number(fm.readString(stamp)) || 0 : 0;
        if (Date.now() - last > 6 * 3600e3 && fm.fileExists(fm.joinPath(fm.documentsDirectory(), "ssinstall.js"))) {
          fm.writeString(stamp, String(Date.now()));
          const cur = fm.fileExists(path("version.txt")) ? fm.readString(path("version.txt")).slice(0, 7) : "";
          const up = await importModule("ssinstall").runFromScriptable({ currentSha: cur });
          if (up && up.ok && !up.upToDate) {
            const nt = new Notification(); nt.title = "Saved Scroll updated"; nt.body = `${up.version}. New features are ready next time you tap the button.`; await nt.schedule();
          }
        }
      } catch (e) {}
    }
    const say = res.notify || (cmdObj.cmd !== "ui" && !config.runsInApp && cmdObj.notify ? res.text : "");
    if (say && !config.runsInApp) { const note = new Notification(); note.title = "Saved Scroll"; note.body = say; await note.schedule(); }
    if (config.runsInApp) { const a = new Alert(); a.message = res.notify || res.text || JSON.stringify(res); await a.present(); }
    Script.complete();
  })();
}

if (typeof module !== "undefined") module.exports = { main, ui };
