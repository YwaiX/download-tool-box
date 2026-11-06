
import { app, BrowserWindow, dialog, ipcMain, shell } from "electron"
import { spawn } from "node:child_process"
import crypto from "node:crypto"
import fs from "node:fs"
import path from "node:path"

let mainWindow = null
let downloader = null
let stopping = false
let selectedListFile = null
let currentLogFile = ""
let currentSessionDir = ""

const ALLOWED_THREADS = new Set([1, 2, 4, 8, 16, 32, 64])

function getAppDataDir () {
  const dir = path.join(path.dirname(app.getPath("exe")), "DownloaderData")
  if(!app.isPackaged) return path.join(app.getAppPath(), "runtime")
  return dir
}

/**
 * 获取长期下载日志文件路径
 */
function getPersistentLogFile () {
  return path.join(getAppDataDir(), "logs", "download.log")
}

/**
 * 写入长期下载日志
 */
function writePersistentLog (message) {
  const logFile = getPersistentLogFile()
  fs.mkdirSync(path.dirname(logFile), { recursive: true })

  const time = new Date().toLocaleTimeString("zh-CN", {
    hour12: false
  })

  fs.appendFileSync(logFile, `[${time}] ${message}\r\n`, "utf8")
}

/**
 * 初始化程序数据目录
 */
function initAppDataDir () {
  const dataDir = getAppDataDir()
  const saveDir = path.join(dataDir, "downloads")

  fs.mkdirSync(dataDir, { recursive: true })
  fs.mkdirSync(saveDir, { recursive: true })
  fs.mkdirSync(path.join(dataDir, "tmp"), { recursive: true })
}

function getPowerShellDir () {
  return app.isPackaged
    ? path.join(process.resourcesPath, "powershell")
    : path.join(app.getAppPath(), "powershell")
}

/**
 * 确保 PowerShell 脚本使用 UTF-8 BOM 编码
 */
function ensurePowerShellEncoding () {
  const scriptDir = app.isPackaged
    ? path.join(process.resourcesPath, "powershell")
    : path.join(app.getAppPath(), "powershell")

  function convertFile (filePath) {
    const buffer = fs.readFileSync(filePath)

    // 已经是 UTF-8 BOM，直接跳过
    if(
      buffer.length >= 3 &&
      buffer[0] === 0xEF &&
      buffer[1] === 0xBB &&
      buffer[2] === 0xBF
    ) {
      return
    }

    // 严格检查是否为合法 UTF-8
    const content = new TextDecoder("utf-8", { fatal: true }).decode(buffer)

    // 转换为 UTF-8 BOM
    const bom = Buffer.from([0xEF, 0xBB, 0xBF])
    fs.writeFileSync(filePath, Buffer.concat([bom, Buffer.from(content, "utf8")]))
  }

  const mainScript = path.join(getPowerShellDir(), "Main.ps1")
  if(fs.existsSync(mainScript)) {
    convertFile(mainScript)
  }

  const moduleDir = path.join(scriptDir, "modules")
  if(fs.existsSync(moduleDir)) {
    for(const file of fs.readdirSync(moduleDir)) {
      if(file.toLowerCase().endsWith(".psm1")) {
        convertFile(path.join(moduleDir, file))
      }
    }
  }
}

/**
 * 创建本次软件运行的日志文件
 */
function createSessionLogFile () {
  const logDir = path.join(getAppDataDir(), "logs")
  fs.mkdirSync(logDir, { recursive: true })

  const now = new Date()
  const pad = (value) => String(value).padStart(2, "0")
  const timestamp =
    `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}_` +
    `${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`

  const uuid = crypto.randomUUID()
  const sessionName = `${timestamp}_${uuid}`
  currentLogFile = path.join(logDir, `${sessionName}.log`)
  currentSessionDir = path.join(getAppDataDir(), "downloads", sessionName)

  fs.mkdirSync(currentSessionDir, { recursive: true })
  fs.writeFileSync(currentLogFile, "", "utf8")
}

