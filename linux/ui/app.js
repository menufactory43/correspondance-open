/* Correspondance pour Linux — l'interface.
   Elle ne décide de rien : ce qui est visible, dans quel ordre, ce qui est lu,
   épinglé, archivé, vient du magasin (RelayStore, le même que l'iPhone) par
   /api/state et /api/thread. Ici, on dessine, et on renvoie les gestes. */
(() => {
  "use strict";

  // ---------- Jeton, réseau ----------
  const token = (() => {
    const m = location.hash.match(/t=([A-Za-z0-9_-]+)/);
    if (m) { sessionStorage.setItem("cc.token", m[1]); history.replaceState(null, "", location.pathname); }
    return sessionStorage.getItem("cc.token") || "";
  })();
  const headers = { "X-Correspondance-Token": token, "Content-Type": "application/json" };
  // Un nouveau jeton dans le fragment (le serveur a été relancé) : la page se recharge avec.
  addEventListener("hashchange", () => { if (/t=[A-Za-z0-9_-]+/.test(location.hash)) location.reload(); });
  async function get(path, params) {
    const q = params ? "?" + new URLSearchParams(params).toString() : "";
    const r = await fetch(path + q, { headers });
    if (r.status === 401) { show401(); throw new Error("401"); }
    return r.json();
  }
  async function post(path, body) {
    const r = await fetch(path, { method: "POST", headers, body: JSON.stringify(body || {}) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok && j.error) toast(j.error);
    return j;
  }
  function show401() {
    document.getElementById("app").innerHTML = `<div class="login"><div class="card"><h1>Correspondance</h1><p class="lede">Cette page a perdu son jeton. Relance <code>correspondance</code> et ouvre l'adresse qu'il affiche.</p></div></div>`;
  }

  // ---------- Thèmes : la même dérivation que WritingTheme.swift ----------
  const clamp = (x) => Math.min(Math.max(x, 0), 1);
  const rgb = (hex) => ({ r: ((hex >> 16) & 255) / 255, g: ((hex >> 8) & 255) / 255, b: (hex & 255) / 255 });
  const mix = (a, b, t) => { const k = clamp(t); return { r: a.r + (b.r - a.r) * k, g: a.g + (b.g - a.g) * k, b: a.b + (b.b - a.b) * k }; };
  const lum = (c) => { const lin = (v) => (v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)); return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b); };
  const contrast = (a, b) => { const l1 = lum(a), l2 = lum(b); return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); };
  const BLACK = rgb(0x000000), WHITE = rgb(0xffffff);
  function step(background, ink, minRatio) {
    if (contrast(background, ink) < minRatio) return ink;
    let low = 0, high = 1;
    for (let i = 0; i < 24; i++) { const mid = (low + high) / 2; if (contrast(mix(background, ink, mid), background) >= minRatio) high = mid; else low = mid; }
    return mix(background, ink, high);
  }
  function filledAccent(accent, lightInk, darkInk, minRatio) {
    let fill = accent;
    for (let i = 0; i < 60; i++) {
      const onLight = contrast(fill, lightInk), onDark = contrast(fill, darkInk);
      if (Math.max(onLight, onDark) >= minRatio) return { fill, ink: onLight >= onDark ? lightInk : darkInk };
      fill = onLight >= onDark ? mix(fill, BLACK, 0.03) : mix(fill, WHITE, 0.03);
    }
    const onLight = contrast(fill, lightInk), onDark = contrast(fill, darkInk);
    return { fill, ink: onLight >= onDark ? lightInk : darkInk };
  }
  function makePalette(paper, ink, accent, accentSoft, isDark) {
    const hollow = isDark ? BLACK : ink;
    const paperSecondary = mix(paper, ink, 0.07);
    const sidebar = mix(paper, hollow, isDark ? 0.42 : 0.05);
    const rail = mix(paper, hollow, isDark ? 0.6 : 0.09);
    const room = mix(paper, hollow, isDark ? 0.72 : 0.13);
    const glow = isDark ? mix(paper, ink, 0.1) : mix(paper, WHITE, 0.6);
    const selection = mix(paper, accent, isDark ? 0.24 : 0.18);
    const separator = mix(paper, ink, isDark ? 0.22 : 0.17);
    const bubbleIn = mix(paper, ink, isDark ? 0.13 : 0.09);
    const surfaces = [paper, paperSecondary, sidebar, rail, room, selection, bubbleIn];
    let worst = paper; for (const s of surfaces) if (contrast(s, ink) < contrast(worst, ink)) worst = s;
    const inkSecondary = step(worst, ink, 7.0);
    const inkTertiary = step(worst, ink, 4.8);
    const filled = filledAccent(accent, mix(WHITE, accent, 0.06), mix(BLACK, accent, 0.1), 4.6);
    return { isDark, paper, paperSecondary, sidebar, rail, room, glow, selection, separator, ink, inkSecondary, inkTertiary, accent, accentSoft, accentFill: filled.fill, accentInk: filled.ink, caret: accent, bubbleIn, bubbleInInk: ink, bubbleOut: filled.fill, bubbleOutInk: filled.ink, badge: filled.fill, badgeInk: filled.ink };
  }
  const THEMES = {
    papier: { label: "Papier", sub: "Parchemin tiède, rose fané", paper: 0xfaf4ed, ink: 0x4a4462, accent: 0xa4536a, soft: 0xd7827e, dark: false, body: 18, leading: 8, tracking: 0.2 },
    dune: { label: "Dune", sub: "Sable et sépia, encre brûlée", paper: 0xfbf1c7, ink: 0x3c3836, accent: 0xaf3a03, soft: 0xd79921, dark: false, body: 18, leading: 9, tracking: 0.15 },
    clairDeLune: { label: "Clair de lune", sub: "Brume claire, bleu franc", paper: 0xeff1f5, ink: 0x4c4f69, accent: 0x1a5ddb, soft: 0x7287fd, dark: false, body: 17.5, leading: 8, tracking: 0.1 },
    encreDeNuit: { label: "Encre de nuit", sub: "Nuit indigo, bleu de lune", paper: 0x1a1b26, ink: 0xc0caf5, accent: 0x7aa2f7, soft: 0x3d59a1, dark: true, body: 18, leading: 9, tracking: 0.25 },
    vieuxBureau: { label: "Vieux bureau", sub: "Lampe verte, forêt sombre", paper: 0x2b3339, ink: 0xd3c6aa, accent: 0xa7c080, soft: 0x4f5b45, dark: true, body: 17.5, leading: 8, tracking: 0.3 },
    cireEtChene: { label: "Cire et chêne", sub: "Bois brûlé, cire orangée", paper: 0x221a15, ink: 0xebdbb2, accent: 0xfe8019, soft: 0x7c4a2a, dark: true, body: 18, leading: 9, tracking: 0.2 },
  };
  const TYPEFACES = {
    quattro: { label: "iA Writer Quattro", sub: "Pour lire longtemps", css: '"iA Writer Quattro", "IBM Plex Sans", sans-serif' },
    duo: { label: "iA Writer Duo", sub: "Un air de machine à écrire", css: '"iA Writer Duo", "iA Writer Quattro", monospace' },
    mono: { label: "iA Writer Mono", sub: "Chaque lettre a la même largeur", css: '"iA Writer Mono", ui-monospace, monospace' },
    plexSerif: { label: "IBM Plex Serif", sub: "À empattements, moderne", css: '"IBM Plex Serif", Georgia, serif' },
    plexSans: { label: "IBM Plex Sans", sub: "Sans empattements, nette", css: '"IBM Plex Sans", system-ui, sans-serif' },
    systemSerif: { label: "Serif du système", sub: "Celle de votre bureau, à empattements", css: 'ui-serif, "Noto Serif", "DejaVu Serif", Georgia, serif' },
  };
  const css = (c) => `rgb(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)})`;
  const prefs = {
    get theme() { return localStorage.getItem("cc.theme") || (matchMedia("(prefers-color-scheme: dark)").matches ? "encreDeNuit" : "papier"); },
    set theme(v) { localStorage.setItem("cc.theme", v); applyTheme(); },
    get typeface() { return localStorage.getItem("cc.typeface") || "quattro"; },
    set typeface(v) { localStorage.setItem("cc.typeface", v); applyTheme(); },
    get scale() { return parseFloat(localStorage.getItem("cc.scale") || "1"); },
    set scale(v) { localStorage.setItem("cc.scale", String(Math.min(1.6, Math.max(0.8, v)))); applyTheme(); },
    get mode() { return localStorage.getItem("cc.mode") || "focus"; },
    set mode(v) { localStorage.setItem("cc.mode", v); },
  };
  function applyTheme() {
    const t = THEMES[prefs.theme] || THEMES.papier;
    const p = makePalette(rgb(t.paper), rgb(t.ink), rgb(t.accent), rgb(t.soft), t.dark);
    const root = document.documentElement.style;
    const set = (k, v) => root.setProperty(k, v);
    set("--paper", css(p.paper)); set("--paper-secondary", css(p.paperSecondary)); set("--sidebar", css(p.sidebar)); set("--rail", css(p.rail));
    set("--room", css(p.room)); set("--glow", css(p.glow)); set("--selection", css(p.selection)); set("--selection-weak", css(mix(p.paper, p.accent, t.dark ? 0.12 : 0.08)));
    set("--separator", css(p.separator)); set("--ink", css(p.ink)); set("--ink-secondary", css(p.inkSecondary)); set("--ink-tertiary", css(p.inkTertiary));
    set("--accent", css(p.accent)); set("--accent-soft", css(p.accentSoft)); set("--accent-fill", css(p.accentFill)); set("--accent-ink", css(p.accentInk)); set("--caret", css(p.caret));
    set("--bubble-in", css(p.bubbleIn)); set("--bubble-in-ink", css(p.bubbleInInk)); set("--bubble-out", css(p.bubbleOut)); set("--bubble-out-ink", css(p.bubbleOutInk));
    set("--badge", css(p.badge)); set("--badge-ink", css(p.badgeInk));
    set("--face", (TYPEFACES[prefs.typeface] || TYPEFACES.quattro).css);
    set("--scale", String(prefs.scale));
    set("--tracking", t.tracking + "px");
    // L'interligne d'une bulle : celui du thème pour son corps de lettre,
    // ramené au corps de la bulle, et resserré aux deux tiers (WritingTheme).
    const bubbleSize = 15 * prefs.scale;
    const spacing = t.leading * (bubbleSize / t.body) * 0.65;
    set("--bubble-leading", String((bubbleSize + spacing) / bubbleSize));
    set("--letter-leading", String((t.body + t.leading) / t.body));
    document.documentElement.dataset.dark = t.dark ? "1" : "0";
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", css(p.paper));
  }
  applyTheme();

  // ---------- Icônes ----------
  const I = {
    all: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h18M3 6h18M3 18h18"/></svg>',
    signal: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l4.9-1.4A10 10 0 1 0 12 2zm0 2a8 8 0 1 1-4.2 14.8l-.4-.2-2.5.7.7-2.4-.3-.4A8 8 0 0 1 12 4z"/></svg>',
    whatsapp: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l4.9-1.4A10 10 0 1 0 12 2zm4.6 14.2c-.2.6-1.2 1.1-1.7 1.2-.4.1-1 .1-1.6-.1-.4-.1-.9-.3-1.5-.5-2.6-1.1-4.3-3.8-4.4-4-.1-.2-1-1.4-1-2.6s.6-1.9.9-2.1c.2-.3.5-.3.7-.3h.5c.2 0 .4 0 .6.4.2.6.8 1.9.8 2 .1.1.1.3 0 .4-.1.2-.1.3-.3.4l-.4.5c-.1.1-.3.3-.1.5.2.3.7 1.2 1.6 1.9 1.1.9 2 1.2 2.3 1.4.3.1.4.1.6-.1.2-.2.7-.8.9-1.1.2-.3.4-.2.6-.1l1.9.9c.3.1.4.2.5.3.1.2.1.6-.1 1.1z"/></svg>',
    instagram: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10zm0 8.2a3.2 3.2 0 1 1 0-6.4 3.2 3.2 0 0 1 0 6.4zM17.3 5.5a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4zM21 8c-.1-1.6-.4-3-1.6-4.2S16.8 2.3 15.3 2.2C13.7 2 10.3 2 8.7 2.2 7.2 2.3 5.8 2.6 4.6 3.8S3 6.4 2.9 8C2.8 9.6 2.8 14.4 2.9 16c.1 1.6.4 3 1.6 4.2s2.6 1.5 4.2 1.6c1.6.1 6.4.1 8 0 1.6-.1 3-.4 4.2-1.6s1.5-2.6 1.6-4.2c.1-1.6.1-6.4 0-8zm-2.1 9.7a3.3 3.3 0 0 1-1.8 1.8c-1.3.5-4.3.4-5.1.4s-3.8.1-5.1-.4a3.3 3.3 0 0 1-1.8-1.8c-.5-1.3-.4-4.3-.4-5.7s-.1-4.4.4-5.7A3.3 3.3 0 0 1 6.9 4.5c1.3-.5 4.3-.4 5.1-.4s3.8-.1 5.1.4a3.3 3.3 0 0 1 1.8 1.8c.5 1.3.4 4.3.4 5.7s.1 4.4-.4 5.7z"/></svg>',
    messenger: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2C6.4 2 2 6.2 2 11.4c0 2.9 1.4 5.5 3.6 7.3V22l3.3-1.8c.9.3 2 .4 3.1.4 5.6 0 10-4.2 10-9.4S17.6 2 12 2zm1 12.6-2.6-2.7-5 2.7 5.5-5.8 2.6 2.7 4.9-2.7-5.4 5.8z"/></svg>',
    iMessage: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 3C6.5 3 2 6.6 2 11c0 2.4 1.3 4.5 3.4 6L4.5 21l4.3-2.2c1 .2 2.1.3 3.2.3 5.5 0 10-3.6 10-8S17.5 3 12 3z"/></svg>',
    selfNote: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M5 4h14v16H5zM8 9h8M8 13h8M8 17h5"/></svg>',
    agent: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l1.8 5.2L19 9l-5.2 1.8L12 16l-1.8-5.2L5 9l5.2-1.8zM5 16l.9 2.1L8 19l-2.1.9L5 22l-.9-2.1L2 19l2.1-.9zM19 14l.9 2.1L22 17l-2.1.9L19 20l-.9-2.1L16 17l2.1-.9z"/></svg>',
    pin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 17v5M9 3h6l-1 6 3 3H7l3-3z"/></svg>',
    mute: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9v6h4l5 4V5l-5 4zM19 5L5 19"/></svg>',
    archive: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 5h18v4H3zM5 9v10h14V9M10 13h4"/></svg>',
    unarchive: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 5h18v4H3zM5 9v10h14V9M12 17v-5M9.5 14.5L12 12l2.5 2.5"/></svg>',
    clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
    more: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>',
    compose: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
    gear: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>',
    left: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 6-6 6 6 6"/></svg>',
    right: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 6 6 6-6 6"/></svg>',
    up: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>',
    down: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12l7 7 7-7"/></svg>',
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>',
    reply: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 17H4V7h11a5 5 0 0 1 5 5v5M7 4 4 7l3 3"/></svg>',
    edit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
    forward: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M15 17h5V7H9a5 5 0 0 0-5 5v5M17 4l3 3-3 3"/></svg>',
    lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>',
    lockOpen: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.5-2"/></svg>',
    file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H6v18h12V7z"/><path d="M14 3v4h4"/></svg>',
    play: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 5v14l11-7z"/></svg>',
    pause: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 5h4v14H7zM13 5h4v14h-4z"/></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4 4L19 6"/></svg>',
    check2: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="m2 12 4 4L14 8M10 16l8-8"/></svg>',
    x: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>',
    hide: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3l18 18M10 6.5A9.7 9.7 0 0 1 12 6c5 0 9 6 9 6a15 15 0 0 1-3 3.3M6.6 6.6C4 8.4 3 12 3 12s4 6 9 6a9 9 0 0 0 3-.5"/></svg>',
    trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>',
    undo: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14 4 9l5-5"/><path d="M4 9h11a5 5 0 0 1 0 10h-3"/></svg>',
    copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5h10"/></svg>',
    group: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="9" cy="8" r="3.5"/><circle cx="17" cy="9" r="2.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0M15 15a4.5 4.5 0 0 1 6.5 4.5"/></svg>',
    incognito: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h18M6 12l1.5-6h9L18 12"/><circle cx="8" cy="17" r="2.5"/><circle cx="16" cy="17" r="2.5"/><path d="M10.5 17h3"/></svg>',
  };
  const NETCOLOR = { iMessage: "#34c759", signal: "#3a76f0", whatsapp: "#25d366", instagram: "#e1306c", messenger: "#0084ff", selfNote: "#8a8a8a", agent: "#b48ead" };

  // ---------- Utilitaires ----------
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
  const initials = (t) => (t || "?").split(/\s+/).slice(0, 2).map((w) => w[0] || "").join("").toUpperCase();
  const fmtTime = (ts) => new Date(ts * 1000).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  function fmtRowTime(ts) {
    const d = new Date(ts * 1000), now = new Date();
    if (d.toDateString() === now.toDateString()) return fmtTime(ts);
    const y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === y.toDateString()) return "hier";
    if (now - d < 6 * 864e5) return d.toLocaleDateString("fr-FR", { weekday: "short" });
    return d.toLocaleDateString("fr-FR", { day: "numeric", month: "short" });
  }
  function fmtSeparator(ts) {
    const d = new Date(ts * 1000), now = new Date();
    const day = d.toDateString() === now.toDateString() ? "Aujourd’hui" : d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });
    return `${day} · ${fmtTime(ts)}`;
  }
  const fmtDur = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
  function fileURL(p) { return `/api/file?token=${encodeURIComponent(token)}&path=${encodeURIComponent(p)}`; }
  function avatarURL(id) { return `/api/avatar?token=${encodeURIComponent(token)}&id=${encodeURIComponent(id)}`; }
  function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }
  let toastTimer;
  function toast(text, action) {
    $$(".toast").forEach((t) => t.remove());
    const el = document.createElement("div"); el.className = "toast";
    el.innerHTML = `<span>${esc(text)}</span>${action ? `<button>${esc(action.label)}</button>` : ""}`;
    if (action) $("button", el).onclick = () => { action.run(); el.remove(); };
    document.body.appendChild(el);
    clearTimeout(toastTimer); toastTimer = setTimeout(() => el.remove(), action ? action.ms || 6000 : 3500);
  }
  function rich(text, links, query) {
    // Texte échappé, liens cliquables, @mentions, surlignage de recherche.
    let html = esc(text);
    for (const l of links || []) {
      const t = esc(l.text);
      html = html.replace(t, `<a href="${esc(l.url)}" target="_blank" rel="noopener">${t}</a>`);
    }
    html = html.replace(/(^|\s)(@[\w.\-]+)/g, '$1<span class="mention">$2</span>');
    if (query) { const re = new RegExp(esc(query).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "ig"); html = html.replace(re, (m) => `<mark>${m}</mark>`); }
    return html;
  }

  // ---------- L'état de la page ----------
  const S = {
    state: null, thread: null, mode: prefs.mode, showFilters: false, threadQuery: "", threadSearchOpen: false,
    chromeRevealed: false, atBottom: true, lastThreadID: null, lastCount: 0, revision: -1, search: "",
  };
  const app = $("#app"), overlay = $("#overlay");

  // ---------- Chargement ----------
  let refreshing = false, again = false;
  async function refresh() {
    if (refreshing) { again = true; return; }
    refreshing = true;
    try {
      S.state = await get("/api/state");
      const id = currentID();
      if (id) {
        const t = await get("/api/thread", { id });
        S.thread = t.error ? null : t;
      } else S.thread = null;
      render();
    } catch (e) { console.error(e); }
    refreshing = false;
    if (again) { again = false; refresh(); }
  }
  const refreshSoon = debounce(refresh, 60);
  function currentID() {
    if (!S.state) return null;
    if (S.mode === "focus") return S.state.focusID || S.state.focusQueue[0] || null;
    return S.state.selectedID;
  }
  function connectEvents() {
    const es = new EventSource(`/events?token=${encodeURIComponent(token)}`);
    es.addEventListener("changed", refreshSoon);
    es.addEventListener("hello", refreshSoon);
    es.onerror = () => { es.close(); setTimeout(connectEvents, 2000); };
  }
  document.addEventListener("visibilitychange", () => post("/api/visibility", { value: !document.hidden }));

  // ---------- Rendu ----------
  function render() {
    const st = S.state;
    if (!st) return;
    // Ce qu'on est en train de taper est plus vrai que le brouillon que le
    // serveur a renvoyé il y a une seconde : on le garde à travers le rendu.
    const live = $("#draft");
    S.liveDraft = live && S.lastThreadID === currentID() ? live.value : null;
    // Et le champ qui a le clavier le garde, curseur compris : un rendu ne
    // doit jamais faire perdre une lettre.
    const active = document.activeElement;
    const keep = active && active.id && /^(INPUT|TEXTAREA)$/.test(active.tagName)
      ? { id: active.id, value: active.value, start: active.selectionStart, end: active.selectionEnd } : null;
    if (st.session === "disconnected" || st.session === "unknown") { renderLogin(); return; }
    // En Focus, le fil est le premier de la file si aucun n'est choisi.
    if (S.mode === "focus" && !st.focusID && st.focusQueue.length) { post("/api/select", { id: st.focusQueue[0], focus: true }); }
    const inbox = S.mode === "inbox";
    app.className = "app" + (inbox ? " inbox" : " focus");
    app.innerHTML = (inbox ? renderRail() + renderSidebar() : "") + renderMain();
    S.restoring = keep;
    wireMain();
    if (inbox) wireSidebar();
    if (keep) {
      const el = document.getElementById(keep.id);
      if (el) { el.value = keep.value; el.focus(); try { el.setSelectionRange(keep.start, keep.end); } catch {} if (el.id === "draft") el.dispatchEvent(new Event("resize")); }
    }
    S.restoring = null;
  }

  // -- connexion
  let loginTab = localStorage.getItem("cc.loginTab") || "code";
  function renderLogin() {
    const st = S.state; app.className = "app";
    const connecting = st.session === "connecting";
    app.innerHTML = `<div class="login"><form class="card" id="login">
      <div><h1>Correspondance</h1><p class="lede">Se connecter au Relais</p></div>
      <div class="tabs"><button type="button" data-tab="code" class="${loginTab === "code" ? "on" : ""}">Code d'appairage</button><button type="button" data-tab="manual" class="${loginTab === "manual" ? "on" : ""}">Adresse et identifiant</button></div>
      ${loginTab === "code" ? `<div class="field"><label>Le code que l'installeur du Relais affiche (<code>correspondance://relais/…</code>)</label><textarea name="code" placeholder="correspondance://relais/eyJ…" autofocus></textarea></div><div class="chemin" id="chemin"></div>`
        : `<div class="field"><label>Adresse du Relais</label><input name="homeserver" placeholder="relais.local:8008" value="${esc(st.rememberedHomeserver)}" autocomplete="url"></div>
           <div class="field"><label>Identifiant</label><input name="user" placeholder="meffysto" autocomplete="username"></div>
           <div class="field"><label>Mot de passe</label><input name="password" type="password" placeholder="••••••••" autocomplete="current-password"></div>`}
      ${st.connectionError ? `<div class="error">${esc(st.connectionError)}</div>` : ""}
      <button class="btn" ${connecting ? "disabled" : ""}>${connecting ? "Connexion…" : "Se connecter"}</button>
      <p class="meta">Le Relais est ton serveur, celui qui porte tes conversations WhatsApp, Instagram, Messenger et Signal. Il faut être sur son réseau pour l’atteindre — par Tailscale, ou par son adresse locale.</p>
    </form></div>`;
    $$("[data-tab]").forEach((b) => (b.onclick = () => { loginTab = b.dataset.tab; localStorage.setItem("cc.loginTab", loginTab); renderLogin(); }));
    const codeField = $("textarea[name=code]");
    if (codeField) codeField.oninput = () => { const c = decodeCode(codeField.value); $("#chemin").innerHTML = c ? `Relais <code>${esc(c.homeserver)}</code> · ${esc(c.user)}${c.tailcat ? " · via Tailcat (l'adresse ordinaire sera utilisée ici)" : ""}` : ""; };
    $("#login").onsubmit = async (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      const body = loginTab === "code" ? { code: f.get("code") } : { homeserver: f.get("homeserver"), user: f.get("user"), password: f.get("password") };
      const r = await post("/api/connect", body);
      if (r.empreinte) toast("Empreinte du Relais : " + r.empreinte.join(" "));
    };
  }
  function decodeCode(raw) {
    try {
      let s = raw.trim(); const p = "correspondance://relais/"; if (s.startsWith(p)) s = s.slice(p.length);
      s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "=";
      const j = JSON.parse(atob(s)); return j.homeserver ? j : null;
    } catch { return null; }
  }

  // -- rail
  function renderRail() {
    const st = S.state;
    const nets = [{ id: "", label: "Tous les réseaux", unread: st.unreadTotal }, ...st.networks];
    return `<nav class="rail">
      <img class="icon" src="/icon.png" alt="">
      ${nets.map((n) => `<button class="net ${(st.networkFilter || "") === n.id ? "on" : ""}" data-net="${esc(n.id)}" title="${esc(n.label)}">${I[n.id || "all"] || I.all}${n.unread ? `<span class="badge">${n.unread > 99 ? "99+" : n.unread}</span>` : ""}</button>`).join("")}
      <div class="spacer"></div>
      <button class="tool" data-act="selfNote" title="Note à soi">${I.selfNote}</button>
      <button class="tool" data-act="settings" title="Réglages">${I.gear}</button>
    </nav>`;
  }

  // -- sidebar
  function renderSidebar() {
    const st = S.state;
    const scopeLabel = { inbox: "Inbox", archive: "Archivés", reminders: "Rappels", requests: "Demandes" };
    let rows = st.conversations;
    const q = S.search.trim().toLowerCase();
    if (q) rows = rows.filter((c) => c.title.toLowerCase().includes(q) || c.preview.toLowerCase().includes(q));
    const pinned = rows.filter((c) => c.isPinned && st.scope === "inbox"), rest = rows.filter((c) => !(c.isPinned && st.scope === "inbox"));
    const list = rows.length ? (pinned.length ? `<div class="section">Épinglés</div>${pinned.map(renderRow).join("")}<div class="section">${scopeLabel[st.scope]}</div>` : "") + rest.map(renderRow).join("")
      : `<div class="empty">${st.scope === "inbox" ? "Rien à lire pour l’instant." : st.scope === "requests" ? "Aucune demande en attente." : st.scope === "reminders" ? "Aucun rappel posé." : "Rien d’archivé."}</div>`;
    return `<aside class="sidebar">
      <div class="head">
        <div class="title-row"><h1>${scopeLabel[st.scope] || "Inbox"}</h1>
          <div class="actions">
            <button class="iconbtn" data-act="compose" title="Nouvelle conversation">${I.compose}</button>
            <button class="iconbtn ${S.showFilters ? "on" : ""}" data-act="filters" title="Filtrer la liste">${I.all}</button>
            <button class="iconbtn ${st.isIncognito ? "on" : ""}" data-act="incognito" title="Mode incognito${st.isIncognito ? " (actif)" : ""}">${I.incognito}</button>
          </div></div>
        <label class="search">${I.search}<input id="sidebar-search" placeholder="Rechercher  Ctrl K" value="${esc(S.search)}"></label>
      </div>
      <div class="scopes">${st.scopes.map((s) => `<button data-scope="${s.id}" class="${st.scope === s.id ? "on" : ""}">${esc(s.label)}</button>`).join("")}</div>
      ${S.showFilters ? `<div class="filters">${st.filters.map((f) => `<button data-filter="${f.id}" class="${st.filter === f.id ? "on" : ""}">${esc(f.label)}</button>`).join("")}</div>` : ""}
      <div class="list" id="list">${list}</div>
      <div class="foot"><span>${esc(st.device)}${st.tailcat ? " · via Tailcat" : ""}${st.syncError ? " · hors ligne" : ""}</span>${st.readArchivableCount ? `<button data-act="archiveAllRead">Archiver tout ce qui est lu (${st.readArchivableCount})</button>` : ""}</div>
    </aside>`;
  }
  function renderAvatar(c, cls) {
    const dot = c.network && c.network !== "selfNote" ? `<span class="net-dot" style="background:${NETCOLOR[c.network] || "#888"}">${I[c.network] || ""}</span>` : "";
    if (c.hasAvatar) return `<div class="avatar ${cls || ""}"><img src="${avatarURL(c.id)}" alt="" onerror="this.replaceWith(document.createTextNode('${esc(initials(c.title))}'))">${dot}</div>`;
    if (c.isGroup) return `<div class="avatar ${cls || ""}">${I.group.replace("<svg", '<svg style="width:18px;height:18px"')}${dot}</div>`;
    return `<div class="avatar ${cls || ""}">${esc(initials(c.title))}${dot}</div>`;
  }
  function renderRow(c) {
    const st = S.state;
    const on = c.id === st.selectedID;
    let preview;
    if (c.typing) preview = `<span class="typing">${esc(c.typing)}</span>`;
    else if (c.draft && !on) preview = `<span class="draft">Brouillon :</span> ${esc(c.draft)}`;
    else preview = (c.isFromMe && !c.isGroup ? "Vous : " : "") + esc(c.preview);
    const badges = [c.isPinned ? `<span class="ico" title="Épinglé">${I.pin}</span>` : "", c.isMuted ? `<span class="ico" title="Muet">${I.mute}</span>` : "", c.reminder ? `<span class="ico" title="${esc(c.reminder.label)}">${I.clock}</span>` : "", c.isScheduled ? `<span class="ico" title="Message programmé">${I.clock}</span>` : ""].join("");
    const side = c.unread && !c.isMuted ? `<span class="count">${c.unread}</span>` : c.unread ? `<span class="dot"></span>` : "";
    return `<div class="row ${on ? "on" : ""} ${c.unread ? "unread" : ""} ${c.isRequest ? "request" : ""}" data-id="${esc(c.id)}">
      ${renderAvatar(c)}
      <div class="body"><div class="name"><span style="overflow:hidden;text-overflow:ellipsis">${esc(c.title)}</span>${badges}</div><div class="preview">${preview}</div></div>
      <div class="side"><span class="time">${fmtRowTime(c.lastMessageAt)}</span>${side}</div>
      <div class="rowmenu">
        <button data-row="archive" title="${c.isArchived ? "Ramener dans l’inbox" : "Archiver"}">${c.isArchived ? I.unarchive : I.archive}</button>
        <button data-row="pin" title="${c.isPinned ? "Ne plus épingler" : "Épingler au-dessus"}">${I.pin}</button>
        <button data-row="more" title="Plus">${I.more}</button>
      </div></div>`;
  }
  function wireSidebar() {
    $$("[data-net]").forEach((b) => (b.onclick = () => post("/api/network", { network: b.dataset.net })));
    $$("[data-scope]").forEach((b) => (b.onclick = () => post("/api/scope", { scope: b.dataset.scope })));
    $$("[data-filter]").forEach((b) => (b.onclick = () => post("/api/filter", { filter: b.dataset.filter })));
    $$("[data-act]").forEach((b) => (b.onclick = () => action(b.dataset.act)));
    const search = $("#sidebar-search");
    if (search) { search.oninput = () => { S.search = search.value; const list = $("#list"); const aside = $(".sidebar"); aside.outerHTML = renderSidebar(); wireSidebar(); const s2 = $("#sidebar-search"); s2.focus(); s2.setSelectionRange(s2.value.length, s2.value.length); }; }
    $$(".row").forEach((row) => {
      const id = row.dataset.id;
      row.onclick = (e) => { if (e.target.closest(".rowmenu")) return; post("/api/select", { id, focus: false }); };
      row.oncontextmenu = (e) => { e.preventDefault(); rowMenu(id, e.clientX, e.clientY); };
      $$("[data-row]", row).forEach((b) => (b.onclick = (e) => { e.stopPropagation(); rowAction(id, b.dataset.row, e); }));
    });
  }
  function conv(id) { return S.state.conversations.find((c) => c.id === id) || (S.thread && S.thread.conversation.id === id ? S.thread.conversation : null); }
  function rowAction(id, what, e) {
    const c = conv(id) || {};
    if (what === "archive") post("/api/archive", { id, value: !c.isArchived });
    else if (what === "pin") post("/api/pin", { id });
    else if (what === "mute") post("/api/mute", { id });
    else if (what === "more") { const r = e.target.closest("button").getBoundingClientRect(); rowMenu(id, r.right, r.bottom); }
  }
  function rowMenu(id, x, y) {
    const c = conv(id) || {}; const st = S.state;
    const items = [
      { label: c.isArchived ? "Ramener dans l’inbox" : "Archiver", icon: c.isArchived ? I.unarchive : I.archive, run: () => post("/api/archive", { id, value: !c.isArchived }) },
      { label: c.isPinned ? "Ne plus épingler" : "Épingler au-dessus", icon: I.pin, run: () => post("/api/pin", { id }) },
      { label: c.isMuted ? "Réactiver les notifications" : "Mettre en sourdine", icon: I.mute, run: () => post("/api/mute", { id }) },
      { label: "Marquer comme lu", icon: I.check, run: () => post("/api/markRead", { id }) },
      { sep: true }, { lab: "Rappel" },
      ...st.reminderSuggestions.map((s) => ({ label: s.title, icon: I.clock, run: () => post("/api/reminder", { id, wakeAt: s.at }) })),
      ...(c.reminder ? [{ label: "Lever le rappel", icon: I.x, run: () => post("/api/reminder", { id }) }] : []),
      { sep: true }, { label: "Ouvrir en Focus", icon: I.right, run: () => { S.mode = "focus"; prefs.mode = "focus"; post("/api/select", { id, focus: true }); } },
    ];
    if (c.isRequest) items.unshift({ label: "Accepter la demande", icon: I.check, run: () => post("/api/request", { id, decision: "accepted" }) }, { label: "Refuser", icon: I.x, run: () => post("/api/request", { id, decision: "declined" }) }, { sep: true });
    menu(items, x, y);
  }
  function menu(items, x, y, extraHTML) {
    const el = document.createElement("div"); el.className = "menu";
    el.innerHTML = (extraHTML || "") + items.map((it, i) => it.sep ? `<div class="sep"></div>` : it.lab ? `<div class="lab">${esc(it.lab)}</div>` : `<button data-i="${i}">${it.icon || ""}<span>${esc(it.label)}</span></button>`).join("");
    overlay.innerHTML = `<div class="scrim" style="background:transparent"></div>`; overlay.appendChild(el);
    const w = 240, h = el.offsetHeight || 300;
    el.style.left = Math.min(x, innerWidth - w - 8) + "px"; el.style.top = Math.min(y, innerHeight - h - 8) + "px";
    $(".scrim", overlay).onclick = closeOverlay;
    $$("button[data-i]", el).forEach((b) => (b.onclick = () => { closeOverlay(); items[+b.dataset.i].run(); }));
    return el;
  }
  function closeOverlay() { overlay.innerHTML = ""; }

  // -- le fil
  function renderMain() {
    const st = S.state, t = S.thread, focus = S.mode === "focus";
    const modes = `<div class="modes"><button data-mode="focus" class="${focus ? "on" : ""}" title="Mode Focus  Ctrl 1">Focus</button><button data-mode="inbox" class="${!focus ? "on" : ""}" title="Inbox  Ctrl 2">Inbox</button></div>`;
    if (!t) {
      const empty = focus ? `<div class="focus-empty"><div>Rien à lire pour l’instant.<small>La file est vide : tout est traité. <kbd>Ctrl</kbd> <kbd>2</kbd> ouvre l’inbox.</small></div></div>` : `<div class="focus-empty"><div>Choisis une conversation.<small><kbd>Ctrl</kbd> <kbd>K</kbd> pour chercher, <kbd>Ctrl</kbd> <kbd>1</kbd> pour le Focus.</small></div></div>`;
      return `<section class="main ${focus ? "focus" : "inbox"}"><div class="chrome ${focus ? "revealed" : ""}"><div class="ttl"><b>Correspondance</b></div>${focus ? `<button class="iconbtn" data-act="settings" title="Réglages">${I.gear}</button>` : ""}${modes}</div>${st.syncError ? `<div class="sync-bar">${esc(st.syncError)}</div>` : ""}${empty}</section>`;
    }
    const c = t.conversation;
    const queue = st.focusQueue, pos = queue.indexOf(c.id);
    const nav = focus ? `<div class="focus-nav"><button class="iconbtn" data-act="prev" title="Conversation précédente  K">${I.left}</button><span class="n">${pos >= 0 ? `${pos + 1} sur ${queue.length}` : "hors file"}</span><button class="iconbtn" data-act="next" title="Conversation suivante  J">${I.right}</button></div>` : "";
    const chrome = `<div class="chrome ${S.chromeRevealed ? "revealed" : "hover-revealed"}" id="chrome">
      ${nav}
      <div class="ttl">${focus ? "" : `<b>${esc(c.title)}</b><span class="meta">${c.networkLabel !== c.title ? esc(c.networkLabel) : ""}${c.isGroup ? " · groupe" : ""}</span>`}${c.typing ? `<span class="phrase">${esc(c.typing)}</span>` : ""}</div>
      <button class="iconbtn" data-act="threadSearch" title="Rechercher dans le fil  Ctrl F">${I.search}</button>
      <button class="iconbtn" data-act="archiveThread" title="${c.isArchived ? "Ramener dans l’inbox" : focus ? "Archiver et passer à la suivante  E" : "Archiver  E"}">${c.isArchived ? I.unarchive : I.archive}</button>
      <button class="iconbtn" data-act="threadMenu" title="Plus">${I.more}</button>
      ${focus ? `<button class="iconbtn" data-act="settings" title="Réglages">${I.gear}</button>` : ""}
      ${modes}</div>`;
    const search = S.threadSearchOpen ? `<div class="threadsearch">${I.search}<input id="thread-search" placeholder="Rechercher dans le fil" value="${esc(S.threadQuery)}"><span class="n" id="thread-search-n"></span><button class="iconbtn" data-act="threadSearchClose">${I.x}</button></div>` : "";
    const request = c.isRequest ? `<div class="request-bar"><span>Demande${c.request && c.request.isKnown ? " d’une personne déjà connue" : " d’un inconnu"}${c.request && c.request.flagged ? " · signalée par le réseau" : ""}.</span><span class="sp"></span><button data-act="decline">Refuser</button><button class="primary" data-act="accept">Accepter</button></div>` : "";
    const head = focus ? `<div class="letterhead"><h2>${esc(c.title)}</h2><div class="meta">${c.networkLabel !== c.title ? `<span>${esc(c.networkLabel)}</span>` : ""}${c.isGroup ? "<span>· groupe</span>" : ""}<span class="privacy" title="${esc(c.privacy)}">${c.hasClosedLock ? I.lock : I.lockOpen} ${esc(c.privacy)}</span>${c.isMerged ? `<span>· ${c.members.map((m) => esc(m.label)).join(" + ")}</span>` : ""}</div></div>` : "";
    const older = t.count >= 20 ? `<button class="older" data-act="older">${t.isLoadingOlder ? "Chargement…" : "Voir les messages précédents"}</button>` : "";
    const groups = t.groups.map(renderGroup).join("");
    const typing = t.typing ? `<div class="typing-row"><i></i><i></i><i></i> ${esc(t.typing)}</div>` : "";
    const seen = t.seenBy ? `<div class="seen">${esc(t.seenBy)}</div>` : "";
    return `<section class="main ${focus ? "focus" : "inbox"}">${chrome}${search}${st.syncError ? `<div class="sync-bar">${esc(st.syncError)}</div>` : ""}
      <div class="thread" id="thread"><div class="column">${head}${request}${older}${groups}${seen}${typing}</div></div>
      ${renderComposer(t)}
    </section>`;
  }
  function renderGroup(g) {
    const parts = [];
    if (g.separator) parts.push(`<div class="sep">${esc(fmtSeparator(g.separator))}</div>`);
    const c = S.thread.conversation;
    const inner = g.messages.map((m) => renderMessage(m, g)).join("");
    if (g.messages.every((m) => m.system)) return parts.join("") + inner;
    parts.push(`<div class="group ${g.isFromMe ? "me" : ""}">${!g.isFromMe && g.sender && (c.isGroup || g.showsNetworkOrigin) ? `<div class="sender">${esc(g.sender)}</div>` : ""}${g.showsNetworkOrigin && g.networkLabel ? `<div class="origin">via ${esc(g.networkLabel)}</div>` : ""}${inner}</div>`);
    return parts.join("");
  }
  function renderMessage(m, g) {
    if (m.system) return `<div class="sysevent">${esc(m.system)}</div>`;
    const q = S.threadSearchOpen ? S.threadQuery : "";
    if (m.proposal) {
      return `<div class="msg" data-id="${esc(m.id)}"><div class="proposal"><div class="who">${esc(m.proposal.agent)} propose</div>${rich(m.proposal.text, m.links, q)}<div class="acts"><button class="primary" data-msg="proposalSend">Envoyer</button><button data-msg="proposalEdit">Modifier…</button><button data-msg="proposalIgnore">Ignorer</button></div></div></div>`;
    }
    let body = "";
    if (m.replyTo) body += `<div class="quote" data-jump="${esc(m.replyTo.id || "")}"><b>${esc(m.replyTo.sender)}</b>${esc(m.replyTo.text)}</div>`;
    for (const a of m.attachments) body += renderAttachment(a);
    if (m.poll) body += renderPoll(m);
    if (m.isRetracted) body += "Message supprimé";
    else if (m.text) body += rich(m.text, m.links, q);
    if (m.linkPreview && (m.linkPreview.title || m.linkPreview.image)) {
      body += `<a class="linkcard" href="${esc(m.linkPreview.url)}" target="_blank" rel="noopener">${m.linkPreview.image ? `<img src="${fileURL(m.linkPreview.image)}" alt="">` : ""}<div class="t">${esc(m.linkPreview.title || m.linkPreview.url)}<small>${esc(m.linkPreview.description || domain(m.linkPreview.url))}</small></div></a>`;
    }
    const delivery = m.isFromMe ? (m.isPending ? I.clock : "") : "";
    const stamp = `<div class="stamp">${m.editedAt ? "<span>modifié</span>" : ""}${m.effect ? `<span>· ${esc(m.effect)}</span>` : ""}<span>${fmtTime(m.sentAt)}</span>${delivery}</div>`;
    const cls = ["bubble", m.isPending ? "pending" : "", m.isRetracted ? "retracted" : "", m.isEmojiOnly && !m.attachments.length ? "emoji" : ""].join(" ");
    const acts = `<div class="acts">
      <button data-msg="react" data-emoji="👍" title="Réagir 👍">👍</button><button data-msg="react" data-emoji="❤️" title="Réagir ❤️">❤️</button><button data-msg="react" data-emoji="😂" title="Réagir 😂">😂</button>
      <button data-msg="reactMore" title="Réagir…">${I.plus}</button>
      <button data-msg="reply" title="Répondre en citant  Ctrl R">${I.reply}</button>
      ${m.canEdit ? `<button data-msg="edit" title="Modifier le message">${I.edit}</button>` : ""}
      ${m.canForward ? `<button data-msg="forward" title="Transférer…">${I.forward}</button>` : ""}
      <button data-msg="more" title="Plus">${I.more}</button></div>`;
    const reactions = m.reactions.length ? `<div class="reactions">${m.reactions.map((r) => `<button class="pill ${r.isMine ? "mine" : ""}" data-msg="react" data-emoji="${esc(r.emoji)}" title="${esc(r.senders.join(", "))}">${esc(r.emoji)} ${r.count > 1 ? r.count : ""}</button>`).join("")}</div>` : "";
    const aside = m.aside ? `<div class="aside">${esc(m.aside)}</div>` : "";
    return `<div class="msg" data-id="${esc(m.id)}">${acts}<div class="${cls}">${body}${m.isEmojiOnly && !m.attachments.length ? "" : stamp}</div>${reactions}${aside}</div>`;
  }
  const domain = (u) => { try { return new URL(u).host.replace(/^www\./, ""); } catch { return u; } };
  function renderAttachment(a) {
    if (!a.localPath) return `<div class="file">${I.file}<div>${esc(a.filename || "Pièce jointe")}<small>en cours de téléchargement…</small></div></div>`;
    const url = fileURL(a.localPath);
    if (a.voice) return renderVoice(a, url);
    if (a.isImage || a.isGIF) return `<img class="att-img" src="${url}" alt="${esc(a.filename || "Image")}" data-light="${url}" loading="lazy">`;
    if (a.isVideo) return `<video src="${url}" controls preload="metadata"></video>`;
    if (a.isAudio) return `<audio src="${url}" controls preload="metadata"></audio>`;
    return `<a class="file" href="${url}" download="${esc(a.filename || "fichier")}">${I.file}<div>${esc(a.filename || "Fichier")}<small>${esc(a.contentType)}</small></div></a>`;
  }
  function renderVoice(a, url) {
    const bars = (a.voice.waveform && a.voice.waveform.length ? a.voice.waveform : Array.from({ length: 40 }, () => 0.4)).slice(0, 60);
    return `<div class="voice" data-audio="${url}"><button class="play">${I.play}</button><div class="wave">${bars.map((v) => `<i style="height:${Math.max(2, Math.round(v * 22))}px"></i>`).join("")}</div><span class="dur">${fmtDur(a.voice.duration || 0)}</span></div>`;
  }
  function renderPoll(m) {
    const p = m.poll;
    return `<div class="poll"><div class="q">${esc(p.question)}</div>${p.answers.map((a) => `<div class="a ${a.mine ? "mine" : ""}" data-answer="${esc(a.id)}"><div class="bar" style="width:${p.total ? Math.round((a.count / p.total) * 100) : 0}%"></div><span>${esc(a.text)}</span><small>${a.count}</small></div>`).join("")}<div class="tot">${p.total} vote${p.total > 1 ? "s" : ""}${p.isClosed ? " · sondage clos" : ""}</div></div>`;
  }
  function renderComposer(t) {
    const c = t.conversation;
    const reply = t.replyTo ? `<div class="banner">${I.reply}<span>Réponse à <b>${esc(t.replyTo.sender)}</b> : ${esc(t.replyTo.text)}</span><button class="x" data-act="cancelReply">${I.x}</button></div>` : "";
    const editing = t.editing ? `<div class="banner">${I.edit}<span><b>Modifier le message</b></span><button class="x" data-act="cancelEdit">${I.x}</button></div>` : "";
    const atts = t.attachments.length ? `<div class="pending-atts">${t.attachments.map((a) => `<div class="p">${a.isImage ? `<img src="${fileURL(a.path)}" alt="">` : esc(a.name)}<button data-remove="${esc(a.path)}">×</button></div>`).join("")}</div>` : "";
    const placeholder = c.network === "selfNote" ? "Une note pour plus tard…" : `Répondre${t.sendingNetwork ? " sur " + t.sendingNetwork : ""}…`;
    return `<div class="composer"><div class="column">${editing}${reply}${atts}
      <div class="box">
        <button class="plus" data-act="attach" title="Joindre un fichier">${I.plus}</button>
        <textarea id="draft" rows="1" placeholder="${esc(placeholder)}">${esc(S.liveDraft ?? t.draft)}</textarea>
        <button class="send" id="send" title="Envoyer  Entrée" ${t.canSend && !t.isSending ? "" : "disabled"}>${I.up}</button>
      </div>
      <div class="hint"><span>${t.editing ? "Entrée valide la correction · Échap annule" : "Entrée envoie · Maj Entrée saute une ligne · Ctrl Entrée envoie et archive"}</span><span>${S.state.isIncognito ? "incognito" : ""}</span></div>
      <input type="file" id="file" multiple class="hidden"></div></div>`;
  }

  // -- câblage du fil
  let audio = null, audioEl = null;
  function wireMain() {
    $$("[data-mode]").forEach((b) => (b.onclick = () => setMode(b.dataset.mode)));
    $$(".main [data-act]").forEach((b) => (b.onclick = () => action(b.dataset.act)));
    const thread = $("#thread");
    if (thread) {
      const t = S.thread; const id = t.conversation.id;
      // Le bas tient : nouveau fil → en bas ; nouveaux messages en bas → on suit.
      const changed = id !== S.lastThreadID;
      if (changed || S.atBottom) thread.scrollTop = thread.scrollHeight;
      S.lastThreadID = id; S.lastCount = t.count;
      thread.onscroll = () => { S.atBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 40; };
      S.atBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 40;
      $$(".msg", thread).forEach((el) => {
        const mid = el.dataset.id;
        $$("[data-msg]", el).forEach((b) => (b.onclick = (e) => { e.stopPropagation(); messageAction(id, mid, b.dataset.msg, b, e); }));
        $$("[data-jump]", el).forEach((q) => (q.onclick = () => jumpTo(q.dataset.jump)));
        $$("[data-light]", el).forEach((img) => (img.onclick = () => lightbox(img.dataset.light)));
        $$("[data-answer]", el).forEach((a) => (a.onclick = () => post("/api/vote", { id, messageID: mid, answerID: a.dataset.answer })));
        $$(".voice", el).forEach((v) => ($(".play", v).onclick = () => toggleVoice(v)));
        el.oncontextmenu = (e) => { if (e.target.closest("a, img, video, audio")) return; e.preventDefault(); messageMenu(id, mid, e.clientX, e.clientY); };
      });
      if (S.threadSearchOpen) wireThreadSearch();
      if (S.pendingJump) { jumpTo(S.pendingJump); S.pendingJump = null; }
    }
    wireComposer();
    // Chrome fantôme du Focus : visible quand la souris monte en haut.
    const main = $(".main.focus");
    if (main) main.onmousemove = (e) => { const r = main.getBoundingClientRect(); const near = e.clientY - r.top < 60; if (near !== S.chromeRevealed) { S.chromeRevealed = near; $("#chrome")?.classList.toggle("revealed", near); } };
  }
  function wireComposer() {
    const ta = $("#draft"); if (!ta) return;
    const t = S.thread, id = t.conversation.id;
    const grow = () => { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, innerHeight * 0.4) + "px"; };
    grow();
    const pushDraft = debounce((v) => post("/api/draft", { id, text: v }), 400);
    ta.oninput = () => { grow(); $("#send").disabled = !(ta.value.trim() || t.attachments.length); pushDraft(ta.value); };
    ta.onkeydown = (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(e.ctrlKey || e.metaKey); }
      else if (e.key === "Escape") { if (t.editing) post("/api/endEdit", { id }); else if (t.replyTo) post("/api/reply", { id }); else ta.blur(); }
    };
    ta.onpaste = (e) => { const files = Array.from(e.clipboardData?.files || []); if (files.length) { e.preventDefault(); upload(files); } };
    $("#send").onclick = () => send(false);
    $("#file").onchange = (e) => upload(Array.from(e.target.files));
    $$("[data-remove]").forEach((b) => (b.onclick = () => post("/api/attachments/remove", { id, path: b.dataset.remove })));
    const main = $(".main");
    main.ondragover = (e) => { e.preventDefault(); main.classList.add("dropping"); };
    main.ondragleave = () => main.classList.remove("dropping");
    main.ondrop = (e) => { e.preventDefault(); main.classList.remove("dropping"); upload(Array.from(e.dataTransfer.files)); };
    if (!S.restoring && (S.lastFocusedTA !== id || document.activeElement === document.body)) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); S.lastFocusedTA = id; }
    ta.addEventListener("resize", grow);
    async function send(andArchive) {
      const text = ta.value;
      if (t.editing) { if (!text.trim()) return; await post("/api/edit", { id, messageID: t.editing.id, text }); return; }
      if (!text.trim() && !t.attachments.length) return;
      ta.value = ""; grow(); S.liveDraft = "";
      await post("/api/draft", { id, text });
      const r = await post("/api/send", { id });
      post("/api/draft", { id, text: "" });
      if (andArchive) { post("/api/archive", { id, value: true }); if (S.mode === "focus") post("/api/focus/next"); }
      S.atBottom = true;
      const delay = S.state.undoSendDelay;
      if (delay > 0) setTimeout(() => { const last = (S.thread?.groups || []).flatMap((g) => g.messages).filter((m) => m.canUndo).pop(); if (last) toast("Envoyé", { label: "Annuler", ms: delay * 1000, run: () => post("/api/undoSend", { messageID: last.id }) }); }, 300);
    }
    async function upload(files) {
      for (const f of files) {
        await fetch(`/api/upload?id=${encodeURIComponent(id)}`, { method: "POST", headers: { "X-Correspondance-Token": token, "X-File-Name": encodeURIComponent(f.name), "Content-Type": "application/octet-stream" }, body: f });
      }
    }
  }
  function toggleVoice(v) {
    const url = v.dataset.audio;
    if (audioEl && audio === url) { if (audioEl.paused) { audioEl.play(); $(".play", v).innerHTML = I.pause; } else { audioEl.pause(); $(".play", v).innerHTML = I.play; } return; }
    if (audioEl) { audioEl.pause(); $$(".voice .play").forEach((p) => (p.innerHTML = I.play)); }
    audio = url; audioEl = new Audio(url); audioEl.play(); $(".play", v).innerHTML = I.pause;
    audioEl.onended = () => { $(".play", v).innerHTML = I.play; };
    audioEl.ontimeupdate = () => { const bars = $$(".wave i", v); const k = Math.floor((audioEl.currentTime / (audioEl.duration || 1)) * bars.length); bars.forEach((b, i) => (b.style.opacity = i <= k ? "1" : ".5")); };
  }
  function jumpTo(mid) {
    if (!mid) return;
    const el = $(`.msg[data-id="${CSS.escape(mid)}"] .bubble`);
    if (!el) { toast("Ce message n’est pas encore chargé — remonte le fil."); return; }
    el.scrollIntoView({ block: "center" }); el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash");
  }
  function lightbox(url) {
    overlay.innerHTML = `<div class="lightbox"><img src="${url}" alt=""></div>`;
    $(".lightbox", overlay).onclick = closeOverlay;
  }

  // -- actions
  function setMode(mode) {
    if (S.mode === mode) return;
    S.mode = mode; prefs.mode = mode; S.chromeRevealed = false; S.threadSearchOpen = false;
    if (mode === "focus") { const id = S.state.focusID || S.state.focusQueue[0]; if (id) post("/api/select", { id, focus: true }); }
    refresh();
  }
  async function action(what) {
    const st = S.state, t = S.thread, id = t?.conversation.id;
    switch (what) {
      case "settings": return settingsSheet();
      case "selfNote": return post("/api/selfNote");
      case "compose": return composeSheet();
      case "filters": S.showFilters = !S.showFilters; return render();
      case "incognito": return post("/api/incognito", { value: !st.isIncognito });
      case "archiveAllRead": return post("/api/archiveAllRead");
      case "prev": return post("/api/focus/previous");
      case "next": return post("/api/focus/next");
      case "archiveThread": if (!id) return; if (t.conversation.isArchived) return post("/api/archive", { id, value: false }); return S.mode === "focus" ? post("/api/focus/archive") : post("/api/archive", { id, value: true });
      case "threadSearch": S.threadSearchOpen = true; render(); $("#thread-search")?.focus(); return;
      case "threadSearchClose": S.threadSearchOpen = false; S.threadQuery = ""; return render();
      case "threadMenu": { const b = $('[data-act="threadMenu"]'); const r = b.getBoundingClientRect(); return threadMenu(id, r.right, r.bottom); }
      case "older": return post("/api/loadOlder", { id });
      case "cancelReply": return post("/api/reply", { id });
      case "cancelEdit": return post("/api/endEdit", { id });
      case "attach": return $("#file").click();
      case "accept": return post("/api/request", { id, decision: "accepted" });
      case "decline": return post("/api/request", { id, decision: "declined" });
    }
  }
  function threadMenu(id, x, y) {
    const c = conv(id) || S.thread.conversation, t = S.thread, st = S.state;
    const items = [
      { label: c.isPinned ? "Ne plus épingler" : "Épingler au-dessus", icon: I.pin, run: () => post("/api/pin", { id }) },
      { label: c.isMuted ? "Réactiver les notifications" : "Mettre en sourdine", icon: I.mute, run: () => post("/api/mute", { id }) },
      { label: "Marquer comme lu", icon: I.check, run: () => post("/api/markRead", { id }) },
      { sep: true }, { lab: "Rappel" },
      ...st.reminderSuggestions.map((s) => ({ label: s.title, icon: I.clock, run: () => post("/api/reminder", { id, wakeAt: s.at }) })),
      ...(c.reminder ? [{ label: "Lever le rappel", icon: I.x, run: () => post("/api/reminder", { id }) }] : []),
      { sep: true },
      { label: "Inviter l’agent cc", icon: I.agent, run: () => post("/api/agent/invite", { id }) },
      ...(t.capabilities.renamesGroup || t.capabilities.addsMember || t.capabilities.removesMember ? [{ label: "Gérer le groupe…", icon: I.group, run: () => groupSheet(id) }] : []),
      { label: "Voir les membres", icon: I.group, run: () => membersSheet(id) },
      { sep: true },
      { label: "Recharger depuis le Relais", icon: I.undo, run: () => post("/api/reload") },
    ];
    menu(items, x, y);
  }
  function messageAction(id, mid, what, btn, e) {
    const m = (S.thread.groups.flatMap((g) => g.messages)).find((x) => x.id === mid) || {};
    switch (what) {
      case "react": return post("/api/react", { id, messageID: mid, emoji: btn.dataset.emoji });
      case "reactMore": { const r = btn.getBoundingClientRect(); return emojiMenu(id, mid, r.left, r.bottom + 4); }
      case "reply": return post("/api/reply", { id, messageID: mid });
      case "edit": return post("/api/beginEdit", { id, messageID: mid });
      case "forward": return forwardSheet(id, mid);
      case "more": { const r = btn.getBoundingClientRect(); return messageMenu(id, mid, r.left, r.bottom + 4); }
      case "proposalSend": return post("/api/proposal/send", { id, messageID: mid });
      case "proposalEdit": return post("/api/proposal/edit", { id, messageID: mid });
      case "proposalIgnore": return post("/api/proposal/ignore", { id, messageID: mid });
    }
  }
  function emojiMenu(id, mid, x, y) {
    const emojis = ["👍", "❤️", "😂", "😮", "😢", "🙏", "🔥", "👏", "🎉", "✅", "👀", "💯"];
    const el = menu([], x, y, `<div class="emojis">${emojis.slice(0, 6).map((e) => `<button data-e="${e}">${e}</button>`).join("")}</div><div class="emojis">${emojis.slice(6).map((e) => `<button data-e="${e}">${e}</button>`).join("")}</div>`);
    $$("[data-e]", el).forEach((b) => (b.onclick = () => { closeOverlay(); post("/api/react", { id, messageID: mid, emoji: b.dataset.e }); }));
  }
  function messageMenu(id, mid, x, y) {
    const m = (S.thread.groups.flatMap((g) => g.messages)).find((x) => x.id === mid) || {};
    const items = [
      { label: "Répondre en citant", icon: I.reply, run: () => post("/api/reply", { id, messageID: mid }) },
      { label: "Copier le texte", icon: I.copy, run: () => navigator.clipboard.writeText(m.text || "") },
      ...(m.canEdit ? [{ label: "Modifier le message", icon: I.edit, run: () => post("/api/beginEdit", { id, messageID: mid }) }] : []),
      ...(m.canForward ? [{ label: "Transférer…", icon: I.forward, run: () => forwardSheet(id, mid) }] : []),
      ...(m.canUndo ? [{ label: "Annuler l’envoi", icon: I.undo, run: () => post("/api/undoSend", { messageID: mid }) }] : []),
      { sep: true },
      { label: "Supprimer ici", icon: I.hide, run: () => post("/api/hide", { id, messageID: mid }) },
      ...(m.canDelete ? [{ label: "Supprimer pour tout le monde", icon: I.trash, run: () => post("/api/deleteEverywhere", { id, messageID: mid }) }] : []),
    ];
    menu(items, x, y, `<div class="emojis">${["👍", "❤️", "😂", "😮", "😢", "🙏"].map((e) => `<button data-e="${e}">${e}</button>`).join("")}</div><div class="sep"></div>`);
    $$("[data-e]", overlay).forEach((b) => (b.onclick = () => { closeOverlay(); post("/api/react", { id, messageID: mid, emoji: b.dataset.e }); }));
  }

  // -- recherche dans le fil
  function wireThreadSearch() {
    const input = $("#thread-search"); if (!input) return;
    const update = () => {
      const marks = $$("#thread mark"); const n = $("#thread-search-n"); n.textContent = marks.length ? `${marks.length} résultat${marks.length > 1 ? "s" : ""}` : S.threadQuery ? "aucun" : "";
    };
    input.oninput = debounce(() => { S.threadQuery = input.value; render(); const i2 = $("#thread-search"); i2.focus(); i2.setSelectionRange(i2.value.length, i2.value.length); }, 120);
    input.onkeydown = (e) => { if (e.key === "Escape") action("threadSearchClose"); if (e.key === "Enter") { const marks = $$("#thread mark"); if (marks.length) { S.searchCursor = ((S.searchCursor ?? -1) + (e.shiftKey ? -1 : 1) + marks.length) % marks.length; marks[S.searchCursor].scrollIntoView({ block: "center" }); } } };
    update();
  }

  // ---------- Feuilles ----------
  function sheet(title, bodyHTML) {
    overlay.innerHTML = `<div class="scrim"></div><div class="sheet"><div class="sh"><h3>${esc(title)}</h3><button class="iconbtn" id="sheet-close">${I.x}</button></div><div class="sc">${bodyHTML}</div></div>`;
    $(".scrim", overlay).onclick = closeOverlay; $("#sheet-close").onclick = closeOverlay;
    return $(".sheet .sc", overlay);
  }
  function settingsSheet() {
    const st = S.state;
    const body = `
      <div class="row-set"><div class="l">Thème d’écriture</div></div>
      <div class="grid" style="margin:8px 0 14px">${Object.entries(THEMES).map(([k, t]) => { const p = makePalette(rgb(t.paper), rgb(t.ink), rgb(t.accent), rgb(t.soft), t.dark); return `<button class="swatch ${prefs.theme === k ? "on" : ""}" data-theme="${k}"><div class="sw"><i style="background:${css(p.paper)}"></i><i style="background:${css(p.bubbleIn)}"></i><i style="background:${css(p.accentFill)}"></i><i style="background:${css(p.ink)}"></i></div><b>${t.label}</b><small>${t.sub}</small></button>`; }).join("")}</div>
      <div class="row-set"><div class="l">Police</div></div>
      <div class="faces" style="margin:8px 0 14px">${Object.entries(TYPEFACES).map(([k, f]) => `<button data-face="${k}" class="${prefs.typeface === k ? "on" : ""}" style="font-family:${f.css}"><b>${f.label}</b><small>${f.sub}</small></button>`).join("")}</div>
      <div class="row-set"><div class="l">Taille du texte<small>Ce qu’on lit et ce qu’on écrit ; le chrome ne bouge pas.</small></div><div style="display:flex;gap:4px;align-items:center"><button class="iconbtn" data-scale="-1">−</button><span style="min-width:44px;text-align:center">${Math.round(prefs.scale * 100)} %</span><button class="iconbtn" data-scale="1">+</button></div></div>
      <div class="row-set"><div class="l">Annuler l’envoi<small>Le message part après ce délai, le temps de se raviser.</small></div><select id="undo">${st.undoSendDelays.map((d) => `<option value="${d.seconds}" ${st.undoSendDelay === d.seconds ? "selected" : ""}>${esc(d.label)}</option>`).join("")}</select></div>
      <div class="row-set"><div class="l">Mode incognito<small>Lire sans accusé de lecture ; répondre lève le voile.</small></div><button class="toggle ${st.isIncognito ? "on" : ""}" id="incog"></button></div>
      <div class="row-set"><div class="l">L’agent cc, quand d’autres lisent<small>${esc(st.agentModes.find((m) => m.id === st.agentMode)?.subtitle || "")}</small></div><select id="agentmode">${st.agentModes.map((m) => `<option value="${m.id}" ${st.agentMode === m.id ? "selected" : ""}>${esc(m.label)}</option>`).join("")}</select></div>
      <div class="row-set"><div class="l">Relais<small>${esc(st.rememberedHomeserver || "connecté")} · ${esc(st.device)}</small></div><div style="display:flex;gap:6px"><button class="btn secondary" style="padding:8px 14px;font-size:13px" id="reload">Recharger</button><button class="btn secondary" style="padding:8px 14px;font-size:13px" id="signout">Se déconnecter</button></div></div>
      <div class="row-set"><div class="l">Raccourcis<small><kbd>Ctrl 1</kbd> Focus · <kbd>Ctrl 2</kbd> Inbox · <kbd>Ctrl K</kbd> chercher · <kbd>Ctrl F</kbd> dans le fil · <kbd>J</kbd>/<kbd>K</kbd> suivante/précédente · <kbd>E</kbd> archiver · <kbd>Ctrl R</kbd> citer · <kbd>Ctrl +</kbd>/<kbd>−</kbd> texte</small></div></div>`;
    const sc = sheet("Réglages", body);
    $$("[data-theme]", sc).forEach((b) => (b.onclick = () => { prefs.theme = b.dataset.theme; settingsSheet(); }));
    $$("[data-face]", sc).forEach((b) => (b.onclick = () => { prefs.typeface = b.dataset.face; settingsSheet(); }));
    $$("[data-scale]", sc).forEach((b) => (b.onclick = () => { prefs.scale = prefs.scale + 0.1 * +b.dataset.scale; settingsSheet(); }));
    $("#undo", sc).onchange = (e) => post("/api/undoSendDelay", { seconds: +e.target.value });
    $("#incog", sc).onclick = () => { post("/api/incognito", { value: !st.isIncognito }); closeOverlay(); };
    $("#agentmode", sc).onchange = (e) => post("/api/agent/mode", { mode: e.target.value });
    $("#reload", sc).onclick = () => { post("/api/reload"); closeOverlay(); };
    $("#signout", sc).onclick = () => { post("/api/signout"); closeOverlay(); };
  }
  function composeSheet() {
    const nets = S.state.networks.filter((n) => ["signal", "whatsapp", "instagram", "messenger"].includes(n.id));
    const sc = sheet("Nouvelle conversation", `<form id="compose">
      <div class="field" style="margin-bottom:12px"><label class="meta">Réseau</label><select name="network" style="width:100%;padding:10px;border-radius:12px;border:1px solid var(--separator);background:var(--paper-secondary)">${(nets.length ? nets : [{ id: "whatsapp", label: "WhatsApp" }, { id: "signal", label: "Signal" }]).map((n) => `<option value="${n.id}">${esc(n.label)}</option>`).join("")}</select></div>
      <div class="field" style="margin-bottom:12px"><label class="meta">Numéro ou identifiant</label><input name="identifier" placeholder="+33 6 12 34 56 78, ou un nom d’utilisateur" style="width:100%;padding:10px;border-radius:12px;border:1px solid var(--separator);background:var(--paper-secondary)" autofocus></div>
      <p class="meta" style="margin-bottom:14px">Le pont du réseau ouvre le fil, comme si tu l’avais commencé depuis ton téléphone. Pour te parler à toi-même : la <b>note à soi</b>, dans le rail.</p>
      <button class="btn" style="width:100%">Ouvrir la conversation</button></form>`);
    $("#compose", sc).onsubmit = (e) => { e.preventDefault(); const f = new FormData(e.target); post("/api/newChat", { network: f.get("network"), identifier: f.get("identifier") }); closeOverlay(); };
  }
  async function membersSheet(id) {
    const r = await get("/api/members", { id });
    sheet("Membres", `<div>${r.members.map((m) => `<div class="row-set"><div class="l">${esc(m.name)}<small>${esc(m.userID)}</small></div></div>`).join("") || "<p class='meta'>Personne d’autre ici.</p>"}</div>`);
  }
  async function groupSheet(id) {
    const t = S.thread, c = t.conversation; const r = await get("/api/members", { id });
    const sc = sheet("Gérer le groupe", `
      ${t.capabilities.renamesGroup ? `<form id="rename" class="row-set"><div class="l" style="flex:1"><input name="name" value="${esc(c.title)}" style="width:100%;padding:8px 10px;border-radius:10px;border:1px solid var(--separator);background:var(--paper-secondary)"></div><button class="btn secondary" style="padding:8px 14px;font-size:13px">Renommer</button></form>` : ""}
      ${t.capabilities.addsMember ? `<form id="invite" class="row-set"><div class="l" style="flex:1"><input name="who" placeholder="Numéro ou identifiant à ajouter" style="width:100%;padding:8px 10px;border-radius:10px;border:1px solid var(--separator);background:var(--paper-secondary)"></div><button class="btn secondary" style="padding:8px 14px;font-size:13px">Ajouter</button></form>` : ""}
      ${r.members.map((m) => `<div class="row-set"><div class="l">${esc(m.name)}<small>${esc(m.userID)}</small></div>${t.capabilities.removesMember ? `<button class="iconbtn" data-remove-member="${esc(m.userID)}" title="Retirer">${I.x}</button>` : ""}</div>`).join("")}`);
    const rename = $("#rename", sc); if (rename) rename.onsubmit = (e) => { e.preventDefault(); post("/api/group/rename", { id, text: new FormData(e.target).get("name") }); closeOverlay(); };
    const invite = $("#invite", sc); if (invite) invite.onsubmit = (e) => { e.preventDefault(); post("/api/group/invite", { id, text: new FormData(e.target).get("who") }); closeOverlay(); };
    $$("[data-remove-member]", sc).forEach((b) => (b.onclick = () => { post("/api/group/remove", { id, userID: b.dataset.removeMember }); closeOverlay(); }));
  }
  async function forwardSheet(id, mid) {
    const render = async (q) => {
      const r = await get("/api/forwardTargets", { q: q || "" });
      $("#fw-res").innerHTML = r.targets.map((c) => `<div class="r" data-t="${esc(c.id)}">${renderAvatar(c)}<div class="t"><b>${esc(c.title)}</b><span>${esc(c.networkLabel)}</span></div></div>`).join("") || "<p class='meta' style='padding:10px'>Aucun fil ne correspond.</p>";
      $$("#fw-res .r").forEach((el) => (el.onclick = () => { post("/api/forward", { id, messageID: mid, target: el.dataset.t }); closeOverlay(); toast("Transféré"); }));
    };
    sheet("Transférer à…", `<label class="search" style="margin-bottom:8px">${I.search}<input id="fw-q" placeholder="Une personne, un groupe" autofocus></label><div id="fw-res" class="res" style="max-height:50vh;overflow-y:auto"></div>`);
    $("#fw-q").oninput = debounce((e) => render(e.target.value), 120); render("");
  }

  // ---------- Recherche rapide (Ctrl K) ----------
  function quickSearch() {
    overlay.innerHTML = `<div class="scrim"></div><div class="quick"><label class="search">${I.search}<input id="qs" placeholder="Une personne, un mot, un message…" autofocus></label><div class="res" id="qs-res"></div></div>`;
    $(".scrim", overlay).onclick = closeOverlay;
    const input = $("#qs"), res = $("#qs-res"); let cursor = 0, rows = [];
    const draw = () => { res.innerHTML = rows.map((r, i) => `<div class="r ${i === cursor ? "on" : ""}" data-i="${i}">${r.avatar}<div class="t"><b>${esc(r.title)}</b><span>${r.sub}</span></div></div>`).join("") || (input.value.trim() ? "<p class='meta' style='padding:12px'>Rien ne correspond.</p>" : ""); $$(".r", res).forEach((el) => (el.onclick = () => go(+el.dataset.i))); };
    const go = (i) => { const r = rows[i]; if (!r) return; closeOverlay(); if (r.messageID) S.pendingJump = r.messageID; post("/api/select", { id: r.id, focus: S.mode === "focus" }); };
    const run = debounce(async () => {
      const q = input.value.trim();
      if (!q) { rows = S.state.conversations.slice(0, 12).map((c) => ({ id: c.id, title: c.title, sub: esc(c.networkLabel), avatar: renderAvatar(c) })); cursor = 0; draw(); return; }
      const r = await get("/api/search", { q });
      rows = [...r.conversations.map((c) => ({ id: c.id, title: c.title, sub: rich(c.excerpt, [], q), avatar: renderAvatar(conv(c.id) || { id: c.id, title: c.title, network: c.network }) })),
        ...r.messages.map((m) => ({ id: m.conversationID, messageID: m.messageID, title: m.title, sub: rich(m.text, [], q) + ` <span class="muted">· ${fmtRowTime(m.sentAt)}</span>`, avatar: renderAvatar(conv(m.conversationID) || { id: m.conversationID, title: m.title }) }))];
      cursor = 0; draw();
    }, 120);
    input.oninput = run; run();
    input.onkeydown = (e) => { if (e.key === "ArrowDown") { cursor = Math.min(rows.length - 1, cursor + 1); draw(); e.preventDefault(); } else if (e.key === "ArrowUp") { cursor = Math.max(0, cursor - 1); draw(); e.preventDefault(); } else if (e.key === "Enter") go(cursor); else if (e.key === "Escape") closeOverlay(); };
  }

  // ---------- Clavier ----------
  document.addEventListener("keydown", (e) => {
    const inField = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || "");
    const mod = e.ctrlKey || e.metaKey;
    if (e.key === "Escape" && overlay.innerHTML) { closeOverlay(); return; }
    if (mod && e.key === "1") { e.preventDefault(); return setMode("focus"); }
    if (mod && e.key === "2") { e.preventDefault(); return setMode("inbox"); }
    if (mod && e.key.toLowerCase() === "k") { e.preventDefault(); return quickSearch(); }
    if (mod && e.key.toLowerCase() === "f") { e.preventDefault(); return action("threadSearch"); }
    if (mod && e.key.toLowerCase() === "r" && S.thread) { e.preventDefault(); const last = S.thread.groups.flatMap((g) => g.messages).filter((m) => !m.system).pop(); if (last) post("/api/reply", { id: S.thread.conversation.id, messageID: last.id }); return; }
    if (mod && (e.key === "+" || e.key === "=")) { e.preventDefault(); prefs.scale = prefs.scale + 0.1; return; }
    if (mod && e.key === "-") { e.preventDefault(); prefs.scale = prefs.scale - 0.1; return; }
    if (mod && e.key === "0") { e.preventDefault(); prefs.scale = 1; return; }
    if (mod && e.key === ",") { e.preventDefault(); return settingsSheet(); }
    if (mod && e.shiftKey && e.key.toLowerCase() === "e") { e.preventDefault(); return post("/api/scope", { scope: S.state.scope === "archive" ? "inbox" : "archive" }); }
    if (inField || mod || e.altKey) return;
    if (!S.state || S.state.session !== "connected") return;
    const id = S.thread?.conversation.id;
    if (e.key === "j" || e.key === "ArrowRight") { if (S.mode === "focus") post("/api/focus/next"); else moveSelection(1); }
    else if (e.key === "k" || e.key === "ArrowLeft") { if (S.mode === "focus") post("/api/focus/previous"); else moveSelection(-1); }
    else if (e.key === "ArrowDown" && S.mode === "inbox") moveSelection(1);
    else if (e.key === "ArrowUp" && S.mode === "inbox") moveSelection(-1);
    else if (e.key === "e" && id) action("archiveThread");
    else if (e.key === "p" && id) post("/api/pin", { id });
    else if (e.key === "m" && id) post("/api/mute", { id });
    else if (e.key === "/") { e.preventDefault(); $("#sidebar-search")?.focus() || quickSearch(); }
    else if (e.key === "Enter" && id) { $("#draft")?.focus(); }
  });
  function moveSelection(delta) {
    const list = S.state.conversations; if (!list.length) return;
    const i = list.findIndex((c) => c.id === S.state.selectedID);
    const next = list[Math.min(list.length - 1, Math.max(0, i + delta))];
    if (next) post("/api/select", { id: next.id, focus: false });
  }

  // ---------- Démarrage ----------
  if (!token) { show401(); return; }
  refresh(); connectEvents();
  setInterval(() => { if (S.state?.session === "connected") refreshSoon(); }, 15000);
})();
