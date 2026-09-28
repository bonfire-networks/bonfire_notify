// `beforeinstallprompt` fires once, often before any hook has mounted, so it's caught at bundle load and handed out via `PWAUtils`.
const INSTALLABLE_EVENT = 'bonfire:pwa-installable';
let deferredInstallPrompt = null;

window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredInstallPrompt = e;
  window.dispatchEvent(new Event(INSTALLABLE_EVENT));
});

window.addEventListener('appinstalled', () => {
  deferredInstallPrompt = null;
  window.dispatchEvent(new Event(INSTALLABLE_EVENT));
});

export const PWAUtils = {
  isStandalone() {
    return window.matchMedia('(display-mode: standalone)').matches;
  },

  isIOSStandalone() {
    return window.navigator.standalone === true;
  },

  isIOS() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
           (navigator.maxTouchPoints > 1 && /Macintosh/.test(navigator.userAgent)) ||
           (/Macintosh/.test(navigator.userAgent) && 'ontouchend' in document);
  },

  isMobile() {
    return this.isIOS() ||
           /Android|webOS|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent) ||
           (window.innerWidth <= 768 && navigator.maxTouchPoints > 0);
  },

  isPWAMode() {
    return this.isStandalone() ||
           this.isIOSStandalone() ||
           window.matchMedia('(display-mode: minimal-ui)').matches ||
           window.matchMedia('(display-mode: fullscreen)').matches;
  },

  // The prompt Chrome offered, if it has and it is still unused (see the listener at the top of this file).
  // Calls `callback` with the prompt (or null) now if installable, and on every change. Returns the unsubscribe.
  onInstallable(callback) {
    if (deferredInstallPrompt) callback(deferredInstallPrompt);
    const handler = () => callback(deferredInstallPrompt);
    window.addEventListener(INSTALLABLE_EVENT, handler);
    return () => window.removeEventListener(INSTALLABLE_EVENT, handler);
  },

  // a prompt can only be shown once
  promptInstall() {
    const prompt = deferredInstallPrompt;
    if (!prompt) return;
    deferredInstallPrompt = null;
    window.dispatchEvent(new Event(INSTALLABLE_EVENT));
    prompt.prompt();
  }
};