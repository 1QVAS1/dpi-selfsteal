// Сверяет текст свитка в site/index.html с эталоном tests/fixtures/scroll-text.txt (дословно, по абзацам).
// Запуск: node tests/scroll-text.test.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const html = readFileSync(new URL('../site/index.html', import.meta.url), 'utf8');
const m = /<!--SCROLL_BODY-->([\s\S]*?)<!--\/SCROLL_BODY-->/.exec(html);
assert.ok(m, 'маркеры SCROLL_BODY не найдены');
const decode = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
const blocks = [...m[1].matchAll(/<(h2|h3|p)\b[^>]*>([\s\S]*?)<\/\1>/g)]
  .map((x) => decode(x[2].replace(/<svg[\s\S]*?<\/svg>/g, '').replace(/<[^>]+>/g, '')).trim());
const expected = readFileSync(new URL('./fixtures/scroll-text.txt', import.meta.url), 'utf8')
  .replace(/\r\n/g, '\n').split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
assert.equal(blocks.length, expected.length, `число абзацев: ${blocks.length} ≠ ${expected.length}`);
expected.forEach((p, i) => assert.equal(blocks[i], p, `абзац ${i + 1} отличается`));
console.log(`ok: ${expected.length} абзацев совпадают дословно`);
