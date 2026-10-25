const { contextBridge, ipcRenderer } = require('electron');

// Only native-only actions are exposed; the page talks to the server over HTTP as before
contextBridge.exposeInMainWorld('lmsApp', {
  login: () => ipcRenderer.invoke('canvas-login'),
  pickFolder: (defaultPath) => ipcRenderer.invoke('pick-folder', defaultPath),
  depsStatus: () => ipcRenderer.invoke('deps-status'),
  installDeps: () => ipcRenderer.invoke('deps-install'),
  ensureDeps: () => ipcRenderer.invoke('deps-ensure'),
  onDepsProgress: (callback) => ipcRenderer.on('deps-progress', (_event, info) => callback(info)),
});
