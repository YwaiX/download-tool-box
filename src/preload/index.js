import { contextBridge, ipcRenderer } from "electron"

contextBridge.exposeInMainWorld("downloader", {
  start: (threadCount) => ipcRenderer.invoke("download:start", threadCount),
  stop: () => ipcRenderer.invoke("download:stop"),
  openList: () => ipcRenderer.invoke("dialog:open-list"),
  openPath: (target) => ipcRenderer.invoke("shell:open-path", target),
  onEvent: (callback) => {
    const listener = (_event, payload) => callback(payload)
    ipcRenderer.on("download:event", listener)
    return () => ipcRenderer.removeListener("download:event", listener)
  },
  getCurrentLog: () => ipcRenderer.invoke("log:get-current"),
  openCurrentLog: () => ipcRenderer.invoke("log:open-current")
})
