// Всплывающий смайлик, который «вылетает» из кнопки-логотипа и быстро гаснет.

export function popHint(anchor, emoji) {
  if (!anchor || !emoji) return;
  const r = anchor.getBoundingClientRect();
  const el = document.createElement('span');
  el.className = 'egg-hint';
  el.setAttribute('aria-hidden', 'true');
  el.textContent = emoji;
  // стартовая точка — центр значка; разброс по горизонтали, чтобы подряд идущие не накладывались
  el.style.left = `${r.left + Math.min(r.width, 48) / 2}px`;
  el.style.top = `${r.top + r.height / 2}px`;
  el.style.setProperty('--dx', `${20 + Math.round(Math.random() * 30)}px`);
  document.body.append(el);
  const done = () => el.remove();
  // удаляем по окончании самой длинной анимации — прозрачности
  el.addEventListener('animationend', (e) => { if (e.animationName === 'egg-fade') done(); });
  setTimeout(done, 2000); // страховка
}
