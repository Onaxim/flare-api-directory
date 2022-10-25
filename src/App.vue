<script setup>
import { RouterLink, RouterView } from "vue-router";
</script>

<template>
  <div class="container mx-auto">
    <div class="my-6">Flare EVM ABI Viewer</div>
  </div>

  <RouterView />

  <div id="footer" class="py-12">
    <p class="text-center">
      Open Source:
      <a href="https://github.com/Onaxim/flare-api-directory" target="_blank"
        >https://github.com/Onaxim/flare-api-directory</a
      >
    </p>
  </div>
</template>

<style scoped></style>
