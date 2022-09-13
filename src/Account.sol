pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "./interfaces/IAbstractAsset.sol";
import "./interfaces/IAbstractManager.sol";
import "./interfaces/IAccount.sol";

/**
 * @title Account
 * @author Lyra
 * @notice Base layer that manages:
 *         1. balances for each (account, asset, subId)
 *         2. routing of manager, asset, allowance hooks / checks 
 *            during any balance adjustment event
 *         3. account creation / manager assignment
 */

contract Account is IAccount, ERC721 {
  using SafeCast for int;
  using SafeCast for uint;

  ///////////////
  // Variables //
  ///////////////

  uint nextId = 1;
  mapping(uint => IAbstractManager) public manager;
  mapping(uint => mapping(IAbstractAsset => mapping(uint => BalanceAndOrder))) public balanceAndOrder;
  mapping(uint => HeldAsset[]) public heldAssets;

  mapping(uint => mapping(IAbstractAsset => mapping(uint => mapping(address => uint)))) public positiveSubIdAllowance;
  mapping(uint => mapping(IAbstractAsset => mapping(uint => mapping(address => uint)))) public negativeSubIdAllowance;
  mapping(uint => mapping(IAbstractAsset => mapping(address => uint))) public positiveAssetAllowance;
  mapping(uint => mapping(IAbstractAsset => mapping(address => uint))) public negativeAssetAllowance;
  
  constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

  ///////////////////
  // Account Admin //
  ///////////////////

  /** 
   * @notice Creates account with new accountId
   * @param owner new account owner
   * @param _manager IAbstractManager of new account
   * @return newId ID of new account
   */
  function createAccount(
    address owner, IAbstractManager _manager
  ) external returns (uint newId) {
    return _createAccount(owner, _manager);
  }

  function _createAccount(
    address owner, IAbstractManager _manager
  ) internal returns (uint newId) {
    newId = ++nextId;
    manager[newId] = _manager;
    _mint(owner, newId);
    emit AccountCreated(owner, newId, address(_manager));
    return newId;
  }

  /** 
   * @notice Burns multiple accounts using ERC721._burn(). 
   *         Account must not hold any assets.
   * @param accountIds account ID array
   */
  function burnAccounts(uint[] memory accountIds) external {
    _burnAccounts(accountIds);
  }

  function _burnAccounts(uint[] memory accountIds) internal {
    uint accountsLen = accountIds.length;
    uint heldAssetLen;
    for (uint i; i < accountsLen; i++) {
      _requireERC721ApprovedOrOwner(msg.sender, accountIds[i]);
      heldAssetLen = heldAssets[accountIds[i]].length;
      if (heldAssetLen > 0) {
        revert CannotBurnAccountWithHeldAssets(address(this), msg.sender, accountIds[i], heldAssetLen);
      }
      _burn(accountIds[i]);
      emit AccountBurned(ownerOf(accountIds[i]), accountIds[i], address(manager[accountIds[i]]));
    }
  }

  /** 
   * @notice Assigns new manager to account. No balances are adjusted.
   *         msg.sender must be ERC721 approved or owner
   * @param accountId ID of account
   * @param newManager new IAbstractManager
   */
  function changeManager(
    uint accountId, IAbstractManager newManager, bytes memory managerData
  ) external {
    _requireERC721ApprovedOrOwner(msg.sender, accountId);

    IAbstractManager oldManager = manager[accountId];
    oldManager.handleManagerChange(accountId, newManager, managerData);

    // only call to asset once 
    HeldAsset[] memory accountAssets = heldAssets[accountId];
    IAbstractAsset[] memory seenAssets = new IAbstractAsset[](accountAssets.length);
    uint nextSeenId;

    for (uint i; i < accountAssets.length; ++i) {
      if (!_findInArray(seenAssets, accountAssets[i].asset)) {
        seenAssets[nextSeenId++] = accountAssets[i].asset;
      }
    }

    for (uint i; i < nextSeenId; ++i) {
      seenAssets[i].handleManagerChange(accountId, oldManager, newManager);
    }

    manager[accountId] = newManager;
    _managerHook(accountId, msg.sender, managerData);

    emit AccountManagerChanged(accountId, address(oldManager), address(newManager));
  }

  ///////////////
  // Approvals //
  ///////////////


  /** 
   * @notice Sets bidirectional allowances for all subIds of an asset. 
   *         During a balance adjustment, if msg.sender not ERC721 approved or owner, 
   *         asset allowance + subId allowance must be >= amount 
   * @param accountId ID of account
   * @param delegate address to assign allowance to
   * @param assets array of assets to set allowance for
   * @param positiveAllowances allowances in positive direction
   * @param negativeAllowances allowances in negative direction
   */
  function setAssetAllowances(
    uint accountId, 
    address delegate, 
    IAbstractAsset[] memory assets,
    uint[] memory positiveAllowances,
    uint[] memory negativeAllowances
  ) external {
    _requireERC721ApprovedOrOwner(msg.sender, accountId);

    uint assetsLen = assets.length;
    for (uint i; i < assetsLen; i++) {
      positiveAssetAllowance[accountId][assets[i]][delegate] = positiveAllowances[i];
      negativeAssetAllowance[accountId][assets[i]][delegate] = negativeAllowances[i];
    }
  }

  /** 
   * @notice Sets bidirectional allowances for a specific subId. 
   *         During a balance adjustment, the subId allowance is decremented first 
   * @param accountId ID of account
   * @param delegate address to assign allowance to
   * @param assets array of assets to set allowance for
   * @param subIds array of subIds, must be in same order as assets
   * @param positiveAllowances allowances in positive direction
   * @param negativeAllowances allowances in negative direction
   */
  function setSubIdAllowances(
    uint accountId, 
    address delegate, 
    IAbstractAsset[] memory assets,
    uint[] memory subIds,
    uint[] memory positiveAllowances,
    uint[] memory negativeAllowances
  ) external {
    _requireERC721ApprovedOrOwner(msg.sender, accountId);

    uint assetsLen = assets.length;
    for (uint i; i < assetsLen; i++) {
      positiveSubIdAllowance[accountId][assets[i]][subIds[i]][delegate] = positiveAllowances[i];
      negativeSubIdAllowance[accountId][assets[i]][subIds[i]][delegate] = negativeAllowances[i];
    }
  }

  function _requireERC721ApprovedOrOwner(
    address sender, uint accountId
  ) internal view {
    if (!_isApprovedOrOwner(sender, accountId)) {
      revert NotOwnerOrERC721Approved(
        address(this), sender, ownerOf(accountId), accountId
      );
    }
  }

  /// @dev giving managers exclusive rights to transfer account ownerships
  function _isApprovedOrOwner(
    address spender, uint tokenId
  ) internal view override returns (bool) {
    address owner = ERC721.ownerOf(tokenId);
    bool isManager = address(manager[tokenId]) == msg.sender;
    return (
      spender == owner || 
      isApprovedForAll(owner, spender) || 
      getApproved(tokenId) == spender || 
      isManager
    );
  }

  /////////////////////////
  // Balance Adjustments //
  /////////////////////////

  /** 
   * @notice Transfer an amount from one account to another for a specific (asset, subId)
   * @param assetTransfer (fromAcc, toAcc, asset, subId, amount)
   */
  function submitTransfer(
    AssetTransfer memory assetTransfer, bytes memory managerData
  ) external {
    _transferAsset(assetTransfer);
    _managerHook(assetTransfer.fromAcc, msg.sender, managerData);
    _managerHook(assetTransfer.toAcc, msg.sender, managerData);
  }

  /** 
   * @notice Batch several transfers
   *         Gas efficient when modifying the same account several times,
   *         as _managerHook() is only performed once per account
   * @param assetTransfers array of (fromAcc, toAcc, asset, subId, amount)
   */
  function submitTransfers(
    AssetTransfer[] memory assetTransfers, bytes memory managerData
  ) external {
    _submitTransfers(assetTransfers, managerData);
  }

  function _submitTransfers(
    AssetTransfer[] memory assetTransfers, bytes memory managerData
  ) internal {
    // Do the transfers
    uint transfersLen = assetTransfers.length;

    // Keep track of seen accounts to assess risk later
    uint[] memory seenAccounts = new uint[](transfersLen * 2);
    uint nextSeenId = 0;

    for (uint i; i < transfersLen; ++i) {
      _transferAsset(assetTransfers[i]);

      uint fromAcc = assetTransfers[i].fromAcc;
      if (!_findInArray(seenAccounts, fromAcc)) {
        seenAccounts[nextSeenId++] = fromAcc;
      }
      uint toAcc = assetTransfers[i].toAcc;
      if (!_findInArray(seenAccounts, toAcc)) {
        seenAccounts[nextSeenId++] = toAcc;
      }
    }

    // Assess the risk for all modified balances
    for (uint i; i < nextSeenId; i++) {
      _managerHook(seenAccounts[i], msg.sender, managerData);
    }
  }

  function _transferAsset(
    AssetTransfer memory assetTransfer
  ) internal {
    AssetAdjustment memory fromAccAdjustment = AssetAdjustment({
      acc: assetTransfer.fromAcc,
      asset: assetTransfer.asset,
      subId: assetTransfer.subId,
      amount: -assetTransfer.amount,
      assetData: assetTransfer.assetData
    });
    BalanceAndOrder storage fromBalanceAndOrder = 
      balanceAndOrder[assetTransfer.fromAcc][assetTransfer.asset][assetTransfer.subId];

    AssetAdjustment memory toAccAdjustment = AssetAdjustment({
      acc: assetTransfer.toAcc,
      asset: assetTransfer.asset,
      subId: assetTransfer.subId,
      amount: assetTransfer.amount,
      assetData: assetTransfer.assetData
    });
    BalanceAndOrder storage toBalanceAndOrder = 
      balanceAndOrder[assetTransfer.fromAcc][assetTransfer.asset][assetTransfer.subId];

    _allowanceCheck(fromAccAdjustment, msg.sender);
    _allowanceCheck(toAccAdjustment, msg.sender);

    _adjustBalance(fromAccAdjustment, fromBalanceAndOrder);
    _adjustBalance(toAccAdjustment, toBalanceAndOrder);
  }

  /** 
   * @notice Transfers all balances from one account to another
   *         More gas efficient than submitTransfers()
   * @param fromAccountId ID of sender account
   * @param toAccountId ID of recipient account
   */
  function transferAll(
    uint fromAccountId, uint toAccountId, bytes memory managerData, bytes32[] memory allAssetData
  ) external {
    _requireERC721ApprovedOrOwner(msg.sender, fromAccountId);
    _requireERC721ApprovedOrOwner(msg.sender, toAccountId);

    _transferAll(fromAccountId, toAccountId, allAssetData);
    _managerHook(fromAccountId, msg.sender, managerData);
    _managerHook(toAccountId, msg.sender, managerData);
  }

  function _transferAll(
    uint fromAccountId, uint toAccountId, bytes32[] memory allAssetData
  ) internal {
    HeldAsset[] memory fromAssets = heldAssets[fromAccountId];
    uint heldAssetLen = fromAssets.length;
    uint allAssetDataLen = allAssetData.length;

    bytes32[] memory formattedAssetData = new bytes32[](heldAssetLen);
    if (allAssetDataLen == heldAssetLen) {
      formattedAssetData = allAssetData;
    } else if (allAssetDataLen != 0 && allAssetDataLen != heldAssetLen) {
      revert AssetDataDoesNotMatchHeldAssets(address(this), allAssetDataLen, heldAssetLen);
    }

    for (uint i; i < heldAssetLen; i++) {
      BalanceAndOrder storage userBalanceAndOrder = 
        balanceAndOrder[toAccountId][fromAssets[i].asset][fromAssets[i].subId];
      
      _adjustBalanceWithoutHeldAssetUpdate(AssetAdjustment({
          acc: fromAccountId,
          asset: fromAssets[i].asset,
          subId: fromAssets[i].subId,
          amount: -int(userBalanceAndOrder.balance),
          assetData: formattedAssetData[i]
        }), 
        userBalanceAndOrder
      );

      _adjustBalance(AssetAdjustment({
          acc: toAccountId,
          asset: fromAssets[i].asset,
          subId: fromAssets[i].subId,
          amount: int(userBalanceAndOrder.balance),
          assetData: formattedAssetData[i]
        }), 
        userBalanceAndOrder
      );
    }

    // gas efficient to batch clear assets
    _clearAllHeldAssets(fromAccountId);
  }

  /** 
   * @notice Assymetric balance adjustment reserved for managers or asset 
   *         Must still pass both _managerHook() and _assetHook()
   * @param adjustment assymetric adjustment of amount for (asset, subId)
   */
  function adjustBalance(
    AssetAdjustment memory adjustment,
    bytes memory managerData
  ) onlyManagerOrAsset(adjustment.acc, adjustment.asset) external returns (int postAdjustmentBalance) {    
    BalanceAndOrder storage userBalanceAndOrder = 
        balanceAndOrder[adjustment.acc][adjustment.asset][adjustment.subId];

    _adjustBalance(adjustment, userBalanceAndOrder);
    _managerHook(adjustment.acc, msg.sender, managerData); // since caller is passed, manager can internally decide to ignore check

    postAdjustmentBalance = int(userBalanceAndOrder.balance);
  }

  function _adjustBalance(
    AssetAdjustment memory adjustment, 
    BalanceAndOrder storage userBalanceAndOrder
) internal {
    int preBalance = int(userBalanceAndOrder.balance);

    // allow asset to modify adjustment in special cases (e.g. socialized losses / interest accruals)
    int postBalance = _assetHook(
      adjustment.asset, 
      adjustment.subId, 
      adjustment.acc, 
      preBalance, 
      int(userBalanceAndOrder.balance) + adjustment.amount, 
      msg.sender, 
      adjustment.assetData
    );
    
    // removeHeldAsset does not change order, instead
    // returns newOrder and stores balance and order in one word
    userBalanceAndOrder.balance = postBalance.toInt240();
    if (preBalance != 0 && postBalance == 0) {
      userBalanceAndOrder.order = _removeHeldAsset(adjustment.acc, userBalanceAndOrder);
    } else if (preBalance == 0 && postBalance != 0) {
      userBalanceAndOrder.order = _addHeldAsset(adjustment.acc, adjustment.asset, adjustment.subId);
    } 

    emit BalanceAdjusted(
      adjustment.acc, 
      address(manager[adjustment.acc]), 
      HeldAsset({
        asset: adjustment.asset, 
        subId: SafeCast.toUint96(adjustment.subId)
      }), 
      preBalance, 
      postBalance
    );
  }

  function _adjustBalanceWithoutHeldAssetUpdate(
    AssetAdjustment memory adjustment,
    BalanceAndOrder storage userBalanceAndOrder
  ) internal{
    int preBalance = int(userBalanceAndOrder.balance);
    int postBalance = _assetHook(
      adjustment.asset, 
      adjustment.subId,
      adjustment.acc, 
      preBalance, 
      int(userBalanceAndOrder.balance) + adjustment.amount, 
      msg.sender, 
      adjustment.assetData
    );

    userBalanceAndOrder.balance = postBalance.toInt240();
  }

  ////////////////////////////
  // Checks and Permissions //
  ////////////////////////////

  /** 
   * @notice Hook that calls the manager once per account during:
   *         1. Transfers / Merges / Splits
   *         2. Assymetric balance adjustments
   *         
   * @param accountId ID of account being checked
   * @param caller address of msg.sender initiating balance adjustment
   */
  function _managerHook(
    uint accountId, 
    address caller,
    bytes memory managerData
  ) internal {
    manager[accountId].handleAdjustment(
      accountId, _getAccountBalances(accountId), caller, managerData
    );
  }

  /** 
   * @notice Hook that calls the asset during:
   *         1. Transfers / Merges / Splits
   *         2. Assymetric balance adjustments
   * @dev as hook is called for every asset transfer (unlike _managerHook())
   *      care must be given to reduce gas usage 
   * @param asset IAbstractAsset being called to
   * @param subId subId of asset being transfered
   * @param accountId ID of account being checked 
   * @param preBalance balance before adjustment
   * @param postBalance balance after adjustment
   * @param caller address of msg.sender initiating balance adjustment
   */
  function _assetHook(
    IAbstractAsset asset, 
    uint subId, 
    uint accountId,
    int preBalance, 
    int postBalance, 
    address caller,
    bytes32 assetData
  ) internal returns (int finalBalance) {
    return asset.handleAdjustment(
      accountId, preBalance, postBalance, subId, manager[accountId], caller, assetData
    );
  }

  /** 
   * @notice Checks allowances during transfers / merges / splits
   *         Not checked during adjustBalance()
   *         1. If delegate ERC721 approved or owner, blanket allowance given
   *         2. Otherwise, sum of subId and asset bidirectional allowances used
   *         The subId allowance is decremented before the asset-wide allowance
   * @param adjustment amount of balance adjustment for an (asset, subId)
   * @param delegate address of msg.sender initiating change
   */
  function _allowanceCheck(
    AssetAdjustment memory adjustment, address delegate
  ) internal {
    // ERC721 approved or owner get blanket allowance
    if (_isApprovedOrOwner(msg.sender, adjustment.acc)) { return; }

    // determine if positive vs negative allowance is needed
    if (adjustment.amount > 0) {
      _absAllowanceCheck(
        positiveSubIdAllowance[adjustment.acc][adjustment.asset][adjustment.subId],
        positiveAssetAllowance[adjustment.acc][adjustment.asset],
        delegate,
        adjustment.amount
      );
    } else {
      _absAllowanceCheck(
        negativeSubIdAllowance[adjustment.acc][adjustment.asset][adjustment.subId],
        negativeAssetAllowance[adjustment.acc][adjustment.asset],
        delegate,
        adjustment.amount
      );
    }

  }

  // TODO: could go back to negative/positive struct to reduce SLOADs?
  function _absAllowanceCheck(
    mapping(address => uint) storage allowancesForSubId,
    mapping(address => uint) storage allowancesForAsset,
    address delegate,
    int amount
  ) internal {
    // check allowance
    uint subIdAllowance = allowancesForSubId[delegate];
    uint assetAllowance = allowancesForAsset[delegate];

    // subId allowances are decremented first
    uint absAmount = _abs(amount); 
    if (absAmount <= subIdAllowance) {
      allowancesForSubId[delegate] -= absAmount;
    } else if (absAmount <= subIdAllowance + assetAllowance) { 
      allowancesForSubId[delegate] = 0;
      allowancesForAsset[delegate] -= absAmount - subIdAllowance;
    } else {
      revert NotEnoughSubIdOrAssetAllowances(address(this), msg.sender, absAmount, subIdAllowance, assetAllowance);
    }
  }


  //////////
  // Util //
  //////////

  /** 
   * @notice Called when the account does not already hold the (asset, subId)
   * @dev Useful for managers to check the risk of the whole account
   */
  function _addHeldAsset(
    uint accountId, IAbstractAsset asset, uint subId
  ) internal returns (uint16 newOrder) {
    heldAssets[accountId].push(HeldAsset({asset: asset, subId: subId.toUint96()}));
    newOrder = (heldAssets[accountId].length - 1).toUint16();
  }
  
  /** 
   * @notice Called when the balance of a (asset, subId) returns to zero
   * @dev BalanceAndOrder.order used to gas efficiently remove assets from large accounts
   *      1. removes ~200k gas overhead for a 100 position portfolio
   *      2. for expiration with strikes, reduces gas overheada by ~150k
   */
  function _removeHeldAsset(
    uint accountId, 
    BalanceAndOrder memory userBalanceAndOrder
  ) internal returns (uint16 newOrder) {

    uint16 currentAssetOrder = userBalanceAndOrder.order; // 100 gas

    // swap orders if middle asset removed
    uint heldAssetLen = heldAssets[accountId].length;

    if (currentAssetOrder != heldAssetLen.toUint16() - 1) { 
      HeldAsset memory assetToMove = heldAssets[accountId][heldAssetLen - 1]; // 2k gas
      heldAssets[accountId][currentAssetOrder] = assetToMove; // 5k gas

      BalanceAndOrder storage toMoveBalanceAndOrder = 
        balanceAndOrder[accountId][assetToMove.asset][uint(assetToMove.subId)];
      toMoveBalanceAndOrder.order = currentAssetOrder; // 5k gas 
    }

    // remove asset from heldAsset
    heldAssets[accountId].pop(); // 200 gas
    return 0;
  }

  /** @dev used for gas efficient transferAll() */
  function _clearAllHeldAssets(uint accountId) internal {
    HeldAsset[] memory assets = heldAssets[accountId];
    uint heldAssetLen = assets.length;
    for (uint i; i < heldAssetLen; i++) {
      BalanceAndOrder storage orderToClear = 
        balanceAndOrder[accountId][assets[i].asset][uint(assets[i].subId)];

      orderToClear.order = 0;
    }
    delete heldAssets[accountId];
  }

  function _abs(int amount) internal pure returns (uint absAmount) {
    return (amount >= 0) ? uint(amount) : SafeCast.toUint256(-amount);
  }

  function _findInArray(
    uint[] memory array, uint toFind
  ) internal pure returns (bool found) {
    uint arrayLen = array.length;
    for (uint i; i < arrayLen; ++i) {
      if (array[i] == 0) {
        return false;
      }
      if (array[i] == toFind) {
        return true;
      }
    }
    return false;
  }

  function _findInArray(
    IAbstractAsset[] memory array, IAbstractAsset toFind
  ) internal pure returns (bool found) {
    uint arrayLen = array.length;
    for (uint i; i < arrayLen; ++i) {
      if (array[i] == IAbstractAsset(address(0))) {
        return false;
      }
      if (array[i] == toFind) {
        return true;
      }
    }
    return false;
  }

  //////////
  // View //
  //////////

  /** 
   * @notice Gets an account's balance for an (asset, subId)
   * @param accountId ID of account
   * @param asset IAbstractAsset of balance
   * @param subId subId of balance
   */
  function getBalance(
    uint accountId, 
    IAbstractAsset asset, 
    uint subId
  ) external view returns (int balance){
    BalanceAndOrder memory userBalanceAndOrder = 
            balanceAndOrder[accountId][asset][subId];
    return int(userBalanceAndOrder.balance);
  }

  /** 
   * @notice Gets a list of all asset balances of an account
   * @dev can use balanceAndOrder() to get the index of a specific balance
   * @param accountId ID of account
  */
  function getAccountBalances(uint accountId) 
    external view returns (AssetBalance[] memory assetBalances) {
    return _getAccountBalances(accountId);
  }

  function _getAccountBalances(uint accountId)
    internal
    view
    returns (AssetBalance[] memory assetBalances)
  {
    uint allAssetBalancesLen = heldAssets[accountId].length;
    assetBalances = new AssetBalance[](allAssetBalancesLen);
    for (uint i; i < allAssetBalancesLen; i++) {
      HeldAsset memory heldAsset = heldAssets[accountId][i];
      BalanceAndOrder memory userBalanceAndOrder = 
            balanceAndOrder[accountId][heldAsset.asset][uint(heldAsset.subId)];

      assetBalances[i] = AssetBalance({
        asset: heldAsset.asset,
        subId: uint(heldAsset.subId),
        balance: int(userBalanceAndOrder.balance)
      });
    }
    return assetBalances;
  }

  ///////////////
  // Modifiers //
  ///////////////

  modifier onlyManagerOrAsset(uint accountId, IAbstractAsset asset) {
    address accountManager = address(manager[accountId]);
    if (msg.sender != accountManager && msg.sender != address(asset)) {
      revert OnlyManagerOrAssetAllowed(address(this), msg.sender, accountManager, address(asset));
    }
    _;
  }
}