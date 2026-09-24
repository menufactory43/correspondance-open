import { Gfx, sample, softBox, type Ctx, type Env, type P } from "./core";
import type { Film } from "./film";
import { letter } from "./drafting";
import { clamp, lerp } from "./gallery";
import { INK, RUST, RUST_SOFT, INK_M, scribble } from "./corresp";

// CORRESPONDANCE · an agent is a contact. Same hand as the inbox loop (STYLE-corresp.md): ink and
// line-wash on a clear ground, words are pen scribbles, no fonts, no logos.
//
// The story in three sentences. Someone writes in the thread, and "cc" joins the conversation the
// way any contact would: its pastille flies into the header. It writes a draft that only you can
// see (dashed, with an eye), you tick it, and the draft becomes a real sent bubble. The thread
// clears and the other person starts typing again.
// Token: the rust pastille of cc. It arrives, it signs the draft, and the sent bubble takes its colour.

const T = 240;
const CUE = {
  dotsOut: [20, 30] as [number, number],  // the typing dots fade as the first message lands
  msg: [20, 45] as [number, number],      // the incoming message draws
  join: [45, 75] as [number, number],     // cc flies into the header
  note: [60, 80] as [number, number],     // "cc a rejoint", the small system line
  draft: [85, 105] as [number, number],   // the dashed draft bubble
  write: [100, 140] as [number, number],  // cc writes into it
  tick: [140, 155] as [number, number],   // the approve button draws, then its check
  press: [155, 165] as [number, number],
  send: [160, 180] as [number, number],   // dashed draft -> solid sent bubble
  seen: [175, 185] as [number, number],   // the sent ticks
  clear: [190, 215] as [number, number],  // the thread dissolves, cc leaves
  dotsIn: [205, 212] as [number, number], // the other person starts typing again: back to frame 0
};
(() => { const bad: string[] = []; Object.entries(CUE).forEach(([k, [a, b]]) => { if (a % 5 && k !== "dotsIn") bad.push(`${k} off grid`); if (b > T) bad.push(`${k} past the end`); }); if (bad.length) throw new Error("cagent cues: " + bad.join("; ")); })();

const ease = (v: number) => { const t = clamp(v); return t * t * (3 - 2 * t); };
const at = (f: number, [a, b]: [number, number]) => ease((f - a) / (b - a));

const CARD = { x0: 300, y0: 50, x1: 900, y1: 575 }, HEAD = 130;
const MSG: P = [480, 272], DRAFT: P = [690, 428], BTN: P = [828, 518], OLD: P = [650, 178];
const CC_HOME: P = [806, 90], CC_FROM: P = [1150, 150], PERSON: P = [850, 90];

// a chat bubble: soft box plus a small tail at the bottom, on the speaker's side
const shape = (c: P, w: number, h: number, side: -1 | 1): P[] => {
  const box = softBox(c[0], c[1], w, h, 4.6, 28);
  return box;
};
const tailOf = (c: P, w: number, h: number, side: -1 | 1): P[] => [[c[0] + side * (w / 2 - 34), c[1] + h / 2 - 6], [c[0] + side * (w / 2 + 6), c[1] + h / 2 + 12], [c[0] + side * (w / 2 - 12), c[1] + h / 2 - 10]];

// the site's hand-ruled text, in any colour (corresp's scribble is ink only)
const scrib = (g: Gfx, x: number, y: number, w: number, seed: number, color: string, op: number, wt: number, progress: number) => {
  const n = Math.max(3, Math.round(w / 22)), pts: P[] = Array.from({ length: n }, (_, i) => [x + (w * i) / (n - 1), y + Math.sin(i * 2.3 + seed) * 1.6] as P);
  g.pen(pts, { w: wt, color, seed, wobble: 0.5, boil: 0.35, opacity: op, retrace: false, taper: 0.8, progress });
};

