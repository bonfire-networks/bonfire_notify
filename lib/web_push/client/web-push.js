import * as ServiceWorker from "./service-worker";

// Initialize service worker
ServiceWorker.registerWorker();

if (ServiceWorker.isPushSupported()) {

    subscribed = function (subscription) {
        const payload = {
            type: "pushSubscription",
            subscription: JSON.stringify(subscription)
        };

        console.log("Push subscribed");
        console.log(payload);
        
        // TODO_updateSubscriptionOnServer(payload);
    }

    getPushSubscription = function () {
        ServiceWorker.getPushSubscription().
            then(subscription => {
            subscribed(subscription);
        });
    }

    pushSubscribe = function () {
        ServiceWorker.pushSubscribe()
            .then(subscription => {
                subscribed(subscription);
            })
            .catch(err => {
                console.error(err);
            });
    }


    ServiceWorker.addEventListener("message", event => {
        const payload = event.data;
        console.log('[Service Worker] Message Received.');
        console.log(payload);
        // logEvent("serviceWorkerIn")(payload);
    });

    ServiceWorker.addEventListener('push', function (event) {
        console.log('[Service Worker] Push Received.');
        console.log(`[Service Worker] Push had this data: "${event.data.text()}"`);

        const title = 'Bonfire';
        const options = {
            body: 'Yay it works.',
            icon: 'images/icon.png',
            badge: 'images/badge.png'
        };

        const notificationPromise = self.registration.showNotification(title, options);
        event.waitUntil(notificationPromise);
    });
}
