const path = require('path');
const { app, BrowserWindow, dialog, ipcMain, shell } = require('electron');

// A second launch only focuses the first window; quit before it tries to bind the port
if (!app.requestSingleInstanceLock()) {
  app.exit(0);
}

// Finder-launched apps get a bare PATH; the script needs Homebrew's jq/ffmpeg/curl
process.env.PATH = [
  '/opt/homebrew/bin',
  '/usr/local/bin',
  path.join(app.getPath('home'), '.local/bin'),
  process.env.PATH,
].join(':');
// Keep config, cookies and default output outside the app bundle
process.env.LMS_DATA_DIR = app.getPath('userData');

const { PORT, ready, stopAllDownloads } = require('../server');

const APP_URL = `http://localhost:${PORT}`;
const CANVAS_URL = 'https://canvas.ssu.ac.kr/';
// Persisted so the SSO session survives restarts and re-login is usually one click
const LOGIN_PARTITION = 'persist:canvas';

let mainWindow = null;
let loginWindow = null;

// ── Main window ────────────────────────────────────────────
function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 960,
    height: 900,
    title: 'LMS 다운로더',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  // Links such as the cookie extension page open in the default browser
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWindow.loadURL(APP_URL);
  mainWindow.on('closed', () => { mainWindow = null; });
}

// ── Canvas login ───────────────────────────────────────────
function isFreshToken(token) {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    return !payload.exp || payload.exp * 1000 > Date.now();
  } catch {
    return false;
  }
}

async function findToken(ses) {
  const cookies = await ses.cookies.get({ name: 'xn_api_token' });
  const fresh = cookies.find((c) => isFreshToken(c.value));
  return fresh ? fresh.value : null;
}

// Same Netscape format that the "Get cookies.txt LOCALLY" extension exports
function toNetscapeLine(c) {
  const bare = c.domain.replace(/^\./, '');
  return [
    (c.httpOnly ? '#HttpOnly_' : '') + (c.hostOnly ? bare : `.${bare}`),
    c.hostOnly ? 'FALSE' : 'TRUE',
    c.path,
    c.secure ? 'TRUE' : 'FALSE',
    Math.floor(c.expirationDate || 0),
    c.name,
    c.value,
  ].join('\t');
}

async function saveLogin(ses) {
  if (!(await findToken(ses))) {
    return { ok: false, message: '로그인이 완료되지 않았습니다. 로그인한 뒤 강의 페이지를 한 번 열어 주세요.' };
  }
  const cookies = (await ses.cookies.get({}))
    .filter((c) => c.domain.replace(/^\./, '').endsWith('ssu.ac.kr'));
  const text = ['# Netscape HTTP Cookie File', ...cookies.map(toNetscapeLine)].join('\n') + '\n';

  // Reuse the upload endpoint so the token extraction stays in one place
  const res = await fetch(`${APP_URL}/api/config/upload-cookie`, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain' },
    body: text,
  });
  const data = await res.json();
  return res.ok
    ? { ok: true, message: '로그인 완료: 쿠키와 토큰을 저장했습니다.' }
    : { ok: false, message: data.error || '쿠키 저장 실패' };
}

function openLoginWindow() {
  return new Promise((resolve) => {
    loginWindow = new BrowserWindow({
      width: 900,
      height: 800,
      parent: mainWindow,
      title: 'Canvas 로그인',
      webPreferences: { partition: LOGIN_PARTITION },
    });
    const win = loginWindow;
    const ses = win.webContents.session;
    let settled = false;

    const finish = async () => {
      if (settled) return;
      settled = true;
      ses.cookies.removeListener('changed', onCookieChanged);
      let result;
      try {
        result = await saveLogin(ses);
      } catch (e) {
        result = { ok: false, message: `쿠키 저장 실패: ${e.message}` };
      }
      if (!win.isDestroyed()) win.close();
      resolve(result);
    };

    // Give the SSO redirect chain a moment to set the remaining cookies
    const finishSoon = () => setTimeout(finish, 1000);

    const onCookieChanged = (_event, cookie, _cause, removed) => {
      if (!removed && cookie.name === 'xn_api_token' && isFreshToken(cookie.value)) finishSoon();
    };
    ses.cookies.on('changed', onCookieChanged);

    // A persisted session may already hold a valid token, which emits no 'changed' event
    win.webContents.on('did-finish-load', async () => {
      if (await findToken(ses)) finishSoon();
    });
    win.on('closed', () => {
      loginWindow = null;
      finish();
    });

    win.loadURL(CANVAS_URL);
  });
}

// ── Output folder picker ───────────────────────────────────
ipcMain.handle('pick-folder', async (_event, defaultPath) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: '다운로드 받을 폴더 선택',
    buttonLabel: '이 폴더에 저장',
    defaultPath: defaultPath || app.getPath('downloads'),
    properties: ['openDirectory', 'createDirectory'],
  });
  return result.canceled ? null : result.filePaths[0];
});

ipcMain.handle('canvas-login', () => {
  if (loginWindow) {
    loginWindow.focus();
    return { ok: false, message: '로그인 창이 이미 열려 있습니다.' };
  }
  return openLoginWindow();
});

// ── App lifecycle ──────────────────────────────────────────
app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  }
});

app.whenReady().then(async () => {
  try {
    await ready;
  } catch (e) {
    dialog.showErrorBox(
      `포트 ${PORT}를 사용할 수 없습니다`,
      `이미 실행 중인 LMS 다운로더(npm start 등)를 종료한 뒤 다시 열어 주세요.\n\n${e.message}`,
    );
    app.quit();
    return;
  }
  createMainWindow();
});

app.on('activate', () => {
  if (!mainWindow) createMainWindow();
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', stopAllDownloads);