// dashes along a closed outline: what you see before you decide
const dashes = (g: Gfx, pts: P[], seed: number, color: string, op: number, progress: number, dash = 3) => {
  const s = sample([...pts, pts[0]], false, 6), n = Math.floor((s.length - 1) * progress);
  for (let i = 0, k = 0; i + dash < n; i += dash * 2, k++) g.pen(s.slice(i, i + dash + 1), { w: 1.35, color, seed: seed + k, wobble: 0.3, boil: 0.3, opacity: op, retrace: false, taper: 0.6 });
};

const eye = (g: Gfx, c: P, op: number, seed: number) => {
  g.pen([[c[0] - 15, c[1]], [c[0], c[1] - 10], [c[0] + 15, c[1]]], { w: 1.1, color: RUST, seed, wobble: 0.3, boil: 0.3, opacity: op, retrace: false });
  g.pen([[c[0] - 15, c[1]], [c[0], c[1] + 10], [c[0] + 15, c[1]]], { w: 1.1, color: RUST, seed: seed + 1, wobble: 0.3, boil: 0.3, opacity: op, retrace: false });
  g.fill(softBox(c[0], c[1], 8, 8, 2, 10), RUST, op);
};

const avatar = (g: Gfx, c: P, r: number, color: string, text: string, op: number, seed: number, textColor = "#ffffff") => {
  if (op <= 0.01) return;
  g.group("paint", () => g.wash(softBox(c[0], c[1], r * 2, r * 2, 2, 16), color, { seed, alpha: 0.9 * op, dx: 0, dy: 0, shrink: 1, rim: true }));
  g.group("ink", () => g.pen([...softBox(c[0], c[1], r * 2, r * 2, 2, 16), softBox(c[0], c[1], r * 2, r * 2, 2, 16)[0]], { w: 1.1, color: INK, seed: seed + 1, wobble: 0.5, boil: 0.35, opacity: 0.7 * op, retrace: false }));
  g.group("plain", () => letter(g, text, c[0], c[1] - r * 0.36, { cap: r * 0.72, color: textColor, seed: seed + 2, align: "center", w: 1.5, opacity: op }));
};

