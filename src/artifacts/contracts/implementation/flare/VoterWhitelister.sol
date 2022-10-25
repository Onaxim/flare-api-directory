// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "../interface/IIVoterWhitelister.sol";
import "../../addressUpdater/implementation/AddressUpdatable.sol";
import "../../genesis/interface/IIPriceSubmitter.sol";
import "../../governance/implementation/Governed.sol";
import "../../token/interface/IIVPToken.sol";
import "../../userInterfaces/IFtsoRegistry.sol";
import "../../utils/implementation/SafePct.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


contract VoterWhitelister is IIVoterWhitelister, Governed, AddressUpdatable {
    using SafeMath for uint256;
    using SafePct for uint256;

    uint256 internal constant TERA = 10 ** 12;                    // 10^12
    uint256 internal constant BIPS100 = 10 ** 4;                  // 100 * 100%

    uint256 public override defaultMaxVotersForFtso;
        
    /**
     * Maximum number of voters in a single ftso whitelist.
     * Adjustable separately for each ftsoIndex.
     */
    mapping (uint256 => uint256) public override maxVotersForFtso;
    
    // mapping: ftsoIndex => array of whitelisted voters for this ftso
    mapping (uint256 => address[]) internal whitelist;
    
    IIPriceSubmitter public immutable priceSubmitter;
    
    IFtsoRegistry public ftsoRegistry;

    address public ftsoManager;

    modifier onlyFtsoManager {
        require(msg.sender == ftsoManager, "only ftso manager");
        _;
    }
    
    constructor(
        address _governance,
        address _addressUpdater,
        IIPriceSubmitter _priceSubmitter,
        uint256 _defaultMaxVotersForFtso
    )
        Governed(_governance) AddressUpdatable(_addressUpdater)
    {
        priceSubmitter = _priceSubmitter;
        defaultMaxVotersForFtso = _defaultMaxVotersForFtso;
    }
    
    /**
     * Request to whitelist `_voter` account to all active ftsos.
     * May be called by any address.
     * It returns an array of supported ftso indices and success flag per index.
     */
    function requestFullVoterWhitelisting(
        address _voter
    ) 
        external override 
        returns (
            uint256[] memory _supportedIndices,
            bool[] memory _success
        )
    {
        if (_isTrustedAddress(_voter)) {
            revert("trusted address");
        }

        _supportedIndices = ftsoRegistry.getSupportedIndices();
        uint256 len = _supportedIndices.length;
        _success = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            _success[i] = _requestWhitelistingVoter(_voter, _supportedIndices[i]);
        }
    }
    
    /**
     * Request to whitelist `_voter` account to ftso at `_ftsoIndex`. Will revert if vote power too low.
     * May be called by any address.
     */
    function requestWhitelistingVoter(address _voter, uint256 _ftsoIndex) external override {
        if (_isTrustedAddress(_voter)) {
            revert("trusted address");
        }
        
        bool success = _requestWhitelistingVoter(_voter, _ftsoIndex);
        require(success, "vote power too low");
    }

    /**
     * Set the maximum number of voters in the whitelist for FTSO at index `_ftsoIndex`.
     * Calling this function might remove several voters with the least votepower from the whitelist.
     */
    function setMaxVotersForFtso(uint256 _ftsoIndex, uint256 _newMaxVoters) external override onlyGovernance {
        maxVotersForFtso[_ftsoIndex] = _newMaxVoters;
        // need to remove any?
        address[] storage addressesForFtso = whitelist[_ftsoIndex];
        if (_newMaxVoters >= addressesForFtso.length) {
            return;
        }
        // remove voters with minimum vote power
        IIFtso ftso = ftsoRegistry.getFtso(_ftsoIndex);
        uint256[] memory votePowers = _getVotePowerWeights(ftso, addressesForFtso);
        uint256 length = votePowers.length;
        uint256 toRemove = length - _newMaxVoters;
        address[] memory removedVoters = new address[](toRemove);
        for (uint256 n = 0; n < toRemove; n++) {
            uint256 minIndex = _findMinimum(votePowers, length);
            removedVoters[n] = addressesForFtso[minIndex];
            if (minIndex < length - 1) {
                addressesForFtso[minIndex] = addressesForFtso[length - 1];
                votePowers[minIndex] = votePowers[length - 1];
            }
            addressesForFtso.pop();
            --length;
        }
        _votersRemovedFromWhitelist(removedVoters, _ftsoIndex);
    }
    
    /**
     * Set the maximum number of voters in the whitelist for a new FTSO.
     */
    function setDefaultMaxVotersForFtso(uint256 _defaultMaxVotersForFtso) external override onlyGovernance {
        defaultMaxVotersForFtso = _defaultMaxVotersForFtso;
    }
    
    /**
     * Create whitelist with default size for ftso.
     */
    function addFtso(uint256 _ftsoIndex) external override onlyFtsoManager {
        require(maxVotersForFtso[_ftsoIndex] == 0, "whitelist already exist");
        maxVotersForFtso[_ftsoIndex] = defaultMaxVotersForFtso;
    }
    
    /**
     * Clear whitelist for ftso at `_ftsoIndex`.
     */
    function removeFtso(uint256 _ftsoIndex) external override onlyFtsoManager {
        _votersRemovedFromWhitelist(whitelist[_ftsoIndex], _ftsoIndex);
        delete whitelist[_ftsoIndex];
        delete maxVotersForFtso[_ftsoIndex];
    }

    /**
     * Remove `_trustedAddress` from whitelist for ftso at `_ftsoIndex`.
     */
    function removeTrustedAddressFromWhitelist(address _trustedAddress, uint256 _ftsoIndex) external override {
        if (!_isTrustedAddress(_trustedAddress)) {
            revert("not trusted address");
        }
        address[] storage addressesForFtso = whitelist[_ftsoIndex];
        uint256 length = addressesForFtso.length;

        // find index of _trustedAddress
        uint256 index = 0;
        for ( ; index < length; index++) {
            if (addressesForFtso[index] == _trustedAddress) {
                break;
            }
        }

        require(index < length, "trusted address not whitelisted");
        
        // kick the index out and replace it with the last one
        address[] memory removedVoters = new address[](1);
        removedVoters[0] = addressesForFtso[index];
        addressesForFtso[index] = addressesForFtso[length - 1];
        addressesForFtso.pop();
        _votersRemovedFromWhitelist(removedVoters, _ftsoIndex);
    }

    /**
     * Get whitelisted price providers for ftso with `_symbol`
     */
    function getFtsoWhitelistedPriceProvidersBySymbol(
        string memory _symbol
    ) 
        external view override 
        returns (
            address[] memory
    ) 
    {
        uint256 ftsoIndex = ftsoRegistry.getFtsoIndex(_symbol);
        return getFtsoWhitelistedPriceProviders(ftsoIndex);
    }

    /**
     * Get whitelisted price providers for ftso at `_ftsoIndex`
     */
    function getFtsoWhitelistedPriceProviders(uint256 _ftsoIndex) public view override returns (address[] memory) {
        uint256 maxVoters = maxVotersForFtso[_ftsoIndex];
        require(maxVoters > 0, "FTSO index not supported");
        return whitelist[_ftsoIndex];
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
        ftsoRegistry = IFtsoRegistry(_getContractAddress(_contractNameHashes, _contractAddresses, "FtsoRegistry"));
        ftsoManager = _getContractAddress(_contractNameHashes, _contractAddresses, "FtsoManager");
    }

    /**
     * Request to whitelist `_voter` account to ftso at `_ftsoIndex` - implementation.
     */
    function _requestWhitelistingVoter(address _voter, uint256 _ftsoIndex) internal returns(bool) {
        uint256 maxVoters = maxVotersForFtso[_ftsoIndex];
        require(maxVoters > 0, "FTSO index not supported");
        
        address[] storage addressesForFtso = whitelist[_ftsoIndex];
        uint256 length = addressesForFtso.length;
        
        // copy to memory and check if it contains _voter
        address[] memory addresses = new address[](length + 1);
        for (uint256 i = 0; i < length; i++) {
            address addr = addressesForFtso[i];
            if (addr == _voter) {
                // _voter is already whitelisted, return
                return true;
            }
            addresses[i] = addr;
        }
        addresses[length] = _voter;
        
        // can we just add a new one?
        if (length < maxVoters) {
            addressesForFtso.push(_voter);
            _voterWhitelisted(_voter, _ftsoIndex);
            return true;
        }
        
        // find a candidate to kick out
        uint256 minIndex = _minVotePowerIndex(addresses, _ftsoIndex);
        if (minIndex == length) {
            // the new _voter has the minimum vote power, do nothing
            return false;
        }
        
        // kick the minIndex out and replace it with _voter
        address[] memory removedVoters = new address[](1);
        removedVoters[0] = addresses[minIndex];
        addressesForFtso[minIndex] = _voter;
        _votersRemovedFromWhitelist(removedVoters, _ftsoIndex);
        _voterWhitelisted(_voter, _ftsoIndex);

        return true;
    }
    
    /**
     * Find index of the element with minimum vote power weight.
     * In case of a tie, returns later index.
     */
    function _minVotePowerIndex(address[] memory _addresses, uint256 _ftsoIndex) internal returns (uint256) {
        IIFtso ftso = ftsoRegistry.getFtso(_ftsoIndex);
        uint256[] memory votePowers = _getVotePowerWeights(ftso, _addresses);
        return _findMinimum(votePowers, votePowers.length);
    }
    
    /**
     * Calculate vote power weights like FTSO.
     * Unlike FTSO, it calls VPToken vote power in a batch to limit gas consumption.
     * Another difference with FTSO is that voter turnout is ignored (it makes
     * no sense for whitelist, since it has to be initialized before any voting occurs).
     * Apart from turnout, the results should be equal as for FTSO.
     */
    function _getVotePowerWeights(IIFtso ftso, address[] memory _addresses) internal 
        returns (uint256[] memory _votePowers)
    {
        // get parameters
        IIVPToken[] memory assets;
        uint256[] memory assetMultipliers;
        uint256 totalVotePowerNat;
        uint256 totalVotePowerAsset;
        uint256 assetWeightRatio;
        uint256 votePowerBlock;
        (assets, assetMultipliers, totalVotePowerNat, totalVotePowerAsset, assetWeightRatio, votePowerBlock)
            = ftso.getVoteWeightingParameters();
        // nat vote powers
        uint256[] memory wNatVP = 
            _getNativeVotePowerWeights(ftso.wNat(), totalVotePowerNat, _addresses, votePowerBlock);
        // asset vote powers
        uint256[] memory combinedAssetVP = 
            _getAssetVotePowerWeights(assets, assetMultipliers, totalVotePowerAsset, _addresses, votePowerBlock);
        // combine asset and wNat
        return _computeWeightedSum(wNatVP, combinedAssetVP, assetWeightRatio);
    }
    
    /**
     * Calculate native vote power weights like FTSO.
     */
    function _getNativeVotePowerWeights(
        IIVPToken _wNat,
        uint256 _totalVotePowerNat,
        address[] memory _addresses, 
        uint256 _blockNumber
    )
        internal
        returns (uint256[] memory _wNatVP)
    {
        _wNatVP = _getVotePowers(_wNat, _addresses, _blockNumber);
        if (_totalVotePowerNat == 0) {
            return _wNatVP;  // if total is 0, all values must be 0, no division needed
        }
        for (uint256 i = 0; i < _addresses.length; i++) {
            _wNatVP[i] = _wNatVP[i].mulDiv(TERA, _totalVotePowerNat);
        }
    }
    
    /**
     * Calculate asset vote power weights like FTSO.
     */
    function _getAssetVotePowerWeights(
        IIVPToken[] memory _assets,
        uint256[] memory _assetMultipliers,
        uint256 _totalVotePowerAsset,
        address[] memory _addresses, 
        uint256 _blockNumber
    )
        internal 
        returns (uint256[] memory _combinedAssetVP)
    {
        _combinedAssetVP = new uint256[](_addresses.length);
        for (uint256 i = 0; i < _addresses.length; i++) {
            _combinedAssetVP[i] = 0;
        }
        if (_totalVotePowerAsset == 0) {
            return _combinedAssetVP;
        }
        uint256 divisor = _totalVotePowerAsset.mul(1e18);
        for (uint256 n = 0; n < _assets.length; n++) {
            IIVPToken asset = _assets[n];
            if (address(asset) != address(0)) {
                uint256[] memory assetVP = _getVotePowers(asset, _addresses, _blockNumber);
                // add
                for (uint256 i = 0; i < _addresses.length; i++) {
                    uint256 weightedVP = assetVP[i].mulDiv(_assetMultipliers[n], divisor);
                    _combinedAssetVP[i] = _combinedAssetVP[i].add(weightedVP);
                }
            }
        }
    }
    
    /**
     * Get vote powers from VPToken in a batch.
     * This is needed to avoid gas consumption of many cros-contract calls.
     */
    function _getVotePowers(
        IIVPToken _token, 
        address[] memory _addresses, 
        uint256 _blockNumber
    )
        internal 
        returns (uint256[] memory)
    {
        // warm up cache for new voter (in this way everyone pays cache storing price for himself)
        _token.votePowerOfAtCached(_addresses[_addresses.length - 1], _blockNumber);
        // get all vote powers in a batch
        return _token.batchVotePowerOfAt(_addresses, _blockNumber);
    }
    
    /**
     * Checks if _voter is trusted address
     */
    function _isTrustedAddress(address _voter) internal view returns(bool) {
        address[] memory trustedAddresses = priceSubmitter.getTrustedAddresses();
        for (uint256 i = 0; i < trustedAddresses.length; i++) {
            if (trustedAddresses[i] == _voter) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * Update a voter whitelisting and emit an event.
     */    
    function _voterWhitelisted(address _voter, uint256 _ftsoIndex) private {
        emit VoterWhitelisted(_voter, _ftsoIndex);
        priceSubmitter.voterWhitelisted(_voter, _ftsoIndex);
    }
    
    /**
     * Update when a  voter is removed from the whitelist. And emit an event.
     */    
    function _votersRemovedFromWhitelist(address[] memory _removedVoters, uint256 _ftsoIndex) private {
        for (uint256 i = 0; i < _removedVoters.length; i++) {
            emit VoterRemovedFromWhitelist(_removedVoters[i], _ftsoIndex);
        }
        priceSubmitter.votersRemovedFromWhitelist(_removedVoters, _ftsoIndex);
    }

    /**
     * Calculate sum of all values in an array.
     */
    function _arraySum(uint256[] memory array) private pure returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < array.length; i++) {
            result = result.add(array[i]);
        }
        return result;
    }
    
    /**
     * Calculate weighted sum of two arrays (like in FTSO):
     *  result[i] = (100% - _assetWeightRatio) * _weightsNat[i] + _assetWeightRatio * _weightsAsset[i]
     */
    function _computeWeightedSum(
        uint256[] memory _weightsNat,
        uint256[] memory _weightsAsset,
        uint256 _assetWeightRatio
    )
        private pure 
        returns (uint256[] memory _weights)
    {
        uint256 weightAssetSum = _arraySum(_weightsAsset);
        uint256 weightNatSum = _arraySum(_weightsNat);
        uint256 weightAssetShare = weightAssetSum > 0 ? _assetWeightRatio : 0;
        uint256 weightNatShare = weightNatSum > 0 ? BIPS100 - weightAssetShare : 0;
        _weights = new uint256[](_weightsNat.length);
        for (uint256 i = 0; i < _weightsNat.length; i++) {
            uint256 weightNat = 0;
            if (weightNatShare > 0) {
                weightNat = weightNatShare.mulDiv(TERA * _weightsNat[i], weightNatSum * BIPS100);
            }
            uint256 weightAsset = 0;
            if (weightAssetShare > 0) {
                weightAsset = weightAssetShare.mulDiv(TERA * _weightsAsset[i], weightAssetSum * BIPS100);
            }
            _weights[i] = weightNat + weightAsset;
        }
    }

    /**
     * Find minimum index of an uint256 array.
     * In case of a tie, returns later index.
     */
    function _findMinimum(uint256[] memory _votePowers, uint256 _length) private pure returns (uint256) {
        uint256 minIndex = 0;
        uint256 minVP = _votePowers[0];
        for (uint256 i = 0; i < _length; i++) {
            uint256 vp = _votePowers[i];
            // using `<=` ensures that later index is used if there is a tie
            // this is useful because in requestWhitelistingVoter, the new voter is last
            // also, when removing, it is cheaper to remove last element
            if (vp <= minVP) {
                minIndex = i;
                minVP = vp;
            }
        }
        return minIndex;
    }
}
