import { Gfx, arc, poly, softBox, type Ctx, type Env, type P } from "./core";
import type { Film } from "./film";
import { clamp, lerp } from "./gallery";
import { RUST, INK_M } from "./corresp";

// CORRESPONDANCE · no server of ours. Same hand as the rest of the page (STYLE-corresp.md), in the
// dark section: light ink on a clear ground, the network colours as the only washes.
//
// The idea in one sentence: your messages travel between your phone, your house and the networks,
// and the one place they never go is the cloud up there, which is crossed out.
// Motion: coloured dots, one per network, run the wires both ways, two whole trips per loop; the
// relay's light breathes. The cloud never moves and nothing ever reaches it.

const T = 240, TAU = Math.PI * 2;
const LIGHT = "#f4f1ea";
const frac = (v: number) => v - Math.floor(v);

const PHONE: P = [170, 285], MAC: P = [560, 300], RELAY: P = [700, 372], DOOR: P = [440, 330];
// seven networks in a staggered column: 62 px apart, alternating sides, so none touch and each still reads at 390 px wide
const NETS: { c: string; at: P; w: number }[] = ["#3a76f0", "#25d366", "#2aabee", "#e1306c", "#0084ff", "#8a8a92", "#4a154b"]
  .map((c, i) => ({ c, at: [i % 2 ? 1105 : 985, 72 + i * 62] as P, w: 100 }));

const pen = (g: Gfx, pts: P[], seed: number, o: { w?: number; op?: number; color?: string } = {}) =>
  g.pen(pts, { w: o.w ?? 1.6, color: o.color ?? LIGHT, seed, wobble: 0.8, boil: 0.35, opacity: o.op ?? 0.9, retrace: false });
const closed = (pts: P[]) => [...pts, pts[0]];
// a ruled polyline: every segment its own stroke, so the pen's smoothing cannot round a corner
const ruled = (g: Gfx, pts: P[], seed: number, o: { w?: number; op?: number } = {}) => pts.slice(1).forEach((p, i) => pen(g, [pts[i], [(pts[i][0] + p[0]) / 2, (pts[i][1] + p[1]) / 2], p], seed + i * 7, o));

// a point at fraction u along a polyline
const along = (pts: P[], u: number): P => {
  const seg = pts.slice(1).map((p, i) => Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1])), L = seg.reduce((a, b) => a + b, 0);
  let d = clamp(u) * L;
  for (let i = 0; i < seg.length; i++) { if (d <= seg[i]) { const k = d / seg[i]; return [lerp(pts[i][0], pts[i + 1][0], k), lerp(pts[i][1], pts[i + 1][1], k)]; } d -= seg[i]; }
  return pts[pts.length - 1];
};

const bubble = (c: P, w: number, h: number): P[] => softBox(c[0], c[1], w, h, 4, 22);

