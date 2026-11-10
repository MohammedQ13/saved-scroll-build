// Engine-era navigator. Position is measured in export ranks so a prefix of new
// saves cancels when subtracting two anchors. Motion and anchor identity supply
// independent evidence. The planner only moves from a verified observation.
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
const dot = (a, b) => a.reduce((sum, v, i) => sum + v * b[i], 0);
const normal = rng => Math.sqrt(-2 * Math.log(1 - rng())) * Math.cos(2 * Math.PI * rng());
const BASE = { iv: 1000, dy: 400, dur: 180 };
const RHYTHMS = [BASE, { ...BASE, iv: 1150 }, { ...BASE, iv: 1400 }];
const PROBE_OFFSETS = [0, 3, 2, 1, 4, 5, 6, 7, 8]; // first three are the initial localization probes
const TOLERANCE = 5;
const MAX_LEGS = 56;
const DEFAULT_TUNING = { coldAim: 0.5, warmAim: 0.9, shortMs: 150000, longMs: 360000, fineAt: 55, scout: 14 };

function features(context, rhythm, depth, warm) {
  const { battery, charging, lowPower, thermal, network, constrained, expensive, hour, weekday, month, rttMs } = context || {};
  return [1, Math.log(rhythm.iv / BASE.iv), Math.log(Math.abs(rhythm.dy) / BASE.dy),
    Math.log(BASE.dur / rhythm.dur), Math.log1p(Math.max(0, depth) / 3000),
    network === "cell" ? 1 : 0, network === "wifi" ? 1 : 0, constrained ? 1 : 0,
    Number.isFinite(battery) ? battery - 0.5 : 0, charging ? 1 : 0, lowPower ? 1 : 0,
    Number.isFinite(thermal) ? thermal / 3 : 0,
    Number.isFinite(hour) ? Math.sin(hour * Math.PI / 12) : 0,
    Number.isFinite(hour) ? Math.cos(hour * Math.PI / 12) : 0,
    weekday === 1 || weekday === 7 ? 1 : 0,
    Number.isFinite(rttMs) ? clamp(Math.log(Math.max(1, rttMs) / 100), -2, 3) : 0,
    warm ? 0 : Number(network === "cell") * Math.log(rhythm.iv / BASE.iv),
    expensive ? 1 : 0, Number.isFinite(month) ? Math.sin(month * Math.PI / 6) : 0,
    Number.isFinite(month) ? Math.cos(month * Math.PI / 6) : 0];
}

// Recursive Bayesian linear regression on log(saves/swipe). Zero-centred
// feature priors shrink incidental correlations until observations support them.
function model(warm) {
  const mean = features({}, BASE, 1, warm).map((_, i) => i === 0 ? Math.log(warm ? 41 : 11) : 0);
  return { mean, cov: mean.map((_, i) => mean.map((_, j) => i === j ? (i === 0 ? 0.12 : 0.025) : 0)) };
}

function predict(fit, x) {
  const cx = fit.cov.map(row => dot(row, x));
  return { mu: dot(fit.mean, x), variance: Math.max(0, dot(cx, x)), cx };
}

function update(fit, x, y, noise) {
  const { mu, variance, cx } = predict(fit, x);
  const scale = 1 / (noise + variance);
  const residual = clamp(y - mu, -1.3, 1.3);
  fit.mean = fit.mean.map((v, i) => v + cx[i] * scale * residual);
  fit.cov = fit.cov.map((r, i) => r.map((v, j) => v - cx[i] * cx[j] * scale + (i === j ? 0.0001 : 0)));
}

function sampleParameters(fit, rng) {
  const size = fit.mean.length;
  const lower = Array.from({ length: size }, () => Array(size).fill(0));
  for (let i = 0; i < size; i++) {
    for (let j = 0; j <= i; j++) {
      let value = fit.cov[i][j];
      for (let k = 0; k < j; k++) value -= lower[i][k] * lower[j][k];
      lower[i][j] = i === j ? Math.sqrt(Math.max(value, 1e-12)) : value / lower[j][j];
    }
  }
  const draw = fit.mean.map(() => normal(rng));
  return fit.mean.map((mu, i) => mu + dot(lower[i], draw));
}

