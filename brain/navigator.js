// Saved Scroll navigator: plans jumps through the TikTok Saved grid and learns from every landing.
// Plain JavaScript, no dependencies: runs in Node (testing) and in Scriptable on iPhone.
//
// Model (learned on your phone, updated after every landing)
//   log(speed in saves/second) = recipe effect + network effect + depth effect
//                                + recipe x network interactions (+ more features later)
//   Bayesian linear regression: every jump teaches every part of the model, and the model
//   always knows how unsure it is.
//   Accidental taps (a fast flick read as a tap opens a video) are learned per recipe as
//   a separate rate, so one bad run never poisons the speed estimates.
// Choosing a scroll pattern: Thompson sampling. Draw a plausible speed for each recipe
//   and use the best draw, so it exploits what works and keeps exploring while unsure.
// Aiming: the plan lands at or before the target 80% of the time. Optional midway check
//   ("Where am I?" at ~90%) removes most of the remaining error.

// A Switch Control recording keeps at most 10 strokes (iOS 16+; confirmed on the user's iPhone).
// Each press of the switch plays the recording once, and presses queue up. So a dive is
// "N presses" of a 10-stroke recording, and a recipe is just the spacing between strokes.
// Shorter recordings (fewer swipes per tap) stop sooner if you cancel mid-dive, at the cost of more taps.
const STROKES = 10;
const mk = (strokes, iv) => ({ id: `${strokes}x${iv}s`, strokes, interval: iv, runSec: strokes * iv });
const RECIPES = [...[0.7, 1, 1.5, 2, 3, 4, 6].map(iv => mk(10, iv)), mk(5, 1), mk(3, 1)];
const NETS = ["wifi-good", "wifi-weak", "cell"];
const NUDGE_SEC = null;          // no separate short recording: one recording, N presses
const TOTAL_GUESS = 36000;      // only scales the depth feature
const FORGET = 0.995;           // per-jump decay of old evidence (half-life ~140 jumps)

const R = RECIPES.length, DIM = R + 2 + 1 + 2 * R;
const PRIOR_MEAN = [...Array(R).fill(Math.log(15)), 0, 0, 0, ...Array(2 * R).fill(0)];
const PRIOR_SD = [...Array(R).fill(1.0), 0.5, 0.5, 0.5, ...Array(2 * R).fill(0.3)];

function features(ri, net, depth) {
  const x = new Array(DIM).fill(0);
  const weak = net === "wifi-weak" ? 1 : 0, cell = net === "cell" ? 1 : 0;
  x[ri] = 1; x[R] = weak; x[R + 1] = cell; x[R + 2] = depth / TOTAL_GUESS;
  x[R + 3 + ri] = weak; x[R + 3 + R + ri] = cell;
  return x;
}

function newState() {
  return {
    XtX: Array.from({ length: DIM }, () => new Array(DIM).fill(0)), Xty: new Array(DIM).fill(0), yy: 0, n: 0,
    mistap: RECIPES.map(() => ({ a: 1, b: 15 })),           // prior: taps are rare
    warmNorm: { n: 0, mean: Math.log(40 / 1.4), m2: 0 },     // saves per stroke through loaded grid, momentum removed
    frontier: { pos: 0, at: 0 },                             // deepest loaded point this session
    history: [],
  };
}

// ---------- linear algebra ----------
function inv(A) {
  const n = A.length, M = A.map((r, i) => [...r, ...Array.from({ length: n }, (_, j) => (i === j ? 1 : 0))]);
  for (let c = 0; c < n; c++) {
    let p = c; for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    [M[c], M[p]] = [M[p], M[c]];
    const d = M[c][c]; for (let j = 0; j < 2 * n; j++) M[c][j] /= d;
    for (let r = 0; r < n; r++) if (r !== c) { const f = M[r][c]; if (f) for (let j = 0; j < 2 * n; j++) M[r][j] -= f * M[c][j]; }
  }
  return M.map(r => r.slice(n));
}
const dot = (a, b) => a.reduce((s, v, i) => s + v * b[i], 0);
const mv = (A, x) => A.map(r => dot(r, x));

