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

  promptToInstallPWA() {
    let deferredPrompt = null;
    window.addEventListener('beforeinstallprompt', (e) => {
      e.preventDefault();
      deferredPrompt = e;
      const installBtn = document.getElementById('install-button');

      if (installBtn) {
        installBtn.addEventListener('click', async () => {
          installBtn.disabled = true;
          deferredPrompt.prompt();
          installBtn.disabled = false;
          installBtn.style.display = 'none';
          deferredPrompt = null;
        }, { once: true });
      }
    });
  }
};