<script setup>
defineProps({
  active: { type: String, required: true }
})
defineEmits(["change"])
</script>

<template>
  <aside class="sidebar">
    <div class="brand">
      <div class="brand-logo">D</div>
      <div><strong>Downloader</strong><small>桌面下载管理器</small></div>
    </div>
    <nav>
      <button :class="['nav-item', { active: active === 'tasks' }]" @click="$emit('change', 'tasks')">
        <span class="nav-icon">▦</span>下载任务
      </button>
      <button :class="['nav-item', { active: active === 'settings' }]" @click="$emit('change', 'settings')">
        <span class="nav-icon">⚙</span>设置
      </button>
    </nav>
  </aside>
</template>
