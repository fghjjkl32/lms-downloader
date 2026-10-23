const { contextBridge, ipcRenderer } = require('electron');

// Only native-only actions are exposed; the page talks to the server over HTTP as before
contextBridge.exposeInMainWorld('lmsApp', {
  login: () => ipcRenderer.invoke('canvas-login'),
  pickFolder: (defaultPath) => ipcRenderer.invoke('pick-folder', defaultPath),
});