/**
 * 清理停止下载后残留的分段临时文件
 */
function cleanupDownloadTempFiles () {
  const tempDir = path.join(getAppDataDir(), "tmp")
  try {
    for(const name of fs.readdirSync(tempDir)) {
      if(/\.download\.tmp(?:\.part\d+)?$/.test(name)) {
        fs.rmSync(path.join(tempDir, name), { force: true })
      }
    }
  } catch(error) {
    writeLog(`清理临时下载文件失败：${error.message}`)
  }
}

function getPowerShellMain () {
  return app.isPackaged
    ? path.join(process.resourcesPath, "powershell", "Main.ps1")
    : path.join(app.getAppPath(), "powershell", "Main.ps1")
}

/**
 * 写入当前会话日志
 */
function writeLog (message) {
  if(!currentLogFile) return

  const time = new Date().toLocaleTimeString("zh-CN", {
    hour12: false
  })

  fs.appendFileSync(currentLogFile, `[${time}] ${message}\r\n`, "utf8")
}

function send (type, payload = {}) {
  const message = payload.message

  if(
    ["started", "log", "error", "summary", "finished"].includes(type) &&
    typeof message === "string" &&
    message.trim()
  ) {
    writeLog(message)
  }

  if(mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send("download:event", { type, ...payload })
  }
}

function createWindow () {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1440,
    minHeight: 900,
    resizable: true,
    minimizable: true,
    maximizable: true,
    fullscreen: false,
    frame: true,
    title: "Downloader",
    backgroundColor: "#F3F5F9",
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })

  const devUrl = process.env.ELECTRON_RENDERER_URL
  if(devUrl) void mainWindow.loadURL(devUrl)
  else void mainWindow.loadFile(path.join(__dirname, "../renderer/index.html"))

  mainWindow.on("closed", () => {
    mainWindow = null
  })
}
function decodeOutput (buffer) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(buffer)
  } catch {
    return new TextDecoder("gbk").decode(buffer)
  }
}

function parseJsonLines (buffer, streamType) {
  const lines = buffer.split(/\r?\n/)
  for(const line of lines) {
    if(!line.trim()) continue
    try {
      const event = JSON.parse(line)
      send(event.type || (streamType === "stderr" ? "error" : "log"), event)
    } catch {
      send(streamType === "stderr" ? "error" : "log", { message: line })
    }
  }
}

ipcMain.handle("download:start", async (_event, threadCount) => {
  if(downloader) throw new Error("下载任务已经在运行。")

  const threads = ALLOWED_THREADS.has(threadCount) ? threadCount : 64
  const dataDir = getAppDataDir()
  const listFile = selectedListFile || path.join(dataDir, "download.txt")
  const saveDir = currentSessionDir || path.join(dataDir, "downloads")
  const script = getPowerShellMain()

  if(!fs.existsSync(script)) {
    throw new Error(`找不到下载脚本：${script}`)
  }

  if(!fs.existsSync(listFile)) {
    throw new Error(`下载清单不存在：${listFile}`)
  }

  fs.mkdirSync(saveDir, { recursive: true })
  stopping = false

  ensurePowerShellEncoding()

  const child = spawn("powershell.exe", [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-OutputFormat", "Text",
    "-ExecutionPolicy", "Bypass",
    "-File", script,
    "-ListFile", listFile,
    "-SaveDir", saveDir,
    "-DataDir", dataDir,
    "-Threads", String(threads)
  ], {
    windowsHide: true,
    cwd: dataDir,
    env: {
      ...process.env,
      PYTHONIOENCODING: "utf-8"
    }
  })

  downloader = child
  send("started", { message: "下载引擎已启动。", listFile, saveDir })

  let stdoutBuffer = Buffer.alloc(0)
  let stderrBuffer = Buffer.alloc(0)

  child.stdout.on("data", (chunk) => {
    stdoutBuffer = Buffer.concat([stdoutBuffer, chunk])
    const lastNewline = stdoutBuffer.lastIndexOf(0x0A)
    if(lastNewline >= 0) {
      parseJsonLines(decodeOutput(stdoutBuffer.subarray(0, lastNewline)), "stdout")
      stdoutBuffer = stdoutBuffer.subarray(lastNewline + 1)
    }
  })

  child.stderr.on("data", (chunk) => {
    stderrBuffer = Buffer.concat([stderrBuffer, chunk])
    const lastNewline = stderrBuffer.lastIndexOf(0x0A)
    if(lastNewline >= 0) {
      parseJsonLines(decodeOutput(stderrBuffer.subarray(0, lastNewline)), "stderr")
      stderrBuffer = stderrBuffer.subarray(lastNewline + 1)
    }
  })

  child.on("error", error => {
    send("error", { message: `PowerShell 启动失败：${error.message}` })
    downloader = null
  })

  child.on("close", (code, signal) => {
    if(stdoutBuffer.length) parseJsonLines(decodeOutput(stdoutBuffer), "stdout")
    if(stderrBuffer.length) parseJsonLines(decodeOutput(stderrBuffer), "stderr")

    downloader = null
    cleanupDownloadTempFiles()

    send("finished", {
      message: stopping
        ? "下载任务已停止。"
        : `下载进程结束，退出码：${code ?? signal ?? "未知"}`,
      exitCode: code
    })

    stopping = false
  })

  return { started: true }
})

