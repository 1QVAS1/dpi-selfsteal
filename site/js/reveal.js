// Появление блоков при скролле и прорисовка таймлайна.

export function initReveal({ reducedMotion }) {
  const items = [...document.querySelectorAll('.reveal')];

  // Каскад: у элементов внутри .cascade небольшая задержка по порядку
  document.querySelectorAll('.cascade').forEach((group) => {
    [...group.querySelectorAll(':scope > .reveal')].forEach((el, i) => {
      el.style.setProperty('--delay', `${Math.min(i, 6) * 80}ms`);
    });
  });

  if (reducedMotion || !('IntersectionObserver' in window)) {
    items.forEach((el) => el.classList.add('is-visible'));
    return (els) => els.forEach((el) => el.classList.add('is-visible'));
  }

  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        io.unobserve(entry.target);
      }
    }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  items.forEach((el) => io.observe(el));
  // для элементов, добавленных позже (например, карточек новостей)
  return (els) => els.forEach((el) => io.observe(el));
}

/** Линия таймлайна «дорисовывается» по мере прокрутки. */
export function initTimeline({ reducedMotion }) {
  const list = document.getElementById('timeline-list');
  if (!list) return;
  if (reducedMotion) { list.style.setProperty('--progress', '1'); return; }

  let ticking = false;
  let active = false;
  const update = () => {
    ticking = false;
    const rect = list.getBoundingClientRect();
    const vh = window.innerHeight || document.documentElement.clientHeight;
    // линия доходит до точки на 70% высоты экрана
    const p = (vh * 0.7 - rect.top) / Math.max(rect.height, 1);
    list.style.setProperty('--progress', String(Math.min(1, Math.max(0, p))));
  };
  const onScroll = () => {
    if (!active || ticking) return;
    ticking = true;
    requestAnimationFrame(update);
  };
  // слушаем скролл только пока таймлайн рядом с экраном
  new IntersectionObserver(([entry]) => {
    active = entry.isIntersecting;
    if (active) update();
  }, { rootMargin: '200px 0px' }).observe(list);
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });
  update();
}
