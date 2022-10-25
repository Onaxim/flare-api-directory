// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "./DelegationAccountClonable.sol";
import "./CloneFactory.sol";
import "../interface/IDelegationAccountManager.sol";
import "../../tokenPools/interface/IIFtsoRewardManager.sol";
import "../../token/implementation/WNat.sol";
import "../../userInterfaces/IDistributionToDelegators.sol";
import "../..//userInterfaces/IGovernanceVotePower.sol";
import "../../governance/implementation/Governed.sol";
import "../../addressUpdater/implementation/AddressUpdatable.sol";

contract DelegationAccountManager is CloneFactory, IDelegationAccountManager, Governed, AddressUpdatable {

    WNat public wNat;
    IIFtsoRewardManager[] public ftsoRewardManagers;
    IGovernanceVotePower public governanceVP;
    IDistributionToDelegators[] public distributions;

    address public libraryAddress;

    mapping(address => address) public accountToDelegationAccount;

    constructor(
        address _governance,
        address _addressUpdater
    ) 
        Governed(_governance)
        AddressUpdatable(_addressUpdater)
    {}

    function setLibraryAddress(address _libraryAddress) external override onlyGovernance {
        libraryAddress = _libraryAddress;
        emit SetLibraryAddress(libraryAddress);
    }

    function createDelegationAccount() external override returns (DelegationAccountClonable) {
        require(libraryAddress != address(0), "library address is not set yet");
        require(accountToDelegationAccount[msg.sender] == address(0), "account already has delegation account");

        DelegationAccountClonable delegationAccount = DelegationAccountClonable(
            payable(createClone(libraryAddress))
        );

        delegationAccount.initialize(msg.sender, DelegationAccountManager(address(this)));
            
        accountToDelegationAccount[msg.sender] = address(delegationAccount);

        emit CreateDelegationAccount(address(delegationAccount), msg.sender);

        return delegationAccount;
    }

    function getFtsoRewardManagers() external view override returns(IIFtsoRewardManager[] memory) {
        return ftsoRewardManagers;
    }

    function getDistributions() external view override returns(IDistributionToDelegators[] memory) {
        return distributions;
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
        wNat = WNat(payable(_getContractAddress(_contractNameHashes, _contractAddresses, "WNat")));

        governanceVP = wNat.governanceVotePower();

        IIFtsoRewardManager ftsoRewardManager = IIFtsoRewardManager(
            _getContractAddress(_contractNameHashes, _contractAddresses, "FtsoRewardManager"));
        bool rewardManagersContain = false;
        for (uint256 i = 0; i < ftsoRewardManagers.length; i++) {
            if (ftsoRewardManagers[i] == ftsoRewardManager) {
                rewardManagersContain = true;
                break;
            }
        }
        if (!rewardManagersContain) {
            ftsoRewardManagers.push(ftsoRewardManager);
        }

        IDistributionToDelegators distribution = IDistributionToDelegators(
            _getContractAddress(_contractNameHashes, _contractAddresses, "DistributionToDelegators"));
        bool distributionsContain = false;
        for (uint256 i = 0; i < distributions.length; i++) {
            if (distributions[i] == distribution) {
                distributionsContain = true;
                break;
            }
        }
        if (!distributionsContain) {
            distributions.push(distribution);
        }
    }
}