function readPrior(value) {
  const width = model(false).mean.length;
  const vector = x => Array.isArray(x) && x.length === width && x.every(v => Number.isFinite(v) && Math.abs(v) <= 12);
  const fit = m => vector(m?.mean) && Array.isArray(m.cov) && m.cov.length === width &&
    m.cov.every((row, i) => vector(row) && row[i] > 0 && row[i] <= 1);
  return value?.version === 1 && Number.isFinite(value.trainedThrough) && fit(value.warm) && fit(value.cold)
    ? { cold: value.cold, warm: value.warm, trainedThrough: value.trainedThrough } : null;
}

function create(target, total, { witness = "on-surprise", verifySpan = false, tuning = DEFAULT_TUNING, leading = false, cache = null } = {}) {
  return { target, total, rank: null, frontier: null, observations: [], action: null, legs: 0, stalled: 0,
    session: { mu: 0, var: 0.32 }, warmSession: { mu: 0, var: 0.15 }, prediction: null, scouts: 0, witness,
    verifySpan, terminalProbes: 0, terminalEvidence: null, tuning, leading, cache };
}

function check(row = 0) { return { ...BASE, n: 0, row }; }

function verificationSlots(target, rank, used = []) {
  return PROBE_OFFSETS.map((offset, row) => ({ row, distance: Math.abs(rank + offset - target) }))
    .filter(p => !used.includes(p.row))
    .sort((a, b) => a.distance - b.distance)
    .slice(0, 2).map(p => p.row);
}

function dateAim(firstRank, count) { return firstRank + Math.min(6, Math.floor((count - 1) / 2)); }

// Anchor proposals let the filter recover from a reset or speed surprise.
// Model nearby rows as noisy measurements of row zero. A uniform contamination
// component covers relocated saves, unrelated tiles, and bad clipboard reads.
function localize(jump, rank, row, rng = Math.random) {
  jump.observations.push({ rank, row });
  const anchors = jump.observations.filter(a => Number.isFinite(a.rank));
  const motion = jump.prediction;
  const proposal = anchors.map(a => a.rank - PROBE_OFFSETS[a.row]);
  if (motion) proposal.push(motion.pos);
  if (!proposal.length) return null;
  const candidates = proposal.flatMap(pos => [pos, ...Array.from({ length: 47 }, () => pos + normal(rng) * (motion && pos === motion.pos ? motion.sd : 3))]);
  const particles = candidates.map(pos => {
    const prior = motion ? 0.2 + 0.8 * Math.exp(-0.5 * ((pos - motion.pos) / motion.sd) ** 2) : 1;
    const likelihood = anchors.reduce((p, a) => p * (0.025 + 0.975 * Math.exp(-0.5 * ((pos + PROBE_OFFSETS[a.row] - a.rank) / 3) ** 2)), prior);
    return { pos, likelihood };
  }).sort((a, b) => a.pos - b.pos);
  const totalWeight = particles.reduce((sum, p) => sum + p.likelihood, 0);
  function quantile(q) {
    let weight = 0;
    return particles.find(p => (weight += p.likelihood) >= q * totalWeight).pos;
  }
  const compatible = anchors.filter(a => anchors.some(b => {
    const delta = PROBE_OFFSETS[a.row] - PROBE_OFFSETS[b.row];
    return delta !== 0 && Math.sign(a.rank - b.rank) === Math.sign(delta) &&
      Math.abs((a.rank - b.rank) - delta) <= 9;
  }));
  // Using the primary link verbatim when corroborated avoids blurring an exact
  // ID match across dates. A lone anchor needs a plausible odometry prior.
  const estimate = compatible.length ? compatible[0].rank - PROBE_OFFSETS[compatible[0].row] : proposal[0];
  const plausible = motion && Math.abs(estimate - motion.pos) < 2.4 * motion.sd;
  const near = Math.abs(estimate - jump.target) <= 40;
  const verified = compatible.length >= 2 || (anchors.length === 1 && jump.observations.length === 1 && plausible && !near && !motion?.terminal);
  return { rank: clamp(estimate, 1, jump.total), lo: quantile(0.1), hi: quantile(0.9), verified,
    corroborated: compatible.length >= 2, row: compatible[0]?.row ?? anchors[0]?.row,
    anchors: compatible.map(a => a.rank), probes: compatible.map(a => a.row) };
}

