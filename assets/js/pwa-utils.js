export const PWAUtils = {
  isStandalone() {
    return window.matchMedia('(display-mode: standalone)').matches;
  },

  isIOSStandalone() {
    return window.navigator.standalone === true;
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
          console.log('PWA button clicked');
          installBtn.disabled = true;
          deferredPrompt.prompt();

          installBtn.disabled = false;
          installBtn.style.display = 'none';
          deferredPrompt = null;
        }, { once: true });
      }

      console.log('✅ PWA install prompt initialized');
    });


  }
};