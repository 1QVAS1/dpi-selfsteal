import { EasterEggCounter, hintFor } from './easter-egg-counter.js';
import { popHint } from './click-hint.js';
import { ScrollModal } from './scroll-modal.js';
import { createConfetti } from './confetti.js';
import { initReveal, initTimeline } from './reveal.js';
import { initHeroCanvas } from './hero-canvas.js';
import { initNews } from './news.js';

const motionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
const reducedMotion = () => motionQuery.matches;

// Анимации появления включаются только если JS работает и движение разрешено
if (!reducedMotion()) document.documentElement.classList.add('motion-ok');

// ---------- Кнопка-логотип и пасхалка ----------
const logoBtn = document.getElementById('logo-btn');
const dialog = document.getElementById('scroll-dialog');
const confetti = dialog ? createConfetti(dialog) : null;
const modal = dialog ? new ScrollModal(dialog, {
  reducedMotion,
  onOpen: () => { if (!reducedMotion()) confetti?.burst(); },
  onClose: () => confetti?.clear(),
}) : null;
const counter = new EasterEggCounter({ target: 42, windowMs: 3000 });

logoBtn?.addEventListener('click', () => {
  // Плавная прокрутка в начало страницы (при reduced-motion — мгновенно)
  window.scrollTo({ top: 0, left: 0, behavior: reducedMotion() ? 'instant' : 'smooth' });
  if (counter.click(performance.now())) {
    modal?.open(logoBtn);
    return;
  }
  // намёки по ходу серии: 4-й, 15-й и 35-й клик
  popHint(logoBtn, hintFor(counter.count));
});

// ---------- Верхняя панель: рамка при прокрутке и активный раздел ----------
const topbar = document.querySelector('.topbar');
const onScroll = () => topbar?.classList.toggle('is-scrolled', window.scrollY > 8);
window.addEventListener('scroll', onScroll, { passive: true });
onScroll();

const navLinks = [...document.querySelectorAll('.topnav a[href^="#"]')];
if ('IntersectionObserver' in window && navLinks.length) {
  const byId = new Map(navLinks.map((a) => [a.getAttribute('href').slice(1), a]));
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      navLinks.forEach((a) => a.removeAttribute('aria-current'));
      byId.get(e.target.id)?.setAttribute('aria-current', 'true');
    }
  }, { rootMargin: '-45% 0px -50% 0px' });
  byId.forEach((_, id) => { const s = document.getElementById(id); if (s) io.observe(s); });
}

// ---------- Анимации ----------
const observe = initReveal({ reducedMotion: reducedMotion() });
initTimeline({ reducedMotion: reducedMotion() });
initHeroCanvas(document.getElementById('hero-canvas'), { reducedMotion: reducedMotion() });

// ---------- Новости и счётчик источников ----------
initNews({
  onRendered: ({ cards }) => {
    observe(cards);
    const count = document.querySelectorAll('#sources-list li[id]').length;
    const out = document.getElementById('src-count');
    if (out && count) out.textContent = String(count);
  },
});