function plan(jump, learned, context = {}, { rng = Math.random, explore = false, calibrate = false, forecast = null } = {}) {
  if (jump.rank == null) return check();
  const close = Math.abs(jump.target - jump.rank) <= 55;
  const aimRank = jump.leading && close ? Math.max(1, jump.target - 2) : jump.target;
  const remaining = aimRank - jump.rank, distance = Math.abs(remaining);
  const warm = remaining < 0 || jump.frontier >= jump.target;
  const tuning = jump.tuning || DEFAULT_TUNING;
  const fine = distance <= tuning.fineAt || (jump.stalled > 0 && distance <= 120);
  const direction = Math.sign(remaining);
  const key = warm ? "warm" : "cold";
  const fit = jump.provisionalFits?.[key] || learned[key] || model(warm);
  const session = warm ? jump.warmSession : jump.session;
  // Sub-row gestures are intentionally slow and spaced apart to avoid a fling.
  const eligible = !fine && !warm && distance > 700 && !context.lowPower && !(context.thermal >= 2);
  const randomized = eligible && calibrate;
  // GridLab GL-04 found 5%-height drags could open posts. Use at least 10%.
  const fineMinimum = jump.stalled > 0 ? (tuning.stallBoost || 160) : 100;
  const rhythms = fine ? [{ iv: 1000, dy: clamp(Math.round(distance * 10), fineMinimum, 240), dur: 480 }]
    : randomized ? [RHYTHMS[Math.floor(rng() * RHYTHMS.length)]]
    : eligible && explore ? RHYTHMS : [BASE];
  const draw = rhythms.length > 1 ? sampleParameters(fit, rng) : null;
  let best;
  for (const rhythm of rhythms) {
    const x = features(context, rhythm, jump.rank, warm);
    const { mu, variance } = predict(fit, x);
    const per = fine ? Math.abs(rhythm.dy) / 16 : clamp(Math.exp(mu + session.mu), 1, 90);
    const value = (draw ? dot(draw, x) : Math.log(per)) - Math.log(rhythm.iv);
    if (!best || value > best.value) best = { rhythm, x, per, mu, variance, value };
  }
  const { rhythm, x, per, mu, variance } = best;
  const sd = fine ? 0.28 : Math.sqrt(0.08 + variance + session.var);
  const aim = fine ? 1 : warm ? tuning.warmAim : Math.exp(-tuning.coldAim * sd);
  const maxMs = randomized ? 45000 : !warm && distance > 3000 ? tuning.longMs : tuning.shortMs;
  const cap = Math.floor(maxMs / rhythm.iv);
  let n = clamp(Math.round(distance * aim / per), 1, cap);
  let travel = per * n, spread = travel * sd;
  if (forecast && !fine && distance > 250 && n >= 8) {
    let bestCost = Infinity;
    let chosenCount = n;
    for (const k of [0.65, 0.85, 1, 1.25, 1.55]) {
      const candidate = clamp(Math.round(n * k), 4, cap);
      const [lo, mid, hi] = forecast({ jump, warm, n: candidate, ...rhythm });
      const remaining = value => Math.max(0, distance - value) / Math.max(2, per) +
        Math.max(0, value - distance) / 35;
      const cost = candidate * rhythm.iv / 1000 + 0.2 * remaining(lo) + 0.6 * remaining(mid) + 0.2 * remaining(hi);
      if (cost >= bestCost) continue;
      bestCost = cost;
      travel = mid;
      spread = Math.max(8, (hi - lo) / 3.29);
      chosenCount = candidate;
    }
    n = chosenCount;
  }
  jump.prediction = { pos: clamp(jump.rank + direction * travel, 1, jump.total),
    sd: Math.max(8, Math.hypot(spread, jump.positionSpread || 0)), from: jump.rank, warm, fine, x, mu, n, direction, iv: rhythm.iv };
  jump.legs++;
  return { ...rhythm, dy: direction * rhythm.dy, n, row: 0, ...(randomized ? { propensity: 1 / RHYTHMS.length } : {}) };
}

