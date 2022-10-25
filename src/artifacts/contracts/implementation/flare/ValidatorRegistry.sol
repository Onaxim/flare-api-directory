// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "../../userInterfaces/IPriceSubmitter.sol";
import "../../userInterfaces/IValidatorRegistry.sol";


/**
 * @title Validator registry contract
 * @notice This contract is used as a mapping from data provider's address to {node id, P-Chain public key}
 * @notice In order to get the ability to become a validator, data provider must register using this contract
 * @dev Only whitelisted data provider can register
 */
contract ValidatorRegistry is IValidatorRegistry {

    address public constant PRICE_SUBMITTER = address(0x1000000000000000000000000000000000000003);

    mapping(address => string) internal dataProviderToNodeId;
    mapping(address => string) internal dataProviderToPChainPublicKey;

    mapping(bytes32 => address) internal nodeIdToDataProvider;
    mapping(bytes32 => address) internal pChainPublicKeyToDataProvider;

    /**
     * @notice Register data provider's address as a validator - emits DataProviderRegistered event
     * @param _nodeId Data provider's node id
     * @param _pChainPublicKey Data provider's P-Chain public key
     * @dev Data provider must be whitelisted
     * @dev `_nodeId` and `_pChainPublicKey` should not be already in use by some other data provider
     */
    function registerDataProvider(string memory _nodeId, string memory _pChainPublicKey) external override {
        // check that data provider is whitelisted
        require(IPriceSubmitter(PRICE_SUBMITTER).voterWhitelistBitmap(msg.sender) > 0, "not whitelisted");

        bytes32 nodeIdHash = keccak256(abi.encode(_nodeId));
        address currentAddress = nodeIdToDataProvider[nodeIdHash];
        if (currentAddress == address(0)) {
            // delete old value, could be 0
            delete nodeIdToDataProvider[keccak256(abi.encode(dataProviderToNodeId[msg.sender]))];
            // set new values
            dataProviderToNodeId[msg.sender] = _nodeId;
            nodeIdToDataProvider[nodeIdHash] = msg.sender;
        } else {
            // make sure data provider sent the same nodeId again
            require(currentAddress == msg.sender, "nodeId already in use");
        }

        bytes32 pChainPublicKeyHash = keccak256(abi.encode(_pChainPublicKey));
        currentAddress = pChainPublicKeyToDataProvider[pChainPublicKeyHash];
        if (currentAddress == address(0)) {
            // delete old value, could be 0
            delete pChainPublicKeyToDataProvider[keccak256(abi.encode(dataProviderToPChainPublicKey[msg.sender]))];
            // set new values
            dataProviderToPChainPublicKey[msg.sender] = _pChainPublicKey;
            pChainPublicKeyToDataProvider[pChainPublicKeyHash] = msg.sender;
        } else {
            // make sure data provider sent the same pChainPublicKey again
            require(currentAddress == msg.sender, "pChainPublicKey already in use");
        }

        emit DataProviderRegistered(msg.sender, _nodeId, _pChainPublicKey);
    }

    /**
     * @notice Unregister data provider's address as a validator - emits DataProviderUnregistered event
     */
    function unregisterDataProvider() external override {
        delete nodeIdToDataProvider[keccak256(abi.encode(dataProviderToNodeId[msg.sender]))];
        delete dataProviderToNodeId[msg.sender];
        delete pChainPublicKeyToDataProvider[keccak256(abi.encode(dataProviderToPChainPublicKey[msg.sender]))];
        delete dataProviderToPChainPublicKey[msg.sender];

        emit DataProviderUnregistered(msg.sender);
    }

    /**
     * @notice Returns data provider's node id and P-Chain public key
     * @param _dataProvider Data provider's address
     * @return _nodeId Data provider's node id
     * @return _pChainPublicKey Data provider's P-Chain public key
     */
    function getDataProviderInfo(address _dataProvider)
        external view override returns (string memory _nodeId, string memory _pChainPublicKey) {
        return (dataProviderToNodeId[_dataProvider], dataProviderToPChainPublicKey[_dataProvider]);
    }

    /**
     * @notice Returns data provider's address that was registered with given node id
     * @param _nodeId Data provider's node id hash
     * @return _dataProvider Data provider's address
     */
    function getDataProviderForNodeId(bytes32 _nodeId) 
        external view override returns (address _dataProvider) {
        return nodeIdToDataProvider[_nodeId];
    }

    /**
     * @notice Returns data provider's address that was registered with given P-Chain public key
     * @param _pChainPublicKey Data provider's P-Chain public key hash
     * @return _dataProvider Data provider's address
     */
    function getDataProviderForPChainPublicKey(bytes32 _pChainPublicKey) 
        external view override returns (address _dataProvider) {
        return pChainPublicKeyToDataProvider[_pChainPublicKey];
    }
}
