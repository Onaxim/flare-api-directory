<script setup>
import { onMounted, reactive } from "vue";
import SongbirdAbiList from "../components/SongbirdAbiList.vue";
import FlareAbiList from "../components/FlareAbiList.vue";

const state = reactive({
  network: "flare",
});
</script>

<template>
  <main>
    <div class="container mx-auto">
      <select v-model="state.network">
        <option value="flare">Flare</option>
        <option value="songbird">Songbird</option>
      </select>
      <SongbirdAbiList v-if="state.network == 'songbird'" />
      <FlareAbiList v-if="state.network == 'flare'" />
    </div>
  </main>
</template>
