import { Gfx, softBox, type Ctx, type Env, type Medium, type P } from "./core";
import type { Film } from "./film";
import { letter } from "./drafting";
import { clamp, lerp, mix } from "./gallery";

// CORRESPONDANCE · eight networks, one list. Ink + line-wash on a clear ground (the landing is
// white): the washes carry the only colour, one per network, and a loose flexible nib draws
// over them. No logos: each network is a colour and a bubble shape, the way the site's pastilles
// already name them.
//
// The story in three sentences. Seven bubbles pop up all over, each with its red badge, each
// jittering for attention. They fly, one after another, into a single calm list and become
// rows: the badges are gone, only the network's pastille stays. The list rests, a selection band
// walks down it, then it empties back to the bare card and the noise starts again.
// Token: the red badge. Present on every bubble in the noise, absent from every row in the list.

const T = 240, BEAT = 15; // 8 s at 30 fps, 120 bpm: 15 frames a beat
export const INK = "#111114", RUST = "#8a3f2b", RUST_SOFT = "#f4e9e4", BADGE = "#d8412f";
export const INK_M: Medium = { nib: 1.5, taper: 1, pressure: 1.5, retrace: false, wobble: 1.2, rough: 0.6 };

// ONE cue table. Every frame number in the loop lives here; the checker below runs at load.
const CUE = {
  pop: 5, popEvery: 5, popLen: 20,        // bubble i starts drawing at pop + i*popEvery
  fly: 70, flyEvery: 10, flyLen: 35,      // bubble i leaves at fly + i*flyEvery (last lands at 175)
  sweep: [175, 205] as [number, number],  // the selection band walks down the rows
  clear: 205, clearEvery: 2, clearLen: 14, // rows dissolve, top first; empty card by 233
};
(() => { const bad: string[] = []; const on5 = (n: number, k: string) => { if (n % 5) bad.push(`${k}=${n} off the 5-frame grid`); if (n > T) bad.push(`${k}=${n} past the end`); };
  for (let i = 0; i < 8; i++) { on5(CUE.pop + i * CUE.popEvery, `pop${i}`); on5(CUE.fly + i * CUE.flyEvery, `fly${i}`); on5(CUE.fly + i * CUE.flyEvery + CUE.flyLen, `land${i}`); }
  on5(CUE.sweep[0], "sweep0"); on5(CUE.sweep[1], "sweep1"); on5(CUE.clear, "clear");
  if (CUE.clear + 7 * CUE.clearEvery + CUE.clearLen > T - 2) bad.push("rows not cleared before the seam");
  if (bad.length) throw new Error("corresp cue table: " + bad.join("; ")); })();

// the eight, in the site's own network colours, told apart by SHAPE as much as colour:
// e = corner squareness, tail = where the bubble points from, av = an avatar beside it.
// Four wait on the left, three on the right; they leave alternately, so two bubbles in the air
// at once always come from opposite sides and never cross. Rows keep each side's top-to-bottom order.
type Tail = "low" | "corner" | "nub" | "curl" | "none";
type Net = { color: string; e: number; tail: Tail; side: -1 | 1; at: P; w: number; h: number; badge: string; row: number; av?: "square" | "circle" };
const NETS: Net[] = [
  { color: "#34c759", e: 2.3, tail: "low", side: -1, at: [215, 120], w: 180, h: 84, badge: "3", row: 0 },          // iMessage: round, curled tail
  { color: "#25d366", e: 3.0, tail: "corner", side: 1, at: [985, 130], w: 190, h: 82, badge: "12", row: 1 },       // WhatsApp: pointed top corner
  { color: "#3a76f0", e: 2.0, tail: "nub", side: -1, at: [200, 280], w: 176, h: 84, badge: "1", row: 2 },          // Signal: an oval, a small nub
  { color: "#4a154b", e: 7.0, tail: "none", side: 1, at: [1000, 285], w: 170, h: 76, badge: "4", row: 3, av: "square" }, // Slack: a block with a square avatar
  { color: "#e1306c", e: 3.2, tail: "nub", side: -1, at: [230, 440], w: 168, h: 80, badge: "5", row: 4, av: "circle" },  // Instagram: a photo circle beside it
  { color: "#0084ff", e: 2.0, tail: "low", side: 1, at: [975, 445], w: 170, h: 84, badge: "2", row: 5 },           // Messenger: round, soft tail
  { color: "#111114", e: 9.0, tail: "none", side: -1, at: [210, 605], w: 160, h: 70, badge: "9", row: 6 },          // X: a hard square card
  { color: "#2aabee", e: 2.6, tail: "curl", side: 1, at: [990, 600], w: 176, h: 80, badge: "7", row: 7 },          // Telegram: rounded, a small hook curled flat at the bottom left
];
// flight order: left, right, left, right... (index into NETS)
const ORDER = [0, 1, 2, 3, 4, 5, 6, 7];

