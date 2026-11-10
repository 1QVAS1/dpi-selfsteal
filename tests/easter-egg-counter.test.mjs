// Тесты логики счётчика пасхалки. Запуск: node tests/easter-egg-counter.test.mjs
// Без зависимостей: только node:assert.
import assert from 'node:assert/strict';
import { EasterEggCounter, hintFor } from '../site/js/easter-egg-counter.js';

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { console.error(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
}

/** Прогоняет клики с заданными интервалами, возвращает номера кликов (1-based), на которых открылось окно. */
function run(counter, intervals, start = 10_000) {
  const opened = [];
  let t = start;
  intervals.forEach((dt, i) => {
    t += dt;
    if (counter.click(t)) opened.push(i + 1);
  });
  return opened;
}
const repeat = (n, v) => Array.from({ length: n }, () => v);

console.log('EasterEggCounter');

test('42 клика с интервалом 1 с открывают окно ровно на 42-м', () => {
  const c = new EasterEggCounter();
  assert.deepEqual(run(c, repeat(42, 1000)), [42]);
  assert.equal(c.count, 0, 'после срабатывания счётчик обнулён');
});

test('41 клик не открывает окно', () => {
  const c = new EasterEggCounter();
  assert.deepEqual(run(c, repeat(41, 1000)), []);
  assert.equal(c.count, 41);
});

test('пауза 3,5 с на 30-м клике сбрасывает счётчик; окно — только после 42 кликов подряд от сброса', () => {
  const c = new EasterEggCounter();
  const intervals = [...repeat(29, 1000), 3500, ...repeat(60, 1000)];
  const opened = run(c, intervals);
  // 30-й клик стал первым в новой серии → 42-й в серии = 30 + 41 = 71-й клик всего
  assert.deepEqual(opened, [71]);
});

test('после паузы на 30-м клике счётчик равен 1', () => {
  const c = new EasterEggCounter();
  run(c, [...repeat(29, 1000), 3500]);
  assert.equal(c.count, 1);
});

test('интервал ровно 3000 мс ещё засчитывается', () => {
  const c = new EasterEggCounter();
  assert.deepEqual(run(c, repeat(42, 3000)), [42]);
});

test('интервал 3001 мс уже сбрасывает', () => {
  const c = new EasterEggCounter();
  assert.deepEqual(run(c, repeat(100, 3001)), []);
  assert.equal(c.count, 1);
});

test('после срабатывания следующий клик начинает новую серию с 1', () => {
  const c = new EasterEggCounter();
  run(c, repeat(42, 500));
  assert.equal(c.click(1e9), false);
  assert.equal(c.count, 1);
  // и вторая полная серия снова срабатывает
  const c2 = new EasterEggCounter();
  assert.deepEqual(run(c2, repeat(84, 200)), [42, 84]);
});

test('первый клик всегда = 1', () => {
  const c = new EasterEggCounter();
  c.click(0);
  assert.equal(c.count, 1);
});

test('время, идущее назад, не засчитывается как быстрый клик', () => {
  const c = new EasterEggCounter();
  c.click(5000); c.click(4000);
  assert.equal(c.count, 1);
});

test('параметры target/windowMs настраиваются', () => {
  const c = new EasterEggCounter({ target: 3, windowMs: 100 });
  assert.deepEqual(run(c, [0, 100, 100]), [3]);
  assert.deepEqual(run(new EasterEggCounter({ target: 3, windowMs: 100 }), [0, 100, 101, 50, 50]), [5]);
});

test('некорректная метка времени — ошибка', () => {
  assert.throws(() => new EasterEggCounter().click('1'), TypeError);
  assert.throws(() => new EasterEggCounter().click(NaN), TypeError);
});

test('подсказки: смайлики только на 4, 15 и 35 кликах серии', () => {
  const c = new EasterEggCounter();
  const hints = [];
  let t = 0;
  for (let i = 1; i <= 42; i++) {
    t += 500;
    c.click(t);
    const h = hintFor(c.count);
    if (h) hints.push([i, h]);
  }
  assert.deepEqual(hints, [[4, '😮'], [15, '🤔'], [35, '😤']]);
});

test('подсказки: после сброса серии отсчёт начинается заново', () => {
  const c = new EasterEggCounter();
  run(c, repeat(3, 500));
  c.click(1e7); // пауза → счётчик = 1
  assert.equal(hintFor(c.count), null);
  run(c, repeat(3, 500), 1e7); // 2, 3, 4
  assert.equal(hintFor(c.count), '😮');
});

console.log(`\n${passed} passed${process.exitCode ? ', есть падения' : ''}`);
