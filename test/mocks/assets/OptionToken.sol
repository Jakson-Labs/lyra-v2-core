pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "synthetix/DecimalMath.sol";
import "synthetix/Owned.sol";
import "util/BlackScholesV2.sol";
import "forge-std/console2.sol";

import "src/Account.sol";
import "src/interfaces/IAbstractAsset.sol";

import "../assets/QuoteWrapper.sol";
import "../feeds/SettlementPricer.sol";
import "../feeds/PriceFeeds.sol";

// Adapter condenses all deposited positions into a single position per subId
contract OptionToken is IAbstractAsset, Owned {
  using SignedDecimalMath for int;
  using BlackScholesV2 for BlackScholesV2.BlackScholesInputs;
  using DecimalMath for uint;

  struct Listing {
    uint strikePrice;
    uint expiry;
    bool isCall;
  }

  Account account;
  PriceFeeds priceFeeds;
  SettlementPricer settlementPricer;

  uint feedId;
  uint96 nextId = 0;
  mapping(IAbstractManager => bool) riskModelAllowList;
  
  mapping(uint => uint) totalLongs;
  mapping(uint => uint) totalShorts;
  // need to write down ratio as totalOIs change atomically during transfers
  mapping(uint => uint) ratios;
  mapping(uint => uint) liquidationCount;

  mapping(uint96 => Listing) subIdToListing;
  constructor(
    Account account_, PriceFeeds feeds_, SettlementPricer settlementPricer_, uint feedId_
  ) Owned() {
    account = account_;
    priceFeeds = feeds_;
    settlementPricer = settlementPricer_;
    feedId = feedId_;

    priceFeeds.assignFeedToAsset(IAbstractAsset(address(this)), feedId);
  }

  //////////
  // Admin

  function setRiskModelAllowed(IAbstractManager riskModel, bool allowed) external onlyOwner {
    riskModelAllowList[riskModel] = allowed;
  }

  //////
  // Transfer

  // account.sol already forces amount from = amount to, but at settlement this isnt necessarily true.
  function handleAdjustment(
    uint, int preBal, int amount, uint96 subId, IAbstractManager riskModel, address caller, bytes32
    ) external override returns (int finalBalance)
  {
    Listing memory listing = subIdToListing[subId];
    int postBal = _getPostBalWithRatio(preBal, amount, subId);

    if (block.timestamp >= listing.expiry) {
      require(riskModelAllowList[IAbstractManager(caller)], "only RM settles");
      require(preBal != 0 && postBal == 0);
      return postBal;
    }

    require(listing.expiry != 0 && riskModelAllowList[riskModel]);

    _updateOI(preBal, postBal, subId);

    return postBal;
  }

  ////
  // Liquidation

  function incrementLiquidations(uint subId) external {
    require(riskModelAllowList[IAbstractManager(msg.sender)], "only RM");
    liquidationCount[subId]++;
    // delay settlement for subid by n min
  }

  function decrementLiquidations(uint subId) external {
    require(riskModelAllowList[IAbstractManager(msg.sender)], "only RM");
    liquidationCount[subId]--;
    // delay settlement for subid by n min
  }

  /////
  // Option Value

  // currently hard-coded to optionToken but can have multiple assets if sharing the same logic
  function getValue(uint subId, int balance, uint spotPrice, uint iv) external view returns (int value) {
    Listing memory listing = subIdToListing[uint96(subId)];
    balance = _ratiodBalance(balance, subId);

    if (block.timestamp > listing.expiry) {
      SettlementPricer.SettlementDetails memory settlementDetails = settlementPricer.maybeGetSettlementDetails(feedId, listing.expiry);

      return _getSettlementValue(listing, balance, settlementDetails.price != 0 ? settlementDetails.price : spotPrice);
    }

    (uint callPrice, uint putPrice) = BlackScholesV2.BlackScholesInputs({
    timeToExpirySec: listing.expiry,
    volatilityDecimal: iv,
    spotDecimal: spotPrice,
    strikePriceDecimal: listing.strikePrice,
    rateDecimal: 5e16
    }).prices();

    value = (listing.isCall) ? balance.multiplyDecimal(int(callPrice)) : balance.multiplyDecimal(int(putPrice));
    return value;
  }

  /////
  // Settlement

  function calculateSettlement(uint subId, int balance) external view returns (int PnL, bool settled) {
    Listing memory listing = subIdToListing[uint96(subId)];
    SettlementPricer.SettlementDetails memory settlementDetails = settlementPricer.maybeGetSettlementDetails(feedId, listing.expiry);

    if (listing.expiry < block.timestamp || settlementDetails.price == 0) {
      return (0, false);
    }
    balance = _ratiodBalance(balance, subId);

    return (_getSettlementValue(listing, balance, settlementDetails.price), true);
  }

  function _getSettlementValue(Listing memory listing, int balance, uint spotPrice) internal pure returns (int value) {
    int PnL = (SafeCast.toInt256(spotPrice) - SafeCast.toInt256(listing.strikePrice));

    if (listing.isCall && PnL > 0) {
      // CALL ITM
      return PnL * balance;
    } else if (!listing.isCall && PnL < 0) {
      // PUT ITM
      return -PnL * balance;
    } else {
      // OTM
      return 0;
    }
  }

  //////
  // Views

  /**
   * subId encodes strike, expiry and isCall
   * bit 0 => isCall
   * bits 64-128 => expiry
   * bits 128-256 => strikePrice
   */

  function _ratiodBalance(int balance, uint subId) internal view returns (int ratiodBalance) {
    if (ratios[nextId] < 1e17) {
      // create some hardcoded limit to where asset freezes at certain levels of socialized losses
      revert("Socialized lossess too high");
    }
    // for socialised losses
    return _applyRatio(balance, subId);
  }

  function handleManagerChange(uint, IAbstractManager, IAbstractManager) external pure override {}

  function addListing(uint strike, uint expiry, bool isCall) external returns (uint subId) {
    Listing memory newListing = Listing({
      strikePrice: strike,
      expiry: expiry,
      isCall: isCall
    });
    subIdToListing[nextId] = newListing;
    ratios[nextId] = 1e18;
    ++nextId;
    return uint256(nextId) - 1;
  }

  function socializeLoss(uint insolventAcc, uint subId, int reduction) external {
    require(riskModelAllowList[IAbstractManager(msg.sender)], "only RM socializes losses");

    int preBal = account.getBalance(insolventAcc, IAbstractAsset(address(this)), subId);
    int postBal = preBal + reduction;

    account.adjustBalance(
      IAccount.AssetAdjustment({
        acc: insolventAcc,
        asset: IAbstractAsset(address(this)),
        subId: subId,
        amount: reduction,
        assetData: bytes32(0)
      }),
      ""
    );

    ratios[subId] = DecimalMath.UNIT * totalShorts[subId] / totalLongs[subId];

    _updateOI(preBal, postBal, subId);
  }

  function _getPostBalWithRatio(int preBal, int amount, uint subId) internal view returns (int postBal) {
    bool crossesZero;
    if (preBal < 0) {
      crossesZero = _abs(preBal) < _abs(amount) && amount > 0
        ? true 
        : false;

      if (crossesZero) {
        return _applyInverseRatio((amount - preBal), subId);
      } else {
        return preBal + amount;
      }
    } else {
      crossesZero = 
        _abs(preBal) < _abs(_applyInverseRatio(amount, subId)) && amount < 0
        ? true 
        : false;

      if (crossesZero) {
        return amount + _applyRatio(preBal, subId);
      } else {
        return preBal + _applyInverseRatio(amount , subId);
      }
    }
  }

  function _applyRatio(int amount, uint subId) internal view returns (int) {
    return int(ratios[subId]) * amount / SignedDecimalMath.UNIT;
  }

  function _applyInverseRatio(int amount, uint subId) internal view returns (int) {
    int inverseRatio = SignedDecimalMath.UNIT / int(ratios[subId]);
    return inverseRatio * amount / SignedDecimalMath.UNIT;
  }

  function _updateOI(int preBal, int postBal, uint subId) internal {
    if (preBal < 0) {
      totalShorts[subId] -= uint(-preBal);
    } else {
      totalLongs[subId] -= uint(preBal);
    }

    if (postBal < 0) {
      totalShorts[subId] += uint(-postBal);
    } else {
      totalLongs[subId] += uint(postBal);
    }
  }

  function _abs(int x) internal pure returns (uint absAmount) {
 return (x >= 0) ? uint(x) : uint(-x);
  }
}
