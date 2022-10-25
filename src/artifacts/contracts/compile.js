const fs = require("fs");
const path = require("path");
const { DownloaderHelper } = require("node-downloader-helper");

const repositoryUrl =
  "https://gitlab.com/flarenetwork/flare-smart-contracts/-/raw";
const flareBranch = "flare_network_deployed_code";
const songbirdBranch = "songbird_network_deployed_code";

const contractsMap = {
  flare: {
    FtsoRegistry: `${repositoryUrl}/${flareBranch}/contracts/utils/implementation/FtsoRegistry.sol`,
    VoterWhitelister: `${repositoryUrl}/${flareBranch}/contracts/utils/implementation/VoterWhitelister.sol`,
    ValidatorRegistry: `${repositoryUrl}/${flareBranch}/contracts/utils/implementation/ValidatorRegistry.sol`,
    Ftso: `${repositoryUrl}/${flareBranch}/contracts/ftso/implementation/Ftso.sol`,
    FtsoManager: `${repositoryUrl}/${flareBranch}/contracts/ftso/implementation/FtsoManager.sol`,
    StateConnector: `${repositoryUrl}/${flareBranch}/contracts/genesis/implementation/StateConnector.sol`,
    PriceSubmitter: `${repositoryUrl}/${flareBranch}/contracts/genesis/implementation/PriceSubmitter.sol`,
    Supply: `${repositoryUrl}/${flareBranch}/contracts/inflation/implementation/Supply.sol`,
    Inflation: `${repositoryUrl}/${flareBranch}/contracts/inflation/implementation/Inflation.sol`,
    InflationAllocation: `${repositoryUrl}/${flareBranch}/contracts/inflation/implementation/InflationAllocation.sol`,
    DelegationAccountManager: `${repositoryUrl}/${flareBranch}/contracts/personalDelegation/implementation/DelegationAccountManager.sol`,
    WNat: `${repositoryUrl}/${flareBranch}/contracts/token/implementation/WNat.sol`,
    IncentivePoolAllocation: `${repositoryUrl}/${flareBranch}/contracts/tokenPools/implementation/IncentivePoolAllocation.sol`,
    IncentivePool: `${repositoryUrl}/${flareBranch}/contracts/tokenPools/implementation/IncentivePool.sol`,
    FtsoRewardManager: `${repositoryUrl}/${flareBranch}/contracts/tokenPools/implementation/FtsoRewardManager.sol`,
  },
  songbird: {
    FtsoRegistry: `${repositoryUrl}/${songbirdBranch}/contracts/utils/implementation/FtsoRegistry.sol`,
    VoterWhitelister: `${repositoryUrl}/${songbirdBranch}/contracts/utils/implementation/VoterWhitelister.sol`,
    Ftso: `${repositoryUrl}/${songbirdBranch}/contracts/ftso/implementation/Ftso.sol`,
    FtsoManager: `${repositoryUrl}/${songbirdBranch}/contracts/ftso/implementation/FtsoManager.sol`,
    StateConnector: `${repositoryUrl}/${songbirdBranch}/contracts/genesis/implementation/StateConnector.sol`,
    PriceSubmitter: `${repositoryUrl}/${songbirdBranch}/contracts/genesis/implementation/PriceSubmitter.sol`,
    Supply: `${repositoryUrl}/${songbirdBranch}/contracts/inflation/implementation/Supply.sol`,
    Inflation: `${repositoryUrl}/${songbirdBranch}/contracts/inflation/implementation/Inflation.sol`,
    WNat: `${repositoryUrl}/${songbirdBranch}/contracts/token/implementation/WNat.sol`,
    FtsoRewardManager: `${repositoryUrl}/${songbirdBranch}/contracts/tokenPools/implementation/FtsoRewardManager.sol`,
  },
};

