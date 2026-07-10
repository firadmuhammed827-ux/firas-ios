const { app, BrowserWindow, shell, Menu } = require("electron");
const path = require("path");
const LIVE_URL = "https://firasai.netlify.app";
function createWindow() {
  const win = new BrowserWindow({
    width: 1280, height: 860, minWidth: 380, minHeight: 560,
    backgroundColor: "#1a1a18",
    title: "Firas AI",
    icon: path.join(__dirname, "..", "build", "icon.ico"),
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      partition: "persist:firas",   // keep the login session across launches
    },
  });
  win.loadURL(LIVE_URL);
  // open OAuth popups (Google sign-in) INSIDE the app so the flow completes, external http links in the browser
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/firebaseapp\.com|accounts\.google\.com|firasai\.netlify\.app/.test(url)) return { action: "allow" };
    if (/^https?:/.test(url)) { shell.openExternal(url); return { action: "deny" }; }
    return { action: "allow" };
  });
  // offline fallback
  win.webContents.on("did-fail-load", (e, code, desc, u, isMainFrame) => {
    if (isMainFrame && code !== -3) win.loadURL("data:text/html,<meta charset=utf-8><body style='font-family:system-ui;background:#1a1a18;color:#eee;display:grid;place-items:center;height:100vh;text-align:center'><div><h2>Firas AI</h2><p>لا يوجد اتصال بالإنترنت. تأكّد من الشبكة ثم أعد فتح التطبيق.</p></div></body>");
  });
}
app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  createWindow();
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
