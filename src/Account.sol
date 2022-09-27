pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "./interfaces/IAsset.sol";
import "./interfaces/IManager.sol";
import "./interfaces/IAccount.sol";
import "forge-std/console2.sol";

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

  uint nextId = 0;

  /// @dev account Id to manager 
  mapping(uint => IManager) public manager;

  /// @dev account Id => asset => subId => BalanceAndOrder struct
  mapping(uint => mapping(IAsset => mapping(uint => BalanceAndOrder))) public balanceAndOrder;

  /// @dev account Id to non-zero assets array
  mapping(uint => HeldAsset[]) public heldAssets;

  mapping(uint => mapping(IAsset => mapping(uint => mapping(address => uint)))) public positiveSubIdAllowance;
  mapping(uint => mapping(IAsset => mapping(uint => mapping(address => uint)))) public negativeSubIdAllowance;
  mapping(uint => mapping(IAsset => mapping(address => uint))) public positiveAssetAllowance;
  mapping(uint => mapping(IAsset => mapping(address => uint))) public negativeAssetAllowance;
  
  constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

  ///////////////////
  // Account Admin //
  ///////////////////

  /** 
   * @notice Creates account with new accountId
   * @param owner new account owner
   * @param _manager IManager of new account
   * @return newId ID of new account
   */
  function createAccount(
    address owner, IManager _manager
  ) external returns (uint newId) {
    return _createAccount(owner, _manager);
  }

  /** 
   * @notice Creates account and gives spender full allowance
   * @param owner new account owner
   * @param spender give address ERC721 approval
   * @param _manager IManager of new account
   * @return newId ID of new account
   */
  function createAccount(
    address owner, address spender, IManager _manager
  ) external returns (uint newId) {
    newId = _createAccount(owner, _manager);
    _approve(spender, newId);
  }

  function _createAccount(
    address owner, IManager _manager
  ) internal returns (uint newId) {
    newId = ++nextId;
    manager[newId] = _manager;
    _mint(owner, newId);
    emit AccountCreated(owner, newId, address(_manager));
  }

  /** 
   * @notice Burns multiple accounts using ERC721._burn(). 
   *         Account must not hold any assets.
   *         This account can never be reused.
   * @param accountId accountId to burn
   */
  function burnAccount(uint accountId) external onlyOwnerOrManagerOrERC721Approved(msg.sender, accountId) {
    uint heldAssetLen = heldAssets[accountId].length;
    if (heldAssetLen > 0) {
      revert CannotBurnAccountWithHeldAssets(address(this), msg.sender, accountId, heldAssetLen);
    }
    _burn(accountId);
    emit AccountBurned(ownerOf(accountId), accountId, address(manager[accountId]));
  }

  /** 
   * @notice Assigns new manager to account. No balances are adjusted.
   *         msg.sender must be ERC721 approved or owner
   * @param accountId ID of account
   * @param newManager new IManager
   * @param newManagerData data to be passed to manager._managerHook 
   */
  function changeManager(
    uint accountId, IManager newManager, bytes memory newManagerData
  ) external onlyOwnerOrManagerOrERC721Approved(msg.sender, accountId) {    
    IManager oldManager = manager[accountId];
    if (oldManager == newManager) { 
      revert CannotChangeToSameManager(address(this), msg.sender, accountId); 
    }
    oldManager.handleManagerChange(accountId, newManager);

    /* get unique assets to only call to asset once */
    HeldAsset[] memory accountAssets = heldAssets[accountId];
    (IAsset[] memory uniqueAssets, uint uniqueLength) = _getUniqueAssets(accountAssets);

    for (uint i; i < uniqueLength; ++i) {
      uniqueAssets[i].handleManagerChange(accountId, newManager);
    }

    manager[accountId] = newManager;
    
    // trigger the manager hook on the new manager. Same as post-transfer checks
    _managerHook(accountId, msg.sender, newManagerData);

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
   * @param allowances positive and negative amounts for each asset
   */
  function setAssetAllowances(
    uint accountId, 
    address delegate,
    AssetAllowance[] memory allowances
  ) external onlyOwnerOrManagerOrERC721Approved(msg.sender, accountId) {
    uint allowancesLen = allowances.length;
    for (uint i; i < allowancesLen; i++) {
      // TODO: think about whether we need to clear asset / subId allowances
      positiveAssetAllowance[accountId][allowances[i].asset][delegate] = allowances[i].positive;
      negativeAssetAllowance[accountId][allowances[i].asset][delegate] = allowances[i].negative;
    }
  }

  /** 
   * @notice Sets bidirectional allowances for a specific subId. 
   *         During a balance adjustment, the subId allowance is decremented first 
   * @param accountId ID of account
   * @param delegate address to assign allowance to
   * @param allowances positive and negative amounts for each (asset, subId)
   */
  function setSubIdAllowances(
    uint accountId, 
    address delegate,
    SubIdAllowance[] memory allowances
  ) external onlyOwnerOrManagerOrERC721Approved(msg.sender, accountId) {
    uint allowancesLen = allowances.length;
    for (uint i; i < allowancesLen; i++) {
      positiveSubIdAllowance[accountId][allowances[i].asset][allowances[i].subId][delegate] = allowances[i].positive;
      negativeSubIdAllowance[accountId][allowances[i].asset][allowances[i].subId][delegate] = allowances[i].negative;
    }
  }

  /// @dev giving managers exclusive rights to transfer account ownerships
  /// @dev this function overrides ERC721._isApprovedOrOwner(spender, tokenId);
  function _isApprovedOrOwner(
    address spender, uint tokenId
  ) internal view override returns (bool) {
    address owner = ERC721.ownerOf(tokenId);
    
    // return early if msg.sender is owner
    if (
      spender == owner || 
      isApprovedForAll(owner, spender) || 
      getApproved(tokenId) == spender
    ) return true;

    // check if caller is manager
    return address(manager[tokenId]) == msg.sender;
  }

  /////////////////////////
  // Balance Adjustments //
  /////////////////////////

  /** 
   * @notice Transfer an amount from one account to another for a specific (asset, subId)
   * @param assetTransfer (fromAcc, toAcc, asset, subId, amount)
   * @param managerData data passed to managers of both accounts 
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
   * @param managerData data passed to every manager involved in trade 
   */
  function submitTransfers(
    AssetTransfer[] memory assetTransfers, bytes memory managerData
  ) external {
    uint transfersLen = assetTransfers.length;

    /* Keep track of seen accounts to assess risk once per account */
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

    for (uint i; i < nextSeenId; i++) {
      _managerHook(seenAccounts[i], msg.sender, managerData);
    }
  }


  /** 
   * @notice Transfer an amount from one account to another for a specific (asset, subId)
   * @dev    update the allowance and balanceAndOrder storage
   * @param assetTransfer (fromAcc, toAcc, asset, subId, amount)
   */
  function _transferAsset(
    AssetTransfer memory assetTransfer
  ) internal {

    if (assetTransfer.fromAcc == assetTransfer.toAcc) {
      revert CannotTransferAssetToOneself(address(this), msg.sender, assetTransfer.toAcc);
    }

    AssetAdjustment memory fromAccAdjustment = AssetAdjustment({
      acc: assetTransfer.fromAcc,
      asset: assetTransfer.asset,
      subId: assetTransfer.subId,
      amount: -assetTransfer.amount,
      assetData: assetTransfer.assetData
    });

    AssetAdjustment memory toAccAdjustment = AssetAdjustment({
      acc: assetTransfer.toAcc,
      asset: assetTransfer.asset,
      subId: assetTransfer.subId,
      amount: assetTransfer.amount,
      assetData: assetTransfer.assetData
    });

    _spendAllowance(fromAccAdjustment, msg.sender);
    _spendAllowance(toAccAdjustment, msg.sender);

    // balance is adjusted based on asset hook
    _adjustBalance(fromAccAdjustment);
    _adjustBalance(toAccAdjustment);
  }

  /** 
   * @notice Assymetric balance adjustment reserved for managers
   *         Must still pass both _assetHook()
   * @param adjustment assymetric adjustment of amount for (asset, subId)
   */
  function adjustBalance(
    AssetAdjustment memory adjustment
  ) onlyManager(adjustment.acc) external returns (int postAdjustmentBalance) {    

    // balance is adjusted based on asset hook
    postAdjustmentBalance = _adjustBalance(adjustment);
  }

  /** 
   * @notice Assymetric balance adjustment reserved for assets
   *         Must still pass both _managerHook()
   * @param adjustment assymetric adjustment of amount for (asset, subId)
   * @param managerData data passed to manager of account
   */
  function adjustBalance(
    AssetAdjustment memory adjustment,
    bytes memory managerData
  ) onlyAsset(adjustment.asset) external returns (int postAdjustmentBalance) {    

    // balance adjustment is routed through asset again 
    postAdjustmentBalance = _adjustBalance(adjustment);

    // check manager hook
    _managerHook(adjustment.acc, msg.sender, managerData);
  }

  /**
   * @dev the order field is never set back to 0 to safe on gas
   *      ensure balance != 0 when using the BalandAnceOrder.order field
   */
  function _adjustBalance(AssetAdjustment memory adjustment) internal returns (int256 postBalance) {
    BalanceAndOrder storage userBalanceAndOrder 
      = balanceAndOrder[adjustment.acc][adjustment.asset][adjustment.subId];
    int preBalance = int(userBalanceAndOrder.balance);

    // allow asset to modify final balance in special cases
    postBalance = _assetHook(
      adjustment, 
      preBalance, 
      msg.sender
    );

    /* for gas efficiency, order unchanged when asset removed */
    userBalanceAndOrder.balance = postBalance.toInt240();
    if (preBalance != 0 && postBalance == 0) {
      _removeHeldAsset(adjustment.acc, userBalanceAndOrder.order);
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
      adjustment.amount,
      preBalance, 
      postBalance
    );
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
   * @param managerData open ended data passed to manager
   */
  function _managerHook(
    uint accountId, 
    address caller,
    bytes memory managerData
  ) internal {
    manager[accountId].handleAdjustment(
      accountId, caller, managerData
    );
  }

  /** 
   * @notice Hook that calls the asset during:
   *         1. Transfers / Merges / Splits
   *         2. Assymetric balance adjustments
   * @dev as hook is called for every asset transfer (unlike _managerHook())
   *      care must be given to reduce gas usage 
   * @param adjustment all details related to balance adjustment
   * @param preBalance balance before adjustment
   * @param caller address of msg.sender initiating balance adjustment
   * @return finalBalance the amount should be written as final balance
   */
  function _assetHook(
    AssetAdjustment memory adjustment,
    int preBalance, 
    address caller
  ) internal returns (int finalBalance) {
    return adjustment.asset.handleAdjustment(
      adjustment, preBalance, manager[adjustment.acc], caller
    );
  }

  /** 
   * @notice Checks allowances during transfers / merges / splits
   *         Not checked during adjustBalance()
   *         1. If delegate ERC721 approved or owner, blanket allowance given
   *         2. Otherwise, sum of subId and asset bidirectional allowances used
   *         The subId allowance is decremented before the asset-wide allowance
   * @dev finalBalance adjustments tweaked by the asset not considered in allowances 
   * @param adjustment amount of balance adjustment for an (asset, subId)
   * @param delegate address of msg.sender initiating change
   */
  function _spendAllowance(
    AssetAdjustment memory adjustment, address delegate
  ) internal {
    /* ERC721 approved, manager or owner get blanket allowance */
    if (_isApprovedOrOwner(delegate, adjustment.acc)) { return; }

    /* determine if positive vs negative allowance is needed */
    if (adjustment.amount > 0) {
      _spendAbsAllowance(
        adjustment.acc,
        positiveSubIdAllowance[adjustment.acc][adjustment.asset][adjustment.subId],
        positiveAssetAllowance[adjustment.acc][adjustment.asset],
        delegate,
        adjustment.amount
      );
    } else if (adjustment.amount < 0) {
      _spendAbsAllowance(
        adjustment.acc,
        negativeSubIdAllowance[adjustment.acc][adjustment.asset][adjustment.subId],
        negativeAssetAllowance[adjustment.acc][adjustment.asset],
        delegate,
        adjustment.amount
      );
    } else {
    /* handle amount = 0 case */
      return;
    }

  }

  function _spendAbsAllowance(
    uint accountId,
    mapping(address => uint) storage allowancesForSubId,
    mapping(address => uint) storage allowancesForAsset,
    address delegate,
    int256 amount
  ) internal {
    uint subIdAllowance = allowancesForSubId[delegate];
    uint assetAllowance = allowancesForAsset[delegate];

    uint256 absAmount = _abs(amount);
    /* subId allowances are decremented before asset allowances */
    if (absAmount <= subIdAllowance) {
      allowancesForSubId[delegate] = subIdAllowance - absAmount;
    } else if (absAmount <= subIdAllowance + assetAllowance) { 
      allowancesForSubId[delegate] = 0;
      allowancesForAsset[delegate] = assetAllowance - (absAmount - subIdAllowance);
    } else {
      revert NotEnoughSubIdOrAssetAllowances(
        address(this), 
        msg.sender, 
        accountId, 
        amount,
        subIdAllowance, 
        assetAllowance);
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
    uint accountId, IAsset asset, uint subId
  ) internal returns (uint16 newOrder) {
    heldAssets[accountId].push(HeldAsset({asset: asset, subId: subId.toUint96()}));
    newOrder = (heldAssets[accountId].length - 1).toUint16();
  }
  
  /** 
   * @notice Called when the balance of a (asset, subId) returns to zero
   * @dev order used to gas efficiently remove assets from large accounts
   *      1. removes ~200k gas overhead for a 100 position portfolio
   *      2. for expiration with strikes, reduces gas overheada by ~150k
   */
  function _removeHeldAsset(
    uint accountId, 
    uint16 order
  ) internal {
    /* swap order value if middle asset removed */
    uint heldAssetLen = heldAssets[accountId].length;

    if (order != heldAssetLen.toUint16() - 1) { 
      HeldAsset memory assetToMove = heldAssets[accountId][heldAssetLen - 1]; // 2k gas
      heldAssets[accountId][order] = assetToMove; // 5k gas

      // update the "order" field of the moved asset for an account 
      balanceAndOrder[accountId][assetToMove.asset][uint(assetToMove.subId)].order = order; // 5k gas 
    }

    heldAssets[accountId].pop(); // 200 gas
  }

  function _abs(int amount) internal pure returns (uint absAmount) {
    return amount >= 0 ? uint(amount) : uint(-amount);
  }

  /**
   * @dev get unique assets from heldAssets. heldAssets can hold multiple entries with same asset but different subId
   * @return uniqueAssets list of address
   * @return length max index of returned address that is non-zero
   */
  function _getUniqueAssets(
    HeldAsset[] memory assets
  ) internal pure returns (IAsset[] memory uniqueAssets, uint length) {
    uniqueAssets = new IAsset[](assets.length);

    for (uint i; i < assets.length; ++i) {
      if (!_findInArray(uniqueAssets, assets[i].asset)) {
        uniqueAssets[length++] = assets[i].asset;
      }
    }
  }

  function _findInArray(
    uint[] memory array, uint toFind
  ) internal pure returns (bool found) {
    uint arrayLen = array.length;
    for (uint i; i < arrayLen; ++i) {
      if (array[i] == 0) {
        break;
      }
      if (array[i] == toFind) {
        return true;
      }
    }
  }

  function _findInArray(
    IAsset[] memory array, IAsset toFind
  ) internal pure returns (bool found) {
    uint arrayLen = array.length;
    for (uint i; i < arrayLen; ++i) {
      if (array[i] == IAsset(address(0))) {
        break;
      }
      if (array[i] == toFind) {
        return true;
      }
    }
  }

  //////////
  // View //
  //////////

  /** 
   * @notice Gets an account's balance for an (asset, subId)
   * @param accountId ID of account
   * @param asset IAsset of balance
   * @param subId subId of balance
   */
  function getBalance(
    uint accountId, 
    IAsset asset, 
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

  modifier onlyManager(uint256 accountId) {
    address accountManager = address(manager[accountId]);
    if (msg.sender != accountManager) revert OnlyManager(address(this), msg.sender, accountManager); 
      _;
  }

  modifier onlyAsset (IAsset asset) {
    if (msg.sender != address(asset)) revert OnlyAsset(address(this), msg.sender, address(asset)); 
      _;
  }

  modifier onlyOwnerOrManagerOrERC721Approved(address sender, uint accountId) {
    if (!_isApprovedOrOwner(sender, accountId)) {
      revert NotOwnerOrERC721Approved(
        address(this), 
        sender, 
        accountId, 
        ownerOf(accountId), 
        manager[accountId], 
        getApproved(accountId)
      );
    }
    _;
  }
}