// Downloads .sol implementation contracts from official Flare Foundation repository (based on above map)
function downloadManager(network) {
  const downloadDirectory = `${__dirname}/implementation/${network}`;

  createDirectory(`${__dirname}/implementation/`);
  createDirectory(downloadDirectory);

  const deleteIfExists = (name) => {
    let filePath = `${downloadDirectory}/${name}`;
    fs.exists(filePath, function (exists) {
      if (exists) {
        console.log(`Deleting ${filePath}`);
        fs.unlinkSync(filePath);
      }
    });
  };

  for (let contract of Object.keys(contractsMap[network])) {
    deleteIfExists(`${contract}.sol`);

    let downloadUrl = contractsMap[network][contract];
    const dl = new DownloaderHelper(downloadUrl, downloadDirectory);
    dl.on("end", () => console.log(`${contract} download complete.`));
    dl.on("error", (err) => console.log(`${contract} download failed.`, err));
    dl.start();
  }
}

function readFile(file) {
  try {
    const data = fs.readFileSync(file, "utf8");
    return data;
  } catch (err) {
    console.error(err);
  }
}

function createDirectory(directory) {
  // If directory not exists, creates
  if (!fs.existsSync(directory)) {
    fs.mkdirSync(directory);
  }
}

function createJson(path, data) {
  fs.writeFileSync(path, JSON.stringify(data));
}

function getLine(filename, line_no, callback) {
  var data = fs.readFileSync(filename, "utf8");
  var lines = data.split("\n");

  if (+line_no > lines.length) {
    throw new Error("File end reached without finding line");
  }

  callback(null, lines[+line_no]);
}

function parseContract(file, outputPath) {
  let contractCode = readFile(file);
  const Comments = require("parse-comments");
  const comments = new Comments();
  const ast = comments.parse(contractCode);

  let document = [];
  for (let com of ast) {
    let lineNumber = com.loc.end.line;
    getLine(file, lineNumber, function (err, line) {
      // Find the method name between "function " and the parameter brackets "(" - ie. "function --> balance <-- (address) ..."
      let regex = /(?<=function )(.*)(?=\()/gm;
      // let foundFunc = line.match(pattern);

      let result = regex.exec(line);
      if (!result) return;
      let method = result[0].split("(")[0];
      let natSpec = { return: [] };

      for (let tag of com.tags) {
        if (tag.title == "notice") {
          natSpec.notice = tag.description;
        }

        if (tag.title == "dev") {
          natSpec.dec = tag.description;
        }
        if (tag.title == "param") {
          natSpec.param = { [tag.name]: tag.description };
        }
        if (tag.title == "return") {
          let variable = tag.description.split(" ", 1)[0];
          let descripter = tag.description.substring(
            tag.description.indexOf(" ")
          );

          natSpec.return.push([variable, descripter]);
        }
      }
      document.push({ method, natSpec });
    });
  }

  createJson(outputPath + ".json", document);
  return document;
}

function parseContracts(network) {
  const downloadDirectory = `${__dirname}/implementation/${network}/`;
  const contractNames = Object.keys(contractsMap[network]);
  const outputPath = `${__dirname}/documentation/${network}/`;

  createDirectory(`${__dirname}/documentation/`);
  createDirectory(`${__dirname}/documentation/${network}`);

  // Test single output
  // let file = downloadDirectory + contractNames[0] + ".sol";
  // parseContract(file, outputPath + contractNames[0]);

  let fullDocumentation = {};
  for (let contractName of contractNames) {
    console.log(`Processing ${contractName}`);
    let file = downloadDirectory + contractName + ".sol";
    let document = parseContract(file, outputPath + contractName);
    fullDocumentation[contractName] = document;
  }
  createJson(outputPath + "documentation.json", fullDocumentation);
  console.log(
    `\nFull documentation output to: ${outputPath + "documentation.json"}`
  );
  console.log(`\n ==== Processing Complete ==== \n`);
}

// Use these methods to download contracts
// downloadManager("flare");
// downloadManager("songbird");

// Run after downloading contract
parseContracts("songbird");
parseContracts("flare");