ipcMain.handle("download:stop", async () => {
  if(!downloader) throw new Error("当前没有正在运行的下载任务。")

  stopping = true
  downloader.kill()

  return { stopping: true }
})

ipcMain.handle("dialog:open-list", async () => {
  const result = await dialog.showOpenDialog({
    title: "选择下载清单",
    defaultPath: selectedListFile || path.join(getAppDataDir(), "download.txt"),
    properties: ["openFile"],
    filters: [{ name: "文本文件", extensions: ["txt"] }]
  })

  if(result.canceled || !result.filePaths.length) {
    return null
  }

  selectedListFile = result.filePaths[0]
  writePersistentLog(`已切换下载清单：${selectedListFile}`)

  return selectedListFile
})

ipcMain.handle("shell:open-path", async (_event, target) => {
  const dir = getAppDataDir()

  const paths = {
    data: dir,
    downloads: currentSessionDir || path.join(dir, "downloads"),
    logs: getPersistentLogFile()
  }

  const selected = paths[target]
  if(!selected) throw new Error("无效的目录类型。")

  if(target === "logs") {
    fs.mkdirSync(path.dirname(selected), { recursive: true })
    if(!fs.existsSync(selected)) {
      fs.writeFileSync(selected, "", "utf8")
    }
  } else {
    fs.mkdirSync(selected, { recursive: true })
  }

  const error = await shell.openPath(selected)
  if(error) throw new Error(error)

  return true
})

// 获取当前日志文件名
ipcMain.handle("log:get-current", () => {
  return currentLogFile ? path.basename(currentLogFile) : ""
})

// 打开当前日志文件
ipcMain.handle("log:open-current", async () => {
  if(!currentLogFile || !fs.existsSync(currentLogFile)) {
    throw new Error("当前日志文件不存在。")
  }

  const error = await shell.openPath(currentLogFile)
  if(error) throw new Error(error)

  return true
})

app.whenReady().then(() => {
  try {
    initAppDataDir()
    createSessionLogFile()
  } catch(error) {
    dialog.showErrorBox(
      "初始化失败",
      `程序数据目录或日志文件创建失败：\n${String(error)}`
    )
    app.quit()
    return
  }

  createWindow()

  app.on("activate", () => {
    if(BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
})

app.on("window-all-closed", () => {
  if(process.platform !== "darwin") app.quit()
})

app.on("before-quit", () => {
  if(downloader) {
    stopping = true
    downloader.kill()
  }
})
