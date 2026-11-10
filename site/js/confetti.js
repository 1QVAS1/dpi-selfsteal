// Конфетти при открытии свитка: две «хлопушки» из нижних углов экрана.
// Только CSS-анимации, без canvas; куски удаляются после завершения.

const COLORS = ['#3DDCFF', '#FF4D2E', '#F2C94C', '#F1E4C6', '#B5281B', '#7FD88F', '#FFFFFF', '#C9A867'];
const rand = (a, b) => a + Math.random() * (b - a);

export function createConfetti(host) {
  const layer = document.createElement('div');
  layer.className = 'confetti';
  layer.setAttribute('aria-hidden', 'true');
  host.append(layer);
  let cleanupTimer = 0;

  function burst() {
    clear();
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const count = vw < 600 ? 70 : 130;
    const frag = document.createDocumentFragment();
    let maxEnd = 0;
    for (let i = 0; i < count; i++) {
      const fromLeft = i % 2 === 0;
      const piece = document.createElement('i');
      const w = rand(6, 11);
      const isStrip = Math.random() < 0.35;
      const bx = rand(0.12, 0.55) * vw;           // насколько далеко вылетает по горизонтали
      const by = -rand(0.45, 0.92) * vh;          // высота взлёта
      const ex = bx + rand(-0.08, 0.12) * vw;     // снос при падении
      const ey = by + rand(0.75, 1.15) * vh;      // падение
      const dur = rand(2.2, 3.4);
      const delay = rand(0, 0.25);
      maxEnd = Math.max(maxEnd, dur + delay);
      const sign = fromLeft ? 1 : -1;
      const set = (k, v) => piece.style.setProperty(k, v);
      set('--x0', fromLeft ? `${rand(-10, 30)}px` : `${vw - rand(-10, 30)}px`);
      set('--bx', `${sign * bx}px`);
      set('--by', `${by}px`);
      set('--ex', `${sign * ex}px`);
      set('--ey', `${ey}px`);
      set('--r1', `${rand(-360, 360)}deg`);
      set('--r2', `${rand(-900, 900)}deg`);
      set('--w', `${isStrip ? w * 0.45 : w}px`);
      set('--h', `${isStrip ? w * 2.2 : w * rand(0.5, 1)}px`);
      set('--c', COLORS[(Math.random() * COLORS.length) | 0]);
      set('--br', Math.random() < 0.25 ? '50%' : '2px');
      set('--t', `${dur}s`);
      set('--d', `${delay}s`);
      frag.append(piece);
    }
    layer.append(frag);
    cleanupTimer = setTimeout(clear, (maxEnd + 0.3) * 1000);
  }

  function clear() {
    clearTimeout(cleanupTimer);
    layer.replaceChildren();
  }

  return { burst, clear };
}
