// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "../../governance/implementation/GovernedAtGenesis.sol";
import "../interface/IIPriceSubmitter.sol";


/**
 * @title Price submitter
 * @notice A contract used to submit/reveal prices to multiple Flare Time Series Oracles in one transaction
 */
contract PriceSubmitter is IIPriceSubmitter, GovernedAtGenesis {

    string internal constant ERR_ARRAY_LENGTHS = "Array lengths do not match";
    string internal constant ERR_NOT_WHITELISTED = "Not whitelisted";
    string internal constant ERR_FTSO_MANAGER_ONLY = "FTSOManager only";
    string internal constant ERR_WHITELISTER_ONLY = "Voter whitelister only";


    IFtsoRegistryGenesis internal ftsoRegistry; 
    address internal ftsoManager;
    address internal voterWhitelister;

    // Bit at index `i` corresponds to being whitelisted for vote on ftso at index `i`
    mapping(address => uint256) internal whitelistedFtsoBitmap;
    
    address[] internal trustedAddresses;
    // for checking addresses at submit/reveal
    mapping(address => bool) internal trustedAddressesMapping;

    
    modifier onlyFtsoManager {
        require(msg.sender == ftsoManager, ERR_FTSO_MANAGER_ONLY);
        _;
    }

    modifier onlyWhitelister {
        require(msg.sender == voterWhitelister, ERR_WHITELISTER_ONLY);
        _;
    }

    /**
     * @dev This constructor should contain no code as this contract is pre-loaded into the genesis block.
     *   The super constructor is called for testing convenience.
     */
    constructor() GovernedAtGenesis(address(0)) {
        /* empty block */
    }

    /**
     * Sets ftso registry, voter whitelist and ftso manager contracts.
     * Only governance can call this method.
     * If replacing the registry or the whitelist and the old one is not empty, make sure to replicate the state,
     * otherwise internal whitelist bitmaps won't match.
     */
    function setContractAddresses(
        IFtsoRegistryGenesis _ftsoRegistry,
        address _voterWhitelister,
        address _ftsoManager
    ) 
        external override 
        onlyGovernance
    {
        ftsoRegistry = _ftsoRegistry;
        voterWhitelister = _voterWhitelister;
        ftsoManager = _ftsoManager;
    }
    
    /**
     * Set trusted addresses that are always allowed to submit and reveal.
     * Only ftso manager can call this method.
     */
    function setTrustedAddresses(address[] memory _trustedAddresses) external override onlyFtsoManager {
        // remove old addresses mapping
        uint256 len = trustedAddresses.length;
        for (uint256 i = 0; i < len; i++) {
            trustedAddressesMapping[trustedAddresses[i]] = false;
        }
        // set new addresses mapping
        len = _trustedAddresses.length;
        for (uint256 i = 0; i < len; i++) {
            trustedAddressesMapping[_trustedAddresses[i]] = true;
        }
        trustedAddresses = _trustedAddresses;
    }
    
    /**
     * Called from whitelister when new voter has been whitelisted.
     */
    function voterWhitelisted(address _voter, uint256 _ftsoIndex) external override onlyWhitelister {
        whitelistedFtsoBitmap[_voter] |= 1 << _ftsoIndex;
    }
    
    /**
     * Called from whitelister when one or more voters have been removed.
     */
    function votersRemovedFromWhitelist(address[] memory _removedVoters, uint256 _ftsoIndex) 
        external override 
        onlyWhitelister
    {
        for (uint256 i = 0; i < _removedVoters.length; i++) {
            whitelistedFtsoBitmap[_removedVoters[i]]  &= ~(1 << _ftsoIndex);
        }
    }
    
    /**
     * @notice Submits price hashes for current epoch
     * @param _ftsoIndices          List of ftso indices
     * @param _hashes               List of hashed price and random number
     * @notice Emits PriceHashesSubmitted event
     */
    function submitPriceHashes(
        uint256 _epochId, 
        uint256[] memory _ftsoIndices, 
        bytes32[] memory _hashes
    ) external override {
        // Submit the prices
        uint256 length = _ftsoIndices.length;
        require(length == _hashes.length, ERR_ARRAY_LENGTHS);

        IFtsoGenesis[] memory ftsos = ftsoRegistry.getFtsos(_ftsoIndices);
        uint256 allowedBitmask = whitelistedFtsoBitmap[msg.sender];
        bool isTrustedAddress = false;

        for (uint256 i = 0; i < length; i++) {
            uint256 ind = _ftsoIndices[i];
            if (allowedBitmask & (1 << ind) == 0) {
                if (!isTrustedAddress) {
                    if (trustedAddressesMapping[msg.sender]) {
                        isTrustedAddress = true;
                    } else {
                        revert(ERR_NOT_WHITELISTED);
                    }
                }
            }
            ftsos[i].submitPriceHashSubmitter(msg.sender, _epochId, _hashes[i]);
        }
        emit PriceHashesSubmitted(msg.sender, _epochId, ftsos, _hashes, block.timestamp);
    }

    /**
     * @notice Reveals submitted prices during epoch reveal period
     * @param _epochId              Id of the epoch in which the price hashes was submitted
     * @param _ftsoIndices          List of ftso indices
     * @param _prices               List of submitted prices in USD
     * @param _randoms              List of submitted random numbers
     * @notice The hash of _price and _random must be equal to the submitted hash
     * @notice Emits PricesRevealed event
     */
    function revealPrices(
        uint256 _epochId,
        uint256[] memory _ftsoIndices,
        uint256[] memory _prices,
        uint256[] memory _randoms
    )
        external override
    {
        uint256 length  = _ftsoIndices.length;
        require(length == _prices.length, ERR_ARRAY_LENGTHS);
        require(length == _randoms.length, ERR_ARRAY_LENGTHS);

        IFtsoGenesis[] memory ftsos = ftsoRegistry.getFtsos(_ftsoIndices);
        uint256 allowedBitmask = whitelistedFtsoBitmap[msg.sender];
        bool isTrustedAddress = false;

        uint256 wNatVP = uint256(-1);

        for (uint256 i = 0; i < length; i++) {
            uint256 ind = _ftsoIndices[i];
            if (allowedBitmask & (1 << ind) == 0) {
                if (!isTrustedAddress) {
                    if (trustedAddressesMapping[msg.sender]) {
                        isTrustedAddress = true;
                    } else {
                        revert(ERR_NOT_WHITELISTED);
                    }
                }
            }
            // read native VP only once
            if (wNatVP == uint256(-1)) {
                wNatVP = ftsos[i].wNatVotePowerCached(msg.sender, _epochId);
            }
            // call reveal price on ftso
            ftsos[i].revealPriceSubmitter(msg.sender, _epochId, _prices[i], _randoms[i], wNatVP);
        }
        emit PricesRevealed(msg.sender, _epochId, ftsos, _prices, _randoms, block.timestamp);
    }
    
    /**
     * Returns bitmap of all ftso's for which `_voter` is allowed to submit prices/hashes.
     * If voter is allowed to vote for ftso at index (see *_FTSO_INDEX), the corrsponding
     * bit in the result will be 1.
     */    
    function voterWhitelistBitmap(address _voter) external view override returns (uint256) {
        return whitelistedFtsoBitmap[_voter];
    }
    
    function getTrustedAddresses() external view override returns (address[] memory) {
        return trustedAddresses;
    }

    function getVoterWhitelister() external view override returns (address) {
        return voterWhitelister;
    }

    function getFtsoRegistry() external view override returns (IFtsoRegistryGenesis) {
        return ftsoRegistry;
    }
    
    function getFtsoManager() external view override returns (address) {
        return ftsoManager;
    }
}