function posterior(state) {
  let s2 = 0.09, mu, S;
  for (let it = 0; it < 2; it++) {
    const L = state.XtX.map((r, i) => r.map((v, j) => v / s2 + (i === j ? 1 / PRIOR_SD[i] ** 2 : 0)));
    const b = state.Xty.map((v, i) => v / s2 + PRIOR_MEAN[i] / PRIOR_SD[i] ** 2);
    S = inv(L); mu = mv(S, b);
    const rss = Math.max(0, state.yy - 2 * dot(mu, state.Xty) + dot(mu, mv(state.XtX, mu)));
    s2 = (rss + 3 * 0.09) / (state.n + 3);
  }
  return { mu, S, s2 };
}

// inverse normal CDF (Acklam), for aim -> z
function qnorm(p) {
  const a = [-39.69683028665376, 220.9460984245205, -275.9285104469687, 138.357751867269, -30.66479806614716, 2.506628277459239];
  const b = [-54.47609879822406, 161.5858368580409, -155.6989798598866, 66.80131188771972, -13.28068155288572];
  const c = [-0.007784894002430293, -0.3223964580411365, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783];
  const d = [0.007784695709041462, 0.3224671290700398, 2.445134137142996, 3.754408661907416];
  const q = Math.min(Math.max(p, 1e-9), 1 - 1e-9), lo = 0.02425;
  if (q < lo) { const r = Math.sqrt(-2 * Math.log(q)); return (((((c[0] * r + c[1]) * r + c[2]) * r + c[3]) * r + c[4]) * r + c[5]) / ((((d[0] * r + d[1]) * r + d[2]) * r + d[3]) * r + 1); }
  if (q > 1 - lo) return -qnorm(1 - q);
  const r = q - 0.5, t = r * r;
  return (((((a[0] * t + a[1]) * t + a[2]) * t + a[3]) * t + a[4]) * t + a[5]) * r / (((((b[0] * t + b[1]) * t + b[2]) * t + b[3]) * t + b[4]) * t + 1);
}

function randn(rng) { let u = 0, w = 0; while (!u) u = rng(); while (!w) w = rng(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * w); }

