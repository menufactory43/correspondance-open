import { Gfx, arc, line, oval, poly, softBox, turn, type Ctx, type Env, type P } from "./core";
import type { Film } from "./film";
import { letter } from "./drafting";
import { mix } from "./gallery";
import { INK, RUST, RUST_SOFT, BADGE, INK_M, scribble } from "./corresp";

// CORRESPONDANCE · the spot family. Seventeen small objects that replace the line icons of the
// .cap cards, one per card, in the same ink-and-wash hand as the inbox loop (STYLE-corresp.md).
// Each one is drawn on a 320 box and shown at 64 px, so the contour is heavier than a 1200 px
// scene would take, the wash is one flat colour, and each object keeps a clear silhouette.

const NET = { imsg: "#34c759", signal: "#3a76f0", wa: "#25d366", ig: "#e1306c", msg: "#0084ff", x: "#111114", slack: "#4a154b" };
const GREY = "#83828a";
type Spot = { slug: string; title: string; paint: (g: Gfx) => void; ink: (g: Gfx) => void };

// the hand, sized for a 320 box read at 64 px
const out = (g: Gfx, pts: P[], seed: number, w = 3.1, closed = true) => g.pen(closed ? [...pts, pts[0]] : pts, { w, color: INK, seed, wobble: 0.7, boil: 0, opacity: 0.92, retrace: false, taper: 0.7 });
const stroke = (g: Gfx, pts: P[], seed: number, w = 2.2, color = INK, opacity = 0.9, taper = 0.8) => g.pen(pts, { w, color, seed, wobble: 0.5, boil: 0, opacity, retrace: false, taper });
// straight-edged objects: each side its own stroke, so the pen never rounds a corner
const edges = (g: Gfx, c: P[], seed: number, w = 3.1, closed = true) => { for (let i = 0; i < c.length - (closed ? 0 : 1); i++) stroke(g, line(c[i], c[(i + 1) % c.length], (i % 2 ? 1 : -1) * 1.5), seed + i, w, INK, 0.92, 0.25); };
const wash = (g: Gfx, pts: P[], color: string, seed: number, alpha = 0.55) => g.wash(pts, color, { seed, alpha, dx: 4, dy: 4, shrink: 0.97, rim: true });
const lines = (g: Gfx, x: number, y: number, w: number, n: number, seed: number, gap = 26, color = INK) => { for (let i = 0; i < n; i++) scribble(g, x, y + i * gap, w * (i === n - 1 ? 0.6 : 1), seed + i, { op: color === INK ? 0.7 : 0.9, wt: 2.3 }); };
const greyLine = (g: Gfx, x: number, y: number, w: number, seed: number) => { const n = Math.max(3, Math.round(w / 22)); stroke(g, Array.from({ length: n }, (_, i) => [x + (w * i) / (n - 1), y + Math.sin(i * 2.3 + seed) * 1.6] as P), seed, 2.6, GREY, 0.85); };
// a speech bubble: soft box + a tail on one side
const bub = (cx: number, cy: number, w: number, h: number, side: -1 | 1, e = 2.6): { body: P[]; tail: P[] } => ({
  body: softBox(cx, cy, w, h, e, 26),
  tail: [[cx + side * w * 0.18, cy + h * 0.44], [cx + side * w * 0.36, cy + h * 0.5 + 26], [cx + side * w * 0.34, cy + h * 0.38]],
});
const bubble = (g: Gfx, b: { body: P[]; tail: P[] }, seed: number) => { out(g, b.body, seed); stroke(g, b.tail, seed + 1, 2.8); };
const bubbleWash = (g: Gfx, b: { body: P[]; tail: P[] }, color: string, seed: number, alpha = 0.55) => { wash(g, b.body, color, seed, alpha); wash(g, b.tail, color, seed + 1, alpha); };

