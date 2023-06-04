// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "src/interfaces/ISpotDiffFeed.sol";

contract MockSpotDiffFeed is ISpotDiffFeed {
  ISpotFeed public spotFeed;
  int public spotDiff;
  uint public confidence;

  constructor(ISpotFeed _spotFeed) {
    spotFeed = _spotFeed;
    confidence = 1e18;
  }

  function setSpotFeed(ISpotFeed _spotFeed) external {
    spotFeed = _spotFeed;
  }

  function setSpotDiff(int _spotDiff, uint _confidence) external {
    spotDiff = _spotDiff;
    confidence = _confidence;
  }

  function getResult() external view returns (uint, uint) {
    (uint spot,) = spotFeed.getSpot();
    return (uint(int(spot) + spotDiff), confidence);
  }
}
