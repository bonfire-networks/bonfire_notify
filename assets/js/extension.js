import { PWAUtils } from "./pwa-utils";

let NotifyHooks = {};

// A second, older hook (PushNotificationHook) lived here: ~315 lines whose only host was a component that was never mounted, so none of it ran. What it did that is worth having was carried into the hook below rather than deleted with it: checking that a removed endpoint is *this* browser's before unsubscribing, and the subscribe-failure diagnostics (browser info, plus the Firefox AbortError guidance, which is the one thing that makes a remote report actionable). Its browser-vs-server status comparison is now `checkCurrentSubscription`, which reports and lets the server decide, while the half that poked at button text and a status dot is superseded by state the server renders.
// Its 72 `console.log` calls were the debug capability, so they sit behind this one switch rather than being lost: noisy for whoever is diagnosing a device, silent for everyone else. Genuine failures still use console.error unconditionally.
const pushDebug = (...args) => {
  if (window.localStorage?.getItem('bonfire:debug:push')) console.log('push:', ...args);
};

// Hook for push settings in user preferences
// Works with PushNotificationsLive component using pushEventTo for component communication
NotifyHooks.PushSettingsHook = {
  async mounted() {
    this.vapidKey = this.el.dataset.vapidKey;
    this.swRegistration = null;

    // Store bound handlers for cleanup
    this._boundHandlers = {};

    // Setup PWA install handling
    this.setupPwaInstall();

    if (!('serviceWorker' in navigator)) {
      this.reportNotSupported();
      return;
    }

    await this.initServiceWorker();

    // report it, or the page waits for a report that never comes
    if (!this.swRegistration) {
      this.reportNotSupported();
      return;
    }

    // Check PushManager after SW registration — in PWAs it may only be
    // available on the registration object, not on window
    if (!this.swRegistration.pushManager && !('PushManager' in window)) {
      this.reportNotSupported();
      return;
    }

    await this.checkCurrentSubscription();

    // these reach every hook on the page, so each answers only the events its own component sent (see `push_to_own_hook`)
    const own = (payload) => !payload?.target || payload.target === this.el.id;

    this.handleEvent('request_push_permission', async (payload) => {
      if (own(payload)) await this.requestPushPermission(payload.vapid_key);
    });

    this.handleEvent('request_push_disable', async (payload) => {
      if (own(payload)) await this.disablePush();
    });

    this.handleEvent('push_unsubscribe', async (payload) => {
      if (own(payload)) await this.unsubscribeBrowser();
    });
  },

  destroyed() {
    // Clean up event listeners
    this._boundHandlers.unsubscribeInstallable?.();
    if (this._boundHandlers.installClick) {
      const installBtn = document.getElementById('pwa-install-btn');
      if (installBtn) {
        installBtn.removeEventListener('click', this._boundHandlers.installClick);
      }
    }
    this.swRegistration = null;
  },

  setupPwaInstall() {
    const installSection = document.getElementById('pwa-install-section');
    const installBtn = document.getElementById('pwa-install-btn');
    if (!installSection) return;

    // the browser only offers a prompt while not installed
    this._boundHandlers.unsubscribeInstallable = PWAUtils.onInstallable((prompt) => {
      installSection.classList.toggle('hidden', !prompt || PWAUtils.isPWAMode());
    });

    if (installBtn) {
      this._boundHandlers.installClick = () => PWAUtils.promptInstall();
      installBtn.addEventListener('click', this._boundHandlers.installClick);
    }
  },

  async initServiceWorker() {
    try {
      this.swRegistration = await navigator.serviceWorker.register('/pwabuilder-sw.js', { scope: '/' });
      await navigator.serviceWorker.ready;
      pushDebug('service worker ready, state', this.swRegistration?.active?.state);
    } catch (error) {
      console.error('PushSettings: Service worker init failed:', error);
    }
  },

  // What the browser holds and what we have stored are the same fact in two places, and they drift:
  // an earlier registration may never have reached the server, a 410 may have pruned our row while the browser kept its subscription, or the user may have cleared site data. 
  // The browser knows whether this device can receive anything, so report it and let the server decide.
  //
  // Reporting only, never asking: `Notification.requestPermission()` is not called here, since a browser resolves it to `denied` without a prompt once blocked, and permission is the user's to give from the toggle.
  async checkCurrentSubscription() {
    if (!this.swRegistration) return;

    try {
      const subscription = await this.swRegistration.pushManager.getSubscription();

      // the worker needs this to re-register a rotated endpoint, and cannot read the DOM
      if (this.vapidKey) {
        (this.swRegistration.active || navigator.serviceWorker.controller)?.postMessage({
          type: 'VAPID_KEY',
          key: this.vapidKey
        });
      }

      pushDebug(
        'reporting to the server:',
        subscription ? subscription.endpoint : 'no subscription',
        'permission',
        typeof Notification === 'undefined' ? 'unavailable' : Notification.permission
      );

      this.pushEventTo(this.el, 'check_subscription', {
        // the whole subscription, not just its endpoint: a subscription we have no row for is one the server can store as it stands, which is what makes the two agree again
        subscription: subscription ? subscription.toJSON() : null,
        permission: (typeof Notification === 'undefined') ? null : Notification.permission
      });
    } catch (error) {
      console.error('PushSettings: Error checking subscription:', error);
      this.reportNotSupported();
    }
  },

  async requestPushPermission(vapidKey) {
    try {
      if (!this.swRegistration) {
        await this.initServiceWorker();
      }

      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        this.pushEventTo(this.el, 'push_subscription_error', {
          error: 'Permission denied',
          name: 'NotAllowedError',
          permission: permission
        });
        return;
      }

      const applicationServerKey = this.urlBase64ToUint8Array(vapidKey);

      const existingSub = await this.swRegistration.pushManager.getSubscription();
      if (existingSub) {
        await existingSub.unsubscribe();
      }

      const subscription = await this.swRegistration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: applicationServerKey
      });

      this.pushEventTo(this.el, 'push_subscription_created', {
        subscription: subscription.toJSON()
      });

      this.announcePushChanged();

    } catch (error) {
      console.error('PushSettings: Subscription failed:', error.name, error.message, error);
      this.logSubscribeDiagnostics(error);

      // the name as well as the message: the server turns a known failure into something the person can act on, while the console keeps the detail a bug report needs. Permission too, since it survives a failed subscribe and decides whether notifications still arrive while a page is open
      this.pushEventTo(this.el, 'push_subscription_error', {
        error: error.message,
        name: error.name,
        permission: (typeof Notification === 'undefined') ? null : Notification.permission
      });
    }
  },

  // A failed subscribe is reported by people who cannot debug it, so the console has to carry enough to act on: what the browser is, what state the worker reached, and for the one error with a known cause, what to check. Firefox raises AbortError when its push connection cannot be made, which is usually the page not being served over real HTTPS, or the network blocking WebSockets.
  logSubscribeDiagnostics(error) {
    console.error('push: browser info', {
      userAgent: navigator.userAgent,
      platform: navigator.platform,
      serviceWorkerState: this.swRegistration?.active?.state,
      url: window.location.href,
      protocol: window.location.protocol,
      online: navigator.onLine
    });

    if (error.name !== 'AbortError') return;

    console.error(
      [
        'push: could not establish a push subscription (AbortError).',
        'This usually means the browser could not reach a push service. Things to check:',
        '- the page must be served over HTTPS with a valid certificate (localhost will not do)',
        '- the network may be blocking WebSockets: try a mobile hotspot, since corporate and VPN networks often do',
        '- on Firefox, about:config → dom.push.enabled and dom.serviceWorkers.enabled must be true,',
        '  and dom.push.serverURL should not be pointing somewhere custom',
        '- a private window rules out an extension or a per-site setting interfering'
      ].join('\n')
    );
  },

  // Tell the server, and do NOT unsubscribe the browser here: one browser can be signed into several accounts subscribed to the same endpoint, so dropping it because one of them turned push off would silently break it for the others. The server knows who is left, and asks for the browser's subscription to go (push_unsubscribe, below) only when nobody is.
  async disablePush() {
    try {
      if (!this.swRegistration) return;

      const subscription = await this.swRegistration.pushManager.getSubscription();
      if (subscription) {
        this.pushEventTo(this.el, 'push_subscription_disabled', { endpoint: subscription.endpoint });
        this.announcePushChanged();
      }
    } catch (error) {
      console.error('PushSettings: Error disabling push:', error);
      this.pushEventTo(this.el, 'push_subscription_error', { error: error.message });
    }
  },

  // nobody is subscribed to this browser any more, so its own subscription is worth dropping
  async unsubscribeBrowser() {
    try {
      const subscription = await this.swRegistration?.pushManager.getSubscription();
      if (subscription) await subscription.unsubscribe();
      this.announcePushChanged();
    } catch (error) {
      console.error('PushSettings: Error unsubscribing this browser:', error);
    }
  },

  // The server shows why there is no toggle; a prompt that holds this component (the app banner) is told too, so it can drop an offer that cannot work rather than show the warning
  reportNotSupported() {
    this.pushEventTo(this.el, 'push_not_supported', {});
    window.dispatchEvent(new CustomEvent('bonfire:push:unsupported', { detail: { el: this.el } }));
  },

  // The notification component shows an in-page notification only where push is not doing it, and it lives on every page while this panel does not, so a change here is announced rather than pushed at it directly. It re-reads the subscription itself, so this carries no state.
  announcePushChanged() {
    window.dispatchEvent(new CustomEvent('bonfire:push:changed'));
  },

  urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - base64String.length % 4) % 4);
    const base64 = (base64String + padding)
      .replace(/-/g, '+')
      .replace(/_/g, '/');
    const rawData = window.atob(base64);
    return new Uint8Array([...rawData].map(char => char.charCodeAt(0)));
  }
};

