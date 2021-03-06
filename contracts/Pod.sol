/**
Copyright 2020 PoolTogether Inc.

This file is part of PoolTogether.

PoolTogether is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation under version 3 of the License.

PoolTogether is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with PoolTogether.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.5.12;

import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC777/ERC777.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@kleros/kleros/contracts/data-structures/SortitionSumTreeFactory.sol";
import "@pooltogether/pooltogether-contracts/contracts/UniformRandomNumber.sol";
import "@pooltogether/pooltogether-contracts/contracts/MCDAwarePool.sol";
import "@pooltogether/pooltogether-contracts/contracts/IRewardListener.sol";

import "./ScheduledBalance.sol";
import "./ExchangeRateTracker.sol";

/**
 * @title PoolTogether Pod
 * @author Brendan Asselstine
 * @notice Allows users to own shares in pooled tickets for a PoolTogether Pool
 *
 * Designed to be bound to the PoolTogether Pool that support RewardListeners.
 *
 * A RewardListener is a contract that is registered to be the reward listener for an address using the ERC 1820 registry.
 *
 * When the Pool picks a winner, the Pool will look for a registered RewardListener.  If one exists, it calls `rewarded`
 * on the listener with a stipend of 200000 gas.
 *
 * In this way the Pod is able to track historic exchange rates.
 */
