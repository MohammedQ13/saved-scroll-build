// Engine-era navigator. Position is measured in export ranks so a prefix of new
// saves cancels when subtracting two anchors. Motion and anchor identity supply
// independent evidence. The planner only moves from a verified observation.
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
const dot = (a, b) => a.reduce((sum, v, i) => sum + v * b[i], 0);
const normal = rng => Math.sqrt(-2 * Math.log(1 - rng())) * Math.cos(2 * Math.PI * rng());
const BASE = { iv: 1000, dy: 400, dur: 180 };
const RHYTHMS = [BASE, { ...BASE, iv: 1150 }, { ...BASE, iv: 1400 }];
const TOLERANCE = 5;
const MAX_LEGS = 48;

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

function create(target, total) {
  return { target, total, rank: null, frontier: null, observations: [], action: null, legs: 0, stalled: 0,
    session: { mu: 0, var: 0.32 }, warmSession: { mu: 0, var: 0.15 }, prediction: null, scouts: 0 };
}

function check(row = 0) { return { ...BASE, n: 0, row }; }

function dateAim(firstRank, count) { return firstRank + Math.min(6, Math.floor((count - 1) / 2)); }

// Anchor proposals let the filter recover from a reset or speed surprise.
// Model nearby rows as noisy measurements of row zero. A uniform contamination
// component covers relocated saves, unrelated tiles, and bad clipboard reads.
function localize(jump, rank, row, rng = Math.random) {
  jump.observations.push({ rank, row });
  const anchors = jump.observations.filter(a => Number.isFinite(a.rank));
  const motion = jump.prediction;
  const proposal = anchors.map(a => a.rank - a.row * 3);
  if (motion) proposal.push(motion.pos);
  if (!proposal.length) return null;
  const candidates = proposal.flatMap(pos => [pos, ...Array.from({ length: 47 }, () => pos + normal(rng) * (motion && pos === motion.pos ? motion.sd : 3))]);
  const particles = candidates.map(pos => {
    const prior = motion ? 0.2 + 0.8 * Math.exp(-0.5 * ((pos - motion.pos) / motion.sd) ** 2) : 1;
    const likelihood = anchors.reduce((p, a) => p * (0.025 + 0.975 * Math.exp(-0.5 * ((pos + a.row * 3 - a.rank) / 3) ** 2)), prior);
    return { pos, likelihood };
  }).sort((a, b) => a.pos - b.pos);
  const totalWeight = particles.reduce((sum, p) => sum + p.likelihood, 0);
  function quantile(q) {
    let weight = 0;
    return particles.find(p => (weight += p.likelihood) >= q * totalWeight).pos;
  }
  const compatible = anchors.filter(a => anchors.some(b =>
    a.row !== b.row && a.rank !== b.rank && Math.sign(a.rank - b.rank) === Math.sign(a.row - b.row) &&
    Math.abs((a.rank - b.rank) - 3 * (a.row - b.row)) <= 9));
  // Using the primary link verbatim when corroborated avoids blurring an exact
  // ID match across dates. A lone anchor needs a plausible odometry prior.
  const estimate = compatible.length ? compatible[0].rank - 3 * compatible[0].row : proposal[0];
  const plausible = motion && Math.abs(estimate - motion.pos) < 2.4 * motion.sd;
  const near = Math.abs(estimate - jump.target) <= 40;
  const verified = compatible.length >= 2 || (anchors.length === 1 && jump.observations.length === 1 && plausible && !near);
  return { rank: clamp(estimate, 1, jump.total), lo: quantile(0.1), hi: quantile(0.9), verified,
    corroborated: compatible.length >= 2, row: compatible[0]?.row ?? anchors[0]?.row };
}

