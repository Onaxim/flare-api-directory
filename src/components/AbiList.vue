<script setup>
import { ref, onMounted, reactive, computed } from "vue";
import { useRoute } from "vue-router";
import Fuse from "fuse.js";

const route = useRoute();
const props = defineProps({
  network: {
    required: true,
  },
  abiMeta: {
    required: true,
  },
  abiList: {
    required: true,
  },
  documentation: {
    required: true,
  },
});

const state = reactive({
  selectedContract: null,
  selectedMethod: "read",
  search: "",
});

var parsedDocumentation = {};

if (props.documentation) {
  for (let contractName of Object.keys(props.documentation)) {
    let contract = props.documentation[contractName];
    parsedDocumentation[contractName] = {};
    for (let item of contract) {
      parsedDocumentation[contractName][item.method] = item.natSpec;
    }
  }
  console.log({ parsedDocumentation });
}
onMounted(() => {
  state.search = route.query.search ?? "";
  const method = route.query.method ?? state.selectedMethod;
  const item = route.query.item ?? null;

  document.getElementById(`${method}Button`).click();

  if (!item) return;
  console.log(item);
  document.getElementById(item).scrollIntoView(true);
});

import abiMeta from "../artifacts/songbird/meta.json";

const meta = props.abiMeta;
const abiList = props.abiList;
const parsedAbis = {};

for (let abi of abiList) {
  let events = abi.file.filter((item) => item.type == "event");
  let functions = abi.file.filter((item) => item.type == "function");

  let writeMethods = functions.filter(
    (item) => item.stateMutability == "nonpayable"
  );
  let readMethods = functions.filter((item) => item.stateMutability == "view");

  parsedAbis[abi.name] = { name: abi.name, events, readMethods, writeMethods };
  console.log(parsedAbis);
}
state.selectedContract = reactive(parsedAbis[abiList[0].name]);

function searchAbis() {
  console.log("SEARCH");
  if (state.search == "") return state.selectedContract;

  const options = {
    includeScore: true,
    keys: ["name"],
    threshold: 0.1,
  };

  let keys = { read: "readMethods", write: "writeMethods", events: "events" };
  let key = keys[state.selectedMethod];

  const fuse = new Fuse(state.selectedContract[key], options);
  let result = fuse.search(state.search).map((m) => m.item);
  console.log("FUSE", { [key]: result });

  return { [key]: result };
}

const searchedAbis = computed(() => {
  return searchAbis();
});

function selectContract(abi) {
  console.log({ new: abi });
  console.log({ state: state.selectedContract });
  state.selectedContract = abi;
}

function openTab(evt, tabName) {
  // Declare all variables
  var i, tabcontent, tablinks;

  // Get all elements with class="tabcontent" and hide them
  tabcontent = document.getElementsByClassName("tabcontent");
  for (i = 0; i < tabcontent.length; i++) {
    tabcontent[i].style.display = "none";
  }

  // Get all elements with class="tablinks" and remove the class "active"
  tablinks = document.getElementsByClassName("tablinks");
  for (i = 0; i < tablinks.length; i++) {
    tablinks[i].className = tablinks[i].className.replace(" active", "");
  }

  // Show the current tab, and add an "active" class to the button that opened the tab
  document.getElementById(tabName).style.display = "block";
  evt.currentTarget.className += " active";
  state.selectedMethod = tabName;
}
</script>

