// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;


import "../interface/IIFtsoRegistry.sol";
import "../../addressUpdater/implementation/AddressUpdatable.sol";
import "../../ftso/interface/IIFtsoManager.sol";
import "../../governance/implementation/Governed.sol";

/**
 * @title A contract for FTSO registry
 */
contract FtsoRegistry is IIFtsoRegistry, Governed, AddressUpdatable { 

    // constants
    uint256 internal constant MAX_HISTORY_LENGTH = 5;

    // errors
    string internal constant ERR_TOKEN_NOT_SUPPORTED = "FTSO index not supported";
    string internal constant ERR_FTSO_MANAGER_ONLY = "FTSO manager only";

    // storage 
    IIFtso[MAX_HISTORY_LENGTH][] private ftsoHistory;

    // addresses
    // This address has to be set in deploy phase
    IIFtsoManager public ftsoManager;

    modifier onlyFtsoManager () {
        require (msg.sender == address(ftsoManager), ERR_FTSO_MANAGER_ONLY);
        _;
    }

    constructor(
        address _governance,
        address _addressUpdater
    )
        Governed(_governance) AddressUpdatable(_addressUpdater)
    {
        /* empty block */
    }

    /**
     * @notice Update current active FTSO contracts mapping
     * @param _ftsoContract new target FTSO contract
     */
    function addFtso(IIFtso _ftsoContract) external override onlyFtsoManager returns(uint256 _ftsoIndex) {
        uint256 len = ftsoHistory.length;
        string memory _symbol = _ftsoContract.symbol();
        bytes32 _encodedSymbol = keccak256(abi.encode(_symbol));
        _ftsoIndex = 0;
        // Iterate over supported symbol array
        for ( ; _ftsoIndex < len; _ftsoIndex++) {
            // Deletion of symbols leaves an empty address "hole", so the address might be zero
            IIFtso current = ftsoHistory[_ftsoIndex][0];
            if (address(current) == address(0)) {
                continue;
            }
            if (_encodedSymbol == keccak256(abi.encode(current.symbol()))) {
                break;
            }
        }
        // ftso with the same symbol is not yet in history array, add it
        if (_ftsoIndex == len) {
            ftsoHistory.push();
        } else {
            // Shift history
            _shiftHistory(_ftsoIndex);
        }
        ftsoHistory[_ftsoIndex][0] = _ftsoContract;
    }

    /**
     * Removes the ftso at specified index and keeps part of the history
     * @dev Reverts if the provided index is unsupported
     * @param _ftso ftso to remove
     */
    function removeFtso(IIFtso _ftso) external override onlyFtsoManager {
        bytes32 _encodedSymbol = keccak256(abi.encode(_ftso.symbol()));
        uint256 len = ftsoHistory.length;
        for (uint256 i = 0; i < len; ++i) {
            IIFtso current = ftsoHistory[i][0];
            if (address(current) == address(0)) {
                continue;
            }
            // Removal behaves the same as setting null value as current
            if (_encodedSymbol == keccak256(abi.encode(current.symbol()))) {
                _shiftHistory(i);
                ftsoHistory[i][0] = IIFtso(address(0));
                return;
            }

        }

        revert(ERR_TOKEN_NOT_SUPPORTED);
    }

    /**
     * @dev Reverts if unsupported index is passed
     * @return _activeFtso FTSO contract for provided index
     */
    function getFtso(uint256 _assetIndex) external view override returns(IIFtso _activeFtso) {
        return _getFtso(_assetIndex);
    }

    /**
     * @dev Reverts if unsupported symbol is passed
     * @return _activeFtso FTSO contract for provided symbol
     */
    function getFtsoBySymbol(string memory _symbol) external view override returns(IIFtso _activeFtso) {
        return _getFtso(_getFtsoIndex(_symbol));
    }

    /**
     * @notice Public view function to get the price of active FTSO for given asset index
     * @dev Reverts if unsupported index is passed
     * @return _price current price of asset in USD
     * @return _timestamp timestamp for when this price was updated
     */
    function getCurrentPrice(uint256 _assetIndex) external view override 
        returns(uint256 _price, uint256 _timestamp) 
    {
        return _getFtso(_assetIndex).getCurrentPrice();
    }

    function getCurrentPrice(string memory _symbol) external view override 
        returns(uint256 _price, uint256 _timestamp) 
    {
        return _getFtso(_getFtsoIndex(_symbol)).getCurrentPrice();
    }
    

    /**
     * @return _supportedIndices the array of all active FTSO indices in increasing order. 
     * Active FTSOs are ones that currently receive price feeds.
     */
    function getSupportedIndices() external view override returns(uint256[] memory _supportedIndices) {
        return _getSupportedIndices();
    }

    /**
     * @return _supportedSymbols the array of all active FTSO symbols in increasing order. 
     * Active FTSOs are ones that currently receive price feeds.
     */
    function getSupportedSymbols() external view override returns(string[] memory _supportedSymbols) {
        uint256[] memory _supportedIndices = _getSupportedIndices();
        uint256 len = _supportedIndices.length;
        _supportedSymbols = new string[](len);
        while (len > 0) {
            --len;
            IIFtso ftso = ftsoHistory[_supportedIndices[len]][0];
            _supportedSymbols[len] = ftso.symbol();
        }
    }

    /**
     * @notice Get array of all supported indices and corresponding FTSOs
     * @return _supportedIndices the array of all supported indices
     * @return _ftsos the array of all supported ftsos
     */
    function getSupportedIndicesAndFtsos() external view override
        returns(uint256[] memory _supportedIndices, IIFtso[] memory _ftsos)
    {
        _supportedIndices = _getSupportedIndices();
        uint256 len = _supportedIndices.length;
        _ftsos = new IIFtso[](len);
        while (len > 0) {
            --len;
            _ftsos[len] = ftsoHistory[_supportedIndices[len]][0];
        }
    }

    /**
     * @notice Get array of all supported symbols and corresponding FTSOs
     * @return _supportedSymbols the array of all supported symbols
     * @return _ftsos the array of all supported ftsos
     */
    function getSupportedSymbolsAndFtsos() external view override
        returns(string[] memory _supportedSymbols, IIFtso[] memory _ftsos)
    {
        uint256[] memory _supportedIndices = _getSupportedIndices();
        uint256 len = _supportedIndices.length;
        _ftsos = new IIFtso[](len);
        _supportedSymbols = new string[](len);
        while (len > 0) {
            --len;
            _ftsos[len] = ftsoHistory[_supportedIndices[len]][0];
            _supportedSymbols[len] = _ftsos[len].symbol();
        }
    }

    /**
     * @notice Get array of all supported indices and corresponding symbols
     * @return _supportedIndices the array of all supported indices
     * @return _supportedSymbols the array of all supported symbols
     */
    function getSupportedIndicesAndSymbols() external view override
        returns(uint256[] memory _supportedIndices, string[] memory _supportedSymbols) 
    {
        _supportedIndices = _getSupportedIndices();
        uint256 len = _supportedIndices.length;
        _supportedSymbols = new string[](len);
        while (len > 0) {
            --len;
            IIFtso ftso = ftsoHistory[_supportedIndices[len]][0];
            _supportedSymbols[len] = ftso.symbol();
        }
    }

    /**
     * @notice Get array of all supported indices, corresponding symbols and FTSOs
     * @return _supportedIndices the array of all supported indices
     * @return _supportedSymbols the array of all supported symbols
     * @return _ftsos the array of all supported ftsos
     */
    function getSupportedIndicesSymbolsAndFtsos() external view override
        returns(uint256[] memory _supportedIndices, string[] memory _supportedSymbols, IIFtso[] memory _ftsos)
    {
        _supportedIndices = _getSupportedIndices();
        uint256 len = _supportedIndices.length;
        _ftsos = new IIFtso[](len);
        _supportedSymbols = new string[](len);
        while (len > 0) {
            --len;
            _ftsos[len] = ftsoHistory[_supportedIndices[len]][0];
            _supportedSymbols[len] = _ftsos[len].symbol();
        }
    }

    /**
     * @notice Get array of all FTSO contracts for all supported asset indices. 
     * The index of FTSO in returned array does not necessarily correspond to _assetIndex
     * Due to deletion, some indices might be unsupported. 
     * @dev See `getSupportedIndicesAndFtsos` for pair of correct indices and `getAllFtsos` 
     * for FTSOs at valid indices but with possible "null" holes.
     * @return _ftsos the array of all supported FTSOs
     */
    function getSupportedFtsos() external view override returns(IIFtso[] memory _ftsos) {
        uint256[] memory supportedIndices = _getSupportedIndices();
        uint256 len = supportedIndices.length;
        _ftsos = new IIFtso[](len);
        while (len > 0) {
            --len;
            _ftsos[len] = ftsoHistory[supportedIndices[len]][0];
        }
    }

    /**
     * @notice Get the active FTSOs for given indices
     * @return _ftsos the array of FTSOs
     */
    function getFtsos(uint256[] memory _assetIndices) external view override returns(IFtsoGenesis[] memory _ftsos) {
        uint256 ftsoLength = ftsoHistory.length;
        uint256 len = _assetIndices.length;
        _ftsos = new IFtsoGenesis[](len);
        while (len > 0) {
            --len;
            uint256 assetIndex = _assetIndices[len];
            require(assetIndex < ftsoLength, ERR_TOKEN_NOT_SUPPORTED);
            _ftsos[len] = ftsoHistory[assetIndex][0];
            if (address(_ftsos[len]) == address(0)) {
                // Invalid index, revert if address is zero address
                revert(ERR_TOKEN_NOT_SUPPORTED);
            }
        }
    }

    /**
     * @notice Get array of all FTSO contracts for all supported asset indices
     * @return _ftsos the array of all FTSOs
     * @dev Return value might contain uninitialized FTSOS at zero address. 
     */
    function getAllFtsos() external view returns(IIFtso[] memory _ftsos) {
        uint256 len = ftsoHistory.length;
        IIFtso[] memory ftsos = new IIFtso[](len);
        while (len > 0) {
            --len;
            ftsos[len] = ftsoHistory[len][0];
        }
        return ftsos;
    }

    /**
     * @notice Get the history of FTSOs for given index
     * @dev If there are less then MAX_HISTORY_LENGTH the remaining addresses will be 0 addresses
     * @param _assetIndex asset index
     * @return _ftsoAddressHistory the history of FTSOs contract for provided index
     */
    function getFtsoHistory(uint256 _assetIndex) external view 
        returns(IIFtso[MAX_HISTORY_LENGTH] memory _ftsoAddressHistory) 
    {
        require(_assetIndex < ftsoHistory.length && 
                address(ftsoHistory[_assetIndex][0]) != address(0), ERR_TOKEN_NOT_SUPPORTED);
        return ftsoHistory[_assetIndex];
    }

    function getFtsoIndex(string memory _symbol) external view override returns (uint256 _assetIndex) {
        return _getFtsoIndex(_symbol);
    }

    function getFtsoSymbol(uint256 _assetIndex) external view override returns (string memory _symbol) {
        return _getFtso(_assetIndex).symbol();
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
        ftsoManager = IIFtsoManager(_getContractAddress(_contractNameHashes, _contractAddresses, "FtsoManager"));
    }

    /**
     * @notice Shift the FTSOs history by one so the FTSO at index 0 can be overwritten
     * @dev Internal helper function
     */
    function _shiftHistory(uint256 _assetIndex) internal {
        for (uint256 i = MAX_HISTORY_LENGTH-1; i > 0; i--) {
            ftsoHistory[_assetIndex][i] = ftsoHistory[_assetIndex][i-1];
        }
    }

    function _getFtsoIndex(string memory _symbol) private view returns (uint256 _assetIndex) {
        bytes32 _encodedSymbol = keccak256(abi.encode(_symbol));
        uint256 len = ftsoHistory.length;
        for (uint256 i = 0; i < len; ++i) {
            IIFtso current = ftsoHistory[i][0];
            if (address(current) == address(0)) {
                continue;
            }
            if (_encodedSymbol == keccak256(abi.encode(current.symbol()))) {
                return i;
            }
        }

        revert(ERR_TOKEN_NOT_SUPPORTED); 
    }

    /**
     * @notice Get the active FTSO for given index
     * @dev Internal get ftso function so it can be used within other methods
     */
    function _getFtso(uint256 _assetIndex) private view returns(IIFtso _activeFtso) {
        require(_assetIndex < ftsoHistory.length, ERR_TOKEN_NOT_SUPPORTED);

        IIFtso ftso = ftsoHistory[_assetIndex][0];
        if (address(ftso) == address(0)) {
            // Invalid index, revert if address is zero address
            revert(ERR_TOKEN_NOT_SUPPORTED);
        }
        _activeFtso = ftso;
    }

    function _getSupportedIndices() private view 
        returns(uint256[] memory _supportedIndices) 
    {
        uint256 len = ftsoHistory.length;
        uint256[] memory supportedIndices = new uint256[](len);
        address zeroAddress = address(0);
        uint256 taken = 0;
        for (uint256 i = 0; i < len; ++i) {
            if (address(ftsoHistory[i][0]) != zeroAddress) {
                supportedIndices[taken] = i;
                ++taken;
            }
        }
        _supportedIndices = new uint256[](taken);
        while (taken > 0) {
            --taken;
            _supportedIndices[taken] = supportedIndices[taken];
        }
        return _supportedIndices;
    }
}
