<template>
  <section class="panel log-panel">
    <div class="panel-heading">
      <div>
        <h2>运行日志</h2>
        <p>{{ currentLogFile || "正在获取日志文件名..." }}</p>
      </div>
      <el-button text @click="$emit('clear')">清空日志</el-button>
    </div>

    <!-- 日志控制台 -->
    <OverlayScrollbarsComponent
      ref="container"
      class="log-console"
      :options="{
        overflow: {
          x: 'hidden',
          y: 'scroll'
        },
        scrollbars: {
          theme: 'os-theme-custom',
          autoHide: 'never',
          clickScroll: true,
          visibility: 'visible'
        }
      }">
      <div v-if="logs.length === 0" class="empty">
        暂无日志，点击「开始下载」启动任务。
      </div>
      <div v-for="(line, index) in logs" :key="index" class="log-line">
        {{ line }}
      </div>
    </OverlayScrollbarsComponent>
  </section>
</template>

<script setup>
import { OverlayScrollbarsComponent } from "overlayscrollbars-vue"
import { nextTick, ref, watch } from "vue"

const props = defineProps({
  logs: { type: Array, required: true },
  currentLogFile: { type: String, required: true }
})

defineEmits(["clear", "open-log"])

const container = ref(null)

watch(() => props.logs.length, async () => {
  await nextTick()
  const instance = container.value?.osInstance()
  const viewport = instance?.elements().viewport
  if (viewport) viewport.scrollTop = viewport.scrollHeight
})
</script>
