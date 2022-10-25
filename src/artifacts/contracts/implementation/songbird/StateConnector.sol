// (c) 2021, Flare Networks Limited. All rights reserved.
// Please see the file LICENSE for licensing terms.

// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

contract StateConnector {

    enum DataAvailabilityPeriodFinalityType {
        PROPOSED,
        LOW_FINALISED_CLAIM_PERIOD_INDEX,
        REWARDED,
        BANNED
    }

//====================================================================
// Data Structures
//====================================================================

    struct Chain {
        bool        exists;
        uint64      genesisLedger;
        // Range of ledgers below finalisedLedgerIndex that can be searched when proving a payment
        uint64      ledgerHistorySize;
        // Number of ledgers in a dataAvailabilityPeriod
        uint16      dataAvailabilityPeriodLength; 
        // Number of confirmations required to consider this dataAvailabilityPeriod finalised
        uint16      numConfirmations; 
        uint64      finalisedDataAvailabilityPeriodIndex;
        uint64      finalisedLedgerIndex;
        uint256     finalisedTimestamp;
        uint256     timeDiffExpected;
        uint256     timeDiffAvg;
    }

    struct HashExists {
        bool        exists;
        bytes32     dataAvailabilityPeriodHash;
        bytes32     commitHash;
        uint256     commitTime;
        uint256     permittedRevealTime;
        bytes32     revealHash;
        uint64      index;
        uint64      indexSearchRegion;
        bool        proven;
        address     provenBy;
    }

    address internal constant GENESIS_COINBASE = address(0x0100000000000000000000000000000000000000);
    bool public initialised;
    uint32 public numChains;
    uint256 public initialiseTime;
    uint256 public commitRevealLowerBound;
    uint256 public commitRevealUpperBound;
    uint64 public rewardPeriodTimespan;

    // Chain ID mapping to Chain struct
    mapping(uint32 => Chain) public chains;
    // msg.sender => Location hash => dataAvailabilityPeriod
    mapping(address => mapping(bytes32 => HashExists)) public proposedDataAvailabilityProofs;
    // Location hash => dataAvailabilityPeriod
    mapping(bytes32 => HashExists) public finalisedDataAvailabilityPeriods;
    // Location hash => ledger => paymentProof
    mapping(bytes32 => mapping(uint64 => HashExists)) public proposedPaymentProofs;
    // Location hash => ledger => nonPaymentProof
    mapping(bytes32 => mapping(uint64 => HashExists)) public proposedNonPaymentProofs;
    // Finalised payment hashes
    mapping(bytes32 => HashExists) public finalisedPayments;
    // Mapping of how many dataAvailabilityPeriods an address has successfully mined
    mapping(address => mapping(uint256 => uint64)) public dataAvailabilityPeriodsMined;
    // Mapping of how many dataAvailabilityPeriods were successfully mined
    mapping(uint256 => uint64) public totalDataAvailabilityPeriodsMined;
    // Data avail provers are banned temporarily for submitting chainTipHash values that do not ultimately
    // become accepted, if their submitted chainTipHash value is accepted then they will earn a reward
    mapping(address => uint256) public senderBannedUntil;

//====================================================================
// Events
//====================================================================

    event DataAvailabilityPeriodFinalityProved(uint32 chainId, uint64 ledger, DataAvailabilityPeriodFinalityType finType, address sender);
    event PaymentFinalityProved(uint32 chainId, uint64 ledger, string txId, bytes32 paymentHash, address sender);
    event PaymentFinalityDisproved(uint32 chainId, uint64 ledger, string txId, bytes32 paymentHash, address sender);

//====================================================================
// Modifiers
//====================================================================

    modifier isInitialised() {
        require(initialised, "state connector is not initialised, run initialiseChains()");
        _;
    }
    
    modifier chainExists(uint32 chainId) {
        require(chains[chainId].exists, "chainId does not exist");
        _;
    }

    modifier senderNotBanned() {
        require(block.timestamp > senderBannedUntil[msg.sender], 
            "msg.sender is currently banned for sending an unaccepted chainTipHash");
        _;
    }

//====================================================================
// Constructor for genesis-deployed code
//====================================================================

    constructor() {
    }

    function initialiseChains() external returns (bool success) {
        require(!initialised, "initialised != false");
        chains[0] = Chain(true, 689300, 0, 1, 4, 0, 689300, block.timestamp, 900, 30); //BTC
        chains[1] = Chain(true, 2086110, 0, 1, 12, 0, 2086110, block.timestamp, 150, 30); //LTC
        chains[2] = Chain(true, 3768500, 0, 2, 40, 0, 3768500, block.timestamp, 120, 30); //DOGE
        chains[3] = Chain(true, 62880000, 0, 30, 1, 0, 62880000, block.timestamp, 120, 30); //XRP
        chains[4] = Chain(true, 16169600, 0, 26, 1, 0, 16169600, block.timestamp, 120, 30); //ALGO
        numChains = 5;
        commitRevealLowerBound = 30;
        commitRevealUpperBound = 1 days;
        rewardPeriodTimespan = 7 days; //604800
        initialiseTime = block.timestamp;
        initialised = true;
        return true;
    }

//====================================================================
// Functions
//====================================================================  

    function proveDataAvailabilityPeriodFinality(
        uint32 chainId,
        uint64 ledger,
        bytes32 dataAvailabilityPeriodHash,
        bytes32 chainTipHash
    ) external isInitialised chainExists(chainId) senderNotBanned returns (
        uint32 _chainId,
        uint64 _ledger,
        uint16 _numConfirmations,
        bytes32 _dataAvailabilityPeriodHash
    ) {
        require(dataAvailabilityPeriodHash > 0x0, "dataAvailabilityPeriodHash == 0x0");
        require(chainTipHash > 0x0, "chainTipHash == 0x0");
        require(chains[chainId].numConfirmations > 0, "chains[chainId].numConfirmations > 0");
        require(block.coinbase == msg.sender || block.coinbase == GENESIS_COINBASE, "invalid block.coinbase value");
        require(ledger == chains[chainId].finalisedLedgerIndex + chains[chainId].dataAvailabilityPeriodLength, "invalid ledger");
        require(block.timestamp > chains[chainId].finalisedTimestamp, 
            "block.timestamp <= chains[chainId].finalisedTimestamp");
        if (2 * chains[chainId].timeDiffAvg < chains[chainId].timeDiffExpected) {
            require(3 * (block.timestamp - chains[chainId].finalisedTimestamp) >= 2 * chains[chainId].timeDiffAvg, 
                "not enough time elapsed since prior finality");
        } else {
            require(block.timestamp - chains[chainId].finalisedTimestamp + 15 >= chains[chainId].timeDiffAvg, 
                "not enough time elapsed since prior finality");
        }

        bytes32 locationHash = keccak256(abi.encodePacked(chainId, chains[chainId].finalisedDataAvailabilityPeriodIndex));
        require(!finalisedDataAvailabilityPeriods[locationHash].proven, "locationHash already finalised");

        if (chains[chainId].finalisedDataAvailabilityPeriodIndex > 0) {
            bytes32 prevLocationHash = keccak256(abi.encodePacked(
                    chainId, chains[chainId].finalisedDataAvailabilityPeriodIndex - 1));
            require(finalisedDataAvailabilityPeriods[prevLocationHash].proven, "previous dataAvailabilityPeriod not yet finalised");
        }
        uint16 numConfirmations;
        if (proposedDataAvailabilityProofs[msg.sender][locationHash].exists) {
            require(block.timestamp >= proposedDataAvailabilityProofs[msg.sender][locationHash].permittedRevealTime, 
                "block.timestamp < proposedDataAvailabilityProofs[msg.sender][locationHash].permittedRevealTime");
            require(proposedDataAvailabilityProofs[msg.sender][locationHash].commitHash == 
                keccak256(abi.encodePacked(msg.sender, chainTipHash)), 
                "invalid chainTipHash");
            require(proposedDataAvailabilityProofs[msg.sender][locationHash].commitTime + commitRevealUpperBound > block.timestamp,
                "reveal is too late");
        } else if (block.coinbase != msg.sender && block.coinbase == GENESIS_COINBASE) {
            numConfirmations = chains[chainId].numConfirmations;
        }

        if (block.coinbase == msg.sender && block.coinbase != GENESIS_COINBASE) {
            if (!proposedDataAvailabilityProofs[msg.sender][locationHash].exists) {
                uint256 permittedRevealTime = chains[chainId].timeDiffAvg / 2;
                if (permittedRevealTime < commitRevealLowerBound) {
                    permittedRevealTime = commitRevealLowerBound;
                }
                proposedDataAvailabilityProofs[msg.sender][locationHash] = HashExists(
                    true,
                    dataAvailabilityPeriodHash,
                    chainTipHash,
                    block.timestamp,
                    block.timestamp + permittedRevealTime,
                    0x0,
                    ledger,
                    0,
                    false,
                    address(0x0)
                );
                emit DataAvailabilityPeriodFinalityProved(chainId, ledger, DataAvailabilityPeriodFinalityType.PROPOSED, msg.sender);
            } else {
                // Node checked dataAvailabilityPeriodHash, and it was valid
                // Now determine whether to reward or ban the sender of the suggested chainTipHash
                // from 'numConfirmations' dataAvailabilityPeriodIndexes ago
                if (chains[chainId].finalisedDataAvailabilityPeriodIndex > chains[chainId].numConfirmations) {
                    bytes32 prevLocationHash = keccak256(abi.encodePacked(
                        chainId, chains[chainId].finalisedDataAvailabilityPeriodIndex - chains[chainId].numConfirmations));
                    if (finalisedDataAvailabilityPeriods[prevLocationHash].revealHash == dataAvailabilityPeriodHash) {
                        // Reward
                        uint256 currentRewardPeriod = getRewardPeriod();
                        dataAvailabilityPeriodsMined[finalisedDataAvailabilityPeriods[prevLocationHash].provenBy][currentRewardPeriod]
                            += 1;
                        totalDataAvailabilityPeriodsMined[currentRewardPeriod] += 1;
                        emit DataAvailabilityPeriodFinalityProved(chainId, ledger, DataAvailabilityPeriodFinalityType.REWARDED, 
                            finalisedDataAvailabilityPeriods[prevLocationHash].provenBy);
                    } else {
                        // Temporarily ban
                        senderBannedUntil[finalisedDataAvailabilityPeriods[prevLocationHash].provenBy] = 
                            block.timestamp + chains[chainId].numConfirmations * chains[chainId].timeDiffExpected;
                        emit DataAvailabilityPeriodFinalityProved(chainId, ledger, DataAvailabilityPeriodFinalityType.BANNED, 
                            finalisedDataAvailabilityPeriods[prevLocationHash].provenBy);
                    }
                } else {
                    // this is only true for the first few method calls 
                    emit DataAvailabilityPeriodFinalityProved(chainId, ledger, 
                        DataAvailabilityPeriodFinalityType.LOW_FINALISED_CLAIM_PERIOD_INDEX, msg.sender);
                }

                finalisedDataAvailabilityPeriods[locationHash] = HashExists(
                    true,
                    dataAvailabilityPeriodHash,
                    0x0,
                    proposedDataAvailabilityProofs[msg.sender][locationHash].commitTime,
                    block.timestamp,
                    chainTipHash,
                    ledger,
                    0,
                    true,
                    msg.sender
                );

                chains[chainId].finalisedDataAvailabilityPeriodIndex += 1;
                chains[chainId].finalisedLedgerIndex = ledger;

                uint256 timeDiffAvgUpdate = (proposedDataAvailabilityProofs[msg.sender][locationHash].commitTime -
                    chains[chainId].finalisedTimestamp + chains[chainId].timeDiffAvg) / 2;
                if (timeDiffAvgUpdate > 2 * chains[chainId].timeDiffExpected) {
                    chains[chainId].timeDiffAvg = 2 * chains[chainId].timeDiffExpected;
                } else {
                    chains[chainId].timeDiffAvg = timeDiffAvgUpdate;
                }

                chains[chainId].finalisedTimestamp = proposedDataAvailabilityProofs[msg.sender][locationHash].commitTime;
            }
        }
        return (chainId, ledger - 1, numConfirmations, dataAvailabilityPeriodHash);
    }

    // If ledger == payment's ledger -> return true
    function provePaymentFinality(
        uint32 chainId,
        bytes32 paymentHash,
        uint64 ledger,
        string memory txId
    ) external isInitialised chainExists(chainId) returns (
        uint32 _chainId,
        uint64 _ledger,
        uint64 _finalisedLedgerIndex,
        bytes32 _paymentHash,
        string memory _txId
    ) {
        require(paymentHash > 0x0, "paymentHash == 0x0");
        require(chains[chainId].finalisedLedgerIndex > 0, "chains[chainId].finalisedLedgerIndex == 0");
        require(block.coinbase == msg.sender || block.coinbase == GENESIS_COINBASE, "invalid block.coinbase value");
        bytes32 locationHash = keccak256(abi.encodePacked(chainId, paymentHash));
        require(!finalisedPayments[locationHash].proven, "payment already proven");
        require(ledger < chains[chainId].finalisedLedgerIndex, "ledger >= chains[chainId].finalisedLedgerIndex");

        uint64 indexSearchRegion = chains[chainId].genesisLedger;
        if (chains[chainId].ledgerHistorySize > 0) {
            require(chains[chainId].finalisedLedgerIndex - chains[chainId].genesisLedger > 
                chains[chainId].ledgerHistorySize, 
                "finalisedLedgerIndex - genesisLedger <= ledgerHistorySize");
            indexSearchRegion = chains[chainId].finalisedLedgerIndex - chains[chainId].ledgerHistorySize;
        }
        require(ledger >= indexSearchRegion, "ledger < indexSearchRegion");
        
        uint64 finalisedLedgerIndex;
        if (proposedPaymentProofs[locationHash][ledger].exists) {
            require(block.timestamp >= proposedPaymentProofs[locationHash][ledger].permittedRevealTime, 
                "block.timestamp < proposedPaymentProofs[locationHash].permittedRevealTime");
            require(proposedPaymentProofs[locationHash][ledger].revealHash == paymentHash, 
                "invalid paymentHash");
            require(proposedPaymentProofs[locationHash][ledger].commitTime + commitRevealUpperBound > block.timestamp,
                "reveal is too late");
        } else if (block.coinbase != msg.sender && block.coinbase == GENESIS_COINBASE) {
            finalisedLedgerIndex = chains[chainId].finalisedLedgerIndex;
        }

        if (block.coinbase == msg.sender && block.coinbase != GENESIS_COINBASE) {
            if (!proposedPaymentProofs[locationHash][ledger].exists) {
                proposedPaymentProofs[locationHash][ledger] = HashExists(
                    true, 
                    0x0, 
                    0x0,
                    block.timestamp, 
                    block.timestamp + commitRevealLowerBound, 
                    paymentHash, 
                    ledger, 
                    indexSearchRegion, 
                    false,
                    msg.sender
                );
            } else {
                finalisedPayments[locationHash] = HashExists(
                    true, 
                    0x0, 
                    0x0,
                    0, 
                    block.timestamp, 
                    paymentHash, 
                    ledger, 
                    indexSearchRegion, 
                    true,
                    msg.sender
                );
                emit PaymentFinalityProved(chainId, ledger, txId, paymentHash, msg.sender);
            }
        }
        return (chainId, ledger, finalisedLedgerIndex, paymentHash, txId);
    }

    // If ledger < payment's ledger or payment does not exist within data-available region -> return true
    function disprovePaymentFinality(
        uint32 chainId,
        bytes32 paymentHash,
        uint64 ledger,
        string memory txId
    ) external isInitialised chainExists(chainId) returns (
        uint32 _chainId,
        uint64 _ledger,
        uint64 _finalisedLedgerIndex,
        bytes32 _paymentHash,
        string memory _txId
    ) {
        require(paymentHash > 0x0, "paymentHash == 0x0");
        require(chains[chainId].finalisedLedgerIndex > 0, "chains[chainId].finalisedLedgerIndex == 0");
        require(block.coinbase == msg.sender || block.coinbase == GENESIS_COINBASE, "invalid block.coinbase value");
        bytes32 locationHash = keccak256(abi.encodePacked(chainId, paymentHash));
        require(!finalisedPayments[locationHash].proven, "txId already proven");
        require(finalisedPayments[locationHash].index < ledger,
            "finalisedPayments[locationHash].index >= ledger");
        require(ledger < chains[chainId].finalisedLedgerIndex, "ledger >= chains[chainId].finalisedLedgerIndex");

        uint64 indexSearchRegion = chains[chainId].genesisLedger;
        if (chains[chainId].ledgerHistorySize > 0) {
            require(chains[chainId].finalisedLedgerIndex - chains[chainId].genesisLedger > 
                chains[chainId].ledgerHistorySize,
                "finalisedLedgerIndex - genesisLedger <= ledgerHistorySize");
            indexSearchRegion = chains[chainId].finalisedLedgerIndex - chains[chainId].ledgerHistorySize;
        }
        require(ledger >= indexSearchRegion, "ledger < indexSearchRegion");

        uint64 finalisedLedgerIndex;
        if (proposedNonPaymentProofs[locationHash][ledger].exists) {
            require(block.timestamp >= proposedNonPaymentProofs[locationHash][ledger].permittedRevealTime, 
                "block.timestamp < proposedNonPaymentProofs[locationHash][ledger].permittedRevealTime");
            require(proposedNonPaymentProofs[locationHash][ledger].revealHash == paymentHash, 
                "invalid paymentHash");
            require(proposedNonPaymentProofs[locationHash][ledger].commitTime + commitRevealUpperBound > block.timestamp,
                "reveal is too late");
        } else if (block.coinbase != msg.sender && block.coinbase == GENESIS_COINBASE) {
            finalisedLedgerIndex = chains[chainId].finalisedLedgerIndex;
        }

        if (block.coinbase == msg.sender && block.coinbase != GENESIS_COINBASE) {
            if (!proposedNonPaymentProofs[locationHash][ledger].exists) {
                proposedNonPaymentProofs[locationHash][ledger] = HashExists(
                    true, 
                    0x0, 
                    0x0,
                    block.timestamp, 
                    block.timestamp + commitRevealLowerBound, 
                    paymentHash, 
                    ledger, 
                    indexSearchRegion, 
                    false,
                    msg.sender
                );
            } else {
                finalisedPayments[locationHash] = HashExists(
                    true, 
                    0x0, 
                    0x0,
                    0, 
                    block.timestamp, 
                    paymentHash, 
                    ledger, 
                    indexSearchRegion, 
                    false,
                    msg.sender
                );
                emit PaymentFinalityProved(chainId, ledger, txId, paymentHash, msg.sender);
            }
        }
        return (chainId, ledger, finalisedLedgerIndex, paymentHash, txId);
    }
    
    function getDataAvailabilityPeriodsMined(
        address miner,
        uint256 rewardSchedule
    ) external view isInitialised returns (uint64 numMined) {
        return dataAvailabilityPeriodsMined[miner][rewardSchedule];
    }

    function getTotalDataAvailabilityPeriodsMined(
        uint256 rewardSchedule
    ) external view isInitialised returns (uint64 numMined) {
        return totalDataAvailabilityPeriodsMined[rewardSchedule];
    }

    function getLatestIndex(uint32 chainId) external view isInitialised chainExists(chainId) returns (
        uint64 genesisLedger,
        uint64 finalisedDataAvailabilityPeriodIndex,
        uint16 dataAvailabilityPeriodLength,
        uint64 finalisedLedgerIndex,
        uint256 finalisedTimestamp,
        uint256 timeDiffAvg
    ) {
        finalisedTimestamp = chains[chainId].finalisedTimestamp;
        timeDiffAvg = chains[chainId].timeDiffAvg;

        bytes32 locationHash = keccak256(abi.encodePacked(chainId, chains[chainId].finalisedDataAvailabilityPeriodIndex));
        if (proposedDataAvailabilityProofs[msg.sender][locationHash].exists) {
            finalisedTimestamp = 0;
            timeDiffAvg = proposedDataAvailabilityProofs[msg.sender][locationHash].permittedRevealTime;
        }

        return (
            chains[chainId].genesisLedger,
            chains[chainId].finalisedDataAvailabilityPeriodIndex,
            chains[chainId].dataAvailabilityPeriodLength,
            chains[chainId].finalisedLedgerIndex,
            finalisedTimestamp,
            timeDiffAvg
        );
    }

    function getDataAvailabilityPeriodIndexFinality(
        uint32 chainId,
        uint64 dataAvailabilityPeriodIndex
    ) external view isInitialised chainExists(chainId) returns (bool finality) {
        bytes32 locationHash = keccak256(abi.encodePacked(chainId, dataAvailabilityPeriodIndex));
        return (finalisedDataAvailabilityPeriods[locationHash].exists);
    }

    function getPaymentFinality(
        uint32 chainId,
        bytes32 txId,
        bytes32 destinationHash,
        uint64 amount,
        bytes32 currencyHash
    ) external view isInitialised chainExists(chainId) returns (
        uint64 ledger,
        uint64 indexSearchRegion,
        bool finality
    ) {
        bytes32 paymentHash = keccak256(abi.encodePacked(
            txId,
            destinationHash,
            keccak256(abi.encode(amount)),
            currencyHash));
        bytes32 locationHash = keccak256(abi.encodePacked(chainId, paymentHash));
        require(finalisedPayments[locationHash].exists, "payment does not exist");
        require(finalisedPayments[locationHash].revealHash == paymentHash, "invalid paymentHash");

        return (
            finalisedPayments[locationHash].index,
            finalisedPayments[locationHash].indexSearchRegion,
            finalisedPayments[locationHash].proven
        );
    }

    function getRewardPeriod() public view isInitialised returns (uint256 rewardSchedule) {
        require(block.timestamp > initialiseTime, "block.timestamp <= initialiseTime");
        return (block.timestamp - initialiseTime) / rewardPeriodTimespan;
    }
    
}