contract Pod is ERC777, ReentrancyGuard, IERC777Recipient, IRewardListener {
  using ScheduledBalance for ScheduledBalance.State;
  using ExchangeRateTracker for ExchangeRateTracker.State;

  /// @notice The initial exchange rate for shares.  Starts high as the shares perpetually deflate.
  uint256 internal constant BASE_EXCHANGE_RATE_MANTISSA = 1e24;

  /// @notice keccak256("PoolTogetherRewardListener")
  bytes32 constant internal REWARD_LISTENER_INTERFACE_HASH =
      0x68f03b0b1a978ee238a70b362091d993343460bc1a2830ab3f708936d9f564a4;

  /// @notice keccak256("ERC777TokensRecipient")
  bytes32 constant internal TOKENS_RECIPIENT_INTERFACE_HASH =
      0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b;

  /// @notice A reference to interact with the ERC1820 registry
  IERC1820Registry constant internal ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

  /**
   * @notice Event emitted when a user withdraws their pending deposit
   * @param operator The operator who kicked off the transaction
   * @param from The account that is being debited
   * @param collateral The amount of collateral being withdrawn
   * @param data Data the debited account included in the tx
   * @param operatorData Data the operator included in the tx
   */
  event PendingDepositWithdrawn(address indexed operator, address indexed from, uint256 collateral, bytes data, bytes operatorData);

  /**
   * @notice Event emitted when a user or operator redeems tokens into the backing collateral
   * @param operator The operator who kicked off the transaction
   * @param from The account that is being debited
   * @param amount The amount of Pod shares burned
   * @param collateral The amount of collateral that was returned
   * @param data Data the debited account included in the tx
   * @param operatorData Data the operator included in the tx
   */
  event Redeemed(address indexed operator, address indexed from, uint256 amount, uint256 collateral, bytes data, bytes operatorData);

  /**
   * @notice Event emitted when a user or operator redeems tokens into Pool tickets
   * @param operator The operator who kicked off the transaction
   * @param from The account that is being debited
   * @param amount The amount of Pod shares burned
   * @param collateral The amount of Pool tickets redeemed.
   * @param data Data the debited account included in the tx
   * @param operatorData Data the operator included in the tx
   */
  event RedeemedToPool(address indexed operator, address indexed from, uint256 amount, uint256 collateral, bytes data, bytes operatorData);

  /**
   * @notice Event emitted when the collateralization of the Pod shares changes.
   * @param timestamp The timestamp at which the collateralization changed
   * @param tokens The new token supply
   * @param collateral The new collateral amount
   * @param mantissa The new exchange rate mantissa
   */
  event CollateralizationChanged(uint256 indexed timestamp, uint256 tokens, uint256 collateral, uint256 mantissa);

  /**
   * @notice Event emitted when a user or operator deposits collateral for Pod shares
   * @param operator The operator who kicked off the transaction
   * @param from The account that will be credited with Pod shares
   * @param collateral The amount of collateral deposited
   * @param drawId The open draw id in which the account deposited
   * @param data Data the debited account included in the tx
   * @param operatorData Data the operator included in the tx
   */
  event Deposited(address indexed operator, address indexed from, uint256 collateral, uint256 drawId, bytes data, bytes operatorData);

  /// @notice Tracks the consolidated and unconsolidated supply of tokens
  ScheduledBalance.State internal scheduledSupply;

  /// @notice Tracks the consolidated and unconsolidated balances of tokens per user
  mapping(address => ScheduledBalance.State) internal scheduledBalances;

  /// @notice Tracks the historic exchange rate
  ExchangeRateTracker.State internal exchangeRateTracker;

  /// @notice The PoolTogether Pool that this Pod is bound to
  MCDAwarePool public pool;

  /**
   * @notice Initializes the Pod.
   * @param _pool The Pool to bind this Pod to.
   */
  function initialize(
    MCDAwarePool _pool
  ) public initializer {
    require(address(_pool) != address(0), "Pod/pool-def");
    exchangeRateTracker.initialize(BASE_EXCHANGE_RATE_MANTISSA);
    pool = _pool;
    ERC1820_REGISTRY.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    ERC1820_REGISTRY.setInterfaceImplementer(address(this), REWARD_LISTENER_INTERFACE_HASH, address(this));
  }

  /**
   * @notice Deposits on behalf of a user by an operator.  The deposit will become Pod shares upon the next Pool reward.
   * @param user The user on whose behalf to deposit
   * @param amount The amount of collateral to deposit
   * @param data Included user data
   * @param operatorData Included operator data
   */
  function operatorDeposit(address user, uint256 amount, bytes calldata data, bytes calldata operatorData) external {
    _deposit(msg.sender, user, amount, data, operatorData);
  }

  /**
   * @notice Deposits into the Pod. The deposit will become Pod shares upon the next Pool reward.
   * @param amount The amount of collateral to deposit
   * @param data Included user data
   */
  function deposit(uint256 amount, bytes calldata data) external {
    _deposit(msg.sender, msg.sender, amount, data, "");
  }

  /**
   * @notice Deposits on behalf of a user by an operator.  The operator may also be the user. The deposit will become Pod shares upon the next Pool reward.
   * @param operator The operator who kicked of the deposit
   * @param from The user on whose half to deposit
   * @param amount The amount of collateral to deposit
   * @param data Included user data
   * @param operatorData Included operator data
   */
  function _deposit(
    address operator,
    address from,
    uint256 amount,
    bytes memory data,
    bytes memory operatorData
  ) internal nonReentrant {
    consolidateBalanceOf(from);
    pool.token().transferFrom(operator, address(this), amount);
    pool.token().approve(address(pool), amount);
    pool.depositPool(amount);
    uint256 openDrawId = pool.currentOpenDrawId();
    scheduledSupply.deposit(amount, openDrawId);
    scheduledBalances[from].deposit(amount, openDrawId);
    emit Deposited(operator, from, amount, openDrawId, data, operatorData);
  }

  /**
   * @notice IERC777Recipient callback to handle direct Pool token transfers. When users transfer their Pool tickets to this contract they will be instantly converted into Pod shares.
   * @param from The user whose tickets are being transferred
   * @param amount The number of tickets being transferred
   */
  function tokensReceived(
    address,
    address from,
    address, // to address can't be anything but us because we don't implement ERC1820ImplementerInterface
    uint256 amount,
    bytes calldata,
    bytes calldata
  ) external {
    // if this is a transfer of pool tickets
    if (msg.sender == address(pool.poolToken())) {
      // convert to shares
      consolidateBalanceOf(from);
      uint256 tokens = exchangeRateTracker.collateralToTokenValue(amount);
      _mint(address(this), from, tokens, "", "");
    } else {
      // The only other allowed token is itself and the asset
      require(msg.sender == address(this) || msg.sender == address(pool.token()), "Pod/unknown-token");
    }
  }

  /**
   * @notice Returns the collateral value of the given users tokens. If the user does not have any tokens, this will be zero.  Pending deposits are not included.
   * @param user The user whose balance should be checked
   * @return The collateral value of the tokens held by the user.
   */
  function balanceOfUnderlying(address user) public view returns (uint256) {
    return exchangeRateTracker.tokenToCollateralValue(balanceOf(user));
  }

  /**
   * @notice Returns the number of tokens held by the given user.  Does not include pending deposits.
   * @param tokenHolder The user whose balance should be checked
   * @return The users total balance of tokens.
   */
  function balanceOf(address tokenHolder) public view returns (uint256) {
    (uint256 balance, uint256 drawId) = scheduledBalances[tokenHolder].consolidatedBalanceInfo(pool.currentOpenDrawId());
    return super.balanceOf(tokenHolder).add(
      exchangeRateTracker.collateralToTokenValueAt(
        balance,
        drawId
      )
    );
  }

  /**
   * @notice Returns the amount of collateral a user has deposited that is pending conversion to tokens.
   * @param user The user whose pending collateral balance should be returned.
   * @return The amount of collateral the user has deposited that has not converted to tokens.
   */
  function pendingDeposit(address user) public view returns (uint256) {
    return scheduledBalances[user].unconsolidatedBalance(pool.currentOpenDrawId());
  }

  /**
   * @notice Allows an operator to withdraw a user's pending deposit on their behalf
   * @param from The user on whose behalf to withdraw
   * @param amount The amount to withdraw
   * @param data Data included by the user
   * @param operatorData Data included by the operator
   */
  function operatorWithdrawPendingDeposit(
    address from,
    uint256 amount,
    bytes calldata data,
    bytes calldata operatorData
  ) external {
    require(isOperatorFor(msg.sender, from), "Pod/not-op");
    _withdrawPendingDeposit(msg.sender, from, amount, data, operatorData);
  }

  /**
   * @notice Allows a user to withdraw their pending deposit
   * @param amount The amount the user wishes to withdraw
   * @param data Data included by the user
   */
  function withdrawPendingDeposit(
    uint256 amount,
    bytes calldata data
  ) external {
    _withdrawPendingDeposit(msg.sender, msg.sender, amount, data, "");
  }

  /**
   * @notice Withdraw from a user's pending deposit
   * @param operator The operator conducting the withdrawal
   * @param from The user whose deposit will be withdrawn
   * @param amount The amount to withdraw
   * @param data Data included by the user
   * @param operatorData Data included by the operator
   */
  function _withdrawPendingDeposit(
    address operator,
    address from,
    uint256 amount,
    bytes memory data,
    bytes memory operatorData
  ) internal {
    uint256 openDrawId = pool.currentOpenDrawId();
    scheduledBalances[from].withdrawUnconsolidated(amount, openDrawId);
    pool.withdrawOpenDeposit(amount);
    pool.token().transfer(from, amount);

    emit PendingDepositWithdrawn(operator, from, amount, data, operatorData);
  }

  /**
   * @notice Returns the total supply of tokens.  Does not included any pending deposits.
   * @return The total supply of tokens.
   */
  function totalSupply() public view returns (uint256) {
    (uint256 balance, uint256 drawId) = scheduledSupply.consolidatedBalanceInfo(pool.currentOpenDrawId());
    return super.totalSupply().add(
      exchangeRateTracker.collateralToTokenValueAt(
        balance,
        drawId
      )
    );
  }

  /**
    * @dev See {IERC777-operatorBurn}.
    *
    * This contract does not support burning.  Redeem must be called.
    */
  function operatorBurn(address, uint256, bytes memory, bytes memory) public {
    revert("Pod/no-op");
  }

  /**
    * @dev See {IERC777-burn}.
    *
    * This contract does not support burning.  Redeem must be called.
    */
  function burn(uint256, bytes memory) public {
    revert("Pod/no-op");
  }

  /**
   * @dev PoolTogetherRewardListener callback that is triggered by the Pool when this Pod wins.
   * @param winnings The amount of collateral won in the prize
   * @param drawId The prize id that was won
   */
  function rewarded(address, uint256 winnings, uint256 drawId) external nonReentrant {
    require(msg.sender == address(pool), "Pod/only-pool");
    uint256 tokens = totalSupply();
    uint256 collateral = exchangeRateTracker.tokenToCollateralValue(tokens).add(winnings);
    uint256 mantissa = exchangeRateTracker.collateralizationChanged(tokens, collateral, drawId.add(1));
    emit CollateralizationChanged(drawId, tokens, collateral, mantissa);
  }

  /**
   * @notice Returns the mantissa of the current exchange rate.
   * @return The current exchange rate mantissa.
   */
  function currentExchangeRateMantissa() external view returns (uint256) {
    return exchangeRateTracker.currentExchangeRateMantissa();
  }

  /**
   * @notice Allows an operator to redeem tokens for collateral on behalf of a user.
   * @param account The user who is redeeming tokens
   * @param amount The amount of tokens to convert to collateral
   * @param data User data included with the tx
   * @param operatorData Operator data included with the tx
   */
  function operatorRedeem(address account, uint256 amount, bytes calldata data, bytes calldata operatorData) external {
    require(isOperatorFor(msg.sender, account), "Pod/not-op");
    _redeem(msg.sender, account, amount, data, operatorData);
  }

  /**
   * @notice Allows a user to redeem tokens for collateral.
   * @param amount The amount of tokens to convert to collateral
   * @param data User data included with the tx
   */
  function redeem(uint256 amount, bytes calldata data) external {
    _redeem(msg.sender, msg.sender, amount, data, "");
  }

  /**
    * @notice Redeems tokens for the underlying asset.
    * @param operator address operator requesting the operation
    * @param from address token holder address
    * @param amount uint256 amount of tokens to redeem
    * @param data bytes extra information provided by the token holder
    * @param operatorData bytes extra information provided by the operator (if any)
    */
  function _redeem(
      address operator,
      address from,
      uint256 amount,
      bytes memory data,
      bytes memory operatorData
  )
      internal nonReentrant
  {
      consolidateBalanceOf(from);
      uint256 collateral = exchangeRateTracker.tokenToCollateralValue(amount);
      pool.withdrawCommittedDeposit(collateral);
      pool.token().transfer(from, collateral);
      emit Redeemed(operator, from, amount, collateral, data, operatorData);
      _burn(operator, from, amount, data, operatorData);
  }

  /**
   * @notice Allows an operator to redeem tokens for Pool tickets on behalf of a user.
   * @param account The user who is redeeming tokens
   * @param amount The amount of tokens to convert to Pool tickets
   * @param data User data included with the tx
   * @param operatorData Operator data included with the tx
   */
  function operatorRedeemToPool(address account, uint256 amount, bytes calldata data, bytes calldata operatorData) external {
    require(isOperatorFor(msg.sender, account), "Pod/not-op");
    _redeemToPool(msg.sender, account, amount, data, operatorData);
  }

  /**
   * @notice Allows a user to redeem tokens for Pool tickets
   * @param amount The amount of tokens to convert to Pool tickets
   * @param data User data included with the tx
   */
  function redeemToPool(uint256 amount, bytes calldata data) external {
    _redeemToPool(msg.sender, msg.sender, amount, data, "");
  }

  /**
   * @notice Allows an operator to redeem tokens for Pool tickets on behalf of a user.
   * @param operator The operator who is running the tx
   * @param from The user who is redeeming tokens
   * @param amount The amount of tokens to convert to Pool tickets
   * @param data User data included with the tx
   * @param operatorData Operator data included with the tx
   */
  function _redeemToPool(
    address operator,
    address from,
    uint256 amount,
    bytes memory data,
    bytes memory operatorData
  ) internal nonReentrant {
    consolidateBalanceOf(from);
    uint256 collateral = exchangeRateTracker.tokenToCollateralValue(amount);
    pool.poolToken().transfer(from, collateral);
    emit RedeemedToPool(operator, from, amount, collateral, data, operatorData);
    _burn(operator, from, amount, data, operatorData);
  }

  /**
   * @dev Mints tokens to the Pod using any consolidated supply, then zeroes out the supply.
   */
  function consolidateSupply() internal {
    uint256 openDrawId = pool.currentOpenDrawId();
    (uint256 balance, uint256 drawId) = scheduledSupply.consolidatedBalanceInfo(openDrawId);
    uint256 tokens = exchangeRateTracker.collateralToTokenValueAt(balance, drawId);
    if (tokens > 0) {
      scheduledSupply.clearConsolidated(openDrawId);
      _mint(address(this), address(this), tokens, "", "");
    }
  }

  /**
   * @dev First calls `consolidateSupply()`, then transfers tokens from the Pod to the user based
   * on the users consolidated supply.  Finally, it zeroes out the users consolidated supply.
   * @param user The user whose balance should be consolidated.
   */
  function consolidateBalanceOf(address user) internal {
    consolidateSupply();
    uint256 openDrawId = pool.currentOpenDrawId();
    (uint256 balance, uint256 drawId) = scheduledBalances[user].consolidatedBalanceInfo(openDrawId);
    uint256 tokens = exchangeRateTracker.collateralToTokenValueAt(balance, drawId);
    if (tokens > 0) {
      scheduledBalances[user].clearConsolidated(openDrawId);
      _send(address(this), address(this), user, tokens, "", "", true);
    }
  }
}
