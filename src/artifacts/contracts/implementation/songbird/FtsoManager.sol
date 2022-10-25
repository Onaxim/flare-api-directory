// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "../interface/IIFtsoManager.sol";
import "../interface/IIFtso.sol";
import "../lib/FtsoManagerSettings.sol";
import "../../genesis/implementation/FlareDaemon.sol";
import "../../genesis/interface/IFlareDaemonize.sol";
import "../../genesis/interface/IIPriceSubmitter.sol";
import "../../governance/implementation/Governed.sol";
import "../../inflation/interface/IISupply.sol";
import "../../tokenPools/interface/IIFtsoRewardManager.sol";
import "../../token/implementation/CleanupBlockNumberManager.sol";
import "../../utils/implementation/GovernedAndFlareDaemonized.sol";
import "../../utils/implementation/RevertErrorTracking.sol";
import "../../utils/interface/IIFtsoRegistry.sol";
import "../../utils/interface/IIVoterWhitelister.sol";


/**
 * FtsoManager is in charge of:
 * - defining reward epochs (few days)
 * - per reward epoch choose a single block that represents vote power of this epoch.
 * - keep track of all FTSO contracts
 * - per price epoch (few minutes)
 *    - randomly choose one FTSO for rewarding.
 *    - trigger finalize price reveal epoch
 *    - determines addresses and reward weights and triggers rewardDistribution
 */    
