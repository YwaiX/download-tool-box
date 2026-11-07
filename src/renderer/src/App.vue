<template>
  <div class="app-shell" :style="appBackgroundStyle">
    <main class="main-content">
      <header class="page-header">
        <div class="brand">
          <div class="brand-logo">D</div>
          <div>
            <h1>Downloader</h1>
            <p>个人下载管理器 · 顺序下载 · 自动重试</p>
          </div>
        </div>
        <div class="header-actions">
          <input
            ref="backgroundInput"
            class="hidden-file-input"
            type="file"
            accept="image/*"
            @change="handleBackgroundChange" />
          <el-select
            v-model="threadCount"
            class="thread-select"
            disabled>
            <el-option
              v-for="count in threadOptions"
              :key="count"
              :label="`${count} 线程`"
              :value="count" />
          </el-select>
          <el-button class="background-button" @click="chooseBackground">
            更换背景
          </el-button>
          <el-button v-if="backgroundUrl" class="background-button" @click="resetBackground">
            恢复默认
          </el-button>
          <div class="opacity-control">
            <span>卡片透明度</span>
            <el-slider
              v-model="cardOpacity"
              :min="0"
              :max="100"
              :step="1"
              :show-tooltip="true"
              @change="saveCardOpacity" />
            <span class="opacity-value">{{ cardOpacity }}%</span>
          </div>
          <span class="version-tag">VERSION 1.0.0</span>
        </div>
      </header>

      <Statistics
        :success="success"
        :failed="failed"
        :pending="pending"
        :status="statusText" />

      <section class="panel control-panel">
        <div class="panel-heading">
          <div>
            <h2>下载控制</h2>
            <p>按下载清单顺序执行 · 网络错误自动重试</p>
          </div>
          <div class="button-group">
            <el-button @click="openList">选择清单</el-button>
            <el-button type="primary" :disabled="running" @click="start">开始下载</el-button>
            <el-button type="danger" plain :disabled="!running" @click="stop">停止下载</el-button>
          </div>
        </div>

        <div class="path-grid">
          <span>下载清单</span><code>{{ listFile }}</code>
          <span>输出目录</span><code>{{ saveDir }}</code>
        </div>

        <div class="progress-heading">
          <b>当前任务</b>
          <span>{{ currentTask }}</span>
        </div>
        <el-progress :percentage="percent" :stroke-width="12" />
        <div class="utility-actions">
          <el-button text @click="openPath('data')">打开数据目录</el-button>
          <el-button text @click="openPath('downloads')">打开下载目录</el-button>
          <el-button text @click="openCurrentLog">打开日志文件</el-button>
        </div>
      </section>

      <LogViewer
        :logs="logs"
        :current-log-file="currentLogFile"
        @clear="logs = []"
        @open-log="openCurrentLog" />
    </main>
  </div>
</template>

<script setup>
import { ElMessage } from "element-plus"
import { computed, onMounted, onUnmounted, ref } from "vue"
import LogViewer from "./components/LogViewer.vue"
import Statistics from "./components/Statistics.vue"

const DB_NAME = "downloader-preferences"
const STORE_NAME = "assets"
const BACKGROUND_KEY = "background-image"
const OPACITY_KEY = "card-opacity"

const currentLogFile = ref("")
const running = ref(false)
const percent = ref(0)
const currentTask = ref("尚未开始")
const success = ref(0)
const failed = ref(0)
const pending = ref(0)
const logs = ref([])
const listFile = ref("DownloaderData/download.txt")
const saveDir = ref("downloads")
const backgroundInput = ref(null)
const backgroundUrl = ref("")
const cardOpacity = ref(100)
const threadOptions = [1, 2, 4, 8, 16, 32, 64]
const threadCount = ref(64)
const statusText = computed(() => running.value ? "运行中" : "空闲")
const appBackgroundStyle = computed(() => ({
  "--custom-background": backgroundUrl.value ? `url("${backgroundUrl.value}")` : "none",
  "--card-opacity": cardOpacity.value / 100
}))
let unsubscribe

async function openCurrentLog() {
  try {
    await window.downloader.openCurrentLog()
  } catch (error) {
    ElMessage.error(`打开日志文件失败：${String(error)}`)
  }
}

function openBackgroundDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1)
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME)
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

async function saveBackgroundBlob(blob) {
  const db = await openBackgroundDb()
  await new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE_NAME, "readwrite")
    transaction.objectStore(STORE_NAME).put(blob, BACKGROUND_KEY)
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(transaction.error)
    transaction.onabort = () => reject(transaction.error)
  })
  db.close()
}

async function loadBackground() {
  try {
    const db = await openBackgroundDb()
    const blob = await new Promise((resolve, reject) => {
      const request = db.transaction(STORE_NAME, "readonly")
        .objectStore(STORE_NAME).get(BACKGROUND_KEY)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
    db.close()
    if (blob) backgroundUrl.value = URL.createObjectURL(blob)
  } catch (error) {
    console.error("读取背景图片失败：", error)
  }
}

async function deleteBackground() {
  const db = await openBackgroundDb()
  await new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE_NAME, "readwrite")
    transaction.objectStore(STORE_NAME).delete(BACKGROUND_KEY)
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(transaction.error)
    transaction.onabort = () => reject(transaction.error)
  })
  db.close()
}

