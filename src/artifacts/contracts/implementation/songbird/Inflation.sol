// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import  "../../genesis/implementation/FlareDaemon.sol";
import "../../genesis/interface/IFlareDaemonize.sol";
import "../../genesis/interface/IInflationGenesis.sol";
import "../../utils/implementation/GovernedAndFlareDaemonized.sol";
import "../lib/InflationAnnum.sol";
import "../lib/InflationAnnums.sol";
import "../interface/IIInflationPercentageProvider.sol";
import "../interface/IIInflationReceiver.sol";
import "../interface/IIInflationSharingPercentageProvider.sol";
import "../lib/RewardService.sol"; 
import "../interface/IISupply.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../../utils/implementation/SafePct.sol";

/**
 * @title Inflation
 * @notice A contract to manage the process of recognizing, authorizing, minting, and funding
 *   native tokens for Flare services that are rewardable by inflation.
 * @dev Please see docs/specs/Inflation.md to better understand this terminology.
 **/
contract Inflation is IInflationGenesis, GovernedAndFlareDaemonized, IFlareDaemonize {
    using InflationAnnums for InflationAnnums.InflationAnnumsState;
    using SafeMath for uint256;
    using SafePct for uint256;

    // Composable contracts
    IIInflationPercentageProvider public inflationPercentageProvider;
    IIInflationSharingPercentageProvider public inflationSharingPercentageProvider;
    IISupply public supply;

    // The annums
    InflationAnnums.InflationAnnumsState private inflationAnnums;       // Inflation annum data

    // Instance vars
    uint256 public lastAuthorizationTs;                                 // The last time inflation was authorized
    mapping(IIInflationReceiver => TopupConfiguration)
        internal topupConfigurations;                                   // A topup configuration for a contract
                                                                        //   receiving inflation.
    uint256 public totalSelfDestructReceivedWei;
    //slither-disable-next-line uninitialized-state                     // no problem, will be zero initialized anyway
    uint256 public totalSelfDestructWithdrawnWei;
    uint256 immutable public rewardEpochStartTs;                        // Do not start inflation annums before this
    uint256 public rewardEpochStartedTs;                                // When the first reward epoch was started

    // Constants
    string internal constant ERR_IS_ZERO = "address is 0";
    string internal constant ERR_OUT_OF_BALANCE = "out of balance";
    string internal constant ERR_TOPUP_LOW = "topup low";
    string internal constant ERR_GET_ANNUAL_PERCENT = "unknown error. getAnnualPercentageBips";
    string internal constant ERR_SUPPLY_UPDATE = "unknown error. updateAuthorizedInflationAndCirculatingSupply";
    string internal constant ERR_REQUEST_MINT = "unknown error. requestMinting";

    uint256 internal constant BIPS100 = 1e4;                            // 100% in basis points
    uint256 internal constant DEFAULT_TOPUP_FACTOR_X100 = 120;
    // DO NOT UPDATE - this affects supply contract, which is expected to be updated once a day
    uint256 internal constant AUTHORIZE_TIME_FRAME_SEC = 1 days;

    event InflationAuthorized(uint256 amountWei);
    event MintingReceived(uint256 amountWei, uint256 selfDestructAmountWei);
    event TopupRequested(uint256 amountWei);
    event InflationPercentageProviderSet(IIInflationPercentageProvider inflationPercentageProvider);
    event InflationSharingPercentageProviderSet(
        IIInflationSharingPercentageProvider inflationSharingPercentageProvider);
    event RewardServiceTopupComputed(IIInflationReceiver inflationReceiver, uint256 amountWei);
    event RewardServiceDailyAuthorizedInflationComputed(IIInflationReceiver inflationReceiver, uint256 amountWei);
    event RewardServiceTopupRequestReceived(IIInflationReceiver inflationReceiver, uint256 amountWei);
    event SupplySet(IISupply oldSupply, IISupply newSupply);
    event TopupConfigurationSet(TopupConfiguration topupConfiguration);
    event NewAnnumInitialized(
        uint16 daysInAnnum,
        uint256 startTimeStamp,
        uint256 endTimeStamp,
        uint256 inflatableSupplyWei,
        uint256 recognizedInflationWei,
        uint256 totalAuthorizedInflationWei,
        uint256 totalInflationTopupRequestedWei,
        uint256 totalInflationTopupReceivedWei,
        uint256 totalInflationTopupWithdrawnWei
    );

    /**
     * @dev This modifier ensures that this contract's balance matches the expected balance.
     */
    modifier mustBalance {
        _;
        require (getExpectedBalance() == address(this).balance, ERR_OUT_OF_BALANCE);
    }

    modifier notZero(address _address) {
        require(_address != address(0), ERR_IS_ZERO);
        _;
    }

    constructor (
        address _governance, 
        FlareDaemon _flareDaemon,
        IIInflationPercentageProvider _inflationPercentageProvider,
        IIInflationSharingPercentageProvider _inflationSharingPercentageProvider,
        uint256 _rewardEpochStartTs
    )
        GovernedAndFlareDaemonized(_governance, _flareDaemon)
        notZero(address(_inflationPercentageProvider))
        notZero(address(_inflationSharingPercentageProvider))
    {
        inflationPercentageProvider = _inflationPercentageProvider;
        inflationSharingPercentageProvider = _inflationSharingPercentageProvider;
        rewardEpochStartTs = _rewardEpochStartTs;
    }

    /**
     * @notice Get a tuple of totals across inflation annums.
     * @return _totalAuthorizedInflationWei     Total inflation authorized to be mintable
     * @return _totalInflationTopupRequestedWei Total inflation requested to be topped up for rewarding
     * @return _totalInflationTopupReceivedWei  Total inflation received for funding reward services
     * @return _totalInflationTopupWithdrawnWei Total inflation used for funding reward services
     * @return _totalRecognizedInflationWei     Total inflation recognized for rewarding
     * @return _totalSelfDestructReceivedWei    Total balance received as a self-destruct recipient
     * @return _totalSelfDestructWithdrawnWei   Total self-destruct balance withdrawn
     */
    function getTotals()
        external view 
        returns (
            uint256 _totalAuthorizedInflationWei,
            uint256 _totalInflationTopupRequestedWei,
            uint256 _totalInflationTopupReceivedWei,
            uint256 _totalInflationTopupWithdrawnWei,
            uint256 _totalRecognizedInflationWei,
            uint256 _totalSelfDestructReceivedWei,
            uint256 _totalSelfDestructWithdrawnWei
        )
    {
        _totalAuthorizedInflationWei = inflationAnnums.totalAuthorizedInflationWei;
        _totalInflationTopupRequestedWei = inflationAnnums.totalInflationTopupRequestedWei;
        _totalInflationTopupReceivedWei = inflationAnnums.totalInflationTopupReceivedWei;
        _totalInflationTopupWithdrawnWei = inflationAnnums.totalInflationTopupWithdrawnWei;
        _totalRecognizedInflationWei = inflationAnnums.totalRecognizedInflationWei;
        _totalSelfDestructReceivedWei = totalSelfDestructReceivedWei;
        _totalSelfDestructWithdrawnWei = totalSelfDestructWithdrawnWei;
    }

    /**
     * @notice Given an index, return the annum at that index.
     * @param _index    The index of the annum to fetch.
     * @return          The inflation annum state.
     * @dev Expect library to revert if index not found.
     */
    function getAnnum(uint256 _index) external view returns(InflationAnnum.InflationAnnumState memory) {
        return inflationAnnums.getAnnum(_index);
    }

    /**
     * @notice Return the current annum.
     * @return The inflation annum state of the current annum.
     * @dev Expect library to revert if there is no current annum.
     */
    function getCurrentAnnum() external view returns(InflationAnnum.InflationAnnumState memory) {
        return inflationAnnums.getCurrentAnnum();
    }

    /**
     * @notice Receive newly minted native tokens from the FlareDaemon.
     * @dev Assume that the amount received will be >= last topup requested across all services.
     *   If there is not enough balance sent to cover the topup request, expect library method will revert.
     *   Also assume that any balance received greater than the topup request calculated
     *   came from self-destructor sending a balance to this contract.
     */
    function receiveMinting() external override payable onlyFlareDaemon mustBalance {
        uint256 amountPostedWei = inflationAnnums.receiveTopupRequest();
        // Assume that if we received (or already have) more than we posted, 
        // it must be amounts sent from a contract self-destruct
        // recipient in this block.
        uint256 prevBalance = getExpectedBalance();
        uint256 selfDestructProceeds = address(this).balance.sub(prevBalance);
        if (selfDestructProceeds > 0) {
            totalSelfDestructReceivedWei = totalSelfDestructReceivedWei.add(selfDestructProceeds);
        }
        emit MintingReceived(amountPostedWei, selfDestructProceeds);
    }

    /**
     * @notice Set a reference to a provider of the annual inflation percentage.
     * @param _inflationPercentageProvider  A contract providing the annual inflation percentage.
     * @dev Assume that referencing contract has reasonablness limitations on percentages.
     */
    function setInflationPercentageProvider(
        IIInflationPercentageProvider _inflationPercentageProvider
    )
        external
        notZero(address(_inflationPercentageProvider))
        onlyGovernance
    {
        inflationPercentageProvider = _inflationPercentageProvider;

        emit InflationPercentageProviderSet(_inflationPercentageProvider);
    }

    /**
     * @notice Set a reference to a provider of sharing percentages by inflation receiver.
     * @param _inflationSharingPercentageProvider   A contract providing sharing percentages.
     * @dev Assume that sharing percentages sum to 100% if at least one exists, but
     *   if no sharing percentages are defined, then no inflation will be authorized.
     */
    function setInflationSharingPercentageProvider(
        IIInflationSharingPercentageProvider _inflationSharingPercentageProvider
    )
        external
        notZero(address(_inflationSharingPercentageProvider))
        onlyGovernance
    {
        inflationSharingPercentageProvider = _inflationSharingPercentageProvider;

        emit InflationSharingPercentageProviderSet(_inflationSharingPercentageProvider);
    }

    /**
     * @notice Set a reference to the Supply contract.
     * @param _supply   The Supply contract.
     * @dev The supply contract is used to get and update the inflatable balance.
     */
    function setSupply(IISupply _supply) external notZero(address(_supply)) onlyGovernance {
        emit SupplySet(supply, _supply);
        supply = _supply;
    }

    /**
     * @notice Set the topup configuration for a reward service.
     * @param _inflationReceiver    The reward service to receive the inflation funds for distribution.
     * @param _topupType            The type to signal how the topup amounts are to be calculated.
     *                              FACTOROFDAILYAUTHORIZED = Use a factor of last daily authorized to set a
     *                              target balance for a reward service to maintain as a reserve for claiming.
     *                              ALLAUTHORIZED = Mint enough native tokens to topup reward service contract to hold
     *                              all authorized but unrequested rewards.
     * @param _topupFactorX100      If _topupType == FACTOROFDAILYAUTHORIZED, then this factor (times 100)
     *                              is multipled by last daily authorized inflation to obtain the
     *                              maximum balance that a reward service can hold at any given time. If it holds less,
     *                              then this max amount is used to compute the mint request topup required to 
     *                              bring the reward service contract native token balance up to that amount.
     * @dev Topup factor, if _topupType == FACTOROFDAILYAUTHORIZED, must be greater than 100.
     */
    function setTopupConfiguration(
        IIInflationReceiver _inflationReceiver, 
        TopupType _topupType, 
        uint256 _topupFactorX100
    )
        external
        notZero(address(_inflationReceiver))
        onlyGovernance
    {
        if (_topupType == TopupType.FACTOROFDAILYAUTHORIZED) {
            require(_topupFactorX100 > 100, ERR_TOPUP_LOW);
        }
        TopupConfiguration storage topupConfiguration = topupConfigurations[_inflationReceiver];
        topupConfiguration.topupType = _topupType;
        topupConfiguration.topupFactorX100 = _topupFactorX100;
        topupConfiguration.configured = true;

        emit TopupConfigurationSet(topupConfiguration);
    }

    /**
     * @notice Given an inflation receiver, get the topup configuration.
     * @param _inflationReceiver    The reward service.
     * @return _topupConfiguration  The configurartion of how the topup requests are calculated for a given
     *                              reward service.
     */
    function getTopupConfiguration(
        IIInflationReceiver _inflationReceiver
    )
        external
        notZero(address(_inflationReceiver))
        returns(TopupConfiguration memory _topupConfiguration)
    {
        TopupConfiguration storage topupConfiguration = topupConfigurations[_inflationReceiver];
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
     * @notice Pulsed by the FlareDaemon to trigger timing-based events for the inflation process.
     * @dev There are two events:
     *   1) an annual event to recognize inflation for a new annum
     *   2) a daily event to:
     *     a) authorize mintable inflation for rewarding
     *     b) request minting of enough native tokens to topup reward services for claiming reserves
     */
    function daemonize() external virtual override notZero(address(supply)) onlyFlareDaemon returns(bool) {
        // If inflation rewarding not started yet, blow off processing until it does.
        if (block.timestamp < rewardEpochStartTs) {
            return true;
        }

        // If inflation rewarding started and we have not updated when it started, do so now.
        if (rewardEpochStartedTs == 0) {
            rewardEpochStartedTs = block.timestamp;
        }

        // Is it time to recognize an initial inflation annum?
        if (inflationAnnums.getCount() == 0) {
            _initNewAnnum(block.timestamp);
        } else {
            uint256 currentAnnumEndTimeStamp = inflationAnnums.getCurrentAnnum().endTimeStamp;

            // Is it time to recognize a new inflation annum?
            if (block.timestamp > currentAnnumEndTimeStamp) {
                _initNewAnnum(currentAnnumEndTimeStamp.add(1));
            }
        }

        // Is it time to authorize new inflation? Do it daily.
        if (lastAuthorizationTs.add(AUTHORIZE_TIME_FRAME_SEC) < block.timestamp) {

            // Update time we last authorized.
            lastAuthorizationTs = block.timestamp;

            // Authorize inflation for current sharing percentges.
            uint256 amountAuthorizedWei = inflationAnnums.authorizeDailyInflation(
                block.timestamp,
                inflationSharingPercentageProvider.getSharingPercentages()
            );

            emit InflationAuthorized(amountAuthorizedWei);

            // Call supply contract to keep inflatable balance and circulating supply updated.
            try supply.updateAuthorizedInflationAndCirculatingSupply(amountAuthorizedWei) {
            } catch Error(string memory message) {
                revert(message);
            } catch {
                revert(ERR_SUPPLY_UPDATE);
            }

            // Time to compute topup amount for inflation receivers.
            uint256 topupRequestWei = inflationAnnums.computeTopupRequest(this);

            emit TopupRequested(topupRequestWei);

            // Send mint request to the daemon.
            try flareDaemon.requestMinting(topupRequestWei) {
            } catch Error(string memory message) {
                revert(message);
            } catch {
                revert(ERR_REQUEST_MINT);
            }
        }
        return true;
    }

    function switchToFallbackMode() external view override onlyFlareDaemon returns (bool) {
        // do nothing - there is no fallback mode in Inflation
        return false;
    }

    function _initNewAnnum(uint256 startTs) internal {
        uint256 inflatableSupply = supply.getInflatableBalance();

        try inflationPercentageProvider.getAnnualPercentageBips() returns(uint256 annualPercentBips) {
            inflationAnnums.initializeNewAnnum(startTs, inflatableSupply, annualPercentBips);
        } catch Error(string memory message) {
            revert(message);
        } catch {
            revert(ERR_GET_ANNUAL_PERCENT);
        }

        InflationAnnum.InflationAnnumState memory inflationAnnum = inflationAnnums.getCurrentAnnum();

        emit NewAnnumInitialized(
            inflationAnnum.daysInAnnum, 
            inflationAnnum.startTimeStamp,
            inflationAnnum.endTimeStamp,
            inflatableSupply,
            inflationAnnum.recognizedInflationWei,
            inflationAnnum.rewardServices.totalAuthorizedInflationWei,
            inflationAnnum.rewardServices.totalInflationTopupRequestedWei,
            inflationAnnum.rewardServices.totalInflationTopupReceivedWei,
            inflationAnnum.rewardServices.totalInflationTopupWithdrawnWei
        );
    }

    /**
     * @notice Compute the expected balance of this contract.
     * @param _balanceExpectedWei   The computed balance expected.
     */
    function getExpectedBalance() private view returns(uint256 _balanceExpectedWei) {
        return inflationAnnums.totalInflationTopupReceivedWei        
            .sub(inflationAnnums.totalInflationTopupWithdrawnWei)
            .add(totalSelfDestructReceivedWei)
            .sub(totalSelfDestructWithdrawnWei);
    }
}