<template>
  <div class="flex items-center justify-between w-full">
    <div class="flex flex-col lg:flex-row w-full rounded bg-white shadow">
      <div class="w-full lg:w-2/3 p-3">
        <div>
          <p class="font-bold capitalize text-lg">
            {{ state.selectedContract.name }} ABI
          </p>
        </div>
        <div class="tab">
          <button
            class="tablinks"
            @click="openTab($event, 'read')"
            id="readButton"
          >
            Read
          </button>
          <button
            class="tablinks"
            @click="openTab($event, 'write')"
            id="writeButton"
          >
            Write
          </button>
          <button
            class="tablinks"
            @click="openTab($event, 'events')"
            id="eventsButton"
          >
            Events
          </button>
        </div>

        <div class="border border-gray-200 rounded-md text-sm p-4 mt-4">
          <p>
            <span class="font-bold text-gray-400">Adddress: </span
            ><a
              v-if="meta?.[state.selectedContract.name]?.address"
              class="text-indigo-700"
              target="_blank"
              :href="`https://${props.network}-explorer.flare.network/address/${
                meta?.[state.selectedContract.name]?.address
              }`"
              >{{ meta?.[state.selectedContract.name]?.address ?? "" }}</a
            >
            <span v-else class="text-gray-200">Please add address</span>
          </p>
          <p class="text-gray-600">
            <span class="font-bold text-gray-400">Description:</span><br />
            <span
              v-if="
                props.documentation?.[state.selectedContract.name]?.description
              "
              >{{ meta?.[state.selectedContract.name]?.description }}</span
            >
            <span v-else class="text-gray-200">Please add description</span>
          </p>
        </div>

        <!-- Search -->
        <input
          type="text"
          class="bg-gray-100 mt-4 ml-3 px-4 rounded-md py-1"
          placeholder="Search"
          v-model="state.search"
        />

        <!-- Read -->
        <div class="pb-4 tabcontent" id="read">
          <div
            class="pb-2 border-b border-gray-200 mb-2"
            v-for="read of searchedAbis.readMethods"
          >
            <p class="w-fit rounded-md bg-indigo-200 px-2 py-1" :id="read.name">
              {{ read.name }}
            </p>
            <div class="py-2">
              <p class="text-sm text-gray-600">
                {{
                  parsedDocumentation?.[state.selectedContract.name]?.[
                    read.name
                  ]?.notice ?? ""
                }}
              </p>
            </div>

            <!-- Inputs -->
            <div
              class="pl-3 border-2 border-gray-50 p-2 my-2"
              v-if="read.inputs.length"
            >
              <p class="text-gray-400 font-semibold">Inputs</p>
              <div v-for="ri of read.inputs">
                <p>{{ ri.name ? ri.name : read.name }} ({{ ri.type }})</p>
              </div>
            </div>

            <!-- Outputs -->
            <div
              class="pl-3 border-2 border-gray-50 p-2 my-2"
              v-if="read.outputs.length"
            >
              <p class="text-gray-400 font-semibold">Outputs</p>
              <div v-for="ri of read.outputs">
                <p>{{ ri.name ? ri.name : `${read.name}` }} ({{ ri.type }})</p>
              </div>
            </div>
          </div>
        </div>
        <!-- Write -->
        <div class="pb-4 tabcontent" id="write">
          <div
            class="pb-2 border-b border-gray-200 mb-2"
            v-for="write of searchedAbis.writeMethods"
          >
            <p
              class="w-fit rounded-md bg-indigo-200 px-2 py-1"
              :id="write.name"
            >
              {{ write.name }}
            </p>
            <div class="py-2">
              <p class="text-sm text-gray-600">
                {{
                  meta?.[state.selectedContract.name]?.comments?.write?.[
                    write.name
                  ] ?? ""
                }}
              </p>
            </div>
            <div
              class="pl-3 border-2 border-gray-50 p-2 my-2"
              v-if="write.inputs.length"
            >
              <p class="text-gray-400 font-semibold">Inputs</p>
              <div v-for="ri of write.inputs">
                <p>{{ ri.name ? ri.name : write.name }} ({{ ri.type }})</p>
              </div>
            </div>
            <div
              class="pl-3 border-2 border-gray-50 p-2 my-2"
              v-if="write.outputs.length"
            >
              <p class="text-gray-400 font-semibold">Outputs</p>
              <div v-for="ri of write.outputs">
                <p>{{ ri.name ? ri.name : `${write.name}` }} ({{ ri.type }})</p>
              </div>
            </div>
          </div>
        </div>

        <!-- Events -->
        <div class="pb-4 tabcontent" id="events">
          <div
            class="pb-2 border-b border-gray-200 mb-2"
            v-for="event of searchedAbis.events"
          >
            <p
              class="w-fit rounded-md bg-indigo-200 px-2 py-1"
              :id="event.name"
            >
              {{ event.name }}
            </p>
            <div class="py-2">
              <p class="text-sm text-gray-600">
                {{
                  meta?.[state.selectedContract.name]?.comments?.event?.[
                    event.name
                  ] ?? ""
                }}
              </p>
            </div>
            <div
              class="pl-3 border-2 border-gray-50 p-2 my-2"
              v-if="event.inputs.length"
            >
              <p class="text-gray-400 font-semibold">Inputs</p>
              <div v-for="ri of event.inputs">
                <p>{{ ri.name ? ri.name : event.name }} ({{ ri.type }})</p>
              </div>
            </div>
            <!-- <div
              class="pl-3 border-2 border-gray-50 p-2 my-2"
              v-if="event.outputs.length"
            >
              <p class="text-gray-400 font-semibold">Outputs</p>
              <div v-for="ri of event.outputs">
                <p>{{ ri.name ? ri.name : event.name }} ({{ ri.type }})</p>
              </div>
            </div> -->
          </div>
        </div>
      </div>
      <div class="w-1/2 p-3">
        <p class="font-bold">Contracts</p>
        <div v-for="abi of parsedAbis">
          <button @click="selectContract(abi)">
            {{ abi.name }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
<style scoped>
.tab {
  overflow: hidden;
  background-color: #f1f1f1;
}

/* Style the buttons that are used to open the tab content */
.tab button {
  background-color: inherit;
  float: left;
  border: none;
  outline: none;
  cursor: pointer;
  padding: 14px 16px;
  transition: 0.3s;
}

/* Change background color of buttons on hover */
.tab button:hover {
  background-color: #ddd;
}

/* Create an active/current tablink class */
.tab button.active {
  background-color: #ccc;
}

/* Style the tab content */
.tabcontent {
  display: none;
  padding: 16px 12px;
  border-top: none;
}
</style>