// the one calm card, centred in the frame
const CARD = { x0: 430, y0: 50, x1: 770, y1: 670 }, ROW0 = 118, ROWH = 67, ROWX = 452, ROWW = 296, ROWHH = 50;
const rowCentre = (r: number): P => [ROWX + ROWW / 2, ROW0 + r * ROWH + ROWHH / 2];

const ease = (v: number) => { const t = clamp(v); return t >= 1 ? 1 : t * t * (3 - 2 * t); };
const span = (f: number, a: number, len: number) => ease((f - a) / len);

// hand-ruled text: a wavy pen line standing in for words (never real text, never a font)
export const scribble = (g: Gfx, x: number, y: number, w: number, seed: number, o: { op?: number; progress?: number; wt?: number } = {}) => {
  const n = Math.max(3, Math.round(w / 22)), pts: P[] = Array.from({ length: n }, (_, i) => [x + (w * i) / (n - 1), y + Math.sin(i * 2.3 + seed) * 1.6] as P);
  g.pen(pts, { w: o.wt ?? 1.3, color: INK, seed, wobble: 0.5, boil: 0.35, opacity: o.op ?? 0.55, retrace: false, taper: 0.8, progress: o.progress ?? 1 });
};

// a bubble at centre c, size w x h, morphing to a row as m goes 0 -> 1
const bubble = (g: Gfx, n: Net, i: number, c: P, w: number, h: number, draw: number, m: number, alpha: number) => {
  const e = lerp(n.e, 4.5, m), outline = softBox(c[0], c[1], w, h, e, 26), tailK = (1 - m) * draw, sd = -n.side; // tails point away from the card
  let tail: P[] = [];
  if (n.tail === "low") { const r1: P = [c[0] + sd * w * 0.24, c[1] + h * 0.44], r2: P = [c[0] + sd * w * 0.4, c[1] + h * 0.34], tip: P = [c[0] + sd * (w * 0.5 + 14), c[1] + h * 0.5 + 12]; tail = [r1, [lerp(r1[0], tip[0], 0.75), lerp(r1[1], tip[1], 0.95)], [lerp(r1[0], tip[0], tailK), lerp(r1[1], tip[1], tailK)], r2]; }
  if (n.tail === "corner") { const r1: P = [c[0] + sd * (w * 0.5 - 22), c[1] - h * 0.5 + 1], r2: P = [c[0] + sd * (w * 0.5 - 2), c[1] - h * 0.5 + 20], tip: P = [c[0] + sd * (w * 0.5 + 16), c[1] - h * 0.5 - 1]; tail = [r1, [lerp(r1[0], tip[0], tailK), lerp(r1[1], tip[1], tailK)], r2]; }
  if (n.tail === "nub") { const r1: P = [c[0] + sd * w * 0.3, c[1] + h * 0.45], r2: P = [c[0] + sd * w * 0.18, c[1] + h * 0.48], tip: P = [c[0] + sd * w * 0.3, c[1] + h * 0.5 + 12]; tail = [r1, [lerp(r1[0], tip[0], tailK), lerp(r1[1], tip[1], tailK)], r2]; }
  if (n.tail === "curl") { const r1: P = [c[0] - w * 0.5 + 26, c[1] + h * 0.5 - 2], r2: P = [c[0] - w * 0.5 + 4, c[1] + h * 0.3], tip: P = [c[0] - w * 0.5 - 14, c[1] + h * 0.5 + 2], hook: P = [c[0] - w * 0.5 - 18, c[1] + h * 0.5 - 8]; tail = [r1, [lerp(r1[0], tip[0], tailK), lerp(r1[1], tip[1], tailK)], [lerp(r1[0], hook[0], tailK), lerp(r1[1], hook[1], tailK)], r2]; }
  const hasTail = tail.length > 0 && tailK > 0.05;
  const av = n.av ? (1 - ease(m * 2.5)) * draw : 0, ac: P = [c[0] + sd * (w / 2 + 30), c[1] - h * 0.12];
  // the wash: full colour in the noise, a pale tint once it is a row; the pastille carries the colour there
  g.group("paint", () => {
    g.wash(outline, lerp(0, 1, m) > 0.5 ? mix(n.color, "#ffffff", 0.86) : mix(n.color, "#ffffff", lerp(0.25, 0.86, m)), { seed: 40 + i, alpha: 0.7 * draw * alpha, dx: 2, dy: 2, shrink: 0.98, rim: true });
    if (hasTail) g.wash(tail, mix(n.color, "#ffffff", 0.25), { seed: 50 + i, alpha: 0.7 * draw * alpha, dx: 1, dy: 1, shrink: 1, rim: false });
    if (m > 0.02) { const pc: P = [c[0] - w / 2 + 26, c[1]]; g.wash(softBox(pc[0], pc[1], 26 * m, 26 * m, 2, 12), n.color, { seed: 60 + i, alpha: 0.9 * alpha, dx: 0, dy: 0, shrink: 1, rim: false }); }
    if (av > 0.02) g.wash(n.av === "square" ? softBox(ac[0], ac[1], 40, 40, 6, 16) : softBox(ac[0], ac[1], 40, 40, 2, 16), mix(n.color, "#ffffff", 0.35), { seed: 65 + i, alpha: 0.8 * av * alpha, dx: 0, dy: 0, shrink: 1, rim: true });
  }, { alpha });
  g.group("ink", () => {
    if (av > 0.02) { const o = n.av === "square" ? softBox(ac[0], ac[1], 40, 40, 6, 16) : softBox(ac[0], ac[1], 40, 40, 2, 16); g.pen([...o, o[0]], { w: 1.1, color: INK, seed: 75 + i, wobble: 0.6, boil: 0.35, opacity: 0.75 * av * alpha, retrace: false }); }
    g.pen([...outline, outline[0]], { w: 1.25, color: INK, seed: 70 + i, wobble: 0.9, boil: 0.45, opacity: 0.85 * alpha, retrace: false, progress: draw });
    if (hasTail) g.pen(tail, { w: 1.1, color: INK, seed: 80 + i, wobble: 0.6, boil: 0.45, opacity: 0.8 * alpha, retrace: false, progress: draw });
    // words: two lines inside; in a row they shift right of the pastille
    const lx = c[0] - w / 2 + lerp(22, 52, m), lw = w - lerp(44, 90, m), wt = lerp(1.5, 1.2, m);
    scribble(g, lx, c[1] - lerp(12, 7, m), lw * 0.62, 90 + i, { op: 0.75 * alpha, progress: clamp(draw * 1.6 - 0.4), wt: wt + 0.5 });
    scribble(g, lx, c[1] + lerp(10, 9, m), lw * (0.85 - (i % 3) * 0.12), 100 + i, { op: 0.4 * alpha, progress: clamp(draw * 1.6 - 0.6), wt });
    if (m > 0.3) scribble(g, c[0] + w / 2 - 44, c[1] - 7, 26, 110 + i, { op: 0.3 * alpha * m, wt: 1 }); // the time, right-aligned
  });
  // the badge: the noise's token. It shrinks away as the bubble files into the list.
  const b = (1 - ease(m * 2.2)) * clamp(draw * 2 - 1) * alpha;
  if (b > 0.01) {
    const bc: P = [c[0] + n.side * (w / 2 - 6), c[1] - h / 2 + 4], r = 17 * (0.4 + 0.6 * b);
    g.group("paint", () => g.wash(softBox(bc[0], bc[1], r * 2, r * 2, 2, 14), BADGE, { seed: 120 + i, alpha: 0.95 * b, dx: 0, dy: 0, shrink: 1, rim: true }));
    g.group("plain", () => letter(g, n.badge, bc[0], bc[1] - r * 0.42, { cap: r * 0.85, color: "#ffffff", seed: 130 + i, align: "center", w: 1.6, opacity: b }));
  }
};