async function saveCardOpacity() {
  try {
    const db = await openBackgroundDb()
    await new Promise((resolve, reject) => {
      const transaction = db.transaction(STORE_NAME, "readwrite")
      transaction.objectStore(STORE_NAME).put(cardOpacity.value, OPACITY_KEY)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
    db.close()
  } catch (error) {
    ElMessage.error(`保存透明度失败：${String(error)}`)
  }
}

async function loadCardOpacity() {
  try {
    const db = await openBackgroundDb()
    const value = await new Promise((resolve, reject) => {
      const request = db.transaction(STORE_NAME, "readonly")
        .objectStore(STORE_NAME).get(OPACITY_KEY)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
    })
    db.close()
    if (typeof value === "number" && value >= 20 && value <= 100) {
      cardOpacity.value = value
    }
  } catch (error) {
    console.error("读取卡片透明度失败：", error)
  }
}

function chooseBackground() {
  backgroundInput.value?.click()
}

async function handleBackgroundChange(event) {
  const input = event.target
  const file = input.files?.[0]
  if (!file) return

  if (!file.type.startsWith("image/")) {
    ElMessage.warning("请选择图片文件。")
    input.value = ""
    return
  }

  if (file.size > 20 * 1024 * 1024) {
    ElMessage.warning("背景图片不能超过 20 MB。")
    input.value = ""
    return
  }

  try {
    await saveBackgroundBlob(file)
    if (backgroundUrl.value) URL.revokeObjectURL(backgroundUrl.value)
    backgroundUrl.value = URL.createObjectURL(file)
    ElMessage.success("背景图片已更新。")
  } catch (error) {
    ElMessage.error(`保存背景图片失败：${String(error)}`)
  } finally {
    input.value = ""
  }
}

async function resetBackground() {
  try {
    await deleteBackground()
    if (backgroundUrl.value) URL.revokeObjectURL(backgroundUrl.value)
    backgroundUrl.value = ""
    ElMessage.success("已恢复默认背景。")
  } catch (error) {
    ElMessage.error(`恢复默认背景失败：${String(error)}`)
  }
}

function toRelativeSaveDir(fullPath) {
  const parts = String(fullPath).split(/[\\/]/).filter(Boolean)
  return parts.slice(-2).join("\\")
}

function log(message) {
  logs.value.push(`[${new Date().toLocaleTimeString("zh-CN", { hour12: false })}] ${message}`)
  if (logs.value.length > 1000) logs.value.splice(0, logs.value.length - 1000)
}

async function start() {
  try {
    await window.downloader.start(64)
  } catch (error) {
    log(`启动失败：${String(error)}`)
  }
}

async function stop() {
  try {
    await window.downloader.stop()
    log("已发送停止请求。")
  } catch (error) {
    log(`停止失败：${String(error)}`)
  }
}

async function openList() {
  try {
    const selected = await window.downloader.openList()
    if (selected) {
      listFile.value = selected
      log(`已切换下载清单：${selected}`)
      ElMessage.success("下载清单切换成功。")
    }
  } catch (error) {
    log(`选择下载清单失败：${String(error)}`)
  }
}

async function openPath(target) {
  try {
    await window.downloader.openPath(target)
  } catch (error) {
    log(`打开路径失败：${String(error)}`)
  }
}

onMounted(async () => {
  void loadBackground()
  void loadCardOpacity()

  try {
    currentLogFile.value = await window.downloader.getCurrentLog()
  } catch (error) {
    log(`获取当前日志文件失败：${String(error)}`)
  }

  unsubscribe = window.downloader.onEvent((event) => {
    if (typeof event.total === "number") pending.value = event.total

    if (event.type === "started") {
      running.value = true
      percent.value = 0
      success.value = 0
      failed.value = 0
      pending.value = 0
      if (event.listFile) listFile.value = event.listFile
      if (event.saveDir) saveDir.value = toRelativeSaveDir(event.saveDir)
      log(event.message || "下载任务启动。")
    } else if (event.type === "log" || event.type === "error") {
      log(event.message || "")
    } else if (event.type === "progress") {
      currentTask.value = String(event.current ?? currentTask.value)
      success.value = Number(event.success ?? success.value)
      failed.value = Number(event.failed ?? failed.value)
      pending.value = Number(event.pending ?? pending.value)
    } else if (event.type === "file-progress") {
      if (typeof event.percent === "number") percent.value = event.percent
      if (event.current) currentTask.value = String(event.current)
    } else if (event.type === "summary") {
      log(event.message || "下载统计完成。")
    } else if (event.type === "finished") {
      running.value = false
      log(event.message || "下载进程已结束。")
    }
  })
})

onUnmounted(() => {
  unsubscribe?.()
  if (backgroundUrl.value) URL.revokeObjectURL(backgroundUrl.value)
})
</script>