// Returns a check or a terminal outcome. After a confirmed reading the caller
// chooses the next leg with fresh context. Retry from other rows without motion.
function observe(jump, learned, rank, row, { rng = Math.random, done } = {}) {
  const loc = localize(jump, rank, row, rng);
  if (!loc?.verified) {
    if (jump.preferredInitialProbe && jump.rank == null && jump.legs === 0) {
      if (jump.observations.length < 3) {
        const next = [0, 1, 2].find(candidate => !jump.observations.some(read => read.row === candidate));
        if (next != null) return { action: check(next), reason: "confirm" };
      }
    } else if (row < 2) {
      return { action: check(row + 1), reason: "confirm" };
    }
    if (jump.scouts < 4 && jump.legs < MAX_LEGS) {
      const anchor = jump.observations.find(a => Number.isFinite(a.rank));
      const nearEnd = anchor && anchor.rank > jump.total - 20;
      const nearTop = jump.rank != null && (jump.target <= 35 ||
        (jump.rank <= 130 && jump.prediction?.direction < 0 && jump.prediction.pos <= 16));
      const retreat = !nearTop && (nearEnd || jump.scouts === 3 || jump.rank != null);
      const coarseTop = nearTop && jump.scouts >= 2;
      const shortInitial = jump.tuning?.shortInitial && !jump.shortInitialTried &&
        jump.rank == null && jump.target <= 35 && jump.scouts === 0;
      const n = shortInitial ? 1 : nearTop ? (coarseTop ? 4 * (jump.scouts - 1) : jump.scouts + 1) :
        jump.rank == null && !retreat ? (jump.tuning || DEFAULT_TUNING).scout * (jump.scouts + 1) : 2;
      if (shortInitial) jump.shortInitialTried = true;
      else jump.scouts++;
      jump.legs++;
      jump.observations = [];
      jump.prediction = null;
      const action = shortInitial ? { ...BASE, dy: 240 } :
        nearTop && !coarseTop ? { ...BASE, dy: 140, dur: 480 } : { ...BASE, dy: retreat ? -240 : BASE.dy };
      return { action: { ...action, n, row: 0 }, reason: "scout" };
    }
    return { failed: "Couldn't locate this spot from the visible saves. Open your Saved grid and try again." };
  }
  const p = jump.prediction;
  const priorRank = jump.rank;
  jump.rank = loc.rank;
  jump.positionSpread = loc.corroborated ? 3 : clamp((loc.hi - loc.lo) / 2, 3, 20);
  jump.frontier = Math.max(jump.frontier || 0, loc.rank);
  if (priorRank == null && loc.corroborated && jump.cache && Math.abs(jump.cache.rank - loc.rank) <= 150) {
    jump.frontier = Math.max(jump.frontier, jump.cache.frontier);
    jump.retainedFrontier = jump.frontier > loc.rank;
  }
  jump.observations = [];
  jump.scouts = 0;
  jump.prediction = null;
  let sample;
  // A jump back toward the top during a downward leg invalidates the idea
  // that anything near the old frontier is still loaded.
  const reset = p && p.direction > 0 && loc.corroborated && loc.rank < p.from - 30;
  const cacheMiss = p && jump.retainedFrontier && p.warm && !p.fine && p.direction > 0 && p.n >= 6 &&
    loc.rank - p.from < Math.abs(p.pos - p.from) * 0.35;
  if (cacheMiss) {
    jump.frontier = loc.rank;
    jump.retainedFrontier = false;
    if (jump.provisionalFits) delete jump.provisionalFits.warm;
  }
  if (reset) {
    jump.frontier = loc.rank;
    jump.session = { mu: 0, var: 0.32 };
    jump.warmSession = { mu: 0, var: 0.15 };
    jump.terminalEvidence = null;
    jump.recentMotion = null;
    jump.retainedFrontier = false;
    jump.provisionalFits = null;
  }
  const error = loc.rank - jump.target;
  const suspect = p && loc.corroborated && Math.abs(loc.rank - p.pos) > 2.4 * p.sd;
  // A pair may be from one block re-saved in order. An independent reading
  // after moving breaks many such aliases before a large blind leg.
  const needsWitness = (jump.witness === "always" && priorRank == null) ||
    (jump.witness !== "off" && (reset || (suspect && Math.abs(error) <= TOLERANCE)));
  if (needsWitness && loc.corroborated && !p?.witness && jump.legs < MAX_LEGS) {
    const direction = loc.rank < jump.total - 150 ? 1 : -1;
    const n = 5;
    jump.prediction = { witness: true, from: loc.rank, direction, n,
      pos: clamp(loc.rank + direction * 45, 1, jump.total), sd: 60 };
    jump.legs++;
    return { action: { ...BASE, dy: direction * BASE.dy, n, row: 0 }, reason: "witness" };
  }
  if (p?.terminal) {
    const moved = (loc.rank - p.from) * p.direction;
    if (loc.corroborated && moved >= 30 && moved <= 330) jump.terminalEvidence = p.from;
  }
  if (p) {
    const moved = (loc.rank - p.from) * p.direction;
    if (moved > 0 && !p.fine && !p.witness && !p.terminal) jump.recentMotion = { per: moved / p.n, iv: p.iv };
    jump.stalled = Math.abs(loc.rank - priorRank) < 2 ? jump.stalled + 1 : 0;
    if (!cacheMiss && !p.witness && !p.terminal && !p.fine && p.n >= 6 && done === p.n && moved >= 3 && loc.row === 0 &&
        (p.warm || p.direction > 0) && Math.abs(loc.rank - p.pos) <= 3 * p.sd) {
      const key = p.warm ? "warm" : "cold";
      const session = p.warm ? jump.warmSession : jump.session;
      const y = Math.log(moved / done);
      const innovation = clamp(y - p.mu - session.mu, -1.3, 1.3);
      const gain = session.var / (session.var + 0.09);
      const label = y - session.mu;
      const noise = 0.6 + session.var;
      if (loc.corroborated) {
        const fit = learned[key] || (learned[key] = model(p.warm));
        update(fit, p.x, label, noise);
        learned.samples = (learned.samples || 0) + 1;
        sample = { warm: p.warm, x: p.x, y, verified: true };
      } else if (!jump.provisionalFits?.[key]) {
        // Copy the last corroborated fit. An uncertain reading can help this
        // jump adapt without altering the model used by future jumps.
        (jump.provisionalFits ??= {})[key] = { ...(learned[key] || model(p.warm)) };
      }
      if (jump.provisionalFits?.[key]) update(jump.provisionalFits[key], p.x, label, noise);
      session.mu = clamp(session.mu + gain * innovation, -1.4, 1.4);
      session.var = Math.max(0.04, (1 - gain) * session.var + 0.025);
    }
  }
  if (Math.abs(error) <= TOLERANCE && loc.corroborated && (!jump.leading || error <= 1)) {
    if (!jump.verifySpan || (jump.terminalEvidence != null && Math.abs(jump.terminalEvidence - loc.rank) <= TOLERANCE * 2)) {
      return { done: true, error, sample, anchors: loc.anchors, probes: loc.probes };
    }
    if (jump.terminalProbes < 2 && jump.legs < MAX_LEGS) {
      const direction = jump.terminalProbes || loc.rank > jump.total - 400 ? -1 : 1;
      const n = 6;
      jump.terminalProbes++;
      jump.legs++;
      jump.prediction = { terminal: true, from: loc.rank, n, direction,
        pos: clamp(loc.rank + direction * 100, 1, jump.total), sd: 100 };
      return { action: { ...BASE, dy: direction * BASE.dy, n, row: 0 }, reason: "terminal" };
    }
    return { failed: "Couldn't verify this landing across neighboring saves.", error, sample };
  }
  if (jump.legs >= MAX_LEGS || jump.stalled >= 4) return { failed: "Couldn't verify a closer landing.", error, sample };
  return { located: true, error, sample };
}

module.exports = { create, check, plan, observe, verificationSlots, dateAim, model, predict, update, readPrior,
  PROBE_OFFSETS, TOLERANCE, DEFAULT_TUNING };
