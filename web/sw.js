// Lets the site open from this browser's own copy. In Work mode the page comes only from that copy;
// otherwise the newest page is fetched and the copy refreshed, with the copy as a fallback offline.
const CACHE = "perronote-v1";
const FILES = ["./", "icon.png", "favicon.png", "apple-touch-icon.png", "PermanentMarker-Regular.ttf"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

/** The page saves the Work mode switch in IndexedDB, since a service worker can't read localStorage. */
function workMode() {
  return new Promise((resolve) => {
    let req;
    try { req = indexedDB.open("perronote", 1); } catch (e) { resolve(false); return; }
    req.onupgradeneeded = () => req.result.createObjectStore("kv");
    req.onerror = () => resolve(false);
    req.onsuccess = () => {
      const db = req.result;
      try {
        const get = db.transaction("kv").objectStore("kv").get("workMode");
        get.onsuccess = () => { resolve(get.result === true); db.close(); };
        get.onerror = () => { resolve(false); db.close(); };
      } catch (e) { resolve(false); db.close(); }
    };
  });
}

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  const scope = new URL(self.registration.scope);
  const isApp = e.request.mode === "navigate" && (url.pathname === scope.pathname || url.pathname === scope.pathname + "index.html");
  const key = isApp ? scope.href : e.request;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    if (await workMode()) {
      const hit = await cache.match(key, { ignoreSearch: true });
      if (hit) return hit;
    }
    try {
      const res = await fetch(e.request);
      if (res.ok) cache.put(key, res.clone());
      return res;
    } catch (err) {
      const hit = await cache.match(key, { ignoreSearch: true });
      if (hit) return hit;
      throw err;
    }
  })());
});
