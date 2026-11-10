// Модальное окно-свиток: открытие/закрытие, удержание фокуса, блокировка прокрутки.

// Защита от мисклика: пользователь только что быстро кликал по логотипу, и следующие клики
// попадут на подложку. Поэтому сразу после открытия закрытие временно игнорируется.
export const BACKDROP_GRACE_MS = 1500; // клик по подложке
export const CONTROL_GRACE_MS = 700;   // печать и Esc (пока свиток разворачивается)

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])';

export class ScrollModal {
  /**
   * @param {HTMLDialogElement} dialog
   * @param {{ reducedMotion: () => boolean, onOpen?: () => void, onClose?: () => void }} opts
   */
  constructor(dialog, { reducedMotion, onOpen, onClose }) {
    this.onOpen = onOpen;
    this.onClose = onClose;
    this.dialog = dialog;
    this.sheet = dialog.querySelector('.scroll-sheet');
    this.body = dialog.querySelector('.scroll-body');
    this.closeBtn = dialog.querySelector('.seal-btn');
    this.reducedMotion = reducedMotion;
    this.returnFocusTo = null;
    this.closing = false;
    this.openedAt = -Infinity;
    this.armTimer = 0;

    this.closeBtn.addEventListener('click', () => { if (this.sinceOpen() >= CONTROL_GRACE_MS) this.close(); });
    // Esc: перехватываем нативную отмену, чтобы проиграть анимацию и вернуть фокус
    dialog.addEventListener('cancel', (e) => { e.preventDefault(); if (this.sinceOpen() >= CONTROL_GRACE_MS) this.close(); });
    // Клик по подложке: цель — сам <dialog>, а не его содержимое
    dialog.addEventListener('pointerdown', (e) => {
      // нажатие должно начаться на подложке и уже после «окна защиты»
      this.downOnBackdrop = e.target === dialog && this.sinceOpen() >= BACKDROP_GRACE_MS;
    });
    dialog.addEventListener('click', (e) => {
      if (e.target === dialog && this.downOnBackdrop) this.close();
      this.downOnBackdrop = false;
    });
    dialog.addEventListener('keydown', (e) => this.onKeydown(e));
  }

  get isOpen() { return this.dialog.open; }

  sinceOpen() { return performance.now() - this.openedAt; }

  open(returnFocusTo) {
    if (this.isOpen) return;
    this.returnFocusTo = returnFocusTo || document.activeElement;
    document.body.classList.add('is-locked');
    document.documentElement.style.setProperty('overflow', 'hidden');
    this.openedAt = performance.now();
    this.dialog.classList.remove('is-closing', 'is-armed');
    clearTimeout(this.armTimer);
    // печать становится активной, когда истекает защита от случайного закрытия
    this.armTimer = setTimeout(() => this.dialog.classList.add('is-armed'), CONTROL_GRACE_MS);
    if (!this.reducedMotion()) this.dialog.classList.add('is-opening');
    if (typeof this.dialog.showModal === 'function') this.dialog.showModal();
    else this.dialog.setAttribute('open', '');
    this.body.scrollTop = 0;
    // фокус — на текст свитка, а не на печать: повторное Enter/Space не закроет окно
    this.body.focus({ preventScroll: true });
    this.sheet.addEventListener('animationend', () => this.dialog.classList.remove('is-opening'), { once: true });
    this.onOpen?.();
  }

  close() {
    if (!this.isOpen || this.closing) return;
    const finish = () => {
      this.closing = false;
      clearTimeout(this.armTimer);
      this.dialog.classList.remove('is-closing', 'is-opening', 'is-armed');
      this.onClose?.();
      if (typeof this.dialog.close === 'function') this.dialog.close();
      else this.dialog.removeAttribute('open');
      document.body.classList.remove('is-locked');
      document.documentElement.style.removeProperty('overflow');
      const target = this.returnFocusTo;
      this.returnFocusTo = null;
      if (target && typeof target.focus === 'function') target.focus({ preventScroll: true });
    };
    if (this.reducedMotion()) { finish(); return; }
    this.closing = true;
    this.dialog.classList.remove('is-opening');
    this.dialog.classList.add('is-closing');
    let done = false;
    const once = () => { if (!done) { done = true; finish(); } };
    this.sheet.addEventListener('animationend', once, { once: true });
    setTimeout(once, 500); // страховка, если animationend не придёт
  }

  onKeydown(e) {
    if (e.key === 'Escape') { e.preventDefault(); if (this.sinceOpen() >= CONTROL_GRACE_MS) this.close(); return; }
    if (e.key !== 'Tab') return;
    const items = [...this.dialog.querySelectorAll(FOCUSABLE)].filter((el) => el.offsetParent !== null || el === document.activeElement);
    if (!items.length) { e.preventDefault(); return; }
    const first = items[0];
    const last = items[items.length - 1];
    if (e.shiftKey && (document.activeElement === first || !this.dialog.contains(document.activeElement))) {
      e.preventDefault(); last.focus();
    } else if (!e.shiftKey && (document.activeElement === last || !this.dialog.contains(document.activeElement))) {
      e.preventDefault(); first.focus();
    }
  }
}
