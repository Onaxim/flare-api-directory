<script setup>
import AbiList from "./AbiList.vue";

import abiMetaData from "../artifacts/flare/meta.json";

import FtsoAbi from "../artifacts/flare/Ftso.json";
import FtsoManagerAbi from "../artifacts/flare/FtsoManager.json";
import FtsoRegistryAbi from "../artifacts/flare/FtsoRegistry.json";
import FtsoRewardManagerAbi from "../artifacts/flare/FtsoRewardManager.json";
import PriceSubmitterAbi from "../artifacts/flare/PriceSubmitter.json";
import SupplyAbi from "../artifacts/flare/Supply.json";
import VoterWhitelisterAbi from "../artifacts/flare/VoterWhitelister.json";
import VPTokenAbi from "../artifacts/flare/VPToken.json";
import WNatAbi from "../artifacts/flare/WNat.json";

import documentation from "../artifacts/contracts/documentation/flare/documentation.json";

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
    network="flare"
  />
</template>