// ---------- planning ----------
// from/to: positions from the top of the Saved grid (1 = newest save).
// aim: chance of landing at/before the target. Overshoot is cheap (scroll back up through loaded
// grid), undershoot costs another leg, so legs aim near the middle.
// allowed: recipe ids that can run right now (on the phone: the active Switch Control recipe).
function plan(state, { from, to, net, rng = Math.random, aim = 0.55, allowed = null, runSec = null, nudgeSec = NUDGE_SEC }) {
  const z = qnorm(aim);
  const frontier = Math.max(state.frontier.pos, from);
  const warmDist = Math.max(0, Math.min(to, frontier) - from);
  const coldDist = Math.max(0, to - frontier);
  const depth = frontier + coldDist / 2;
  const post = posterior(state);

  const w = warmNorm(state), wsd = w.n > 2 ? Math.sqrt(w.m2 / (w.n - 1)) : 0.4;
  const warmSpeedOf = r => Math.exp(warmLogPerStroke(state, r)) / r.interval;   // saves/s through loaded grid

  let best = null;
  RECIPES.forEach((r, ri) => {
    if (allowed && !allowed.includes(r.id)) return;
    const x = features(ri, net, depth), m = dot(x, post.mu), v = dot(x, mv(post.S, x));
    const mt = state.mistap[ri], pTap = Math.min(0.95, Math.max(0, mt.a / (mt.a + mt.b) + Math.sqrt(mt.a * mt.b / ((mt.a + mt.b) ** 2 * (mt.a + mt.b + 1))) * randn(rng)));
    // Expected time for this pattern: loaded part + not-yet-loaded part (sampled speed: Thompson).
    const coldDraw = Math.exp(m + Math.sqrt(v) * randn(rng));
    const warmDraw = warmSpeedOf(r) * Math.exp(wsd * randn(rng));
    const sec = warmDist / warmDraw + coldDist / coldDraw;
    // One accidental tap ruins the rest of the dive (it opens a video), so risk grows with dive length.
    const score = Math.pow(1 - pTap, Math.max(1, sec / 60)) / Math.max(sec, 1);
    if (!best || score > best.score) best = { r, ri, m, v, score };
  });

  const fastWarm = warmSpeedOf(best.r) * Math.exp(z * wsd);
  let seconds = 60, coldSec = 0;
  for (let it = 0; it < 3; it++) {                      // noise shrinks over longer dives
    const minutes = Math.max(1, seconds / 60);
    const spread = Math.sqrt(best.v + post.s2 / minutes);
    coldSec = coldDist > 0 ? coldDist / Math.exp(best.m + z * spread) : 0;
    seconds = warmDist / fastWarm + coldSec;
  }
  const run = runSec || best.r.runSec;                  // length of one press (your 10-stroke recording)
  let runs, nudges;
  if (nudgeSec && nudgeSec < run) { runs = Math.floor(seconds / run); nudges = Math.round((seconds - runs * run) / nudgeSec); }
  else { runs = seconds > 0 ? Math.max(1, Math.round(seconds / run)) : 0; nudges = 0; }
  const planned = runs * run + nudges * (nudgeSec || 0);
  return { recipe: best.r.id, ri: best.ri, runs, nudges, presses: runs + nudges, seconds: planned, eta: planned + 3,
           from, to, frontier, warmDist, coldDist, depth, net, interval: best.r.interval,
           expectedSpeed: Math.exp(best.m), warmSpeed: warmSpeedOf(best.r), uncertainty: Math.sqrt(best.v) };
}

// ---------- loaded-grid speed: physics prior + learning ----------
// iOS keeps momentum when swipes come quickly (GridLab bench GL-02: ~4x when <= 0.75 s apart,
// ~1.4x at ~1.1 s, none when slower). The model learns saves per stroke with that effect removed
// (shared across all patterns), plus a shrunk correction per pattern for what physics misses.
function momentum(iv) { return iv <= 0.75 ? 4 : iv <= 1.1 ? 1.4 : 1; }
function warmNorm(state) {
  if (!state.warmNorm) {                                            // migrate older saved states
    const w = state.warm || { n: 0, mean: Math.log(40), m2: 0 };
    state.warmNorm = { n: w.n, mean: w.mean - Math.log(momentum(1)), m2: w.m2 };
  }
  return state.warmNorm;
}
function warmLogPerStroke(state, r) {
  const ri = RECIPES.indexOf(r), w = warmNorm(state);
  const res = state.warmResid && ri >= 0 ? state.warmResid[ri] : null;
  const corr = res && res.n ? (res.sum / res.n) * (res.n / (res.n + 3)) : 0;     // trust a pattern's own data gradually
  return w.mean + Math.log(momentum(r.interval)) + corr;
}

