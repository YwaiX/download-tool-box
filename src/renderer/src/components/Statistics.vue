<script setup>
defineProps({
  success: { type: Number, required: true },
  failed: { type: Number, required: true },
  pending: { type: Number, required: true },
  status: { type: String, required: true }
})
</script>

<template>
  <section class="statistics">
    <div class="stat-card"><span>已完成</span><strong class="green">{{ success }}</strong><small>成功下载任务</small></div>
    <div class="stat-card"><span>失败</span><strong class="red">{{ failed }}</strong><small>需要检查的任务</small></div>
    <div class="stat-card"><span>待处理</span><strong>{{ pending }}</strong><small>等待执行或重试</small></div>
    <div class="stat-card"><span>运行状态</span><strong class="state">{{ status }}</strong><small>顺序下载模式</small></div>
  </section>
</template>
