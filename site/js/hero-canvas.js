// Фон hero: сеть узлов, по которой бегут «пакеты». Часть пакетов упирается в фильтр и гаснет красным.
// Лёгкий режим: ~30 кадров/с, пауза при скрытой вкладке и когда hero вне экрана,
// при prefers-reduced-motion рисуется один статичный кадр.

const FPS = 30;
const BLOCK_RATE = 0.32;

function css(name, fallback) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}
function hexToRgb(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex);
  if (!m) return [61, 220, 255];
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
const rand = (a, b) => a + Math.random() * (b - a);
const pick = (arr) => arr[(Math.random() * arr.length) | 0];

export function initHeroCanvas(canvas, { reducedMotion }) {
  if (!canvas || !canvas.getContext) return () => {};
  const ctx = canvas.getContext('2d', { alpha: true });
  const cyan = hexToRgb(css('--cyan', '#3DDCFF'));
  const red = hexToRgb(css('--red', '#FF4D2E'));
  const grey = hexToRgb(css('--border', '#1F2A36'));
  const rgba = (c, a) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;

  let W = 0, H = 0, dpr = 1;
  let nodes = [], edges = [], packets = [], bursts = [];
  let filter = null;
  let running = false, visible = true, inView = true, rafId = 0, last = 0, acc = 0, spawnAcc = 0;

  function build() {
    const rect = canvas.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = Math.max(1, rect.width); H = Math.max(1, rect.height);
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    const narrow = W < 700;
    // фильтр: на широком экране справа от текста, на узком — ниже по центру
    filter = { x: W * (narrow ? 0.8 : 0.66), y: H * (narrow ? 0.95 : 0.5), r: 9, pulse: 0, kind: 'filter' };
    const nLeft = narrow ? 9 : 16;
    const nRight = narrow ? 6 : 12;
    nodes = [];
    const left = [], right = [];
    for (let i = 0; i < nLeft; i++) {
      left.push({ x: rand(W * 0.04, filter.x - W * 0.12), y: rand(H * 0.12, H * 0.94), r: rand(1.6, 2.6), kind: 'src' });
    }
    for (let i = 0; i < nRight; i++) {
      right.push({ x: rand(filter.x + W * 0.08, W * 0.97), y: rand(H * 0.1, H * 0.92), r: rand(1.6, 2.6), kind: 'dst' });
    }
    nodes = [...left, filter, ...right];

    // рёбра: каждый источник → фильтр; фильтр → каждый адресат; плюс тонкая сетка между соседями
    edges = [];
    left.forEach((n) => edges.push({ a: n, b: filter, main: true }));
    right.forEach((n) => edges.push({ a: filter, b: n, main: true }));
    const mesh = (group) => group.forEach((n) => {
      const near = group.filter((m) => m !== n)
        .sort((p, q) => Math.hypot(p.x - n.x, p.y - n.y) - Math.hypot(q.x - n.x, q.y - n.y))
        .slice(0, 2);
      near.forEach((m) => { if (!edges.some((e) => (e.a === m && e.b === n))) edges.push({ a: n, b: m, main: false }); });
    });
    mesh(left); mesh(right);
    packets = []; bursts = [];
    left.forEach((n) => { n.out = right; });
  }

  function spawn() {
    const srcs = nodes.filter((n) => n.kind === 'src');
    const s = pick(srcs);
    packets.push({
      from: s, to: filter, t: 0,
      speed: rand(0.18, 0.32), // доля ребра в секунду
      stage: 0,
      blocked: Math.random() < BLOCK_RATE,
      trail: [],
    });
  }

  function step(dt) {
    spawnAcc += dt;
    const interval = W < 700 ? 0.5 : 0.28;
    while (spawnAcc > interval) { spawnAcc -= interval; if (packets.length < 40) spawn(); }

    for (const p of packets) {
      p.t += p.speed * dt * (p.stage === 1 ? 1.3 : 1);
      if (p.t >= 1) {
        if (p.stage === 0) {
          if (p.blocked) {
            bursts.push({ x: filter.x, y: filter.y, life: 1 });
            filter.pulse = 1;
            p.dead = true;
          } else {
            p.stage = 1; p.from = filter; p.to = pick(nodes.filter((n) => n.kind === 'dst')); p.t = 0;
          }
        } else {
          p.dead = true;
        }
      }
    }
    packets = packets.filter((p) => !p.dead);
    for (const b of bursts) b.life -= dt * 1.4;
    bursts = bursts.filter((b) => b.life > 0);
    filter.pulse = Math.max(0, filter.pulse - dt * 1.6);
  }

  function pos(p) {
    // перед фильтром заблокированные пакеты слегка «краснеют»
    return { x: p.from.x + (p.to.x - p.from.x) * p.t, y: p.from.y + (p.to.y - p.from.y) * p.t };
  }

  function draw() {
    ctx.clearRect(0, 0, W, H);
    // рёбра
    ctx.lineWidth = 1;
    for (const e of edges) {
      ctx.strokeStyle = e.main ? rgba(cyan, 0.07) : rgba(grey, 0.9);
      ctx.beginPath(); ctx.moveTo(e.a.x, e.a.y); ctx.lineTo(e.b.x, e.b.y); ctx.stroke();
    }
    // узлы
    for (const n of nodes) {
      if (n === filter) continue;
      ctx.fillStyle = n.kind === 'dst' ? rgba(cyan, 0.45) : rgba(cyan, 0.3);
      ctx.beginPath(); ctx.arc(n.x, n.y, n.r, 0, Math.PI * 2); ctx.fill();
    }
    // фильтр — «горлышко»
    const f = filter;
    const s = 16;
    ctx.save();
    ctx.translate(f.x, f.y);
    ctx.strokeStyle = rgba(red, 0.55 + f.pulse * 0.45);
    ctx.lineWidth = 1.5;
    ctx.strokeRect(-s, -s, s * 2, s * 2);
    ctx.fillStyle = rgba(red, 0.06 + f.pulse * 0.18);
    ctx.fillRect(-s, -s, s * 2, s * 2);
    ctx.beginPath();
    ctx.moveTo(-s, -s); ctx.lineTo(-4, -3); ctx.lineTo(s, -3);
    ctx.moveTo(-s, s); ctx.lineTo(-4, 3); ctx.lineTo(s, 3);
    ctx.stroke();
    ctx.restore();
    ctx.font = '11px "JetBrains Mono", monospace';
    ctx.fillStyle = rgba(red, 0.75);
    ctx.fillText('DPI', f.x - 11, f.y + s + 16);

    // пакеты
    for (const p of packets) {
      const { x, y } = pos(p);
      const nearFilter = p.stage === 0 && p.blocked && p.t > 0.8;
      const c = nearFilter ? red : cyan;
      ctx.fillStyle = rgba(c, 0.18);
      ctx.beginPath(); ctx.arc(x, y, 5, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = rgba(c, 0.95);
      ctx.beginPath(); ctx.arc(x, y, 1.9, 0, Math.PI * 2); ctx.fill();
    }
    // вспышки блокировки
    for (const b of bursts) {
      const r = 6 + (1 - b.life) * 26;
      ctx.strokeStyle = rgba(red, b.life * 0.8);
      ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.arc(b.x, b.y, r, 0, Math.PI * 2); ctx.stroke();
    }
  }

  function frame(now) {
    if (!running) return;
    rafId = requestAnimationFrame(frame);
    const dt = Math.min(0.1, (now - (last || now)) / 1000);
    last = now;
    acc += dt;
    if (acc < 1 / FPS) return;
    step(acc);
    acc = 0;
    draw();
  }

  function start() {
    if (running || reducedMotion || !visible || !inView) return;
    running = true; last = 0; acc = 0;
    rafId = requestAnimationFrame(frame);
  }
  function stop() {
    running = false;
    cancelAnimationFrame(rafId);
  }

  function staticFrame() {
    // несколько пакетов в разных фазах и одна вспышка — для статичного режима
    for (let i = 0; i < 14; i++) { spawn(); packets[packets.length - 1].t = Math.random(); }
    bursts.push({ x: filter.x, y: filter.y, life: 0.6 });
    filter.pulse = 0.6;
    draw();
  }

  build();
  if (reducedMotion) staticFrame();
  else { for (let i = 0; i < 90; i++) step(1 / FPS); draw(); }

  let resizeTimer = 0;
  const ro = new ResizeObserver(() => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { build(); if (reducedMotion || !running) staticFrame(); }, 120);
  });
  ro.observe(canvas);

  document.addEventListener('visibilitychange', () => {
    visible = document.visibilityState === 'visible';
    if (visible) start(); else stop();
  });
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(([entry]) => {
      inView = entry.isIntersecting;
      if (inView) start(); else stop();
    }).observe(canvas);
  }
  start();
  return stop;
}