// ---------- learning from a landing ----------
// landed: true position from "Where am I?". mistap: the dive opened a video by accident.
// Returns { outlier: true } when the reading doesn't fit the plan (e.g. the checked video was
// re-saved since the export, so the index still has its old position). Then nothing is learned
// and the caller should check a neighbouring video instead.
function observe(state, pl, { landed, mistap = false, at = Date.now() }) {
  const minutes = Math.max(pl.seconds / 60, 1 / 6);
  if (!mistap) {
    const warmSpeed = pl.warmSpeed, wt = Math.min(pl.seconds, pl.warmDist / warmSpeed);
    const expected = pl.from + wt * warmSpeed + Math.max(0, pl.seconds - wt) * pl.expectedSpeed;
    // Off by more than ~3 standard deviations (in log terms), or behind the start: don't trust it.
    const r = Math.log(Math.max(landed - pl.from, 1) / Math.max(expected - pl.from, 1));
    const limit = Math.max(0.9, 3 * Math.sqrt(pl.uncertainty ** 2 + 0.3 ** 2));
    if (landed < pl.from - 50 || (expected - pl.from > 200 && Math.abs(r) > limit)) return { outlier: true, expected };
  }
  if (pl.seconds < 8) { state.frontier = { pos: Math.max(state.frontier.pos, landed), at }; return { outlier: false, skipped: true }; }
  const mt = state.mistap[pl.ri];
  if (mistap) { mt.a += 1; mt.b += Math.max(0, minutes - 1); }
  else mt.b += minutes;

  const warmTime = pl.warmDist / pl.warmSpeed;
  if (!mistap && pl.coldDist === 0 && pl.warmDist > 0) {
    const r = RECIPES[pl.ri] || { interval: pl.interval };
    const y = Math.log(Math.max(1, landed - pl.from) / Math.max(pl.seconds / pl.interval, 1)) - Math.log(momentum(r.interval));   // per stroke, momentum removed
    const w = warmNorm(state); w.n++; const d = y - w.mean; w.mean += d / w.n; w.m2 += d * (y - w.mean);
    const k = pl.ri; state.warmResid = state.warmResid || RECIPES.map(() => ({ n: 0, sum: 0 }));
    if (state.warmResid[k]) { state.warmResid[k].n++; state.warmResid[k].sum += y - w.mean; }
  } else if (!mistap && pl.coldDist > 0) {
    const coldTime = Math.max(pl.seconds - warmTime, 5);
    const moved = Math.max(1, landed - Math.max(pl.from, pl.frontier));
    const y = Math.log(moved / coldTime), x = features(pl.ri, pl.net, pl.depth);
    const wgt = Math.min(coldTime / 60, 10);              // longer dives are more reliable evidence
    // Slowly forget old evidence (half-life ~140 jumps), so the model adapts when TikTok,
    // your network or your phone changes.
    const keep = FORGET;
    for (let i = 0; i < DIM; i++) { state.Xty[i] *= keep; for (let j = 0; j < DIM; j++) state.XtX[i][j] *= keep; }
    state.yy *= keep; state.n *= keep;
    for (let i = 0; i < DIM; i++) { state.Xty[i] += wgt * x[i] * y; for (let j = 0; j < DIM; j++) state.XtX[i][j] += wgt * x[i] * x[j]; }
    state.yy += wgt * y * y; state.n += wgt;
  }
  state.frontier = { pos: Math.max(state.frontier.pos, landed), at };
  state.history.push({ at, recipe: pl.recipe, net: pl.net, to: pl.to, landed, err: landed - pl.to, sec: pl.seconds, mistap });
  if (state.history.length > 500) state.history.shift();
  return { outlier: false };
}

// Would a different pattern be clearly faster for this network? (expected time incl. tap risk)
function suggest(state, { active, net, depth = 15000, minGain = 0.15 }) {
  const post = posterior(state);
  const value = ri => {
    const x = features(ri, net, depth), mt = state.mistap[ri];
    return Math.exp(dot(x, post.mu)) * Math.pow(1 - mt.a / (mt.a + mt.b), 5);
  };
  const ai = RECIPES.findIndex(r => r.id === active);
  let best = ai;
  RECIPES.forEach((r, ri) => { if (value(ri) > value(best)) best = ri; });
  const gain = value(best) / value(ai) - 1;
  const tried = state.history.filter(h => h.recipe === RECIPES[best].id).length;
  return best !== ai && gain > minGain ? { recipe: RECIPES[best].id, gain, tried } : null;
}

// TikTok restarted or the grid was dropped: everything past the top is cold again.
function sessionReset(state, reason) { state.frontier = { pos: 0, at: Date.now(), reason }; }

if (typeof module !== "undefined") module.exports = { RECIPES, STROKES, NETS, newState, plan, observe, sessionReset, posterior, features, qnorm, suggest, momentum, warmLogPerStroke };