const SPOTS: Spot[] = [
  // ---- #usages
  (() => { // a price tag on its string: selling second-hand
    const tag = turn([[64, 160], [118, 104], [258, 104], [258, 216], [118, 216]], 160, 160, -24), hole = oval(...turn([[112, 160]], 160, 160, -24)[0], 12, 12, 12);
    return { slug: "marketplace", title: "Vendre sur Marketplace, Leboncoin, Vinted",
      paint: (g) => wash(g, poly(tag, 4), RUST, 1, 0.5),
      ink: (g) => { edges(g, tag, 2); out(g, hole, 3, 2.4); const h = turn([[112, 160]], 160, 160, -24)[0]; stroke(g, [h, [h[0] - 26, h[1] - 40], [h[0] - 10, h[1] - 78], [h[0] + 24, h[1] - 92]], 4, 2.2);
        const a = turn([[160, 142], [232, 142]], 160, 160, -24), b = turn([[160, 176], [212, 176]], 160, 160, -24); stroke(g, line(a[0], a[1], 2), 5, 3.4); stroke(g, line(b[0], b[1], -2), 6, 2.4, INK, 0.6); },
    };
  })(),
  (() => { // a small shop front: a striped awning closed on its own frame, a door, a window
    const body: P[] = [[80, 148], [240, 148], [240, 258], [80, 258]], awn: P[] = [[74, 92], [246, 92], [262, 148], [58, 148]], door: P[] = [[176, 184], [218, 184], [218, 258], [176, 258]], win: P[] = [[100, 180], [154, 180], [154, 224], [100, 224]];
    return { slug: "commerce", title: "Indépendants et petits commerces",
      paint: (g) => { wash(g, poly(body, 4), "#ffffff", 10, 0.9); wash(g, poly(awn, 4), RUST, 11, 0.6); wash(g, poly(door, 4), RUST_SOFT, 17, 0.95); },
      ink: (g) => { edges(g, body, 13, 3.4); edges(g, awn, 14, 3.4); [0.25, 0.5, 0.75].forEach((t, i) => stroke(g, line([74 + 172 * t, 94], [58 + 204 * t, 146], 0), 18 + i, 2.2, INK, 0.7, 0.3));
        for (let i = 0; i < 4; i++) stroke(g, arc(58 + i * 51 + 25.5, 148, 25.5, 15, 0, Math.PI, 7), 20 + i, 2.6); edges(g, door, 15, 2.6); edges(g, win, 16, 2.6); },
    };
  })(),
  (() => { // four bubbles, four networks, one family
    const bs = [bub(112, 110, 118, 76, -1), bub(212, 128, 110, 70, 1), bub(106, 208, 108, 68, -1), bub(206, 226, 120, 74, 1)], cs = [NET.imsg, NET.wa, NET.msg, NET.ig];
    return { slug: "famille", title: "La famille sur quatre réseaux",
      paint: (g) => bs.forEach((b, i) => bubbleWash(g, b, cs[i], 30 + i * 2, 0.6)),
      ink: (g) => bs.forEach((b, i) => { bubble(g, b, 40 + i * 3); scribble(g, [112, 212, 106, 206][i] - 30, [110, 128, 208, 226][i], 60, 50 + i, { op: 0.7, wt: 2.2 }); }),
    };
  })(),
  (() => { // an envelope and the quill that wrote it carefully
    const env: P[] = softBox(150, 190, 206, 132, 6, 20), quill: P[] = [[258, 52], [232, 78], [196, 126], [164, 176], [152, 200], [170, 168], [212, 118], [252, 70]];
    return { slug: "message-delicat", title: "Le message délicat",
      paint: (g) => { wash(g, env, RUST_SOFT, 60, 0.95); wash(g, quill, RUST, 61, 0.6); },
      ink: (g) => { out(g, env, 62); stroke(g, [[50, 130], [150, 200], [250, 130]], 63, 2.6); out(g, quill, 64, 2.4); stroke(g, [[262, 46], [210, 118], [148, 208]], 65, 2.2); },
    };
  })(),
  (() => { // a pile of group messages and the counter nobody reads
    const bs = [bub(176, 110, 170, 74, 1), bub(160, 160, 180, 78, -1), bub(146, 214, 190, 82, -1)], badge = oval(250, 88, 30, 30, 14);
    return { slug: "groupe", title: "Le groupe qu’on n’a pas le temps de lire",
      paint: (g) => { bs.forEach((b, i) => wash(g, b.body, mix(NET.wa, "#ffffff", 0.35 + (2 - i) * 0.2), 70 + i, 0.8)); wash(g, badge, BADGE, 74, 0.95); },
      ink: (g) => { bs.forEach((b, i) => { if (i === 2) bubble(g, b, 75); else out(g, b.body, 76 + i, 2.4); }); lines(g, 80, 204, 120, 2, 79, 22); letter(g, "40", 250, 76, { cap: 24, color: "#ffffff", seed: 81, align: "center", w: 3.4 }); },
    };
  })(),
  (() => { // a message in Portuguese, and its translation in grey under it
    const top = bub(150, 104, 190, 84, -1), low = bub(170, 222, 190, 84, 1);
    return { slug: "traduction", title: "La belle-famille qui écrit en portugais",
      paint: (g) => { bubbleWash(g, top, NET.wa, 90, 0.55); wash(g, low.body, "#ffffff", 92, 0.8); },
      ink: (g) => { bubble(g, top, 93); out(g, low.body, 95); lines(g, 90, 94, 120, 2, 96, 22); greyLine(g, 110, 212, 120, 98); greyLine(g, 110, 234, 72, 99); },
    };
  })(),
  (() => { // the assistant: a contact avatar, cc, with its own bubble
    const av = oval(128, 160, 70, 70, 16), b = bub(232, 108, 104, 66, 1);
    return { slug: "assistant", title: "Un assistant joignable comme un contact",
      paint: (g) => { wash(g, av, RUST, 110, 0.7); wash(g, b.body, RUST_SOFT, 111, 0.95); },
      ink: (g) => { out(g, av, 112); letter(g, "CC", 128, 138, { cap: 44, color: "#ffffff", seed: 113, align: "center", w: 5.2 }); out(g, b.body, 114, 2.6); scribble(g, 204, 108, 56, 115, { op: 0.7, wt: 2.2 }); },
    };
  })(),
  (() => { // a phone, and an eye struck out on its screen
    const ph = softBox(160, 164, 138, 240, 4.2, 24), eye: P[] = [[112, 160], [136, 138], [160, 132], [184, 138], [208, 160], [184, 182], [160, 188], [136, 182]];
    return { slug: "tracking", title: "Moins de tracking sur votre téléphone",
      paint: (g) => { wash(g, ph, RUST_SOFT, 120, 0.9); wash(g, oval(160, 160, 16, 16, 10), RUST, 121, 0.75); },
      ink: (g) => { out(g, ph, 122); stroke(g, [[146, 64], [174, 64]], 123, 3); out(g, eye, 124, 2.6); out(g, oval(160, 160, 16, 16, 10), 125, 2.2); stroke(g, [[106, 212], [214, 108]], 126, 4, BADGE, 0.95); },
    };
  })(),
  // ---- #fonctions
  (() => { // a card floating over the desk, and the flash of the shortcut
    const card = turn(softBox(146, 180, 200, 140, 5, 22), 146, 180, -4), bolt: P[] = [[250, 44], [218, 102], [240, 102], [214, 156], [270, 88], [246, 88], [268, 44]];
    return { slug: "reponse-rapide", title: "Réponse rapide",
      paint: (g) => { wash(g, card, "#ffffff", 130, 0.9); wash(g, bolt, RUST, 131, 0.75); },
      ink: (g) => { stroke(g, [[70, 272], [226, 266]], 132, 2.2, INK, 0.35); out(g, card, 133); lines(g, 74, 160, 130, 2, 134, 26); out(g, softBox(150, 222, 150, 30, 6, 16), 136, 2.2); out(g, bolt, 137, 2.4); },
    };
  })(),
  (() => { // a little window pinned above the rest
    const win = softBox(160, 180, 200, 170, 5, 22);
    return { slug: "post-it", title: "Post-it",
      paint: (g) => { wash(g, win, RUST_SOFT, 140, 0.95); wash(g, oval(160, 88, 20, 20, 12), BADGE, 141, 0.9); },
      ink: (g) => { out(g, win, 142); stroke(g, [[62, 126], [258, 128]], 143, 2.2); lines(g, 84, 160, 150, 3, 144, 30); out(g, oval(160, 88, 20, 20, 12), 147, 2.4); stroke(g, [[160, 108], [161, 132]], 148, 2.6); },
    };
  })(),
  (() => { // one conversation, framed: nothing else in view
    const b = bub(160, 156, 170, 96, -1), k = 26, c: [number, number, number, number] = [56, 70, 264, 256];
    return { slug: "focus", title: "Mode Focus",
      paint: (g) => bubbleWash(g, b, NET.signal, 150, 0.5),
      ink: (g) => { bubble(g, b, 151); lines(g, 104, 144, 110, 2, 153, 24); const [x0, y0, x1, y1] = c;
        [[[x0, y0 + k * 1.6], [x0, y0], [x0 + k * 1.6, y0]], [[x1 - k * 1.6, y0], [x1, y0], [x1, y0 + k * 1.6]], [[x1, y1 - k * 1.6], [x1, y1], [x1 - k * 1.6, y1]], [[x0 + k * 1.6, y1], [x0, y1], [x0, y1 - k * 1.6]]].forEach((p, i) => stroke(g, p as P[], 155 + i, 3.4, RUST)); },
    };
  })(),
  (() => { // the menu bar, the unread count, and the card that drops from it
    const bar: P[] = [[34, 70], [286, 70], [286, 112], [34, 112]], drop = softBox(200, 196, 150, 118, 5, 20), pas = softBox(200, 91, 40, 26, 3, 14);
    return { slug: "barre-menus", title: "Barre des menus",
      paint: (g) => { wash(g, bar, "#efede8", 160, 0.95); wash(g, pas, BADGE, 161, 0.9); wash(g, drop, "#ffffff", 162, 0.9); },
      ink: (g) => { out(g, bar, 163); [70, 106, 250].forEach((x, i) => out(g, oval(x, 91, 7, 7, 8), 164 + i, 2)); letter(g, "3", 200, 82, { cap: 17, color: "#ffffff", seed: 168, align: "center", w: 2.8 }); out(g, drop, 169); stroke(g, [[200, 114], [200, 134]], 170, 1.8, INK, 0.5); lines(g, 146, 180, 100, 2, 171, 26); },
    };
  })(),
  (() => { // four themes: paper, wax and oak, moonlight, night ink
    const at: P[] = [[118, 118], [202, 118], [118, 202], [202, 202]], cs = [RUST_SOFT, RUST, mix(NET.signal, "#ffffff", 0.45), INK];
    return { slug: "themes", title: "Quatre thèmes",
      paint: (g) => at.forEach(([x, y], i) => wash(g, oval(x, y, 44, 44, 16), cs[i], 180 + i, i === 3 ? 0.8 : 0.85)),
      ink: (g) => at.forEach(([x, y], i) => out(g, oval(x, y, 44, 44, 16), 186 + i, 2.6)),
    };
  })(),
  (() => { // a tray, and an arrow leaving it
    const tray: P[] = [[92, 150], [72, 150], [72, 262], [248, 262], [248, 150], [228, 150]], arrow: P[] = [[160, 200], [160, 72], [124, 108], [160, 72], [196, 108]];
    return { slug: "partager", title: "Partager",
      paint: (g) => wash(g, poly([[72, 150], [248, 150], [248, 262], [72, 262]], 4), RUST_SOFT, 190, 0.95),
      ink: (g) => { edges(g, tray, 192, 3.1, false); stroke(g, line([160, 214], [160, 62], 0), 193, 4.4, RUST, 0.95, 0.25); stroke(g, [[118, 106], [160, 60]], 194, 4.4, RUST, 0.95, 0.25); stroke(g, [[160, 60], [202, 106]], 195, 4.4, RUST, 0.95, 0.25); },
    };
  })(),
  (() => { // the same inbox, in the pocket
    const ph = softBox(160, 164, 138, 240, 4.2, 24), a = bub(146, 124, 88, 48, -1), b = bub(176, 196, 88, 48, 1);
    return { slug: "iphone", title: "iPhone",
      paint: (g) => { wash(g, ph, "#ffffff", 200, 0.9); bubbleWash(g, a, NET.wa, 201, 0.6); bubbleWash(g, b, RUST, 203, 0.55); },
      ink: (g) => { out(g, ph, 205); stroke(g, [[146, 64], [174, 64]], 206, 3); bubble(g, a, 207); bubble(g, b, 209); stroke(g, [[140, 266], [180, 266]], 211, 2.2, INK, 0.5); },
    };
  })(),
  (() => { // one bubble, its translation in the second line, and the chip that did it on the device
    const b = bub(144, 126, 210, 124, -1), chip: P[] = [[192, 186], [272, 186], [272, 266], [192, 266]], core: P[] = [[214, 208], [250, 208], [250, 244], [214, 244]];
    return { slug: "traduction-appareil", title: "Traduction sur l'appareil",
      paint: (g) => { bubbleWash(g, b, NET.signal, 220, 0.45); wash(g, poly(chip, 4), RUST_SOFT, 222, 0.95); wash(g, poly(core, 4), RUST, 221, 0.7); },
      ink: (g) => { bubble(g, b, 223); scribble(g, 70, 108, 140, 225, { op: 0.8, wt: 2.4 }); { const n = 7, pts = Array.from({ length: n }, (_, i) => [70 + (120 * i) / (n - 1), 142 + Math.sin(i * 2.3) * 1.6] as P); stroke(g, pts, 226, 3, RUST, 0.95); }
        edges(g, chip, 227, 3); edges(g, core, 231, 2.2); for (let k = 0; k < 3; k++) { const o = 208 + k * 24; stroke(g, [[o, 186], [o, 170]], 240 + k, 3.2, INK, 0.9, 0.2); stroke(g, [[o, 266], [o, 282]], 243 + k, 3.2, INK, 0.9, 0.2); stroke(g, [[192, o], [176, o]], 246 + k, 3.2, INK, 0.9, 0.2); stroke(g, [[272, o], [288, o]], 249 + k, 3.2, INK, 0.9, 0.2); } },
    };
  })(),
  (() => { // reading without being seen: a masquerade mask
    const half: P[] = [[160, 132], [132, 114], [94, 108], [62, 116], [46, 138], [52, 168], [80, 192], [116, 194], [142, 180], [160, 166]];
    const mask: P[] = [...half, ...half.slice(1, -1).reverse().map(([x, y]) => [320 - x, y] as P)], eyeL: P[] = [[76, 152], [92, 138], [114, 136], [132, 150], [114, 164], [92, 164]], eyeR = eyeL.map(([x, y]) => [320 - x, y] as P);
    return { slug: "incognito", title: "Mode incognito",
      paint: (g) => { wash(g, mask, RUST, 260, 0.62); wash(g, eyeL, "#ffffff", 261, 0.95); wash(g, eyeR, "#ffffff", 262, 0.95); },
      ink: (g) => { out(g, mask, 263, 3.4); out(g, eyeL, 264, 2.8); out(g, eyeR, 265, 2.8); stroke(g, [[48, 132], [30, 150], [36, 186], [24, 214]], 266, 2.4); stroke(g, [[272, 132], [290, 150], [284, 186], [296, 214]], 267, 2.4); },
    };
  })(),
];

