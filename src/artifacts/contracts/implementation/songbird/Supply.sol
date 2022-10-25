// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "../interface/IISupply.sol";
import "../../tokenPools/interface/IITokenPool.sol";
import "../../token/lib/CheckPointHistory.sol";
import "../../token/lib/CheckPointHistoryCache.sol";
import "../../governance/implementation/Governed.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @title Supply contract
 * @notice This contract maintains and computes various native token supply totals.
 **/

contract Supply is Governed, IISupply {
    using CheckPointHistory for CheckPointHistory.CheckPointHistoryState;
    using CheckPointHistoryCache for CheckPointHistoryCache.CacheState;
    using SafeMath for uint256;

    struct SupplyData {
        IITokenPool tokenPool;
        uint256 foundationAllocatedFundsWei;
        uint256 totalInflationAuthorizedWei;
        uint256 totalClaimedWei;
    }

    string internal constant ERR_INFLATION_ONLY = "inflation only";
    string internal constant ERR_INFLATION_ZERO = "inflation zero";
    string internal constant ERR_TOKEN_POOL_ALREADY_ADDED = "token pool already added";
    string internal constant ERR_INITIAL_GENESIS_AMOUNT_ZERO = "initial genesis amount zero";

    CheckPointHistory.CheckPointHistoryState private circulatingSupplyWei;
    CheckPointHistoryCache.CacheState private circulatingSupplyWeiCache;

    uint256 immutable public initialGenesisAmountWei;
    uint256 public totalInflationAuthorizedWei;
    uint256 public totalFoundationSupplyWei;
    uint256 public distributedFoundationSupplyWei;

    SupplyData[] public tokenPools;

    address public inflation;
    address public burnAddress;

    // balance of burn address at last check - needed for updating circulating supply
    uint256 private burnAddressBalance;

    // events
    event AuthorizedInflationUpdateError(uint256 actual, uint256 expected);

    modifier onlyInflation {
        require(msg.sender == inflation, ERR_INFLATION_ONLY);
        _;
    }

    constructor(
        address _governance,
        address _burnAddress,
        address _inflation,
        uint256 _initialGenesisAmountWei,
        uint256 _totalFoundationSupplyWei,
        IITokenPool[] memory _tokenPools
    )
        Governed(_governance)
    {
        require(_inflation != address(0), ERR_INFLATION_ZERO);
        require(_initialGenesisAmountWei > 0, ERR_INITIAL_GENESIS_AMOUNT_ZERO);
        burnAddress = _burnAddress;
        inflation = _inflation;
        initialGenesisAmountWei = _initialGenesisAmountWei;
        totalFoundationSupplyWei = _totalFoundationSupplyWei;

        _increaseCirculatingSupply(_initialGenesisAmountWei.sub(_totalFoundationSupplyWei));

        for (uint256 i = 0; i < _tokenPools.length; i++) {
            _addTokenPool(_tokenPools[i]);
        }

        _updateCirculatingSupply();
    }

    /**
     * @notice Updates authorized inflation and circulating supply - emits event if error
     * @param _inflationAuthorizedWei               Authorized inflation
     * @dev Also updates the burn address amount
    */
    function updateAuthorizedInflationAndCirculatingSupply(
            uint256 _inflationAuthorizedWei
    )
        external override
        onlyInflation 
    {
        // Save old total inflation authorized value to compare with after update.
        uint256 oldTotalInflationAuthorizedWei = totalInflationAuthorizedWei;
        
        _updateCirculatingSupply();
        
        // Check if new authorized inflation was distributed and updated correctly.
        if (totalInflationAuthorizedWei != oldTotalInflationAuthorizedWei.add(_inflationAuthorizedWei)) {
            emit AuthorizedInflationUpdateError(totalInflationAuthorizedWei - oldTotalInflationAuthorizedWei,
                _inflationAuthorizedWei);
        }
    }

    /**
     * @notice Sets inflation contract. Only governance can call this method.
     */
    function setInflation(address _inflation) external override onlyGovernance {
        require(_inflation != address(0), ERR_INFLATION_ZERO);
        inflation = _inflation;
    }

    /**
     * @notice Adds token pool so it can call updateTokenPoolDistributedAmount method when 
        some tokens are distributed
     * @param _tokenPool                            Token pool address
     * @param _decreaseFoundationSupplyByAmountWei  If token pool was given initial supply from fundation supply, 
        decrease it's value by this amount
     */
    function addTokenPool(
        IITokenPool _tokenPool,
        uint256 _decreaseFoundationSupplyByAmountWei
    )
        external
        onlyGovernance
    {
        _decreaseFoundationSupply(_decreaseFoundationSupplyByAmountWei);
        _addTokenPool(_tokenPool);
        _updateCirculatingSupply();
    }

    /**
     * @notice Decrease foundation supply when foundation funds are released to a token pool or team members
     * @param _amountWei                            Amount to decrease by
     */
    function decreaseFoundationSupply(uint256 _amountWei) external onlyGovernance {
        _decreaseFoundationSupply(_amountWei);
        _updateCirculatingSupply();
    }

    /**
     * @notice Change burn address
     * @param _burnAddress                          New burn address
     * @dev Updates burn value for current address, changes to new address and updates again
     */
    function changeBurnAddress(address _burnAddress) external onlyGovernance {
        _updateCirculatingSupply();
        burnAddressBalance = 0;
        burnAddress = _burnAddress;
        _updateBurnAddressAmount();
    }
    
    /**
     * @notice Get approximate circulating supply for given block number from cache - only past block
     * @param _blockNumber                          Block number
     * @return _circulatingSupplyWei Return approximate circulating supply for last known block <= _blockNumber
    */
    function getCirculatingSupplyAtCached(
        uint256 _blockNumber
    )
        external override 
        returns(uint256 _circulatingSupplyWei)
    {
        // use cache only for the past (the value will never change)
        require(_blockNumber < block.number, "Can only be used for past blocks");
        (_circulatingSupplyWei,) = circulatingSupplyWeiCache.valueAt(circulatingSupplyWei, _blockNumber);
    }

    /**
     * @notice Get approximate circulating supply for given block number
     * @param _blockNumber                          Block number
     * @return _circulatingSupplyWei Return approximate circulating supply for last known block <= _blockNumber
    */
    function getCirculatingSupplyAt(
        uint256 _blockNumber
    )
        external view override 
        returns(uint256 _circulatingSupplyWei)
    {
        return circulatingSupplyWei.valueAt(_blockNumber);
    }

    /**
     * @notice Get total inflatable balance (initial genesis amount + total authorized inflation)
     * @return _inflatableBalanceWei Return inflatable balance
    */
    function getInflatableBalance() external view override returns(uint256 _inflatableBalanceWei) {
        return initialGenesisAmountWei.add(totalInflationAuthorizedWei);
    }

    function _increaseCirculatingSupply(uint256 _increaseBy) internal {
        circulatingSupplyWei.writeValue(circulatingSupplyWei.valueAtNow().add(_increaseBy));
    }

    function _decreaseCirculatingSupply(uint256 _descreaseBy) internal {
        circulatingSupplyWei.writeValue(circulatingSupplyWei.valueAtNow().sub(_descreaseBy));
    }

    function _updateCirculatingSupply() internal {
        uint256 len = tokenPools.length;
        for (uint256 i = 0; i < len; i++) {
            SupplyData storage data = tokenPools[i];

            uint256 newFoundationAllocatedFundsWei;
            uint256 newTotalInflationAuthorizedWei;
            uint256 newTotalClaimedWei;
            
            (newFoundationAllocatedFundsWei, newTotalInflationAuthorizedWei, newTotalClaimedWei) = 
                data.tokenPool.getTokenPoolSupplyData();
            assert(newFoundationAllocatedFundsWei.add(newTotalInflationAuthorizedWei) >= newTotalClaimedWei);
            
            // updates total inflation authorized with daily authorized inflation
            uint256 dailyInflationAuthorizedWei = newTotalInflationAuthorizedWei.sub(data.totalInflationAuthorizedWei);
            totalInflationAuthorizedWei = totalInflationAuthorizedWei.add(dailyInflationAuthorizedWei);

            // updates circulating supply
            _decreaseCirculatingSupply(newFoundationAllocatedFundsWei.sub(data.foundationAllocatedFundsWei));
            _increaseCirculatingSupply(newTotalClaimedWei.sub(data.totalClaimedWei));

            // update data
            data.foundationAllocatedFundsWei = newFoundationAllocatedFundsWei;
            data.totalInflationAuthorizedWei = newTotalInflationAuthorizedWei;
            data.totalClaimedWei = newTotalClaimedWei;
        }

        _updateBurnAddressAmount();
    }

    function _updateBurnAddressAmount() internal {
        uint256 newBalance = burnAddress.balance;
        _decreaseCirculatingSupply(newBalance.sub(burnAddressBalance));
        burnAddressBalance = newBalance;
    }

    function _addTokenPool(IITokenPool _tokenPool) internal {
        uint256 len = tokenPools.length;
        for (uint256 i = 0; i < len; i++) {
            if (_tokenPool == tokenPools[i].tokenPool) {
                revert(ERR_TOKEN_POOL_ALREADY_ADDED);
            }
        }
        tokenPools.push();
        tokenPools[len].tokenPool = _tokenPool;
    }
    
    function _decreaseFoundationSupply(uint256 _amountWei) internal {
        assert(totalFoundationSupplyWei.sub(distributedFoundationSupplyWei) >= _amountWei);
        _increaseCirculatingSupply(_amountWei);
        distributedFoundationSupplyWei = distributedFoundationSupplyWei.add(_amountWei);
    }
}
