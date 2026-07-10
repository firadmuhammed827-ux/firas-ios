/* Rewrites the bundled frontend's same-origin /api/* fetches to the live backend
   (window.FIRAS_API_BASE). No-op until a real http(s) base is set. On mobile the
   Capacitor Http plugin further routes these as NATIVE requests (bypasses CORS +
   carries the session cookie); on desktop Electron runs with webSecurity relaxed. */
(function () {
  var BASE = String(window.FIRAS_API_BASE || "").replace(/\/+$/, "");
  if (!/^https?:\/\//i.test(BASE)) return;               // placeholder / unset → behave normally
  var _fetch = window.fetch ? window.fetch.bind(window) : null;
  if (!_fetch) return;
  var origin = location.origin;
  window.fetch = function (input, init) {
    try {
      var url = (typeof input === "string") ? input : (input && input.url) || "";
      var apiPath = null;
      if (/^\/api\//.test(url)) apiPath = url;
      else if (url.indexOf(origin + "/api/") === 0) apiPath = url.slice(origin.length);
      if (apiPath) {
        init = init || {};
        if (init.credentials === undefined) init.credentials = "include";  // cross-origin session cookie
        var target = BASE + apiPath;
        if (typeof input === "string") return _fetch(target, init);
        return _fetch(new Request(target, input), init);
      }
    } catch (e) {}
    return _fetch(input, init);
  };
})();
