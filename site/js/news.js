// Рендер новостей из data/news.json. Вёрстку трогать не нужно — достаточно обновить JSON.

const MONTHS = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

function formatDate(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return iso;
  return `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}`;
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null) continue;
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else node.setAttribute(k, v);
  }
  for (const c of children) if (c != null) node.append(c);
  return node;
}

function safeUrl(url) {
  try {
    const u = new URL(url, location.href);
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.href : null;
  } catch { return null; }
}

function hostOf(url) {
  try { return new URL(url).hostname.replace(/^www\./, ''); } catch { return ''; }
}

export async function initNews({ onRendered } = {}) {
  const grid = document.getElementById('news-grid');
  const filters = document.getElementById('news-filters');
  const srcList = document.getElementById('news-sources');
  if (!grid) return;

  let data;
  try {
    const res = await fetch('data/news.json', { cache: 'no-cache' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    data = await res.json();
  } catch (err) {
    grid.replaceChildren(el('p', { class: 'news-empty', text: 'Не удалось загрузить новости. Попробуйте обновить страницу.' }));
    return;
  }

  const tagNames = data.tags || {};
  const items = (data.items || [])
    .filter((it) => it && it.date && it.title && safeUrl(it.url))
    .slice();

  // Список источников (по хронологии — так стабильны номера н1…нN)
  if (srcList) {
    const chrono = items.slice().sort((a, b) => a.date.localeCompare(b.date));
    srcList.replaceChildren(...chrono.map((it) => {
      const li = el('li', { id: it.id || null });
      li.append(`${it.title}. ${it.source}, ${formatDate(it.date)}. `,
        el('a', { href: safeUrl(it.url), rel: 'noopener noreferrer', target: '_blank', text: hostOf(it.url) }));
      return li;
    }));
  }

  // Карточки — от новых к старым
  const sorted = items.slice().sort((a, b) => b.date.localeCompare(a.date));
  const cards = sorted.map((it) => {
    const tags = (it.tags || []).filter((t) => tagNames[t]);
    const card = el('article', { class: 'news-card reveal', 'data-tags': tags.join(' ') },
      el('div', { class: 'news-meta' },
        el('time', { datetime: it.date, text: formatDate(it.date) }),
        el('span', { text: it.source || '' })),
      el('h3', { text: it.title }),
      el('p', { text: it.summary || '' }),
      tags.length ? el('ul', { class: 'news-tags', 'aria-label': 'Метки' }, ...tags.map((t) => el('li', { text: tagNames[t] }))) : null,
      el('p', { class: 'news-src' },
        el('a', { href: safeUrl(it.url), rel: 'noopener noreferrer', target: '_blank' },
          `Источник: ${hostOf(it.url)} `, el('span', { 'aria-hidden': 'true', text: '↗' }))),
    );
    return card;
  });
  grid.replaceChildren(...cards);
  cards.forEach((c, i) => c.style.setProperty('--delay', `${Math.min(i % 3, 2) * 80}ms`));

  // Фильтры по меткам, которые реально встречаются
  const used = Object.keys(tagNames).filter((t) => sorted.some((it) => (it.tags || []).includes(t)));
  if (filters && used.length) {
    const buttons = [['all', 'Все'], ...used.map((t) => [t, tagNames[t]])].map(([key, label]) =>
      el('button', { type: 'button', class: 'chip', 'data-filter': key, 'aria-pressed': key === 'all' ? 'true' : 'false', text: label }));
    filters.replaceChildren(...buttons);
    filters.hidden = false;
    filters.addEventListener('click', (e) => {
      const btn = e.target.closest('button[data-filter]');
      if (!btn) return;
      const key = btn.dataset.filter;
      buttons.forEach((b) => b.setAttribute('aria-pressed', String(b === btn)));
      cards.forEach((c) => {
        c.hidden = key !== 'all' && !c.dataset.tags.split(' ').includes(key);
        c.classList.add('is-visible');
      });
    });
  }

  if (onRendered) onRendered({ cards, count: items.length });
}
