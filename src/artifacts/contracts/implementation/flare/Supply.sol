// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "../interface/IISupply.sol";
import "../../tokenPools/interface/IITokenPool.sol";
import "../../token/lib/CheckPointHistory.sol";
import "../../token/lib/CheckPointHistoryCache.sol";
import "../../governance/implementation/Governed.sol";
import "../../addressUpdater/implementation/AddressUpdatable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


/**
 * @title Supply contract
 * @notice This contract maintains and computes various native token supply totals.
 **/

contract Supply is IISupply, Governed, AddressUpdatable {
    using CheckPointHistory for CheckPointHistory.CheckPointHistoryState;
    using CheckPointHistoryCache for CheckPointHistoryCache.CacheState;
    using SafeMath for uint256;

    address payable private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    struct SupplyData {
        IITokenPool tokenPool;
        uint256 totalLockedWei;
        uint256 totalInflationAuthorizedWei;
        uint256 totalClaimedWei;
    }

    string internal constant ERR_INFLATION_ONLY = "inflation only";
    string internal constant ERR_TOKEN_POOL_ALREADY_ADDED = "token pool already added";
    string internal constant ERR_INITIAL_GENESIS_AMOUNT_ZERO = "initial genesis amount zero";

    CheckPointHistory.CheckPointHistoryState private circulatingSupplyWei;
    CheckPointHistoryCache.CacheState private circulatingSupplyWeiCache;

    uint256 immutable public initialGenesisAmountWei;
    uint256 immutable public totalExcludedSupplyWei; // Foundation supply, distribution treasury, team escrow
    uint256 public distributedExcludedSupplyWei;
    uint256 public totalLockedWei; // Amounts temporary locked and not considered in the inflatable supply
    uint256 public totalInflationAuthorizedWei;
    uint256 public totalClaimedWei;

    SupplyData[] public tokenPools;

    address public inflation;

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
        address _addressUpdater,
        uint256 _initialGenesisAmountWei,
        uint256 _totalExcludedSupplyWei,
        IITokenPool[] memory _tokenPools
    )
        Governed(_governance) AddressUpdatable(_addressUpdater)
    {
        require(_initialGenesisAmountWei > 0, ERR_INITIAL_GENESIS_AMOUNT_ZERO);
        initialGenesisAmountWei = _initialGenesisAmountWei;
        totalExcludedSupplyWei = _totalExcludedSupplyWei;

        _increaseCirculatingSupply(_initialGenesisAmountWei.sub(_totalExcludedSupplyWei));

        for (uint256 i = 0; i < _tokenPools.length; i++) {
            _addTokenPool(_tokenPools[i]);
        }

        _updateCirculatingSupply(BURN_ADDRESS);
    }

    /**
     * @notice Updates circulating supply
     * @dev Also updates the burn address amount
    */
    function updateCirculatingSupply() external override onlyInflation {
        _updateCirculatingSupply(BURN_ADDRESS);
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
        
        _updateCirculatingSupply(BURN_ADDRESS);
        
        // Check if new authorized inflation was distributed and updated correctly.
        if (totalInflationAuthorizedWei != oldTotalInflationAuthorizedWei.add(_inflationAuthorizedWei)) {
            emit AuthorizedInflationUpdateError(totalInflationAuthorizedWei - oldTotalInflationAuthorizedWei,
                _inflationAuthorizedWei);
        }
    }

    /**
     * @notice Adds token pool so it can call updateTokenPoolDistributedAmount method when 
        some tokens are distributed
     * @param _tokenPool                            Token pool address
     * @param _increaseDistributedSupplyByAmountWei If token pool was given initial supply from excluded supply, 
        increase distributed value by this amount
     */
    function addTokenPool(
        IITokenPool _tokenPool,
        uint256 _increaseDistributedSupplyByAmountWei
    )
        external
        onlyGovernance
    {
        _increaseDistributedSupply(_increaseDistributedSupplyByAmountWei);
        _addTokenPool(_tokenPool);
        _updateCirculatingSupply(BURN_ADDRESS);
    }

    /**
     * @notice Increase distributed supply when excluded funds are released to a token pool or team members
     * @param _amountWei                            Amount to increase by
     */
    function increaseDistributedSupply(uint256 _amountWei) external onlyGovernance {
        _increaseDistributedSupply(_amountWei);
        _updateCirculatingSupply(BURN_ADDRESS);
    }

    /**
     * @notice Descrease distributed supply if excluded funds are no longer locked to a token pool
     * @param _amountWei                            Amount to decrease by
     */
    function decreaseDistributedSupply(uint256 _amountWei) external onlyGovernance {
        distributedExcludedSupplyWei = distributedExcludedSupplyWei.sub(_amountWei);
        _decreaseCirculatingSupply(_amountWei);
        _updateCirculatingSupply(BURN_ADDRESS);
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
     * @notice Get total inflatable balance (initial genesis amount + total claimed - total excluded/locked amount)
     * @return _inflatableBalanceWei Return inflatable balance
    */
    function getInflatableBalance() external view override returns(uint256 _inflatableBalanceWei) {
        return initialGenesisAmountWei
            .add(totalClaimedWei)
            .sub(totalExcludedSupplyWei.sub(distributedExcludedSupplyWei))
            .sub(totalLockedWei);
    }

    /**
     * Return the burn address (a constant).
     */
    function burnAddress() external pure returns (address payable) {
        return BURN_ADDRESS;
    }

    /**
     * @notice Implementation of the AddressUpdatable abstract method.
     */
    function _updateContractAddresses(
        bytes32[] memory _contractNameHashes,
        address[] memory _contractAddresses
    )
        internal override
    {
        inflation = _getContractAddress(_contractNameHashes, _contractAddresses, "Inflation");
    }

    function _increaseCirculatingSupply(uint256 _increaseBy) internal {
        circulatingSupplyWei.writeValue(circulatingSupplyWei.valueAtNow().add(_increaseBy));
    }

    function _decreaseCirculatingSupply(uint256 _descreaseBy) internal {
        circulatingSupplyWei.writeValue(circulatingSupplyWei.valueAtNow().sub(_descreaseBy));
    }

    function _updateCirculatingSupply(address _burnAddress) internal {
        uint256 len = tokenPools.length;
        for (uint256 i = 0; i < len; i++) {
            SupplyData storage data = tokenPools[i];

            uint256 newTotalLockedWei;
            uint256 newTotalInflationAuthorizedWei;
            uint256 newTotalClaimedWei;
            
            (newTotalLockedWei, newTotalInflationAuthorizedWei, newTotalClaimedWei) = 
                data.tokenPool.getTokenPoolSupplyData();
            assert(newTotalLockedWei.add(newTotalInflationAuthorizedWei) >= newTotalClaimedWei);
            
            // updates total inflation authorized with daily authorized inflation
            uint256 dailyInflationAuthorizedWei = newTotalInflationAuthorizedWei.sub(data.totalInflationAuthorizedWei);
            totalInflationAuthorizedWei = totalInflationAuthorizedWei.add(dailyInflationAuthorizedWei);

            // updates circulating supply
            uint256 claimChange = newTotalClaimedWei.sub(data.totalClaimedWei);
            _increaseCirculatingSupply(claimChange);
            totalClaimedWei = totalClaimedWei.add(claimChange);
            if (newTotalLockedWei >= data.totalLockedWei) {
                uint256 lockChange = newTotalLockedWei - data.totalLockedWei;
                _decreaseCirculatingSupply(lockChange);
                totalLockedWei = totalLockedWei.add(lockChange);
            } else {
                // if founds are unlocked, they are returned to excluded amount
                uint256 lockChange = data.totalLockedWei - newTotalLockedWei;
                distributedExcludedSupplyWei = distributedExcludedSupplyWei.sub(lockChange);
                totalLockedWei = totalLockedWei.sub(lockChange);
            }

            // update data
            data.totalLockedWei = newTotalLockedWei;
            data.totalInflationAuthorizedWei = newTotalInflationAuthorizedWei;
            data.totalClaimedWei = newTotalClaimedWei;
        }

        _updateBurnAddressAmount(_burnAddress);
    }

    function _updateBurnAddressAmount(address _burnAddress) internal {
        uint256 newBalance = _burnAddress.balance;
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
    
    function _increaseDistributedSupply(uint256 _amountWei) internal {
        assert(totalExcludedSupplyWei.sub(distributedExcludedSupplyWei) >= _amountWei);
        _increaseCirculatingSupply(_amountWei);
        distributedExcludedSupplyWei = distributedExcludedSupplyWei.add(_amountWei);
    }
}