export const drawCorresp = (ctx: Ctx, frame: number, env: Env) => {
  const f = ((frame % T) + T) % T, g = new Gfx(ctx, env, f, INK_M);
  ctx.setTransform(env.scale, 0, 0, env.scale, 0, 0); // clear ground: the page is the paper

  // the card: always there, the calm the noise resolves into
  const card = softBox((CARD.x0 + CARD.x1) / 2, (CARD.y0 + CARD.y1) / 2, CARD.x1 - CARD.x0, CARD.y1 - CARD.y0, 7, 40);
  g.group("paint", () => g.wash(card, "#f7f6f3", { seed: 11, alpha: 0.9, dx: 3, dy: 4, shrink: 1, rim: true }));
  g.group("ink", () => {
    g.pen([...card, card[0]], { w: 1.5, color: INK, seed: 12, wobble: 0.8, boil: 0.35, opacity: 0.8, retrace: false });
    g.pen([[CARD.x0 + 6, 98], [CARD.x1 - 6, 98]], { w: 0.9, color: INK, seed: 13, wobble: 0.6, boil: 0.35, opacity: 0.45, retrace: false });
    scribble(g, CARD.x0 + 118, 76, 110, 14, { op: 0.5, wt: 1.3 }); // the window title, as the site's screenshots have it
  });
  // the window's three dots, a hand-painted nod to the Mac screenshots on the page
  g.group("paint", () => ["#ec6a5e", "#f4bf4f", "#61c554"].forEach((col, k) => g.wash(softBox(CARD.x0 + 30 + k * 22, 76, 13, 13, 2, 12), col, { seed: 17 + k, alpha: 0.85, dx: 0, dy: 0, shrink: 1, rim: false })));
  g.group("ink", () => {
  });

  // the selection band walks down the list while it rests
  const sw = (f - CUE.sweep[0]) / (CUE.sweep[1] - CUE.sweep[0]);
  if (sw > 0 && sw < 1) {
    const rowF = sw * 7.99, r0 = Math.floor(rowF), k = ease((rowF - r0) * 1.6), y = ROW0 + (r0 + k) * ROWH + ROWHH / 2, a = Math.sin(sw * Math.PI);
    g.group("paint", () => g.wash(softBox(ROWX + ROWW / 2, y, ROWW + 14, ROWHH + 12, 5, 24), mix(RUST_SOFT, RUST, 0.18), { seed: 15, alpha: 0.95 * a, dx: 0, dy: 0, shrink: 1, rim: true }));
    g.group("ink", () => { const o = softBox(ROWX + ROWW / 2, y, ROWW + 14, ROWHH + 12, 5, 24); g.pen([...o, o[0]], { w: 1.1, color: RUST, seed: 18, wobble: 0.4, boil: 0.3, opacity: 0.7 * a, retrace: false }); g.pen([[ROWX - 10, y - 20], [ROWX - 10, y + 20]], { w: 3, color: RUST, seed: 16, wobble: 0.3, boil: 0.3, opacity: 0.95 * a, retrace: false }); });
  }

  // the eight, back to front by arrival so the one flying lands on top
  NETS.map((n, i) => ({ n, i })).sort((a, b) => a.i - b.i).forEach(({ n, i }) => {
    const k = ORDER.indexOf(i), draw = span(f, CUE.pop + k * CUE.popEvery, CUE.popLen);
    const leave = CUE.fly + k * CUE.flyEvery, m = span(f, leave, CUE.flyLen);
    const gone = 1 - span(f, CUE.clear + n.row * CUE.clearEvery, CUE.clearLen);
    if (draw <= 0 || gone <= 0) return;
    // in the noise every bubble jitters for attention; a whole number of cycles per loop, so no seam
    const jit = (1 - m) * 1, ph = i * 2.39996, t = f / T;
    const wob: P = [Math.sin(t * Math.PI * 2 * 11 + ph) * 3 * jit, Math.sin(t * Math.PI * 2 * 13 + ph * 1.7) * 3 * jit];
    const rc = rowCentre(n.row);
    // the flight bows upward, so each bubble is seen travelling rather than sliding
    const arc = Math.sin(m * Math.PI) * -40;
    const c: P = [lerp(n.at[0], rc[0], m) + wob[0], lerp(n.at[1], rc[1], m) + wob[1] + arc];
    // it travels as a bubble and only becomes a row as it lands: shape follows position, late
    const mo = ease((m - 0.55) / 0.45);
    bubble(g, n, i, c, lerp(n.w, ROWW, mo), lerp(n.h, ROWHH, mo), draw, mo, gone);
  });
};

export const corresp: Film = {
  meta: { title: "corresp", W: 1200, H: 720, fps: 30, bpm: 120, durationFrames: T },
  assets: { images: {} },
  shots: [{ id: "loop", start: 0, end: T, draw: drawCorresp }],
};
void BEAT;