function plan(jump, learned, context = {}, { rng = Math.random, explore = false } = {}) {
  if (jump.rank == null) return check();
  const remaining = jump.target - jump.rank, distance = Math.abs(remaining);
  const warm = remaining < 0 || jump.frontier >= jump.target;
  const fine = distance <= 55 || (jump.stalled > 0 && distance <= 120);
  const direction = Math.sign(remaining);
  const fit = learned[warm ? "warm" : "cold"] || model(warm);
  const session = warm ? jump.warmSession : jump.session;
  // Sub-row gestures are intentionally slow and spaced apart to avoid a fling.
  const rhythms = fine ? [{ iv: 1000, dy: clamp(Math.round(distance * 10), 45, 240), dur: 480 }]
    : explore && !warm && distance > 700 && !context.lowPower && !(context.thermal >= 2) ? RHYTHMS : [BASE];
  let best;
  for (const rhythm of rhythms) {
    const x = features(context, rhythm, jump.rank, warm);
    const { mu, variance } = predict(fit, x);
    const per = fine ? Math.abs(rhythm.dy) / 16 : clamp(Math.exp(mu + session.mu), 2, 90);
    const value = (Math.log(per) - Math.log(rhythm.iv)) + (rhythms.length > 1 ? Math.sqrt(variance) * normal(rng) : 0);
    if (!best || value > best.value) best = { rhythm, x, per, mu, variance, value };
  }
  const { rhythm, x, per, mu, variance } = best;
  const sd = fine ? 0.28 : Math.sqrt(0.08 + variance + session.var);
  const aim = fine ? 1 : warm ? 0.9 : Math.exp(-0.5 * sd);
  const n = clamp(Math.round(distance * aim / per), 1, Math.floor(215000 / rhythm.iv));
  jump.prediction = { pos: clamp(jump.rank + direction * per * n, 1, jump.total),
    sd: Math.max(8, Math.hypot(per * n * sd, jump.positionSpread || 0)), from: jump.rank, warm, fine, x, mu, n, direction };
  jump.legs++;
  return { ...rhythm, dy: direction * rhythm.dy, n, row: 0 };
}

// Returns a check or a terminal outcome. After a confirmed reading the caller
// chooses the next leg with fresh context. Retry from other rows without motion.
function observe(jump, learned, rank, row, { rng = Math.random, done } = {}) {
  const loc = localize(jump, rank, row, rng);
  if (!loc?.verified) {
    if (row < 2) return { action: check(row + 1), reason: "confirm" };
    if (jump.scouts < 4 && jump.legs < MAX_LEGS) {
      const anchor = jump.observations.find(a => Number.isFinite(a.rank));
      const nearEnd = anchor && anchor.rank > jump.total - 20;
      const retreat = nearEnd || jump.scouts === 3 || jump.rank != null;
      const n = jump.rank == null && !retreat ? 14 * (jump.scouts + 1) : 2;
      jump.scouts++;
      jump.legs++;
      jump.observations = [];
      jump.prediction = null;
      return { action: { ...BASE, dy: retreat ? -240 : BASE.dy, n, row: 0 }, reason: "scout" };
    }
    return { failed: "Couldn't locate this spot from the visible saves. Open your Saved grid and try again." };
  }
  const p = jump.prediction;
  const priorRank = jump.rank;
  jump.rank = loc.rank;
  jump.positionSpread = loc.corroborated ? 3 : clamp((loc.hi - loc.lo) / 2, 3, 20);
  jump.frontier = Math.max(jump.frontier || 0, loc.rank);
  jump.observations = [];
  jump.scouts = 0;
  jump.prediction = null;
  let sample;
  if (p) {
    const moved = (loc.rank - p.from) * p.direction;
    jump.stalled = Math.abs(loc.rank - priorRank) < 2 ? jump.stalled + 1 : 0;
    if (!p.fine && p.n >= 6 && done === p.n && moved >= 3 && loc.row === 0 &&
        (p.warm || p.direction > 0) && Math.abs(loc.rank - p.pos) <= 3 * p.sd) {
      const key = p.warm ? "warm" : "cold";
      const session = p.warm ? jump.warmSession : jump.session;
      const fit = learned[key] || (learned[key] = model(p.warm));
      const y = Math.log(moved / done);
      const innovation = clamp(y - p.mu - session.mu, -1.3, 1.3);
      const gain = session.var / (session.var + 0.09);
      // Learn the global context model with a noisy label from this session.
      update(fit, p.x, y - session.mu, 0.6 + session.var);
      session.mu = clamp(session.mu + gain * innovation, -1.4, 1.4);
      session.var = Math.max(0.04, (1 - gain) * session.var + 0.025);
      learned.samples = (learned.samples || 0) + 1;
      sample = { warm: p.warm, x: p.x, y, verified: loc.corroborated };
    }
  }
  const error = loc.rank - jump.target;
  if (Math.abs(error) <= TOLERANCE && loc.corroborated) return { done: true, error, sample };
  if (jump.legs >= MAX_LEGS || jump.stalled >= 4) return { failed: "Couldn't verify a closer landing.", error, sample };
  return { located: true, error, sample };
}

module.exports = { create, check, plan, observe, dateAim, model, predict, update, TOLERANCE };