export const drawCagent = (ctx: Ctx, frame: number, env: Env) => {
  const f = ((frame % T) + T) % T, g = new Gfx(ctx, env, f, INK_M), t = f / T;
  ctx.setTransform(env.scale, 0, 0, env.scale, 0, 0); // clear ground: the page is the paper
  const gone = 1 - at(f, CUE.clear);

  // the conversation card, always there
  const card = softBox((CARD.x0 + CARD.x1) / 2, (CARD.y0 + CARD.y1) / 2, CARD.x1 - CARD.x0, CARD.y1 - CARD.y0, 7, 40);
  g.group("paint", () => g.wash(card, "#ffffff", { seed: 11, alpha: 0.95, dx: 3, dy: 4, shrink: 1, rim: true }));
  g.group("ink", () => {
    g.pen([...card, card[0]], { w: 1.5, color: INK, seed: 12, wobble: 0.8, boil: 0.35, opacity: 0.8, retrace: false });
    g.pen([[CARD.x0 + 6, HEAD], [CARD.x1 - 6, HEAD]], { w: 0.9, color: INK, seed: 13, wobble: 0.6, boil: 0.35, opacity: 0.4, retrace: false });
    scribble(g, CARD.x0 + 34, 82, 150, 14, { op: 0.75, wt: 1.7 }); // the thread's name
    scribble(g, CARD.x0 + 34, 104, 90, 15, { op: 0.35, wt: 1.1 });
  });
  avatar(g, PERSON, 22, "#34c759", "M", 1, 20);

  // the thread so far: your last message, sent earlier. Always there, so frame 0 is already a conversation
  const os = shape(OLD, 300, 70, 1), ot = tailOf(OLD, 300, 70, 1);
  g.group("plain", () => { g.wash(os, RUST, { seed: 16, alpha: 0.9, dx: 2, dy: 2, shrink: 0.99, rim: true }); g.wash(ot, RUST, { seed: 17, alpha: 0.9, dx: 0, dy: 0, shrink: 1, rim: false }); });
  g.group("ink", () => { g.pen([...os, os[0]], { w: 1.2, color: INK, seed: 18, wobble: 0.8, boil: 0.4, opacity: 0.7, retrace: false }); scrib(g, OLD[0] - 115, OLD[1] - 9, 210, 19, "#ffffff", 0.95, 1.6, 1); scrib(g, OLD[0] - 115, OLD[1] + 13, 140, 20, "#ffffff", 0.75, 1.3, 1); });

  // cc joins: its pastille flies in on an arc and settles beside the other contact; it leaves on the clear
  const j = at(f, CUE.join) * gone;
  if (j > 0.001) {
    const arc = Math.sin(j * Math.PI) * -70, s = 0.55 + 0.45 * j;
    const c: P = [lerp(CC_FROM[0], CC_HOME[0], j), lerp(CC_FROM[1], CC_HOME[1], j) + arc];
    avatar(g, c, 22 * s, RUST, "CC", 1, 30); // opaque from its first frame: it arrives, it does not fade in
  }
  const note = at(f, CUE.note) * gone;
  if (note > 0.01) g.group("ink", () => { scribble(g, 520, 345, 160, 40, { op: 0.3 * note, wt: 1, progress: note }); g.fill(softBox(505, 345, 8, 8, 2, 10), RUST, 0.8 * note); });

  // the typing dots: the other person, at the start and again at the end, so the seam is one continuous wait
  const dots = f < 100 ? 1 - at(f, CUE.dotsOut) : at(f, CUE.dotsIn);
  if (dots > 0.01) {
    const dc: P = [370, 272];
    g.group("paint", () => g.wash(softBox(dc[0] + 26, dc[1], 96, 50, 4, 20), "#efede8", { seed: 50, alpha: 0.95 * dots, dx: 0, dy: 0, shrink: 1, rim: true }));
    g.group("plain", () => [0, 1, 2].forEach((k) => {
      const hop = Math.max(0, Math.sin(t * Math.PI * 2 * 16 - k * 0.9)) * 6; // 16 whole cycles per loop
      g.fill(softBox(dc[0] + k * 22 + 4, dc[1] - hop, 11, 11, 2, 10), INK, 0.55 * dots);
    }));
  }

  // the incoming message
  const m = at(f, CUE.msg) * gone;
  if (m > 0.01) {
    const s = shape(MSG, 300, 86, -1), tl = tailOf(MSG, 300, 86, -1);
    g.group("paint", () => { g.wash(s, "#efede8", { seed: 60, alpha: 0.95 * m, dx: 2, dy: 2, shrink: 0.99, rim: true }); g.wash(tl, "#efede8", { seed: 61, alpha: 0.95 * m, dx: 0, dy: 0, shrink: 1, rim: false }); });
    g.group("ink", () => {
      g.pen([...s, s[0]], { w: 1.2, color: INK, seed: 62, wobble: 0.8, boil: 0.4, opacity: 0.7, retrace: false, progress: m });
      g.pen([tl[0], tl[1], tl[2]], { w: 1.1, color: INK, seed: 65, wobble: 0.4, boil: 0.4, opacity: 0.7 * gone, retrace: false, progress: clamp(m * 2 - 1) });
      scribble(g, MSG[0] - 120, MSG[1] - 12, 200, 63, { op: 0.7 * gone, wt: 1.6, progress: clamp(m * 1.6 - 0.4) });
      scribble(g, MSG[0] - 120, MSG[1] + 13, 150, 64, { op: 0.4 * gone, wt: 1.3, progress: clamp(m * 1.6 - 0.6) });
    });
  }

  // cc's draft: dashed, pale, with the eye that says only you can see it. Then it is sent.
  const d = at(f, CUE.draft) * gone, send = at(f, CUE.send), w = at(f, CUE.write);
  if (d > 0.01) {
    const W = 340, H = 104, s = shape(DRAFT, W, H, 1), tl = tailOf(DRAFT, W, H, 1);
    g.group("paint", () => {
      g.wash(s, RUST_SOFT, { seed: 70, alpha: 0.95 * d * (1 - send), dx: 2, dy: 2, shrink: 0.99, rim: false });
    });
    // sent: the site's own rust bubble. A plain wash (no granulation): at full strength the grain reads as dirt
    if (send > 0.01) g.group("plain", () => { g.wash(s, RUST, { seed: 71, alpha: 0.9 * send * gone, dx: 2, dy: 2, shrink: 0.99, rim: true }); g.wash(tl, RUST, { seed: 72, alpha: 0.9 * send * gone, dx: 0, dy: 0, shrink: 1, rim: false }); });
    g.group("ink", () => {
      if (send < 0.99) dashes(g, s, 73, RUST, 0.85 * d * (1 - send), d);
      if (send > 0.01) g.pen([...s, s[0]], { w: 1.2, color: INK, seed: 79, wobble: 0.8, boil: 0.4, opacity: 0.7 * gone, retrace: false, progress: send });
      eye(g, [DRAFT[0] - W / 2 + 32, DRAFT[1] - H / 2 + 26], 0.9 * d * (1 - send), 74);
      // the words: ink while it is a draft, paper-white once it is sent
      const lines: [number, number, number][] = [[-120, -14, 240], [-120, 8, 200], [-120, 30, 130]];
      lines.forEach(([dx, dy, lw], k) => {
        const p = clamp(w * 3 - k), x = DRAFT[0] + dx + (k === 0 ? 30 : 0), L = k === 0 ? lw - 30 : lw;
        if (1 - send > 0.01) scribble(g, x, DRAFT[1] + dy, L, 75 + k, { op: (k ? 0.45 : 0.7) * d * (1 - send), wt: k ? 1.3 : 1.6, progress: p });
        if (send > 0.01 && p > 0) scrib(g, x, DRAFT[1] + dy, L, 75 + k, "#ffffff", (k ? 0.75 : 0.95) * send * gone, k ? 1.3 : 1.6, p);
      });
    });
  }

  // the approve button: a round tick, pressed once
  const b = at(f, CUE.tick) * (1 - at(f, [165, 175])) * gone;
  if (b > 0.01) {
    const press = Math.sin(clamp((f - CUE.press[0]) / (CUE.press[1] - CUE.press[0])) * Math.PI), r = 21 * (1 - 0.14 * press);
    const ring = softBox(BTN[0], BTN[1], r * 2, r * 2, 2, 18);
    g.group("paint", () => g.wash(ring, RUST, { seed: 80, alpha: (0.25 + 0.6 * press) * b, dx: 0, dy: 0, shrink: 1, rim: false }));
    g.group("ink", () => {
      g.pen([...ring, ring[0]], { w: 1.4, color: RUST, seed: 81, wobble: 0.4, boil: 0.3, opacity: 0.9 * b, retrace: false, progress: clamp((f - 140) / 8) });
      g.pen([[BTN[0] - 9, BTN[1]], [BTN[0] - 2, BTN[1] + 7], [BTN[0] + 10, BTN[1] - 8]], { w: 2, color: press > 0.3 ? "#ffffff" : RUST, seed: 82, wobble: 0.3, boil: 0.3, opacity: b, retrace: false, progress: clamp((f - 148) / 7) });
    });
  }

  // sent: two small ticks under the bubble
  const seen = at(f, CUE.seen) * gone;
  if (seen > 0.01) g.group("ink", () => [0, 1].forEach((k) => g.pen([[742 + k * 16, 506], [750 + k * 16, 515], [766 + k * 16, 496]], { w: 2.4, color: RUST, seed: 90 + k, wobble: 0.2, boil: 0.3, opacity: 0.85 * seen, retrace: false, progress: clamp(seen * 2 - k) })));
};

export const cagent: Film = {
  meta: { title: "cagent", W: 1200, H: 625, fps: 30, bpm: 120, durationFrames: T },
  assets: { images: {} },
  shots: [{ id: "loop", start: 0, end: T, draw: drawCagent }],
};
