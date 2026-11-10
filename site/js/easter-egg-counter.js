/**
 * Чистая логика счётчика кликов, без DOM и без чтения часов:
 * метку времени передаёт вызывающий код, поэтому её легко тестировать.
 *
 * Правила:
 *  - если с предыдущего клика прошло ≤ windowMs, счётчик увеличивается на 1;
 *  - если больше (или это первый клик), счётчик сбрасывается и текущий клик считается первым (= 1);
 *  - когда счётчик достигает target, click() возвращает true, а счётчик обнуляется.
 */
export class EasterEggCounter {
  /**
   * @param {{ target?: number, windowMs?: number }} [options]
   */
  constructor({ target = 42, windowMs = 3000 } = {}) {
    if (!Number.isInteger(target) || target < 1) throw new RangeError('target must be a positive integer');
    if (!(windowMs >= 0)) throw new RangeError('windowMs must be >= 0');
    this.target = target;
    this.windowMs = windowMs;
    this.reset();
  }

  /** Обнулить счётчик и забыть время последнего клика. */
  reset() {
    this.count = 0;
    this.lastTs = null;
  }

  /**
   * Зарегистрировать клик.
   * @param {number} ts метка времени в миллисекундах (например, performance.now() или event.timeStamp)
   * @returns {boolean} true, если этим кликом достигнута цель
   */
  click(ts) {
    if (typeof ts !== 'number' || Number.isNaN(ts)) throw new TypeError('timestamp must be a number');
    const withinWindow = this.lastTs !== null && ts - this.lastTs >= 0 && ts - this.lastTs <= this.windowMs;
    this.count = withinWindow ? this.count + 1 : 1;
    this.lastTs = ts;
    if (this.count >= this.target) {
      this.reset();
      return true;
    }
    return false;
  }
}

/**
 * Подсказки по ходу серии кликов: какой смайлик показать при данном значении счётчика.
 * Возвращает строку-эмодзи или null.
 */
export const EGG_HINTS = Object.freeze({ 4: '😮', 15: '🤔', 35: '😤' });

export function hintFor(count) {
  return Object.prototype.hasOwnProperty.call(EGG_HINTS, count) ? EGG_HINTS[count] : null;
}