contract FtsoManager is IIFtsoManager, GovernedAndFlareDaemonized, IFlareDaemonize, RevertErrorTracking {
    using FtsoManagerSettings for FtsoManagerSettings.State;

    struct RewardEpochData {
        uint256 votepowerBlock;
        uint256 startBlock;
        uint256 startTimestamp;
    }

    uint256 public constant MAX_TRUSTED_ADDRESSES_LENGTH = 5;

    string internal constant ERR_FIRST_EPOCH_START_TS_IN_FUTURE = "First epoch start timestamp in future";
    string internal constant ERR_REWARD_EPOCH_DURATION_ZERO = "Reward epoch 0";
    string internal constant ERR_REWARD_EPOCH_START_TOO_SOON = "Reward epoch start too soon";
    string internal constant ERR_REWARD_EPOCH_NOT_INITIALIZED = "Reward epoch not initialized yet";
    string internal constant ERR_REWARD_EPOCH_START_CONDITION_INVALID = "Reward epoch start condition invalid";
    string internal constant ERR_REWARD_EPOCH_DURATION_CONDITION_INVALID = "Reward epoch duration condition invalid";
    string internal constant ERR_PRICE_EPOCH_DURATION_ZERO = "Price epoch 0";
    string internal constant ERR_VOTE_POWER_INTERVAL_FRACTION_ZERO = "Vote power interval fraction 0";
    string internal constant ERR_REVEAL_PRICE_EPOCH_DURATION_ZERO = "Reveal price epoch 0";
    string internal constant ERR_REVEAL_PRICE_EPOCH_TOO_LONG = "Reveal price epoch too long";
    string internal constant ERR_GOV_PARAMS_NOT_INIT_FOR_FTSOS = "Gov. params not initialized";
    string internal constant ERR_GOV_PARAMS_INVALID = "Gov. params invalid";
    string internal constant ERR_ASSET_FTSO_NOT_MANAGED = "Asset FTSO not managed by ftso manager";
    string internal constant ERR_NOT_FOUND = "Not found";
    string internal constant ERR_ALREADY_ADDED = "Already added";
    string internal constant ERR_FTSO_ASSET_FTSO_ZERO = "Asset ftsos list empty";
    string internal constant ERR_FTSO_EQUALS_ASSET_FTSO = "ftso equals asset ftso";
    string internal constant ERR_FTSO_SYMBOLS_MUST_MATCH = "FTSO symbols must match";
    string internal constant ERR_REWARD_EXPIRY_OFFSET_INVALID = "Reward expiry invalid";
    string internal constant ERR_MAX_TRUSTED_ADDRESSES_LENGTH_EXCEEDED = "Max trusted addresses length exceeded";
    string internal constant ERR_CLOSING_EXPIRED_REWARD_EPOCH_FAIL = "Unknown fail when closing expired";
    string internal constant ERR_SET_CLEANUP_BLOCK_FAIL = "unknown fail. setting cleanup block";
    string internal constant ERR_PRICE_EPOCH_FINALIZE_FAIL = "unknown fail. finalize price epoch";
    string internal constant ERR_DISTRIBUTE_REWARD_FAIL = "unknown fail. distribute rewards";
    string internal constant ERR_FALLBACK_FINALIZE_FAIL = "unknown fail. fallback finalize price epoch";
    string internal constant ERR_INIT_EPOCH_REVEAL_FAIL = "unknown fail. init epoch for reveal";
    string internal constant ERR_FALLBACK_INIT_EPOCH_REVEAL_FAIL = "unknown fail. fallback init epoch for reveal";

    bool public override active;
    RewardEpochData[] public rewardEpochs;
    address public lastRewardedFtsoAddress;

    FtsoManagerSettings.State public settings;

    // price epoch data
    uint256 immutable internal firstPriceEpochStartTs;
    uint256 immutable internal priceEpochDurationSeconds;
    uint256 immutable internal revealEpochDurationSeconds;
    uint256 internal lastUnprocessedPriceEpoch;
    uint256 internal lastUnprocessedPriceEpochRevealEnds;

    // reward Epoch data
    uint256 immutable public rewardEpochDurationSeconds;
    uint256 immutable public rewardEpochsStartTs;
    uint256 immutable internal votePowerIntervalFraction;
    uint256 internal currentRewardEpochEnds;
    uint256 internal nextRewardEpochToExpire;

    mapping(IIFtso => bool) internal managedFtsos;
    mapping(IIFtso => bool) internal notInitializedFtsos;

    IIPriceSubmitter public immutable priceSubmitter;
    IIFtsoRewardManager public rewardManager;
    IIFtsoRegistry public ftsoRegistry;
    IIVoterWhitelister public voterWhitelister;
    IISupply public supply;
    CleanupBlockNumberManager public cleanupBlockNumberManager;

    // indicates if lastUnprocessedPriceEpoch is initialized for reveal
    // it has to be finalized before new reward epoch can start
    bool private priceEpochInitialized;

    // fallback mode
    bool internal fallbackMode; // all ftsos in fallback mode
    mapping(IIFtso => bool) internal ftsoInFallbackMode;

    constructor(
        address _governance,
        FlareDaemon _flareDaemon,
        IIPriceSubmitter _priceSubmitter,
        uint256 _firstEpochStartTs,
        uint256 _priceEpochDurationSeconds,
        uint256 _revealEpochDurationSeconds,
        uint256 _rewardEpochsStartTs,
        uint256 _rewardEpochDurationSeconds,
        uint256 _votePowerIntervalFraction
    ) 
        GovernedAndFlareDaemonized(_governance, _flareDaemon)
    {
        require(block.timestamp >= _firstEpochStartTs, ERR_FIRST_EPOCH_START_TS_IN_FUTURE);
        require(_rewardEpochDurationSeconds > 0, ERR_REWARD_EPOCH_DURATION_ZERO);
        require(_priceEpochDurationSeconds > 0, ERR_PRICE_EPOCH_DURATION_ZERO);
        require(_revealEpochDurationSeconds > 0, ERR_REVEAL_PRICE_EPOCH_DURATION_ZERO);
        require(_votePowerIntervalFraction > 0, ERR_VOTE_POWER_INTERVAL_FRACTION_ZERO);

        require(_revealEpochDurationSeconds < _priceEpochDurationSeconds, ERR_REVEAL_PRICE_EPOCH_TOO_LONG);
        require(_firstEpochStartTs + _revealEpochDurationSeconds <= _rewardEpochsStartTs, 
            ERR_REWARD_EPOCH_START_TOO_SOON);
        require((_rewardEpochsStartTs - _revealEpochDurationSeconds - _firstEpochStartTs) %
            _priceEpochDurationSeconds == 0, ERR_REWARD_EPOCH_START_CONDITION_INVALID);
        require(_rewardEpochDurationSeconds % _priceEpochDurationSeconds == 0,
            ERR_REWARD_EPOCH_DURATION_CONDITION_INVALID);

        // reward epoch
        rewardEpochDurationSeconds = _rewardEpochDurationSeconds;
        rewardEpochsStartTs = _rewardEpochsStartTs;
        votePowerIntervalFraction = _votePowerIntervalFraction;
        currentRewardEpochEnds = _rewardEpochsStartTs + _rewardEpochDurationSeconds;

        // price epoch
        firstPriceEpochStartTs = _firstEpochStartTs;
        priceEpochDurationSeconds = _priceEpochDurationSeconds;
        revealEpochDurationSeconds = _revealEpochDurationSeconds;
        lastUnprocessedPriceEpochRevealEnds = _rewardEpochsStartTs;
        lastUnprocessedPriceEpoch = (_rewardEpochsStartTs - _firstEpochStartTs) / _priceEpochDurationSeconds;

        priceSubmitter = _priceSubmitter;
    }

    function setContractAddresses(
        IIFtsoRewardManager _rewardManager,
        IIFtsoRegistry _ftsoRegistry,
        IIVoterWhitelister _voterWhitelister,
        IISupply _supply,
        CleanupBlockNumberManager _cleanupBlockNumberManager
    )
        external
        onlyGovernance
    {
        rewardManager = _rewardManager;
        ftsoRegistry = _ftsoRegistry;
        voterWhitelister = _voterWhitelister;
        supply = _supply;
        cleanupBlockNumberManager = _cleanupBlockNumberManager;
    }
    
    /**
     * @notice Activates FTSO manager (daemonize() runs jobs)
     */
    function activate() external override onlyGovernance {
        active = true;
    }

    /**
     * @notice Runs task triggered by Daemon.
     * The tasks include the following by priority
     * - finalizePriceEpoch     
     * - Set governance parameters and initialize epochs
     * - finalizeRewardEpoch 
     */
    function daemonize() external override onlyFlareDaemon returns (bool) {
        // flare daemon trigger. once every block
        if (!active) return false;

        if (rewardEpochs.length == 0) {
            _initializeFirstRewardEpoch();
        } else {
            // all three conditions can be executed in the same block,
            // but are split into three `if else if` groups to reduce gas usage per one block
            if (priceEpochInitialized && lastUnprocessedPriceEpochRevealEnds <= block.timestamp) {
                // finalizes initialized price epoch if reveal period is over
                // sets priceEpochInitialized = false
                _finalizePriceEpoch();
            } else if (!priceEpochInitialized && currentRewardEpochEnds <= block.timestamp) {
                // initialized price epoch must be finalized before new reward epoch can start
                // advance currentRewardEpochEnds
                _finalizeRewardEpoch();
                _closeExpiredRewardEpochs();
                _cleanupOnRewardEpochFinalization();
            } else if (lastUnprocessedPriceEpochRevealEnds <= block.timestamp) {
                // new price epoch can be initialized after previous was finalized 
                // and after new reward epoch was started (if needed)
                // initializes price epoch and sets governance parameters on ftsos and price submitter
                // advance lastUnprocessedPriceEpochRevealEnds, sets priceEpochInitialized = true
                _initializeCurrentEpochFTSOStatesForReveal(); 
            }
        }
        return true;
    }

    function switchToFallbackMode() external override onlyFlareDaemon returns (bool) {
        if (!fallbackMode) {
            fallbackMode = true;
            emit FallbackMode(true);
            return true;
        }
        return false;
    }

     /**
     * @notice Adds FTSO to the list of rewarded FTSOs
     * All ftsos in multi asset ftso must be managed by this ftso manager
     */
    function addFtso(IIFtso _ftso) external override onlyGovernance {
        _addFtso(_ftso, true);
    }

    /**
     * @notice Removes FTSO from the list of the rewarded FTSOs - revert if ftso is used in multi asset ftso
     * @dev Deactivates _ftso
     */
    function removeFtso(IIFtso _ftso) external override onlyGovernance {
        uint256 ftsoIndex = ftsoRegistry.getFtsoIndex(_ftso.symbol());
        voterWhitelister.removeFtso(ftsoIndex);
        ftsoRegistry.removeFtso(_ftso);
        _cleanFtso(_ftso);
    }
    
    /**
     * @notice Replaces one ftso with another - symbols must match
     * All ftsos in multi asset ftso must be managed by this ftso manager
     * @dev Deactivates _ftsoToRemove
     */
    function replaceFtso(
        IIFtso _ftsoToRemove,
        IIFtso _ftsoToAdd,
        bool _copyCurrentPrice,
        bool _copyAssetOrAssetFtsos
    )
        external override
        onlyGovernance
    {
        // should compare strings but it is not supported - comparing hashes instead
        require(keccak256(abi.encode(_ftsoToRemove.symbol())) == keccak256(abi.encode(_ftsoToAdd.symbol())), 
            ERR_FTSO_SYMBOLS_MUST_MATCH);

        // Check if it already exists
        IIFtso[] memory availableFtsos = _getFtsos();
        uint256 len = availableFtsos.length;
        uint256 k = 0;
        while (k < len) {
            if (availableFtsos[k] == _ftsoToRemove) {
                break;
            }
            ++k;
        }
        if (k == len) {
            revert(ERR_NOT_FOUND);
        }

        if (_copyCurrentPrice) {
            (uint256 currentPrice, uint256 timestamp) = _ftsoToRemove.getCurrentPrice();
            _ftsoToAdd.updateInitialPrice(currentPrice, timestamp);
        }

        if (_copyAssetOrAssetFtsos) {
            IIVPToken asset = _ftsoToRemove.getAsset();
            if (address(asset) != address(0)) { // copy asset if exists
                _ftsoToAdd.setAsset(asset);
            } else { // copy assetFtsos list if not empty
                IIFtso[] memory assetFtsos = _ftsoToRemove.getAssetFtsos();
                if (assetFtsos.length > 0) {
                    _ftsoToAdd.setAssetFtsos(assetFtsos);
                }
            }
        }
        // Add without duplicate check
        _addFtso(_ftsoToAdd, false);
        
        // replace old contract with the new one in multi asset ftsos
        IIFtso[] memory contracts = _getFtsos();

        uint256 ftsosLen = contracts.length;
        for (uint256 i = 0; i < ftsosLen; i++) {
            IIFtso ftso = contracts[i];
            if (ftso == _ftsoToRemove) {
                continue;
            }
            IIFtso[] memory assetFtsos = ftso.getAssetFtsos();
            uint256 assetFtsosLen = assetFtsos.length;
            if (assetFtsosLen > 0) {
                bool changed = false;
                for (uint256 j = 0; j < assetFtsosLen; j++) {
                    if (assetFtsos[j] == _ftsoToRemove) {
                        assetFtsos[j] = _ftsoToAdd;
                        changed = true;
                    }
                }
                if (changed) {
                    ftso.setAssetFtsos(assetFtsos);
                }
            }
        }

        // cleanup old contract
        _cleanFtso(_ftsoToRemove);
    }
    
    /**
     * @notice Set asset for FTSO
     */
    function setFtsoAsset(IIFtso _ftso, IIVPToken _asset) external override onlyGovernance {
        _ftso.setAsset(_asset);
    }

    /**
     * @notice Set asset FTSOs for FTSO - all ftsos should already be managed by this ftso manager
     */
    function setFtsoAssetFtsos(IIFtso _ftso, IIFtso[] memory _assetFtsos) external override onlyGovernance {
        uint256 len = _assetFtsos.length;
        require (len > 0, ERR_FTSO_ASSET_FTSO_ZERO);
        for (uint256 i = 0; i < len; i++) {
            if (_ftso == _assetFtsos[i]) {
                revert(ERR_FTSO_EQUALS_ASSET_FTSO);
            }
        }

        _checkAssetFtsosAreManaged(_assetFtsos);
        _ftso.setAssetFtsos(_assetFtsos);
    }

    /**
     * @notice Set fallback mode
     */
    function setFallbackMode(bool _fallbackMode) external override onlyGovernance {
        fallbackMode = _fallbackMode;
        emit FallbackMode(_fallbackMode);
    }

    /**
     * @notice Set fallback mode for ftso
     */
    function setFtsoFallbackMode(IIFtso _ftso, bool _fallbackMode) external override onlyGovernance {
        require(managedFtsos[_ftso], ERR_NOT_FOUND);
        ftsoInFallbackMode[_ftso] = _fallbackMode;
        emit FtsoFallbackMode(_ftso, _fallbackMode);
    }

    /**
     * @notice Sets governance parameters for FTSOs
     */
    function setGovernanceParameters(
        uint256 _maxVotePowerNatThresholdFraction,
        uint256 _maxVotePowerAssetThresholdFraction,
        uint256 _lowAssetUSDThreshold,
        uint256 _highAssetUSDThreshold,
        uint256 _highAssetTurnoutThresholdBIPS,
        uint256 _lowNatTurnoutThresholdBIPS,
        uint256 _rewardExpiryOffsetSeconds,
        address[] memory _trustedAddresses
    )
        external override onlyGovernance 
    {
        require(_maxVotePowerNatThresholdFraction > 0, ERR_GOV_PARAMS_INVALID);
        require(_maxVotePowerAssetThresholdFraction > 0, ERR_GOV_PARAMS_INVALID);
        require(_highAssetUSDThreshold >= _lowAssetUSDThreshold, ERR_GOV_PARAMS_INVALID);
        require(_highAssetTurnoutThresholdBIPS <= 1e4, ERR_GOV_PARAMS_INVALID);
        require(_lowNatTurnoutThresholdBIPS <= 1e4, ERR_GOV_PARAMS_INVALID);
        require(_rewardExpiryOffsetSeconds > 0, ERR_REWARD_EXPIRY_OFFSET_INVALID);
        require(_trustedAddresses.length <= MAX_TRUSTED_ADDRESSES_LENGTH, ERR_MAX_TRUSTED_ADDRESSES_LENGTH_EXCEEDED);
        settings._setState(
            _maxVotePowerNatThresholdFraction,
            _maxVotePowerAssetThresholdFraction,
            _lowAssetUSDThreshold,
            _highAssetUSDThreshold,
            _highAssetTurnoutThresholdBIPS,
            _lowNatTurnoutThresholdBIPS,
            _rewardExpiryOffsetSeconds,
            _trustedAddresses
        );
    }

    function getVotePowerIntervalFraction() external view returns (uint256) {
        return votePowerIntervalFraction;
    }
    
    function getPriceSubmitter() external view override returns (IPriceSubmitter) {
        return priceSubmitter;
    }

    /**
     * @dev half-closed intervals - end time not included
     */
    function getCurrentPriceEpochData() external view override 
        returns (
            uint256 priceEpochId,
            uint256 priceEpochStartTimestamp,
            uint256 priceEpochEndTimestamp,
            uint256 priceEpochRevealEndTimestamp,
            uint256 currentTimestamp
        )
    {
        uint256 epochId = _getCurrentPriceEpochId();
        return (
            epochId,
            firstPriceEpochStartTs + epochId * priceEpochDurationSeconds,
            firstPriceEpochStartTs + (epochId + 1) * priceEpochDurationSeconds,
            firstPriceEpochStartTs + (epochId + 1) * priceEpochDurationSeconds + revealEpochDurationSeconds,
            block.timestamp
        );
    }
    
    /**
     * @notice Gets vote power block of the specified reward epoch
     * @param _rewardEpoch          Reward epoch sequence number
     */
    function getRewardEpochVotePowerBlock(uint256 _rewardEpoch) external view override returns (uint256) {
        return rewardEpochs[_rewardEpoch].votepowerBlock;
    }

    /*
     * @notice Returns the list of FTSOs
     */
    function getFtsos() external view override returns (IIFtso[] memory _ftsos) {
        return _getFtsos();
    }

    function getPriceEpochConfiguration() external view override 
        returns (
            uint256 _firstPriceEpochStartTs,
            uint256 _priceEpochDurationSeconds,
            uint256 _revealEpochDurationSeconds
        )
    {
        return (firstPriceEpochStartTs, priceEpochDurationSeconds, revealEpochDurationSeconds);
    }

    function getFallbackMode() external view override
        returns (
            bool _fallbackMode,
            IIFtso[] memory _ftsos,
            bool[] memory _ftsoInFallbackMode
        )
    {
        _fallbackMode = fallbackMode;
        _ftsos = _getFtsos();
        uint256 len = _ftsos.length;
        _ftsoInFallbackMode = new bool[](len);
        
        for (uint256 i = 0; i < len; i++) {
            _ftsoInFallbackMode[i] = ftsoInFallbackMode[_ftsos[i]];
        }
    }
        
    /**
     * @notice Returns current reward epoch index (one currently running)
     */
    function getCurrentRewardEpoch() public view override returns (uint256) {
        uint256 rewardEpochsLength = rewardEpochs.length;
        require(rewardEpochsLength != 0, ERR_REWARD_EPOCH_NOT_INITIALIZED);
        return rewardEpochsLength - 1;
    }

    function _addFtso(IIFtso _ftso, bool _addNewFtso) internal {
        require(settings.initialized, ERR_GOV_PARAMS_NOT_INIT_FOR_FTSOS);

        _checkAssetFtsosAreManaged(_ftso.getAssetFtsos());

        if (_addNewFtso) {
            // Check if symbol already exists in registry
            bytes32 symbol = keccak256(abi.encode(_ftso.symbol()));
            string[] memory supportedSymbols = ftsoRegistry.getSupportedSymbols();
            uint256 len = supportedSymbols.length;
            while (len > 0) {
                --len;
                if (keccak256(abi.encode(supportedSymbols[len])) == symbol) {
                    revert(ERR_ALREADY_ADDED);
                }
            }
        }

        _ftso.activateFtso(firstPriceEpochStartTs, priceEpochDurationSeconds, revealEpochDurationSeconds);

        // Set the vote power block
        if (rewardEpochs.length != 0) {
            _ftso.setVotePowerBlock(rewardEpochs[rewardEpochs.length - 1].votepowerBlock);
        }

        // Configure 
        _ftso.configureEpochs(
            settings.maxVotePowerNatThresholdFraction,
            settings.maxVotePowerAssetThresholdFraction,
            settings.lowAssetUSDThreshold,
            settings.highAssetUSDThreshold,
            settings.highAssetTurnoutThresholdBIPS,
            settings.lowNatTurnoutThresholdBIPS,
            settings.trustedAddresses
        );
        
        // skip first round of price finalization if price epoch was already initialized for reveal
        notInitializedFtsos[_ftso] = priceEpochInitialized;
        managedFtsos[_ftso] = true;
        uint256 ftsoIndex = ftsoRegistry.addFtso(_ftso);

        // When a new ftso is added we also add it to the voter whitelister contract
        if (_addNewFtso) {
            voterWhitelister.addFtso(ftsoIndex);
        }
        
        emit FtsoAdded(_ftso, true);
    }

    function _cleanFtso(IIFtso _ftso) internal {
        _ftso.deactivateFtso();
        // Since this is as mapping, we can also just delete it, as false is default value for non-existing keys
        delete ftsoInFallbackMode[_ftso];
        delete notInitializedFtsos[_ftso];
        delete managedFtsos[_ftso];
        _checkMultiAssetFtsosAreManaged(_getFtsos());
        emit FtsoAdded(_ftso, false);
    }

    /**
     * @notice Initializes first reward epoch. Also sets vote power block to FTSOs
     */
    function _initializeFirstRewardEpoch() internal {

        if (block.timestamp >= currentRewardEpochEnds - rewardEpochDurationSeconds) {
            IIFtso[] memory ftsos = _getFtsos();
            uint256 numFtsos = ftsos.length;
            // Prime the reward epoch array with a new reward epoch
            RewardEpochData memory epochData = RewardEpochData({
                votepowerBlock: block.number - 1,
                startBlock: block.number,
                startTimestamp: block.timestamp
            });

            rewardEpochs.push(epochData);

            for (uint256 i = 0; i < numFtsos; ++i) {
                ftsos[i].setVotePowerBlock(epochData.votepowerBlock);
            }
        }
    }

    /**
     * @notice Finalizes reward epoch
     */
    function _finalizeRewardEpoch() internal {
        IIFtso[] memory ftsos = _getFtsos();
        uint256 numFtsos = ftsos.length;

        uint256 lastRandom = block.timestamp;
        // Are there any FTSOs to process?
        if (numFtsos > 0) {
            for (uint256 i = 0; i < numFtsos; ++i) {
                lastRandom += ftsos[i].getCurrentRandom();
            }
        }

        lastRandom = uint256(keccak256(abi.encode(lastRandom)));
        // @dev when considering block boundary for vote power block:
        // - if far from now, it doesn't reflect last vote power changes
        // - if too small, possible loan attacks.     
        // IMPORTANT: currentRewardEpoch is actually the one just getting finalized!
        uint256 votepowerBlockBoundary = 
            (block.number - rewardEpochs[getCurrentRewardEpoch()].startBlock) / votePowerIntervalFraction;
        // note: votePowerIntervalFraction > 0
 
        if (votepowerBlockBoundary == 0) {
            votepowerBlockBoundary = 1;
        }
 
        //slither-disable-next-line weak-prng           // lastRandom calculated from ftso inputs
        uint256 votepowerBlocksAgo = lastRandom % votepowerBlockBoundary;
        // prevent block.number becoming votePowerBlock
        // if  lastRandom % votepowerBlockBoundary == 0  
        if (votepowerBlocksAgo == 0) {
            votepowerBlocksAgo = 1;
        }
        
        RewardEpochData memory epochData = RewardEpochData({
            votepowerBlock: block.number - votepowerBlocksAgo, 
            startBlock: block.number,
            startTimestamp: block.timestamp
        });
        rewardEpochs.push(epochData);
        for (uint256 i = 0; i < numFtsos; i++) {
            ftsos[i].setVotePowerBlock(epochData.votepowerBlock);
        }

        emit RewardEpochFinalized(epochData.votepowerBlock, epochData.startBlock);

        // Advance reward epoch end-time
        currentRewardEpochEnds += rewardEpochDurationSeconds;
    }

    /**
     * @notice Closes expired reward epochs
     */
    function _closeExpiredRewardEpochs() internal {
        uint256 currentRewardEpoch = getCurrentRewardEpoch();
        uint256 expiryThreshold = block.timestamp - settings.rewardExpiryOffsetSeconds;
        // NOTE: start time of (i+1)th reward epoch is the end time of i-th  
        // This loop is clearly bounded by the value currentRewardEpoch, which is
        // always kept to the value of rewardEpochs.length - 1 in code and this value
        // does not change in the loop.
        while (
            nextRewardEpochToExpire < currentRewardEpoch && 
            rewardEpochs[nextRewardEpochToExpire + 1].startTimestamp <= expiryThreshold) 
        {   // Note: Since nextRewardEpochToExpire + 1 starts at that time
            // nextRewardEpochToExpire ends strictly before expiryThreshold, 
            try rewardManager.closeExpiredRewardEpoch(nextRewardEpochToExpire) {
                nextRewardEpochToExpire++;
            } catch Error(string memory message) {
                // closing of expired failed, which is not critical
                // just emit event for diagnostics
                emit ClosingExpiredRewardEpochFailed(nextRewardEpochToExpire);
                addRevertError(address(rewardManager), message);
                // Do not proceed with the loop.
                break;
            } catch {
                emit ClosingExpiredRewardEpochFailed(nextRewardEpochToExpire);
                addRevertError(address(rewardManager), ERR_CLOSING_EXPIRED_REWARD_EPOCH_FAIL);
                // Do not proceed with the loop.
                break;
            }
        }
    }

    /**
     * @notice Performs any cleanup needed immediately after a reward epoch is finalized
     */
    function _cleanupOnRewardEpochFinalization() internal {
        if (address(cleanupBlockNumberManager) == address(0)) {
            emit CleanupBlockNumberManagerUnset();
            return;
        }
        uint256 cleanupBlock = rewardEpochs[nextRewardEpochToExpire].votepowerBlock;
        
        try cleanupBlockNumberManager.setCleanUpBlockNumber(cleanupBlock) {
        } catch Error(string memory message) {
            // cleanup block number manager call failed, which is not critical
            // just emit event for diagnostics
            emit CleanupBlockNumberManagerFailedForBlock(cleanupBlock);
            addRevertError(address(cleanupBlockNumberManager), message);
        } catch {
            emit CleanupBlockNumberManagerFailedForBlock(cleanupBlock);
            addRevertError(address(cleanupBlockNumberManager), ERR_SET_CLEANUP_BLOCK_FAIL);
        }
    }

    function _finalizePriceEpochFailed(IIFtso ftso, string memory message) internal {
        emit FinalizingPriceEpochFailed(
            ftso, 
            lastUnprocessedPriceEpoch, 
            IFtso.PriceFinalizationType.WEIGHTED_MEDIAN
        );

        addRevertError(address(ftso), message);

        _fallbackFinalizePriceEpoch(ftso);
    }

    /**
     * @notice Finalizes price epoch
     */
    function _finalizePriceEpoch() internal {
        IIFtso[] memory ftsos = _getFtsos();
        uint256 numFtsos = ftsos.length;

        // Are there any FTSOs to process?
        if (numFtsos > 0 && !fallbackMode) {
            // choose winning ftso
            uint256 chosenFtsoId;
            if (lastRewardedFtsoAddress == address(0)) {
                // pump not yet primed
                //slither-disable-next-line weak-prng           // only used for first epoch
                chosenFtsoId = uint256(keccak256(abi.encode(
                        block.difficulty, block.timestamp
                    ))) % numFtsos;
            } else {
                // at least one finalize with real FTSO
                uint256 currentRandomSum = 0;
                for (uint256 i = 0; i < numFtsos; i++) {
                    currentRandomSum += ftsos[i].getCurrentRandom(); // may overflow but it is still ok
                }
                //slither-disable-next-line weak-prng           // ftso random calculated safely from inputs
                chosenFtsoId = uint256(keccak256(abi.encode(
                        currentRandomSum, block.timestamp
                    ))) % numFtsos;
            }
            address[] memory addresses;
            uint256[] memory weights;
            uint256 totalWeight;

            // On the off chance that the winning FTSO does not have any
            // recipient within the truncated price distribution to
            // receive rewards, find the next FTSO that does have reward
            // recipients and declare it the winner. Start with the next ftso.
            bool wasDistributed = false;
            address rewardedFtsoAddress = address(0);
            for (uint256 i = 0; i < numFtsos; i++) {
                //slither-disable-next-line weak-prng           // not a random, just choosing next
                uint256 id = (chosenFtsoId + i) % numFtsos;
                IIFtso ftso = ftsos[id];

                // skip finalizing ftso, as it is not initialized for reveal and tx would revert
                if (notInitializedFtsos[ftso]) {
                    delete notInitializedFtsos[ftso];
                    continue;
                }

                try ftso.finalizePriceEpoch(lastUnprocessedPriceEpoch, !wasDistributed) returns (
                    address[] memory _addresses,
                    uint256[] memory _weights,
                    uint256 _totalWeight
                ) {
                    if (!wasDistributed && _addresses.length > 0) { // change also in FTSO if condition changes
                        (addresses, weights, totalWeight) = (_addresses, _weights, _totalWeight);
                        wasDistributed = true;
                        rewardedFtsoAddress = address(ftso);
                    }
                } catch Error(string memory message) {
                    _finalizePriceEpochFailed(ftso, message);
                } catch {
                    _finalizePriceEpochFailed(ftso, ERR_PRICE_EPOCH_FINALIZE_FAIL);
                }
            }

            uint256 currentRewardEpoch = getCurrentRewardEpoch();

            if (wasDistributed) {
                try rewardManager.distributeRewards(
                    addresses,
                    weights,
                    totalWeight,
                    lastUnprocessedPriceEpoch,
                    rewardedFtsoAddress,
                    priceEpochDurationSeconds,
                    currentRewardEpoch,
                    _getPriceEpochEndTime(lastUnprocessedPriceEpoch) - 1, // actual end time (included)
                    rewardEpochs[currentRewardEpoch].votepowerBlock) {
                } catch Error(string memory message) {
                    emit DistributingRewardsFailed(rewardedFtsoAddress, lastUnprocessedPriceEpoch);
                    addRevertError(address(rewardManager), message);
                } catch {
                    emit DistributingRewardsFailed(rewardedFtsoAddress, lastUnprocessedPriceEpoch);
                    addRevertError(address(rewardManager), ERR_DISTRIBUTE_REWARD_FAIL);
                }
            }

            lastRewardedFtsoAddress = rewardedFtsoAddress;
            emit PriceEpochFinalized(rewardedFtsoAddress, currentRewardEpoch);
        } else {
            // only for fallback mode
            for (uint256 i = 0; i < numFtsos; i++) {
                IIFtso ftso = ftsos[i];
                // skip finalizing ftso, as it is not initialized for reveal and tx would revert
                if (notInitializedFtsos[ftso]) {
                    delete notInitializedFtsos[ftso];
                    continue;
                }
                _fallbackFinalizePriceEpoch(ftso);
            }

            lastRewardedFtsoAddress = address(0);
            emit PriceEpochFinalized(address(0), getCurrentRewardEpoch());
        }
        
        priceEpochInitialized = false;
    }

    function _fallbackFinalizePriceEpochFailed(IIFtso _ftso, string memory message) internal {
        emit FinalizingPriceEpochFailed(
            _ftso, 
            lastUnprocessedPriceEpoch, 
            IFtso.PriceFinalizationType.TRUSTED_ADDRESSES
        );
        addRevertError(address(_ftso), message);

        // if reverts we want to propagate up to daemon
        _ftso.forceFinalizePriceEpoch(lastUnprocessedPriceEpoch);
    }

    function _fallbackFinalizePriceEpoch(IIFtso _ftso) internal {
        try _ftso.averageFinalizePriceEpoch(lastUnprocessedPriceEpoch) {
        } catch Error(string memory message) {
            _fallbackFinalizePriceEpochFailed(_ftso, message);
        } catch {
            _fallbackFinalizePriceEpochFailed(_ftso, ERR_FALLBACK_FINALIZE_FAIL);
        }
    }

    /**
     * @notice Initializes epoch states in FTSOs for reveal. 
     * Prior to initialization it sets governance parameters, if 
     * governance has changed them. It also sets price submitter trusted addresses.
     */
    function _initializeCurrentEpochFTSOStatesForReveal() internal {
        if (settings.changed) {
            priceSubmitter.setTrustedAddresses(settings.trustedAddresses);
        }

        IIFtso[] memory ftsos = _getFtsos();
        uint256 numFtsos = ftsos.length;

        // circulating supply is used only when ftso is not in fallback mode
        uint256 circulatingSupplyNat;
        if (numFtsos > 0 && !fallbackMode) {
            uint256 votePowerBlock = rewardEpochs[rewardEpochs.length - 1].votepowerBlock;
            circulatingSupplyNat = supply.getCirculatingSupplyAtCached(votePowerBlock);
        }

        for (uint256 i = 0; i < numFtsos; i++) {
            IIFtso ftso = ftsos[i];
            if (settings.changed) {
                ftso.configureEpochs(
                    settings.maxVotePowerNatThresholdFraction,
                    settings.maxVotePowerAssetThresholdFraction,
                    settings.lowAssetUSDThreshold,
                    settings.highAssetUSDThreshold,
                    settings.highAssetTurnoutThresholdBIPS,
                    settings.lowNatTurnoutThresholdBIPS,
                    settings.trustedAddresses
                );
            }

            try ftso.initializeCurrentEpochStateForReveal(
                circulatingSupplyNat,
                fallbackMode || ftsoInFallbackMode[ftso]) {
            } catch Error(string memory message) {
                _initializeCurrentEpochStateForRevealFailed(ftso, message);
            } catch {
                _initializeCurrentEpochStateForRevealFailed(ftso, ERR_INIT_EPOCH_REVEAL_FAIL);
            }

        }
        settings.changed = false;

        // Advance price epoch id and end-time
        uint256 currentPriceEpochId = _getCurrentPriceEpochId();
        lastUnprocessedPriceEpoch = currentPriceEpochId;
        lastUnprocessedPriceEpochRevealEnds = _getPriceEpochRevealEndTime(currentPriceEpochId);

        priceEpochInitialized = true;
    }

    function _initializeCurrentEpochStateForRevealFailed(IIFtso ftso, string memory message) internal {
        emit InitializingCurrentEpochStateForRevealFailed(ftso, _getCurrentPriceEpochId());
        addRevertError(address(ftso), message);

        // if it was already called with fallback = true, just mark as not initialized, else retry
        if (fallbackMode || ftsoInFallbackMode[ftso]) {
            notInitializedFtsos[ftso] = true;
        } else {
            try ftso.initializeCurrentEpochStateForReveal(0, true) {
            } catch Error(string memory message1) {
                notInitializedFtsos[ftso] = true;
                emit InitializingCurrentEpochStateForRevealFailed(ftso, _getCurrentPriceEpochId());
                addRevertError(address(ftso), message1);
            } catch {
                notInitializedFtsos[ftso] = true;
                emit InitializingCurrentEpochStateForRevealFailed(ftso, _getCurrentPriceEpochId());
                addRevertError(address(ftso), ERR_FALLBACK_INIT_EPOCH_REVEAL_FAIL);
            }
        }
    }

    /**
     * @notice Check if asset ftsos are managed by this ftso manager, revert otherwise
     */
    function _checkAssetFtsosAreManaged(IIFtso[] memory _assetFtsos) internal view {
        uint256 len = _assetFtsos.length;
        for (uint256 i = 0; i < len; i++) {
            if (!managedFtsos[_assetFtsos[i]]) {
                revert(ERR_ASSET_FTSO_NOT_MANAGED);
            }
        }
    }

    /**
     * @notice Check if all multi asset ftsos are managed by this ftso manager, revert otherwise
     */
    function _checkMultiAssetFtsosAreManaged(IIFtso[] memory _ftsos) internal view {
        uint256 len = _ftsos.length;
        for (uint256 i = 0; i < len; i++) {
            _checkAssetFtsosAreManaged(_ftsos[i].getAssetFtsos());
        }
    }

    /**
     * @notice Returns price epoch reveal end time.
     * @param _priceEpochId The price epoch id.
     * @dev half-closed interval - end time not included
     */
    function _getPriceEpochRevealEndTime(uint256 _priceEpochId) internal view returns (uint256) {
        return firstPriceEpochStartTs + (_priceEpochId + 1) * priceEpochDurationSeconds + revealEpochDurationSeconds;
    }

    /**
     * @notice Returns price epoch end time.
     * @param _forPriceEpochId The price epoch id of the end time to fetch.
     * @dev half-closed interval - end time not included
     */
    function _getPriceEpochEndTime(uint256 _forPriceEpochId) internal view returns (uint256) {
        return firstPriceEpochStartTs + ((_forPriceEpochId + 1) * priceEpochDurationSeconds);
    }

    /**
     * @notice Returns current price epoch id. The calculation in this function
     * should fully match to definition of current epoch id in FTSO contracts.
     */
    function _getCurrentPriceEpochId() internal view returns (uint256) {
        return (block.timestamp - firstPriceEpochStartTs) / priceEpochDurationSeconds;
    }

    function _getFtsos() private view returns (IIFtso[] memory) {
        return ftsoRegistry.getSupportedFtsos();
    }
}
