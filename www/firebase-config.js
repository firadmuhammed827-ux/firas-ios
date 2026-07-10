/* Firas AI — Firebase web config (enables "Continue with Google").
 *
 * These web values are NOT secrets — they only identify the project to the
 * browser. The frontend reads apiKey / authDomain / projectId; the rest are kept
 * for completeness (storage / analytics if added later).
 *
 * The server must run with FIREBASE_PROJECT_ID="firas-ai" to verify Google
 * tokens. See FIREBASE_SETUP.md.
 */
/* authDomain: on the DEPLOYED site use this site's OWN host (so the /__/auth proxy in
 * netlify.toml makes the Google sign-in handler first-party → works in Safari). On
 * localhost there's no proxy, so fall back to Firebase's default handler. The site host
 * must also be listed in Firebase → Authentication → Settings → Authorized domains. */
(function () {
  var authDomain = "firas-ai.firebaseapp.com";
  try {
    var h = location.hostname;
    if (h && !/^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[?::1\]?)$/.test(h)) authDomain = h;
  } catch (e) {}
  window.FIREBASE_CONFIG = {
    apiKey: "AIzaSyDoRqmC70HTAgvZuFa1m9aOg9eBMyWSUeA",
    authDomain: authDomain,
    projectId: "firas-ai",
    storageBucket: "firas-ai.firebasestorage.app",
    messagingSenderId: "237562309958",
    appId: "1:237562309958:web:f1840b63a8644088e3c947",
    measurementId: "G-H3LLJQFW01",
  };
})();