export const drawCprivacy = (ctx: Ctx, frame: number, env: Env) => {
  const f = ((frame % T) + T) % T, g = new Gfx(ctx, env, f, INK_M), t = f / T;
  ctx.setTransform(env.scale, 0, 0, env.scale, 0, 0);

  // the wires first, faint, so everything else sits on top of them
  g.group("ink", () => {
    g.pen([[PHONE[0] + 60, PHONE[1] + 10], [300, DOOR[1] - 4], DOOR], { w: 1.1, color: LIGHT, seed: 10, wobble: 0.6, boil: 0.35, opacity: 0.35, retrace: false });
    NETS.forEach((n, i) => g.pen([[RELAY[0] + 34, RELAY[1]], [lerp(RELAY[0], n.at[0], 0.55), lerp(RELAY[1], n.at[1], 0.7)], [n.at[0] - n.w / 2 - 6, n.at[1]]], { w: 1, color: LIGHT, seed: 11 + i, wobble: 0.6, boil: 0.35, opacity: 0.3, retrace: false }));
  });

  // the phone
  const phone = softBox(PHONE[0], PHONE[1], 116, 214, 5, 28), screen = softBox(PHONE[0], PHONE[1] + 2, 96, 176, 5, 24);
  g.group("ink", () => {
    pen(g, closed(phone), 21, { w: 1.8 });
    pen(g, [[PHONE[0] - 16, PHONE[1] - 96], [PHONE[0] + 16, PHONE[1] - 96]], 22, { w: 1.6, op: 0.6 });
    [0, 1, 2, 3].forEach((k) => pen(g, [[PHONE[0] - 34, PHONE[1] - 50 + k * 34], [PHONE[0] + 30 - (k % 2) * 20, PHONE[1] - 50 + k * 34 + 1]], 23 + k, { w: 1.1, op: 0.45 }));
  });

  // the house: your place. The Mac and the relay live inside it
  const roof: P[] = [[410, 214], [600, 104], [790, 214]], walls: P[] = [[440, 200], [440, 440], [760, 440], [760, 200]];
  g.group("ink", () => { ruled(g, roof, 31, { w: 2 }); ruled(g, walls, 32, { w: 1.8 }); ruled(g, [[380, 440], [820, 440]], 33, { w: 1.2, op: 0.5 }); });
  // the Mac, with a green bubble on screen: iMessage never leaves it
  const scr = softBox(MAC[0], MAC[1], 150, 96, 6, 24);
  g.group("paint", () => { g.wash(scr, LIGHT, { seed: 40, alpha: 0.035, dx: 0, dy: 0, shrink: 1, rim: false }); g.wash(bubble([MAC[0] - 22, MAC[1] - 12], 70, 26), "#34c759", { seed: 41, alpha: 0.75, dx: 0, dy: 0, shrink: 1, rim: false }); });
  g.group("ink", () => { pen(g, closed(scr), 42, { w: 1.6 }); ruled(g, [[MAC[0] - 92, MAC[1] + 60], [MAC[0] + 92, MAC[1] + 60], [MAC[0] + 76, MAC[1] + 50], [MAC[0] - 76, MAC[1] + 50], [MAC[0] - 92, MAC[1] + 60]], 43, { w: 1.4 }); });
  // the relay: a small box with a light that breathes, two whole breaths per loop
  const box = softBox(RELAY[0], RELAY[1], 68, 44, 5, 20), breathe = 0.5 + 0.5 * Math.sin(t * TAU * 2);
  g.group("paint", () => { g.wash(box, LIGHT, { seed: 50, alpha: 0.05, dx: 0, dy: 0, shrink: 1, rim: false }); g.wash(softBox(RELAY[0] + 18, RELAY[1], 10, 10, 2, 10), RUST, { seed: 51, alpha: 0.5 + 0.5 * breathe, dx: 0, dy: 0, shrink: 1, rim: false }); });
  g.group("ink", () => { pen(g, closed(box), 52, { w: 1.5 }); pen(g, [[RELAY[0] - 22, RELAY[1] - 4], [RELAY[0] + 4, RELAY[1] - 4]], 53, { w: 1, op: 0.5 }); pen(g, [[RELAY[0] - 22, RELAY[1] + 6], [RELAY[0] - 2, RELAY[1] + 6]], 54, { w: 1, op: 0.5 }); });

  // the padlock on the phone's wire: encrypted end to end
  const L: P = [322, 328], BW = 58, BH = 44, top = L[1] - BH / 2 + 6; // sits on the wire: body centred on it
  const body = softBox(L[0], L[1] + 4, BW, BH, 4, 20);
  g.group("paint", () => g.wash(body, RUST, { seed: 60, alpha: 0.9, dx: 0, dy: 0, shrink: 1, rim: true }));
  g.group("ink", () => {
    // the shackle: a clean U, two straight legs and one round top
    const r = 17, legTop = top - 12, U: P[] = [[L[0] - r, top], [L[0] - r, legTop], ...arc(L[0], legTop, r, r, Math.PI, Math.PI * 2, 9).slice(1, -1), [L[0] + r, legTop], [L[0] + r, top]];
    pen(g, U, 62, { w: 3.2 });
    pen(g, closed(body), 61, { w: 1.6 });
    pen(g, [[L[0], L[1] - 2], [L[0], L[1] + 12]], 63, { w: 2.6, color: "#111114", op: 0.85 }); // the keyhole
  });

  // the networks: just their colours and a bubble each
  g.group("paint", () => NETS.forEach((n, i) => g.wash(bubble(n.at, n.w, 46), n.c, { seed: 70 + i, alpha: 0.7, dx: 1, dy: 1, shrink: 0.98, rim: true })));
  g.group("ink", () => NETS.forEach((n, i) => pen(g, closed(bubble(n.at, n.w, 46)), 80 + i, { w: 1.2, op: 0.75 })));

  // the cloud that is not on the way: off every wire, crossed out in rust
  const C: P = [300, 110], cloud: P[] = [[220, 140], [214, 116], [236, 96], [262, 98], [282, 70], [322, 68], [346, 92], [376, 92], [392, 118], [380, 142]];
  g.group("ink", () => {
    pen(g, closed(cloud), 90, { w: 1.4, op: 0.55 });
    [0, 1, 2].forEach((k) => pen(g, [[C[0] - 26, C[1] - 12 + k * 12], [C[0] + 26, C[1] - 12 + k * 12]], 91 + k, { w: 1, op: 0.4 }));
    pen(g, [[206, 60], [404, 156]], 95, { w: 3, color: RUST, op: 0.95 });
    pen(g, [[206, 156], [404, 60]], 96, { w: 3, color: RUST, op: 0.95 });
  });

  // the traffic: one dot per network, network -> relay -> Mac -> door -> phone, odd ones the other way
  g.group("plain", () => NETS.forEach((n, i) => {
    const path: P[] = [[n.at[0] - n.w / 2 - 6, n.at[1]], [lerp(RELAY[0], n.at[0], 0.55), lerp(RELAY[1], n.at[1], 0.7)], [RELAY[0] + 34, RELAY[1]], [MAC[0] + 40, MAC[1] + 40], DOOR, [300, DOOR[1] - 4], [PHONE[0] + 60, PHONE[1] + 10]];
    const u0 = frac(t * 2 + i / NETS.length), u = i % 2 ? 1 - u0 : u0, a = Math.sin(u0 * Math.PI); // fade at both ends
    const p = along(path, u);
    g.fill(softBox(p[0], p[1], 44, 44, 2, 16), n.c, 0.22 * a); // a halo, so the traffic reads at a glance
    g.fill(softBox(p[0], p[1], 26, 26, 2, 14), n.c, 0.97 * a);
    g.fill(softBox(p[0] - 3, p[1] - 3, 9, 9, 2, 10), LIGHT, 0.75 * a);
  }));
};

export const cprivacy: Film = {
  meta: { title: "cprivacy", W: 1200, H: 500, fps: 30, bpm: 120, durationFrames: T },
  assets: { images: {} },
  shots: [{ id: "loop", start: 0, end: T, draw: drawCprivacy }],
};
