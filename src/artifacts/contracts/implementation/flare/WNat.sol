// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "./VPToken.sol";
import "./VPContract.sol";
import "../../userInterfaces/IWNat.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @title Wrapped Native token
 * @notice Accept native token deposits and mint ERC20 WNAT (wrapped native) tokens 1-1.
 * @dev Attribution: https://rinkeby.etherscan.io/address/0xc778417e063141139fce010982780140aa0cd5ab#code 
 */
contract WNat is VPToken, IWNat {
    using SafeMath for uint256;
    event  Deposit(address indexed dst, uint amount);
    event  Withdrawal(address indexed src, uint amount);

    /**
     * Construct an ERC20 token.
     */
    constructor(address _governance, string memory _name, string memory _symbol) 
        VPToken(_governance, _name, _symbol) 
    {
    }

    receive() external payable {
        deposit();
    }

    /**
     * @notice Withdraw WNAT from an owner and send native tokens to msg.sender given an allowance.
     * @param owner An address spending the Native tokens.
     * @param amount The amount to spend.
     *
     * Requirements:
     *
     * - `owner` must have a balance of at least `amount`.
     * - the caller must have allowance for `owners`'s tokens of at least
     * `amount`.
     */
    function withdrawFrom(address owner, uint256 amount) external override {
        // Reduce senders allowance
        _approve(owner, msg.sender, allowance(owner, msg.sender).sub(amount, "allowance below zero"));
        // Burn the owners balance
        _burn(owner, amount);
        // Emit withdraw event
        emit Withdrawal(owner, amount);
        // Move value to sender (last statement, to prevent reentrancy)
        msg.sender.transfer(amount);
    }

    /**
     * @notice Deposit Native from msg.sender and mints WNAT ERC20 to recipient address.
     * @param recipient An address to receive minted WNAT.
     */
    function depositTo(address recipient) external payable override {
        require(recipient != address(0), "Cannot deposit to zero address");
        // Mint WNAT
        _mint(recipient, msg.value);
        // Emit deposit event
        emit Deposit(recipient, msg.value);
    }

    /**
     * @notice Deposit Native and mint wNat ERC20.
     */
    function deposit() public payable override {
        // Mint WNAT
        _mint(msg.sender, msg.value);
        // Emit deposit event
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw Native and burn WNAT ERC20.
     * @param amount The amount to withdraw.
     */
    function withdraw(uint256 amount) external override {
        // Burn WNAT tokens
        _burn(msg.sender, amount);
        // Emit withdrawal event
        emit Withdrawal(msg.sender, amount);
        // Send Native to sender (last statement, to prevent reentrancy)
        msg.sender.transfer(amount);
    }
}