export const SLUGS = SPOTS.map((s) => ({ slug: s.slug, title: s.title }));
const drawSpot = (g: Gfx, s: Spot) => { g.group("paint", () => s.paint(g)); g.group("ink", () => s.ink(g)); };

// one frame per spot, 320 x 320, clear ground
export const drawCspot = (ctx: Ctx, frame: number, env: Env) => {
  const g = new Gfx(ctx, env, 0, INK_M); ctx.setTransform(env.scale, 0, 0, env.scale, 0, 0);
  drawSpot(g, SPOTS[Math.max(0, Math.min(SPOTS.length - 1, frame))]);
};
export const cspot: Film = { meta: { title: "cspot", W: 320, H: 320, fps: 30, bpm: 120, durationFrames: SPOTS.length }, assets: { images: {} }, shots: [{ id: "spots", start: 0, end: SPOTS.length, draw: drawCspot }] };

// the whole family on one sheet, to judge it as a family: 6 x 3 on a card-coloured ground
export const drawCspotSheet = (ctx: Ctx, _frame: number, env: Env) => {
  const g = new Gfx(ctx, env, 0, INK_M); ctx.setTransform(env.scale, 0, 0, env.scale, 0, 0);
  ctx.fillStyle = "#f7f6f3"; ctx.fillRect(0, 0, env.W, env.H);
  SPOTS.forEach((s, i) => { g.push((i % 6) * 320, Math.floor(i / 6) * 320, 1); drawSpot(g, s); g.pop(); });
};
export const cspotSheet: Film = { meta: { title: "cspotSheet", W: 1920, H: 960, fps: 30, bpm: 120, durationFrames: 1 }, assets: { images: {} }, shots: [{ id: "sheet", start: 0, end: 1, draw: drawCspotSheet }] };
