// Генерирует разметку свитка из эталонного текста tests/fixtures/scroll-text.txt
// и вставляет её в site/index.html между маркерами <!--SCROLL_BODY--> … <!--/SCROLL_BODY-->.
// Запуск: node tools/build-scroll.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = readFileSync(join(root, 'tests/fixtures/scroll-text.txt'), 'utf8').replace(/\r\n/g, '\n');
const paras = src.split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);

const CHAPTERS = new Set([
  'О Великом Замысле',
  'О Долгих Прогулках и Верных Друзьях',
  'О Священном Огне и Великом Дожде',
  'Последнее пророчество',
]);
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const ornament = '<svg class="ornament" viewBox="0 0 240 24" aria-hidden="true" focusable="false"><use href="#ornament"/></svg>';

const out = [];
let dropcapNext = false;
paras.forEach((p, i) => {
  const t = esc(p);
  if (i === 0) { out.push(`<h2 class="scroll-title" id="scroll-title">${t}</h2>`); return; }
  if (i === 1) { out.push(`<p class="scroll-subtitle" id="scroll-subtitle"><em>${t}</em></p>`, ornament); dropcapNext = true; return; }
  if (CHAPTERS.has(p)) {
    out.push(`<h3 class="scroll-chapter">${ornament}<span>${t}</span></h3>`);
    dropcapNext = true;
    return;
  }
  if (i === paras.length - 1) { out.push(`<p class="scroll-finale">${t}</p>`); return; }
  if (p.startsWith('«')) { out.push(`<blockquote class="scroll-saying"><p>${t}</p></blockquote>`); return; }
  const cls = [];
  if (dropcapNext) { cls.push('dropcap'); dropcapNext = false; }
  if (p.startsWith('— ')) cls.push('reply');
  out.push(cls.length ? `<p class="${cls.join(' ')}">${t}</p>` : `<p>${t}</p>`);
});

const block = `<!--SCROLL_BODY-->\n${out.map((l) => '      ' + l).join('\n')}\n      <!--/SCROLL_BODY-->`;
const idxPath = join(root, 'site/index.html');
let html = readFileSync(idxPath, 'utf8');
const re = /<!--SCROLL_BODY-->(?:[\s\S]*?<!--\/SCROLL_BODY-->)?/;
if (!re.test(html)) throw new Error('marker <!--SCROLL_BODY--> not found');
html = html.replace(re, block);
writeFileSync(idxPath, html);
console.log(`scroll: ${paras.length} paragraphs written`);
