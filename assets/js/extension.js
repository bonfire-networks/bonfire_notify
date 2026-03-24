import { PWAUtils } from "./pwa-utils";

// Clear stale badge count when user returns to the app
if ('clearAppBadge' in navigator) {
  const clearBadge = () => navigator.clearAppBadge().catch(() => {});
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') clearBadge();
  });
  window.addEventListener('focus', clearBadge);
  clearBadge();
}

let NotifyHooks = {};

NotifyHooks.PushNotificationHook = {
  mounted() {
    console.log('🔔 PushNotificationHook: mounted() called');
    
    this.vapidPublicKey = document.getElementById('vapid-public-key')?.value;
    console.log('🔑 VAPID public key:', this.vapidPublicKey ? 'Found' : '❌ NOT FOUND');
    
    this.swRegistration = null;
    this.subscribeBtn = document.getElementById('subscribe-btn');
    console.log('🔘 Subscribe button:', this.subscribeBtn ? 'Found' : '❌ NOT FOUND');
    
    this.init();
  },

  async init() {
    console.log('🚀 PushNotificationHook: init() starting...');
    
    if (!('serviceWorker' in navigator)) {
      console.error('❌ Service Worker not supported in this browser');
      return;
    }
    console.log('✅ Service Worker API available');
    
    // Check Push API support
    if (!('PushManager' in window)) {
      console.error('❌ Push API not supported in this browser');
      return;
    }
    console.log('✅ Push API available');

    try {
      console.log('📝 Registering service worker at /pwabuilder-sw.js...');
      this.swRegistration = await navigator.serviceWorker.register('/pwabuilder-sw.js', {
        scope: '/'  // Explicitly set scope
      });
      console.log('✅ Service Worker registered');
      console.log('   - Scope:', this.swRegistration.scope);
      console.log('   - Active:', this.swRegistration.active ? 'Yes' : 'No');
      console.log('   - Installing:', this.swRegistration.installing ? 'Yes' : 'No');
      console.log('   - Waiting:', this.swRegistration.waiting ? 'Yes' : 'No');
      
      await navigator.serviceWorker.ready;
      console.log('✅ Service Worker ready');
      
      // Check service worker state after ready
      console.log('📊 Service Worker state after ready:');
      console.log('   - Active state:', this.swRegistration.active?.state);
      
      // Check if pushManager is available
      if (!this.swRegistration.pushManager) {
        console.error('❌ Push Manager not available on registration');
        return;
      }
      console.log('✅ Push Manager available');

      await this.updateStatus();
      this.setupEventListeners();

      window.addEventListener("phx:device_removed", e => {
        console.log('📢 Received phx:device_removed event:', e.detail);
        e.preventDefault();
        this.handleDeviceRemoved(e.detail.endpoint);
      })

      const installBtn = document.getElementById('install-button');
      
      if(installBtn && PWAUtils.isPWAMode()) {
          console.log('📱 Running in PWA mode, sending is-pwa event');
          this.pushEvent('Bonfire.Notify:is-pwa', true);
        PWAUtils.promptToInstallPWA();
        installBtn.style.display = 'block';
      } else {
        console.log('🌐 Not in PWA mode');
        if (installBtn) { installBtn.style.display = 'none'; }
      }

    } catch (error) {
      console.error('❌ Push hook init failed:', error);
      console.error('Error stack:', error.stack);
    }
  },

  setupEventListeners() {
    console.log('🎧 Setting up event listeners...');
    
    if (this.subscribeBtn) {
      this.subscribeBtn.addEventListener('click', async () => {
        console.log('👆 Subscribe button clicked');
        const isSubscribed = await this.isSubscribed();
        console.log('Current subscription status:', isSubscribed ? 'Subscribed' : 'Not subscribed');
        
        if (isSubscribed) {
          console.log('➡️ Unsubscribing...');
          await this.unsubscribe();
        } else {
          console.log('➡️ Subscribing...');
          await this.subscribe();
        }
        await this.updateStatus();
      });
      console.log('✅ Event listeners set up');
    } else {
      console.warn('⚠️ Subscribe button not found, skipping event listener setup');
    }
  },

  async isSubscribed() {
    if (!this.swRegistration) {
      console.log('❌ No SW registration, returning false');
      return false;
    }
    
    const subscription = await this.swRegistration.pushManager.getSubscription();
    console.log('📊 Current subscription:', subscription ? 'Active' : 'None');
    return !!subscription;
  },

  async subscribe() {
    try {
      console.log('🔔 Starting subscription process...');
      

      // Check current subscription first
      const existingSub = await this.swRegistration.pushManager.getSubscription();
      if (existingSub) {
        console.log('ℹ️ Existing subscription found, unsubscribing first...');
        await existingSub.unsubscribe();
      }
      
      console.log('🔐 Requesting notification permission...');
      const permission = await Notification.requestPermission();
      console.log('📋 Permission result:', permission);
      
      if (permission !== 'granted') {
        console.error('❌ Notification permission denied');
        throw new Error('Permission denied');
      }
      console.log('✅ Notification permission granted');
      
      console.log('🔑 Converting VAPID key...');
      console.log('   - Original key:', this.vapidPublicKey);
      const applicationServerKey = this.urlBase64ToUint8Array(this.vapidPublicKey);
      console.log('✅ VAPID key converted');
      console.log('   - Array length:', applicationServerKey.length);
      console.log('   - First few bytes:', Array.from(applicationServerKey.slice(0, 10)));
      
      console.log('📝 Attempting to subscribe to push manager...');
      console.log('   - userVisibleOnly: true');
      console.log('   - applicationServerKey length:', applicationServerKey.length);
      
      const subscription = await this.swRegistration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: applicationServerKey
      });
      
      console.log('✅ Subscription created successfully!');
      console.log('   - Endpoint:', subscription.endpoint);
      console.log('   - Keys:', Object.keys(subscription.toJSON().keys));
      
      console.log('📤 Sending subscription to server...');
      this.pushEvent('Bonfire.Notify:subscribe', {
        subscription: subscription.toJSON()
      });
      console.log('✅ Subscription sent to server');
      
    } catch (error) {
      console.error('❌ Subscribe failed');
      console.error('   - Error name:', error.name);
      console.error('   - Error message:', error.message);
      console.error('   - Error code:', error.code);
      console.error('   - Full error:', error);
      console.error('   - Stack trace:', error.stack);
      
      // Log additional browser-specific info
      console.log('🔍 Browser info:');
      console.log('   - User agent:', navigator.userAgent);
      console.log('   - Platform:', navigator.platform);
      console.log('   - Service Worker state:', this.swRegistration?.active?.state);
      console.log('   - Current URL:', window.location.href);
      console.log('   - Protocol:', window.location.protocol);
      console.log('   - Online status:', navigator.onLine ? 'Online' : 'Offline');
      
      // Firefox-specific error handling
      if (error.name === 'AbortError') {
        console.error('════════════════════════════════════════════════════════════');
        console.error('🚨 PUSH NOTIFICATION SUBSCRIPTION FAILED');
        console.error('Error: AbortError (code 20) - Cannot establish push subscription');
        console.error('🔍 Diagnosis:');
        console.error('   • WebSocket connection is failing or blocked');
        console.error('✅ Next steps to fix:');
        console.error('-  Make sure you\'re using HTTPS with a valid certificate (i.e. not localhost)');
        console.error('-  Try a different on this same domain');
        console.error('-  On Firefox check about:config');
        console.error('   • Open: about:config');
        console.error('   • Search: dom.push.enabled → must be true');
        console.error('   • Search: dom.push.serverURL → check if custom');
        console.error('   • Search: dom.serviceWorkers.enabled → must be true');
        console.error('-  Test on different network');
        console.error('   • Try mobile hotspot to rule out network/firewall');
        console.error('   • Corporate/VPN networks often block WebSockets');
        console.error('-  Firefox Private Window (Ctrl+Shift+P)');
        console.error('   • Rules out extension/setting interference');
        console.error('════════════════════════════════════════════════════════════');
      }
    }
  },

  async unsubscribe() {
    try {
      console.log('🔕 Starting unsubscribe process...');
      
      const subscription = await this.swRegistration.pushManager.getSubscription();
      if (subscription) {
        console.log('📝 Found subscription to unsubscribe:', subscription.endpoint);
        
        await subscription.unsubscribe();
        console.log('✅ Unsubscribed from push manager');
        
        console.log('📤 Notifying server about unsubscribe...');
        this.pushEvent('Bonfire.Notify:unsubscribe', { endpoint: subscription.endpoint });
        console.log('✅ Server notified');
      } else {
        console.warn('⚠️ No subscription found to unsubscribe');
      }
    } catch (error) {
      console.error('❌ Unsubscribe failed:', error.message);
      console.error('Error details:', error);
    }
  },

  async updateStatus() {
    if (!this.swRegistration) {
      console.log('❌ updateStatus: No SW registration');
      return;
    }
    
    try {
      const subscription = await this.swRegistration.pushManager.getSubscription();
      console.log('🔄 Updating UI status, subscription:', subscription ? 'Active' : 'None');
      
      if (this.subscribeBtn) {
        if (subscription) {
          this.subscribeBtn.textContent = 'Disable Notifications';
          this.subscribeBtn.className = 'btn btn-error btn-sm';
        } else {
          this.subscribeBtn.textContent = 'Enable Notifications';
          this.subscribeBtn.className = 'btn btn-primary btn-sm';
        }
        console.log('✅ Button UI updated');
      }
      
      const indicator = document.getElementById('status-indicator');
      if (indicator) {
        if (subscription) {
          indicator.className = 'badge badge-success w-3 h-3 rounded-full p-0';
        } else {
          indicator.className = 'badge badge-ghost w-3 h-3 rounded-full p-0';
        }
        console.log('✅ Status indicator updated');
      }
    } catch (error) {
      console.error('❌ Error updating status:', error);
    }
  },

  async handleDeviceRemoved(removedEndpoint) {
    console.log('🗑️ Handling device removal for endpoint:', removedEndpoint);
    
    if (!this.swRegistration) {
      console.log('❌ No SW registration, cannot handle device removal');
      return;
    }
    
    try {
      const currentSubscription = await this.swRegistration.pushManager.getSubscription();
      
      if (currentSubscription) {
        console.log('📊 Current subscription endpoint:', currentSubscription.endpoint);
        console.log('🔍 Comparing with removed endpoint...');
        
        if (currentSubscription.endpoint === removedEndpoint) {
          console.log('✅ Match found, unsubscribing...');
          await currentSubscription.unsubscribe();
          console.log('✅ Unsubscribed successfully');
          await this.updateStatus();
        } else {
          console.log('ℹ️ Different endpoint, no action needed');
        }
      } else {
        console.log('ℹ️ No current subscription, no action needed');
      }
    } catch (error) {
      console.error('❌ Error handling device removal:', error);
    }
  },

  urlBase64ToUint8Array(base64String) {
    console.log('🔄 Converting base64 VAPID key, length:', base64String?.length);
    
    const padding = '='.repeat((4 - base64String.length % 4) % 4);
    const base64 = (base64String + padding)
      .replace(/-/g, '+')
      .replace(/_/g, '/');
    const rawData = window.atob(base64);
    const result = new Uint8Array([...rawData].map(char => char.charCodeAt(0)));
    
    console.log('✅ Converted to Uint8Array, length:', result.length);
    return result;
  },

  updated() {
    console.log('🔄 PushNotificationHook: updated() called');
    this.updateStatus();
  }
};

