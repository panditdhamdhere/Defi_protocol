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
 * Om Ganeshay Namah !!
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

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    //////////////////////////////
    ///////// Errors /////////////
    //////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////////////////
    ///////state Variables ///////
    //////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means 10% bonus

    mapping(address token => address priceFeeds) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////////
    ///////// Events /////////////
    //////////////////////////////

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

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
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //////////////////////////////
    ///////// functions //////////
    //////////////////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD and etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////////
    ///// External functions /////
    //////////////////////////////

    /*
     * @param tokenCollateralAddress The address of the token deposite as collateral
     * @param amountCollateral The amount of the collateral to deposite
     * @param amountDscToMint The amount of the Decentralized Stable Coin to mint
     * @notice This function will depoite your collateral and mint DSC in 1 transaction
     */
    function depositeCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositeCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposite as collateral
     * @param amountCollateral The amount of collateral to deposite
     */
    function depositeCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The Amount collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns and redeems underlying collateral in 1 transaction
     */
    function redeemCollateralForDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    //In order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    // DRY - Dont repeat yourself

    // CEI
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @notice follows CEI
     * @param amountDSCToMint The amount of decentralized stable coin to mint
     * @notice They must have more collateral value than the minimal trashhold
     */
    function mintDsc(
        uint256 amountDSCToMint
    ) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I dont think this would ever hit.........
    }

    /*
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor, their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The Amount of DSC you want to burn to improve the users health factor
     * @notice you can partially liquidate a user;
     * @notice you will get liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overCollateralized in order for this to work
     * @notice A known BUG would be if the protocol were 100% or less collateralized, then we would not be able to incentivize the liquidators
     * For example: If the price of the collateral plummeted before anyone could be liquidated!
     *
     * follows CEI
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // I want to burn their DSC "debt"
        // And take their collateral
        // BAD USER: $140 ETH , $100 DSC
        // Debt to cover
        // %100 of  $100 DSC = ????? how much eth
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // And give them 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;

        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );
        // we need to burn dsc
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////////////
    ///// Private & Internal view functions ////
    ////////////////////////////////////////////

    /*
     *@dev low level internal function, do not call unless the function calling it is
     * checking for health factors being broken
     */

    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDSCMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        uint256 collateralAdjustedOrThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedOrThreshold * PRECISION) / totalDSCMinted;
        //    return collateralValueInUsd /totalDSCMinted;
    }

    // 1. check health factor (do they have enough collateral)
    // 2. revert if not
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////////
    ///// Public & External view functions ////
    ///////////////////////////////////////////

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        // price of Eth (token)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // 1 ETH = $1000
        // The return value from CL will be 1000 * 1e8
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}
