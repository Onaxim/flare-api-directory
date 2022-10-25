<script setup>
import AbiList from "../components/AbiList.vue";

import abiMetaData from "../artifacts/songbird/meta.json";

import FtsoAbi from "../artifacts/songbird/Ftso.json";
import FtsoManagerAbi from "../artifacts/songbird/FtsoManager.json";
import FtsoRegistryAbi from "../artifacts/songbird/FtsoRegistry.json";
import FtsoRewardManagerAbi from "../artifacts/songbird/FtsoRewardManager.json";
import PriceSubmitterAbi from "../artifacts/songbird/PriceSubmitter.json";
import SupplyAbi from "../artifacts/songbird/Supply.json";
import VoterWhitelisterAbi from "../artifacts/songbird/VoterWhitelister.json";
import VPTokenAbi from "../artifacts/songbird/VPToken.json";
import WNatAbi from "../artifacts/songbird/WNat.json";

import documentation from "../artifacts/contracts/documentation/songbird/documentation.json";

const abiMeta = abiMetaData;
const abiList = [
  { name: "Ftso", file: FtsoAbi },
  { name: "FtsoManager", file: FtsoManagerAbi },
  { name: "FtsoRegistry", file: FtsoRegistryAbi },
  { name: "FtsoRewardManager", file: FtsoRewardManagerAbi },
  { name: "PriceSubmitter", file: PriceSubmitterAbi },
  { name: "Supply", file: SupplyAbi },
  { name: "VoterWhitelister", file: VoterWhitelisterAbi },
  { name: "VPToken", file: VPTokenAbi },
  { name: "WNat", file: WNatAbi },
];
</script>

<template>
  <AbiList
    :abiMeta="abiMeta"
    :abiList="abiList"
    :documentation="documentation"
    network="songbird"
  />
</template>