// Hook for push settings in user preferences
// Works with PushNotificationsLive component using pushEventTo for component communication
NotifyHooks.PushSettingsHook = {
  async mounted() {
    this.vapidKey = this.el.dataset.vapidKey;
    this.swRegistration = null;
    this.deferredPrompt = null;

    // Store bound handlers for cleanup
    this._boundHandlers = {};

    // Setup PWA install handling
    this.setupPwaInstall();

    if (!('serviceWorker' in navigator)) {
      this.pushEventTo(this.el, 'push_not_supported', {});
      return;
    }

    await this.initServiceWorker();

    // Check PushManager after SW registration — in PWAs it may only be
    // available on the registration object, not on window
    if (!this.swRegistration?.pushManager && !('PushManager' in window)) {
      this.pushEventTo(this.el, 'push_not_supported', {});
      return;
    }

    await this.checkCurrentSubscription();

    this.handleEvent('request_push_permission', async (payload) => {
      await this.requestPushPermission(payload.vapid_key);
    });

    this.handleEvent('request_push_disable', async () => {
      await this.disablePush();
    });
  },

  destroyed() {
    // Clean up event listeners
    if (this._boundHandlers.beforeinstallprompt) {
      window.removeEventListener('beforeinstallprompt', this._boundHandlers.beforeinstallprompt);
    }
    if (this._boundHandlers.installClick) {
      const installBtn = document.getElementById('pwa-install-btn');
      if (installBtn) {
        installBtn.removeEventListener('click', this._boundHandlers.installClick);
      }
    }
    this.deferredPrompt = null;
    this.swRegistration = null;
  },

  setupPwaInstall() {
    const installSection = document.getElementById('pwa-install-section');
    const installBtn = document.getElementById('pwa-install-btn');

    // Store bound handler for cleanup
    this._boundHandlers.beforeinstallprompt = (e) => {
      e.preventDefault();
      this.deferredPrompt = e;
      // Show the install section
      if (installSection) {
        installSection.classList.remove('hidden');
      }
    };
    window.addEventListener('beforeinstallprompt', this._boundHandlers.beforeinstallprompt);

    // Handle install button click
    if (installBtn) {
      this._boundHandlers.installClick = async () => {
        if (!this.deferredPrompt) return;

        this.deferredPrompt.prompt();
        const { outcome } = await this.deferredPrompt.userChoice;

        if (outcome === 'accepted') {
          if (installSection) {
            installSection.classList.add('hidden');
          }
        }
        this.deferredPrompt = null;
      };
      installBtn.addEventListener('click', this._boundHandlers.installClick);
    }

    // Hide install section if already installed as PWA
    if (window.matchMedia('(display-mode: standalone)').matches) {
      if (installSection) {
        installSection.classList.add('hidden');
      }
    }
  },

  async initServiceWorker() {
    try {
      this.swRegistration = await navigator.serviceWorker.register('/pwabuilder-sw.js', { scope: '/' });
      await navigator.serviceWorker.ready;
    } catch (error) {
      console.error('PushSettings: Service worker init failed:', error);
    }
  },

  async checkCurrentSubscription() {
    if (!this.swRegistration) return;

    try {
      const subscription = await this.swRegistration.pushManager.getSubscription();
      if (subscription) {
        this.pushEventTo(this.el, 'check_subscription', {
          endpoint: subscription.endpoint
        });
      }
    } catch (error) {
      console.error('PushSettings: Error checking subscription:', error);
    }
  },

  async requestPushPermission(vapidKey) {
    try {
      if (!this.swRegistration) {
        await this.initServiceWorker();
      }

      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        this.pushEventTo(this.el, 'push_subscription_error', { error: 'Permission denied' });
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

    } catch (error) {
      console.error('PushSettings: Subscription failed:', error);
      this.pushEventTo(this.el, 'push_subscription_error', { error: error.message });
    }
  },

  async disablePush() {
    try {
      if (!this.swRegistration) return;

      const subscription = await this.swRegistration.pushManager.getSubscription();
      if (subscription) {
        const endpoint = subscription.endpoint;
        await subscription.unsubscribe();
        this.pushEventTo(this.el, 'push_subscription_disabled', { endpoint: endpoint });
      }
    } catch (error) {
      console.error('PushSettings: Error disabling push:', error);
      this.pushEventTo(this.el, 'push_subscription_error', { error: error.message });
    }
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

NotifyHooks.PWAInstallBannerHook = {
  mounted() {
    this.deferredPrompt = null;
    this._handlers = {};

    const banner = this.el;
    const installBtn = this.el.querySelector('[data-pwa-install]');
    const dismissBtn = this.el.querySelector('[data-pwa-dismiss]');
    const iosInstructions = this.el.querySelector('[data-pwa-ios]');

    if (localStorage.getItem('pwa-install-dismissed') || PWAUtils.isPWAMode()) {
      return;
    }

    if (PWAUtils.isIOS()) {
      banner.classList.remove('hidden');
      if (iosInstructions) iosInstructions.classList.remove('hidden');
      if (installBtn) installBtn.classList.add('hidden');
    }

    // Android/Desktop: show banner when beforeinstallprompt fires
    this._handlers.beforeinstallprompt = (e) => {
      e.preventDefault();
      this.deferredPrompt = e;
      banner.classList.remove('hidden');
      if (iosInstructions) iosInstructions.classList.add('hidden');
      if (installBtn) installBtn.classList.remove('hidden');
    };
    window.addEventListener('beforeinstallprompt', this._handlers.beforeinstallprompt);

    if (installBtn) {
      this._handlers.installClick = async () => {
        if (!this.deferredPrompt) return;
        this.deferredPrompt.prompt();
        const { outcome } = await this.deferredPrompt.userChoice;
        this.deferredPrompt = null;
        if (outcome === 'accepted') banner.classList.add('hidden');
      };
      installBtn.addEventListener('click', this._handlers.installClick);
    }

    if (dismissBtn) {
      this._handlers.dismissClick = () => {
        banner.classList.add('hidden');
        localStorage.setItem('pwa-install-dismissed', Date.now().toString());
      };
      dismissBtn.addEventListener('click', this._handlers.dismissClick);
    }

    this._handlers.appinstalled = () => {
      banner.classList.add('hidden');
      this.deferredPrompt = null;
    };
    window.addEventListener('appinstalled', this._handlers.appinstalled);
  },

  destroyed() {
    if (this._handlers.beforeinstallprompt) {
      window.removeEventListener('beforeinstallprompt', this._handlers.beforeinstallprompt);
    }
    if (this._handlers.appinstalled) {
      window.removeEventListener('appinstalled', this._handlers.appinstalled);
    }
    if (this._handlers.installClick) {
      this.el.querySelector('[data-pwa-install]')?.removeEventListener('click', this._handlers.installClick);
    }
    if (this._handlers.dismissClick) {
      this.el.querySelector('[data-pwa-dismiss]')?.removeEventListener('click', this._handlers.dismissClick);
    }
    this.deferredPrompt = null;
  }
};

export { NotifyHooks };
