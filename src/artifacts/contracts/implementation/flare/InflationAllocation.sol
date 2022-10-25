// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "../../governance/implementation/Governed.sol";
import "../../addressUpdater/implementation/AddressUpdatable.sol";
import "./Inflation.sol";
import "../interface/IIInflationAllocation.sol";

/**
 * @title Inflation allocation contract
 * @notice This contract implements Inflation settings agreed upon by Flare Foundation governance.
 **/
contract InflationAllocation is IIInflationAllocation, Governed, AddressUpdatable {

    struct InflationReceiver {
        IIInflationReceiver receiverContract;
        uint32 percentageBips; // limited to BIPS100
    }

    // constants
    string internal constant ERR_LENGTH_MISMATCH = "length mismatch";
    string internal constant ERR_HIGH_SHARING_PERCENTAGE = "high sharing percentage";
    string internal constant ERR_SUM_SHARING_PERCENTAGE = "sum sharing percentage not 100%";
    string internal constant ERR_IS_ZERO = "address is 0"; 
    string internal constant ANNUAL_INFLATION_OUT_OF_BOUNDS = "annual inflation out of bounds";
    string internal constant ERR_ANNUAL_INFLATION_SCHEDULE_EMPTY = "annual inflation schedule empty";
    string internal constant ERR_TOO_MANY = "too many";
    string internal constant ERR_ONLY_INFLATION = "only inflation";

    uint256 internal constant BIPS100 = 1e4;                            // 100% in basis points
    uint256 internal constant MAX_SCHEDULE_COUNT = 25;
    uint256 internal constant MAX_INFLATION_RECEIVERS = 10;
    uint256 internal constant MAX_INFLATION_PERCENTAGE_BIPS = BIPS100 / 10;  // 10% in basis points

    InflationReceiver[] public inflationReceivers;
    Inflation public inflation;
    uint256 public lastAnnualInflationPercentageBips;
    uint256[] public annualInflationPercentagesBips;

    event InflationSet(address oldAddress, address newAddress);
    event AnnualInflationPercentageYielded(uint256 percentageBips);
    event AnnualInflationPercentageScheduleSet(uint256[] annualInflationPercentagesBips);
    event InflationSharingPercentagesSet(
        IIInflationReceiver[] inflationReceivers, 
        uint256[] percentagePerReceiverBips
    );

    modifier notZero(address _address) {
        require(_address != address(0), ERR_IS_ZERO);
        _;
    }

    modifier onlyInflation {
        require(msg.sender == address(inflation), ERR_ONLY_INFLATION);
        _;
    }

    /**
     * @dev _inflation contract need not be set here, but must be set at the point that
     *   annual inflation percentages are to be retrieved from the schedule.
     */
    constructor(
        address _governance,
        address _addressUpdater,
        uint256[] memory _annualInflationScheduleBips
    ) 
        Governed(_governance) AddressUpdatable(_addressUpdater)
    {
        require(_annualInflationScheduleBips.length > 0, ERR_ANNUAL_INFLATION_SCHEDULE_EMPTY);

        // validity is checked in _setAnnualInflationSchedule
        lastAnnualInflationPercentageBips = _annualInflationScheduleBips[0];
        _setAnnualInflationSchedule(_annualInflationScheduleBips);
    }

    /**
     * @notice Set the sharing percentages between inflation receiver contracts. Percentages must sum
     *   to 100%.
     * @param _inflationReceivers   An array of contracts to receive inflation rewards for distribution.
     * @param _percentagePerReceiverBips    An array of sharing percentages in bips.
     */
    function setSharingPercentages(
        IIInflationReceiver[] memory _inflationReceivers, 
        uint256[] memory _percentagePerReceiverBips
    )
        external
        onlyGovernance 
    {
        _setSharingPercentages(_inflationReceivers, _percentagePerReceiverBips);
    }

    /**
     * @notice Set the annual inflation percentage schedule. This schedule is meant to be set for recognition
     *   a per-annum basis.
     * @param _annualInflationScheduleBips  An array of inflation percentages in bips.
     * @dev The schedule must be a decaying schedule. Once the schedule has been used up, the last percentage
     *   yielded will be the percentage that will continue to be yielded.
     */
    function setAnnualInflation(uint256[] memory _annualInflationScheduleBips) external onlyGovernance {
        // Clear the existing schedule
        uint256 lenExistingSchedule = annualInflationPercentagesBips.length;
        for (uint256 i = 0; i < lenExistingSchedule; i++) {
            annualInflationPercentagesBips.pop();
        }

        // Set new schedule
        _setAnnualInflationSchedule(_annualInflationScheduleBips);

        emit AnnualInflationPercentageScheduleSet(_annualInflationScheduleBips);
    }

    /**
     * @notice Get the next annual inflation percentage from the schedule and pop it off the schedule.
     *   If there are no percentages remaining within the schedule, yield the last percentage known.
     * @return The annual inflation percentage.
     * @dev Note that it is up to the caller to call this function at the appropriate annum interval.
     */
    function getAnnualPercentageBips() external override notZero(address(inflation)) onlyInflation returns(uint256) {
        // If there is not a schedule of percentages, return the last one given (or set).
        if (annualInflationPercentagesBips.length > 0) {
            // Since there is a schedule, get the next percentage.
            lastAnnualInflationPercentageBips = annualInflationPercentagesBips[0];
            // Iterate over the schedule, shifting each down an index
            uint256 len = annualInflationPercentagesBips.length;
            if (len > 1) {
                for (uint256 i = 0; i < len - 1; i++) {
                    annualInflationPercentagesBips[i] = annualInflationPercentagesBips[i+1];
                }
            }
            annualInflationPercentagesBips.pop();
        }
        emit AnnualInflationPercentageYielded(lastAnnualInflationPercentageBips);
        return lastAnnualInflationPercentageBips;
    }

    /**
     * @notice Get the inflation receiver contracts and the current sharing percentages.
     * @return _sharingPercentages An array of SharingPercentage.
     */
    function getSharingPercentages() external view override returns(SharingPercentage[] memory _sharingPercentages) {
        uint256 len = inflationReceivers.length;

        _sharingPercentages = new SharingPercentage[](len);

        for (uint i = 0; i < len; i++) {
            _sharingPercentages[i].percentBips = inflationReceivers[i].percentageBips;
            _sharingPercentages[i].inflationReceiver = inflationReceivers[i].receiverContract;
        }
    }

    /**
     * @notice Set the sharing percentages between inflation receiver contracts. Percentages must sum
     *   to 100%.
     * @param _inflationReceivers   An array of contracts to receive inflation rewards for distribution.
     * @param _percentagePerReceiverBips    An array of sharing percentages in bips.
     */
    function _setSharingPercentages(
        IIInflationReceiver[] memory _inflationReceivers, 
        uint256[] memory _percentagePerReceiverBips
    )
        internal
    {
        require(_inflationReceivers.length == _percentagePerReceiverBips.length, ERR_LENGTH_MISMATCH);
        require (_inflationReceivers.length <= MAX_INFLATION_RECEIVERS, ERR_TOO_MANY);

        uint256 sumSharingPercentage;

        uint256 len = inflationReceivers.length;
        for (uint256 i = 0; i < len; i++) {
            inflationReceivers.pop();
        }

        for (uint256 i = 0; i < _inflationReceivers.length; i++) {
            require (_percentagePerReceiverBips[i] <= BIPS100, ERR_HIGH_SHARING_PERCENTAGE);
            require (_inflationReceivers[i] != IIInflationReceiver(0), ERR_IS_ZERO);

            sumSharingPercentage += _percentagePerReceiverBips[i];

            inflationReceivers.push( InflationReceiver({
                receiverContract: _inflationReceivers[i],
                percentageBips: uint32(_percentagePerReceiverBips[i])
            }));
        }

        require (sumSharingPercentage == BIPS100, ERR_SUM_SHARING_PERCENTAGE);
        emit InflationSharingPercentagesSet(_inflationReceivers, _percentagePerReceiverBips);
    }

    /**
     * @notice Implementation of the AddressUpdatable abstract method - updates Inflation 
     * and inflation receivers contracts.
     */
    function _updateContractAddresses(
        bytes32[] memory _contractNameHashes,
        address[] memory _contractAddresses
    )
        internal override
    {
        Inflation _inflation = Inflation(_getContractAddress(_contractNameHashes, _contractAddresses, "Inflation"));
        emit InflationSet(address(inflation), address(_inflation));
        inflation = _inflation;

        uint256 len = inflationReceivers.length;
        if (len == 0) {
            return;
        }

        IIInflationReceiver[] memory receivers = new IIInflationReceiver[](len);
        uint256[] memory percentages = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            InflationReceiver memory inflationReceiver = inflationReceivers[i];
            receivers[i] = IIInflationReceiver(
                _getContractAddress(_contractNameHashes, _contractAddresses, 
                inflationReceiver.receiverContract.getContractName()));
            percentages[i] = inflationReceiver.percentageBips;
        }

        _setSharingPercentages(receivers, percentages);
    }

     /**
     * @notice Set the annual inflation percentage schedule. This schedule is meant to be set for recognition
     *   a per-annum basis.
     * @param _annualInflationScheduleBips  An array of inflation percentages in bips.
     * @dev The schedule must be a decaying schedule. Once the schedule has been used up, the last percentage
     *   yielded will be the percentage that will continue to be yielded.
     */
    function _setAnnualInflationSchedule(uint256[] memory _annualInflationScheduleBips) internal {
        require(_annualInflationScheduleBips.length <= MAX_SCHEDULE_COUNT, ERR_TOO_MANY);
        uint256 len = _annualInflationScheduleBips.length;
        uint256 lastOne = lastAnnualInflationPercentageBips;

        for (uint256 i = 0; i < len; i++) {
            // Validate the schedule...percentages must be the same or decay, and cannot be greater than last given.
            require(
                _annualInflationScheduleBips[i] <= lastOne && 
                _annualInflationScheduleBips[i] > 0 &&
                _annualInflationScheduleBips[i] <= MAX_INFLATION_PERCENTAGE_BIPS,
                ANNUAL_INFLATION_OUT_OF_BOUNDS);
                lastOne = _annualInflationScheduleBips[i];

            // Push in the new schedule
            annualInflationPercentagesBips.push(_annualInflationScheduleBips[i]);
        }
    }
}
