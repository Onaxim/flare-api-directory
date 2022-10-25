// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import  "../../genesis/implementation/FlareDaemon.sol";
import "../../genesis/interface/IFlareDaemonize.sol";
import "../../utils/implementation/GovernedAndFlareDaemonized.sol";
import "../../addressUpdater/implementation/AddressUpdatable.sol";
import "../lib/IncentivePoolAnnum.sol";
import "../lib/IncentivePoolAnnums.sol";
import "../interface/IIIncentivePoolAllocation.sol";
import "../lib/IncentivePoolRewardService.sol"; 
import "../../inflation/interface/IISupply.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../../utils/implementation/SafePct.sol";
import "../interface/IITokenPool.sol";
import "../../genesis/implementation/IncentivePoolTreasury.sol";

/**
 * @title IncentivePool
 * @notice A contract to manage the process of recognizing, authorizing and funding
 *   native tokens for Flare services that are rewardable by incentivePool.
 **/
contract IncentivePool is GovernedAndFlareDaemonized, IFlareDaemonize, IITokenPool, AddressUpdatable {
    using IncentivePoolAnnums for IncentivePoolAnnums.IncentivePoolAnnumsState;
    using SafeMath for uint256;
    using SafePct for uint256;

    // Composable contracts
    IncentivePoolTreasury public immutable treasury;
    IIIncentivePoolAllocation public incentivePoolAllocation;
    IISupply public supply;

    // The annums
    IncentivePoolAnnums.IncentivePoolAnnumsState private incentivePoolAnnums;       // IncentivePool annum data

    // Instance vars
    uint256 public lastAuthorizationTs;                             // The last time incentive was authorized
    mapping(IIIncentivePoolReceiver => TopupConfiguration)
        internal topupConfigurations;                               // A topup configuration for a contract
                                                                    //   receiving incentive.
    uint256 public immutable rewardEpochStartTs;                    // Do not start incentivePool annums before this
    uint256 public rewardEpochStartedTs;                            // When the first reward epoch was started

    // Constants
    string internal constant ERR_IS_ZERO = "address is 0";
    string internal constant ERR_OUT_OF_BALANCE = "out of balance";
    string internal constant ERR_TOPUP_LOW = "topup low";
    string internal constant ERR_TOPUP_HIGH = "topup high";
    string internal constant ERR_GET_ANNUAL_PERCENT = "unknown error. getAnnualPercentageBips";
    string internal constant ERR_TREASURY_ONLY = "treasury only";

    uint256 internal constant BIPS100 = 1e4;                            // 100% in basis points
    uint256 internal constant DEFAULT_TOPUP_FACTOR_X100 = 120;
    uint256 internal constant MAX_DAILY_TOPUP_FACTOR_X100 = 400;
    uint256 internal constant AUTHORIZE_TIME_FRAME_SEC = 1 days;

    event IncentiveAuthorized(uint256 amountWei);
    event TopupRequested(uint256 amountWei);
    event IncentivePoolAllocationSet(IIIncentivePoolAllocation incentivePoolAllocation);
    event IncentivePoolRewardServiceTopupComputed(IIIncentivePoolReceiver incentivePoolReceiver, uint256 amountWei);
    event IncentivePoolRewardServiceDailyAuthorizedIncentiveComputed(
        IIIncentivePoolReceiver incentivePoolReceiver,
        uint256 amountWei);
    event IncentivePoolRewardServiceTopupRequestReceived(
        IIIncentivePoolReceiver incentivePoolReceiver,
        uint256 amountWei);
    event SupplySet(IISupply oldSupply, IISupply newSupply);
    event TopupConfigurationSet(TopupConfiguration topupConfiguration);
    event NewAnnumInitialized(
        uint256 startTimeStamp,
        uint256 endTimeStamp,
        uint256 inflatableSupplyWei,
        uint256 recognizedIncentiveWei,
        uint256 totalAuthorizedIncentiveWei,
        uint256 totalIncentiveTopupRequestedWei,
        uint256 totalIncentiveTopupReceivedWei,
        uint256 totalIncentiveTopupWithdrawnWei
    );

    modifier notZero(address _address) {
        require(_address != address(0), ERR_IS_ZERO);
        _;
    }

    constructor (
        address _governance, 
        FlareDaemon _flareDaemon,
        address _addressUpdater,
        IncentivePoolTreasury _treasury,
        uint256 _rewardEpochStartTs
    )
        notZero(address(_treasury))
        GovernedAndFlareDaemonized(_governance, _flareDaemon)
        AddressUpdatable(_addressUpdater)
    {
        treasury = _treasury;
        rewardEpochStartTs = _rewardEpochStartTs;
    }

    /**
     * @notice Needed in order to receive funds from Treasury
     */
    receive() external payable {
        require(msg.sender == address(treasury), ERR_TREASURY_ONLY);
    }

    /**
     * @notice Return token pool supply data
     * @return _lockedFundsWei                  Funds that are intentionally locked in the token pool 
     * and not part of circulating supply
     * @return _totalInflationAuthorizedWei     Total inflation authorized amount (wei)
     * @return _totalClaimedWei                 Total claimed amount (wei)
     */
    function getTokenPoolSupplyData() external view override returns (
        uint256 _lockedFundsWei,
        uint256 _totalInflationAuthorizedWei,
        uint256 _totalClaimedWei
    ){
        _lockedFundsWei = address(treasury).balance.add(incentivePoolAnnums.totalIncentiveTopupWithdrawnWei);
        _totalInflationAuthorizedWei = 0;
        _totalClaimedWei = incentivePoolAnnums.totalIncentiveTopupWithdrawnWei;
    }

    /**
     * @notice Get a tuple of totals across incentivePool annums.
     * @return _totalAuthorizedIncentiveWei     Total authorized incentive
     * @return _totalIncentiveTopupRequestedWei Total incentive requested to be topped up for rewarding
     * @return _totalIncentiveTopupReceivedWei  Total incentive received for funding reward services
     * @return _totalIncentiveTopupWithdrawnWei Total incentive used for funding reward services
     * @return _totalRecognizedIncentiveWei     Total incentive recognized for rewarding
     */
    function getTotals()
        external view 
        returns (
            uint256 _totalAuthorizedIncentiveWei,
            uint256 _totalIncentiveTopupRequestedWei,
            uint256 _totalIncentiveTopupReceivedWei,
            uint256 _totalIncentiveTopupWithdrawnWei,
            uint256 _totalRecognizedIncentiveWei
        )
    {
        _totalAuthorizedIncentiveWei = incentivePoolAnnums.totalAuthorizedIncentiveWei;
        _totalIncentiveTopupRequestedWei = incentivePoolAnnums.totalIncentiveTopupRequestedWei;
        _totalIncentiveTopupReceivedWei = incentivePoolAnnums.totalIncentiveTopupReceivedWei;
        _totalIncentiveTopupWithdrawnWei = incentivePoolAnnums.totalIncentiveTopupWithdrawnWei;
        _totalRecognizedIncentiveWei = incentivePoolAnnums.totalRecognizedIncentiveWei;
    }

    /**
     * @notice Given an index, return the annum at that index.
     * @param _index    The index of the annum to fetch.
     * @return          The incentivePool annum state.
     * @dev Expect library to revert if index not found.
     */
    function getAnnum(uint256 _index) external view returns(IncentivePoolAnnum.IncentivePoolAnnumState memory) {
        return incentivePoolAnnums.getAnnum(_index);
    }

    /**
     * @notice Return the current annum.
     * @return The incentivePool annum state of the current annum.
     * @dev Expect library to revert if there is no current annum.
     */
    function getCurrentAnnum() external view returns(IncentivePoolAnnum.IncentivePoolAnnumState memory) {
        return incentivePoolAnnums.getCurrentAnnum();
    }

    /**
     * @notice Set the topup configuration for a reward service.
     * @param _incentivePoolReceiver    The reward service to receive the incentivePool funds for distribution.
     * @param _topupType            The type to signal how the topup amounts are to be calculated.
     *                              FACTOROFDAILYAUTHORIZED = Use a factor of last daily authorized to set a
     *                              target balance for a reward service to maintain as a reserve for claiming.
     *                              ALLAUTHORIZED = Mint enough native tokens to topup reward service contract to hold
     *                              all authorized but unrequested rewards.
     * @param _topupFactorX100      If _topupType == FACTOROFDAILYAUTHORIZED, then this factor (times 100)
     *                              is multipled by last daily authorized incentive to obtain the
     *                              maximum balance that a reward service can hold at any given time. If it holds less,
     *                              then this max amount is used to compute the mint request topup required to 
     *                              bring the reward service contract native token balance up to that amount.
     * @dev Topup factor, if _topupType == FACTOROFDAILYAUTHORIZED, must be > 100 and <= 400.
     */
    function setTopupConfiguration(
        IIIncentivePoolReceiver _incentivePoolReceiver, 
        TopupType _topupType, 
        uint256 _topupFactorX100
    )
        external
        notZero(address(_incentivePoolReceiver))
        onlyGovernance
    {
        if (_topupType == TopupType.FACTOROFDAILYAUTHORIZED) {
            require(_topupFactorX100 > 100, ERR_TOPUP_LOW);
            require(_topupFactorX100 <= MAX_DAILY_TOPUP_FACTOR_X100, ERR_TOPUP_HIGH);
        }
        TopupConfiguration storage topupConfiguration = topupConfigurations[_incentivePoolReceiver];
        topupConfiguration.topupType = _topupType;
        topupConfiguration.topupFactorX100 = _topupFactorX100;
        topupConfiguration.configured = true;

        emit TopupConfigurationSet(topupConfiguration);
    }

    /**
     * @notice Given an incentivePool receiver, get the topup configuration.
     * @param _incentivePoolReceiver    The reward service.
     * @return _topupConfiguration  The configurartion of how the topup requests are calculated for a given
     *                              reward service.
     */
    function getTopupConfiguration(
        IIIncentivePoolReceiver _incentivePoolReceiver
    )
        external
        notZero(address(_incentivePoolReceiver))
        returns(TopupConfiguration memory _topupConfiguration)
    {
        TopupConfiguration storage topupConfiguration = topupConfigurations[_incentivePoolReceiver];
        if (!topupConfiguration.configured) {
            topupConfiguration.topupType = TopupType.FACTOROFDAILYAUTHORIZED;
            topupConfiguration.topupFactorX100 = DEFAULT_TOPUP_FACTOR_X100;
            topupConfiguration.configured = true;
        }
        _topupConfiguration.topupType = topupConfiguration.topupType;
        _topupConfiguration.topupFactorX100 = topupConfiguration.topupFactorX100;
        _topupConfiguration.configured = topupConfiguration.configured;
    }

    /**
     * @notice Pulsed by the FlareDaemon to trigger timing-based events for the incentive process.
     * @dev There are two events:
     *   1) an annual event to recognize incentive for a new annum
     *   2) a daily event to:
     *     a) authorize incentive for rewarding
     *     b) distribute enough native tokens to topup reward services for claiming reserves
     */
    function daemonize() external virtual override notZero(address(supply)) onlyFlareDaemon returns(bool) {
        // If incentive rewarding not started yet, blow off processing until it does.
        if (rewardEpochStartTs == 0 || block.timestamp < rewardEpochStartTs) {
            return true;
        }

        // If incetive rewarding started and we have not updated when it started, do so now.
        if (rewardEpochStartedTs == 0) {
            rewardEpochStartedTs = block.timestamp;
        }

        // Is it time to recognize an initial incentivePool annum?
        if (incentivePoolAnnums.getCount() == 0) {
            _initNewAnnum(block.timestamp);
        } else {
            uint256 currentAnnumEndTimeStamp = incentivePoolAnnums.getCurrentAnnum().endTimeStamp;

            // Is it time to recognize a new incentivePool annum?
            if (block.timestamp > currentAnnumEndTimeStamp) {
                _initNewAnnum(currentAnnumEndTimeStamp.add(1));
            }
        }

        // Is it time to authorize new incentive? Do it daily.
        if (lastAuthorizationTs.add(AUTHORIZE_TIME_FRAME_SEC) <= block.timestamp) {
            // Update time we last authorized.
            lastAuthorizationTs = block.timestamp;

            // Authorize incentive for current sharing percentages.
            uint256 amountAuthorizedWei = incentivePoolAnnums.authorizeDailyIncentive(
                block.timestamp,
                treasury.MAX_DAILY_PULL_AMOUNT_WEI().mulDiv(100, MAX_DAILY_TOPUP_FACTOR_X100),
                incentivePoolAllocation.getSharingPercentages()
            );

            emit IncentiveAuthorized(amountAuthorizedWei);

            // Time to compute topup amount for incentivePool receivers.
            uint256 topupRequestWei = incentivePoolAnnums.computeTopupRequest(this);
            emit TopupRequested(topupRequestWei);
            // Pull funds from treasury contract
            treasury.pullFunds(topupRequestWei);
            // Distribute received funds
            uint256 amountPostedWei = incentivePoolAnnums.distributeTopupRequest();
            // calculated and distributed amount should be the same
            assert(topupRequestWei == amountPostedWei);
        }
        return true;
    }

    function switchToFallbackMode() external view override onlyFlareDaemon returns (bool) {
        // do nothing - there is no fallback mode in IncentivePool
        return false;
    }

    /**
     * @notice Implement this function for updating daemonized contracts through AddressUpdater.
     */
    function getContractName() external pure override returns (string memory) {
        return "IncentivePool";
    }

    /**
     * @notice Returns next expected incentive topup timestamp which is also incentive authorization time. 
     *     The returned time from this API is actually the time of the block in which the topup is requested. 
     *     The Actual topup will take place in the same block.
     */
    function getNextExpectedTopupTs() external view returns (uint256 _nextTopupTs) {
        _nextTopupTs = lastAuthorizationTs.add(AUTHORIZE_TIME_FRAME_SEC);
    }

    /**
     * @notice Implementation of the AddressUpdatable abstract method - updates supply and incentivePool allocation.
     * @notice Set a reference to a provider of sharing percentages by incentivePool receiver.
     * @dev Assume that sharing percentages sum to 100% if at least one exists, but
     *      if no sharing percentages are defined, then no incentive will be authorized.
     * @notice Set a reference to a provider of the annual incentivePool percentage.
     * @dev Assume that referencing contract has reasonablness limitations on percentages.
     */
    function _updateContractAddresses(
        bytes32[] memory _contractNameHashes,
        address[] memory _contractAddresses
    )
        internal override
    {
        IISupply _supply = IISupply(_getContractAddress(_contractNameHashes, _contractAddresses, "Supply"));
        emit SupplySet(supply, _supply);
        supply = _supply;

        incentivePoolAllocation = IIIncentivePoolAllocation(
            _getContractAddress(_contractNameHashes, _contractAddresses, "IncentivePoolAllocation"));
        emit IncentivePoolAllocationSet(incentivePoolAllocation);
    }

    function _initNewAnnum(uint256 startTs) internal {
        uint256 inflatableSupply = supply.getInflatableBalance();
        uint256 freeTreasuryBalance = address(treasury).balance
            .add(incentivePoolAnnums.totalIncentiveTopupWithdrawnWei)
            .sub(incentivePoolAnnums.totalAuthorizedIncentiveWei);

        try incentivePoolAllocation.getAnnualPercentageBips() returns(uint256 annualPercentBips) {
            incentivePoolAnnums.initializeNewAnnum(startTs, freeTreasuryBalance, inflatableSupply, annualPercentBips);
        } catch Error(string memory message) {
            revert(message);
        } catch {
            revert(ERR_GET_ANNUAL_PERCENT);
        }

        IncentivePoolAnnum.IncentivePoolAnnumState memory incentivePoolAnnum = incentivePoolAnnums.getCurrentAnnum();

        emit NewAnnumInitialized(
            incentivePoolAnnum.startTimeStamp,
            incentivePoolAnnum.endTimeStamp,
            inflatableSupply,
            incentivePoolAnnum.recognizedIncentiveWei,
            incentivePoolAnnum.incentivePoolRewardServices.totalAuthorizedIncentiveWei,
            incentivePoolAnnum.incentivePoolRewardServices.totalIncentiveTopupRequestedWei,
            incentivePoolAnnum.incentivePoolRewardServices.totalIncentiveTopupReceivedWei,
            incentivePoolAnnum.incentivePoolRewardServices.totalIncentiveTopupWithdrawnWei
        );
    }
}