// the card's ✕ is for good on this device: the settings page is where to turn push on later
const APP_BANNER_DISMISSED = 'app-banner-dismissed';
// long enough to read the "enabled" or "blocked" line the push row shows before it goes
const PUSH_SETTLE_MS = 4000;

function stored(key) {
  try {
    return localStorage.getItem(key);
  } catch (_e) {
    return null;
  }
}

// Only where the browser can still ask (never asked, push available), so the card never offers what can't work. iOS has PushManager only inside the installed app, which keeps the push row out of Safari tabs.
function pushPromptable() {
  return typeof Notification !== 'undefined' &&
    Notification.permission === 'default' &&
    'serviceWorker' in navigator &&
    'PushManager' in window;
}

// Works out which rows of `Bonfire.Notify.AppBannerLive` apply on this device and sends them, since only the browser knows
NotifyHooks.AppBannerHook = {
  mounted() {
    if (stored(APP_BANNER_DISMISSED)) return;

    this.prompt = null;
    this.unsubscribeInstallable = PWAUtils.onInstallable((prompt) => {
      this.prompt = prompt;
      this.sendRows();
    });
    this.sendRows();

    this.onClick = (e) => {
      if (e.target.closest('[data-app-banner-install]')) return PWAUtils.promptInstall();
      if (!e.target.closest('[data-app-banner-dismiss]')) return;
      try {
        localStorage.setItem(APP_BANNER_DISMISSED, Date.now().toString());
      } catch (_e) {}
      this.pushEventTo(this.el, 'rows', {});
    };
    this.el.addEventListener('click', this.onClick);

    // the browser turned out unable to subscribe (no service worker, say, in a private window): drop the push row now rather than show its warning
    this.onPushUnsupported = (e) => {
      if (!this.el.contains(e.detail?.el)) return;
      this.pushUnsupported = true;
      this.sendRows();
    };
    window.addEventListener('bonfire:push:unsupported', this.onPushUnsupported);

    // subscribed: the push row shows "enabled", then goes
    this.onPushChanged = () => this.settle();
    window.addEventListener('bonfire:push:changed', this.onPushChanged);

    // refused at the browser's prompt: the push row shows "blocked", then goes
    navigator.permissions?.query({ name: 'notifications' }).then((status) => {
      // the query can answer after this hook is gone, and a listener set then would never be cleared
      if (this.gone) return;
      this.permissionStatus = status;
      status.onchange = () => {
        if (status.state === 'denied') this.settle();
      };
    }).catch(() => {});
  },

  sendRows() {
    if (stored(APP_BANNER_DISMISSED)) return;

    const ios = PWAUtils.isIOS();
    const install = !PWAUtils.isPWAMode() && (ios || !!this.prompt);
    // where the page already offers push (settings, the getting-started step) the card doesn't offer it twice. Our own push row doesn't count
    const otherOffer = [...document.querySelectorAll('[phx-hook="PushSettingsHook"]')].some((el) => !this.el.contains(el));
    const push = pushPromptable() && !otherOffer && !this.pushUnsupported;

    this.pushEventTo(this.el, 'rows', { install, ios, push });
  },

  settle() {
    clearTimeout(this.settleTimer);
    this.settleTimer = setTimeout(() => this.sendRows(), PUSH_SETTLE_MS);
  },

  destroyed() {
    this.gone = true;
    this.unsubscribeInstallable?.();
    this.el.removeEventListener('click', this.onClick);
    window.removeEventListener('bonfire:push:changed', this.onPushChanged);
    window.removeEventListener('bonfire:push:unsupported', this.onPushUnsupported);
    if (this.permissionStatus) this.permissionStatus.onchange = null;
    clearTimeout(this.settleTimer);
  }
};

export { NotifyHooks };
