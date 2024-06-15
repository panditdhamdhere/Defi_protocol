// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

/**
 * @title DSCEngine
 * @author Pandit dhamdhere (https://github.com/panditdhamdhere)
 *
 * The System is designed to be as minimal as possible, and have the tokens maintain a 1 token == $ 1 peg
 * This stable has the properties
 * - Exogenous Collateral
 * - Doller pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized", at no point, should the value of all collateral <= the $ backed value of all DSC
 *
 * @notice This contract is the core of the DSC System, It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 *
 * @notice This contract is Very loosly based on the MAKERDAO DSS (DAI) system
 */
pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DSCEngine is ReentrancyGuard {
    //////////////////////////////
    ///////// Errors /////////////
    //////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
    error DSCEngine__NotAllowedToken();

    //////////////////////////////
    ///////state Variables ///////
    //////////////////////////////
    mapping(address token => address priceFeeds) private s__priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////////
    ///////// modifiers //////////
    //////////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s__priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //////////////////////////////
    ///////// functions //////////
    //////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD and etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s__priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////////
    ///// External functions /////
    //////////////////////////////

    function depositeCollateralAndMintDSC() external {}

    /*
     * @param tokenCollateralAddress The address of the token to deposite as a collateral
     * @param amountCollateral The amount of collateral to deposite
     */

    function depositeCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
    }

    function redeemCollateralForDSC() external {}

    function redeemCollateral() external {}

    function mintDSC() external {}

    function burnDSC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
