/*
-----------------------------------------------------------------
FILE INFORMATION
-----------------------------------------------------------------
file:       CollateralisedNomin.sol
version:    0.3
author:     Block8 Technologies, in partnership with Havven

            Anton Jurisevic

date:       2018-1-3

checked:    -
approved:   -

-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

Ether-backed nomin stablecoin contract.

-----------------------------------------------------------------
LICENCE INFORMATION
-----------------------------------------------------------------

Copyright (c) 2017 Havven.io

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
    
-----------------------------------------------------------------
RELEASE NOTES
-----------------------------------------------------------------

Initial scaffolding of nomin alpha contract. It will require
a price oracle to run externally.

-----------------------------------------------------------------
Block8 Technologies is accelerating blockchain technology
by incubating meaningful next-generation businesses.
Find out more at https://www.block8.io/
-----------------------------------------------------------------
*/

pragma solidity ^0.4.19;

import "ERC20FeeToken.sol";

/* Issues nomins, which are tokens worth 1 USD each. They are backed
 * by a pool of ether collateral, so that if a user has nomins, they may
 * redeem them for ether from the pool, or if they want to obtain nomins,
 * they may pay ether into the pool in order to do so. 
 * 
 * The supply of nomins that may be in circulation at any time is limited.
 * The contract owner may increase this quantity, but only if they provide
 * ether to back it. The backing they provide must be at least 1-to-1
 * nomin to fiat value of the ether collateral. In this way each nomin is
 * at least 2x overcollateralised. The owner may also destroy nomins
 * in the pool, but they must respect the collateralisation requirement.
 *
 * Ether price is continually updated by an external oracle, and the value
 * of the backing is computed on this basis. To ensure the integrity of
 * this system, if the contract's price has not been updated recently enough,
 * it will temporarily disable itself until it receives more price information.
 *
 * The contract owner may at any time initiate contract liquidation.
 * During the liquidation period, most contract functions will be deactivated.
 * No new nomins may be issued or bought, but users may sell nomins back
 * to the system.
 * After the liquidation period has elapsed, which is initially 90 days,
 * the owner may destroy the contract, transferring any remaining collateral
 * to a nominated beneficiary address.
 * This liquidation period may be extended up to a maximum of 180 days.
 *
 * The contract's owner should be the Havven foundation multisig command contract.
 * Only the owner may perform the following actions:
 *   - Setting the owner;
 *   - Setting the oracle;
 *   - Setting the beneficiary;
 *   - Issuing new nomins into the pool;
 *   - Burning nomins in the pool;
 *   - Initiating and extending liquidation;
 *   - Selfdestructing the contract
 */
contract CollateralisedNomin is ERC20FeeToken {
    // The oracle provides price information to this contract.
    // It may only call the setPrice() function.
    address oracle;

    // Foundation wallet for funds to go to post liquidation.
    address beneficiary;
    
    // ERC20 token information.
    string public constant name = "Collateralised Nomin";
    string public constant symbol = "CNOM";

    // Nomins in the pool ready to be sold.
    uint public pool = 0;
    
    // Impose a 50 basis-point fee for buying from and selling to the nomin pool.
    uint public poolFee = UNIT / 200;
    
    // Minimum quantity of nomins purchasable: 1 cent by default.
    uint public purchaseMininum = UNIT / 100;

    // When issuing, nomins must be overcollateralised by this ratio.
    uint public collatRatioMinimum =  2 * UNIT;

    // The time that must pass before the liquidation period is complete.
    uint public liquidationPeriod = 90 days;
    
    // The liquidation period can be extended up to this duration.
    uint public maxLiquidationPeriod = 180 days;

    // The timestamp when liquidation was activated. We initialise this to
    // uint max, so that we know that we are under liquidation if the 
    // liquidation timestamp is in the past.
    uint public liquidationTimestamp = ~uint(0);
    
    // Ether price from oracle (fiat per ether).
    uint public etherPrice;
    
    // Last time the price was updated.
    uint public lastPriceUpdate;

    // The period it takes for the price to be considered stale.
    // If the price is stale, functions that require the price are disabled.
    uint public stalePeriod = 3 days;

    // Constructor
    function CollateralisedNomin(address _owner, address _oracle,
                                 address _beneficiary, uint initialEtherPrice)
        ERC20FeeToken(_owner)
        public
    {
        oracle = _oracle;
        beneficiary = _beneficiary;
        etherPrice = initialEtherPrice;
        lastPriceUpdate = now;

        // Each transfer of nomins incurs a 10 basis point fee by default.
        transferFee = UNIT / 1000; 
    }

    // Throw an exception if the caller is not the contract's designated price oracle.
    modifier onlyOracle
    {
        require(msg.sender == oracle);
        _;
    }

    // Throw an exception if the contract is currently undergoing liquidation.
    modifier notLiquidating
    {
        require(!isLiquidating());
        _;
    }

    modifier priceNotStale
    {
        require(!priceIsStale());
        _;
    }  
    
    // Set the price oracle of this contract. Only the contract owner should be able to call this.
    function setOracle(address newOracle)
        public
        onlyOwner
    {
        oracle = newOracle;
    }
    
    // Set the beneficiary of this contract. Only the contract owner should be able to call this.
    function setBeneficiary(address newBeneficiary)
        public
        onlyOwner
    {
        beneficiary = newBeneficiary;
    }
    
    /* Return the equivalent fiat value of the given quantity
     * of ether at the current price.
     * Exceptional conditions:
     *     Price is stale. */
    function fiatValue(uint eth)
        public
        view
        priceNotStale
        returns (uint)
    {
        return safeMul(eth, etherPrice);
    }
    
    /* Return the current fiat value of the contract's balance. 
     * Exceptional conditions:
     *     Price is stale. */
    function fiatBalance()
        public
        view
        returns (uint)
    {
        // Price staleness check occurs inside the call to fiatValue.
        return fiatValue(this.balance);
    }
    
    /* Return the equivalent ether value of the given quantity
     * of fiat at the current price.
     * Exceptional conditions:
     *     Price is stale. */
    function etherValue(uint fiat)
        public
        view
        priceNotStale
        returns (uint)
    {
        return safeDiv(fiat, etherPrice);
    }

    /* Return the fee charged on a transfer of n nomins. */
    function transferFeeIncurred(uint n)
        public
        view
        returns (uint)
    {
        return safeMul(n, transferFee);
    }

    /* Issues n nomins into the pool available to be bought by users.
     * Must be accompanied by $n worth of ether.
     * Exceptional conditions:
     *     Not called by contract owner.
     *     Insufficient backing funds provided (less than $n worth of ether).
     *     Price is stale. */
    function issue(uint n)
        public
        onlyOwner
        payable
    {
        // Price staleness check occurs inside the call to fiatValue.
        // Safe additions are unnecessary here, as either the addition is checked on the following line
        // or the overflow would cause the requirement not to be satisfied.
        require(fiatValue(msg.value) + fiatBalance() >= safeMul(supply + n, collatRatioMinimum));
        supply = safeAdd(supply, n);
        pool = safeAdd(pool, n);
        Issuance(n, msg.value);
    }

    /* Burns n nomins from the pool.
     * Exceptional conditions:
     *     Not called by contract owner.
     *     There are fewer than n nomins in the pool.
     */
    function burn(uint n)
        public
        onlyOwner
    {
        // Require that there are enough nomins in the accessible pool to burn; and
        require(pool >= n);
        pool = safeSub(pool, n);
        supply = safeSub(supply, n);
        Burning(n);
    }

    /* Return the fee charged on a purchase or sale of n nomins. */
    function poolFeeIncurred(uint n)
        public
        view
        returns (uint)
    {
        return safeMul(n, poolFee);
    }

    /* Return the fiat cost (including fee) of purchasing n nomins */
    function purchaseCostFiat(uint n)
        public
        view
        returns (uint)
    {
        return safeAdd(n, poolFeeIncurred(n));
    }

    /* Return the ether cost (including fee) of purchasing n nomins.
     * Exceptional conditions:
     *     Price is stale. */
    function purchaseCostEther(uint n)
        public
        view
        returns (uint)
    {
        // Price staleness check occurs inside the call to etherValue.
        return etherValue(purchaseCostFiat(n));
    }

    /* Sends n nomins to the sender from the pool, in exchange for
     * $n plus the fee worth of ether.
     * Exceptional conditions:
     *     Insufficient or too many funds provided.
     *     More nomins requested than are in the pool.
     *     n below the purchase minimum (1 cent).
     *     contract in liquidation.
     *     Price is stale. */
    function buy(uint n)
        public
        notLiquidating
        payable
    {
        // Price staleness check occurs inside the call to purchaseEtherCost.
        require(n >= purchaseMininum &&
                msg.value == purchaseCostEther(n));
        // sub requires that pool >= n
        pool = safeSub(pool, n);
        balances[msg.sender] = safeAdd(balances[msg.sender], n);
        Purchase(msg.sender, n, msg.value);
    }
    
    /* Return the fiat proceeds (less the fee) of selling n nomins.*/
    function saleProceedsFiat(uint n)
        public
        view
        returns (uint)
    {
        return safeSub(n, poolFeeIncurred(n));
    }

    /* Return the ether proceeds (less the fee) of selling n
     * nomins.
     * Exceptional conditions:
     *     Price is stale. */
    function saleProceedsEther(uint n)
        public
        view
        returns (uint)
    {
        // Price staleness check occurs inside the call to etherValue.
        return etherValue(saleProceedsFiat(n));
    }

    /* Sends n nomins to the pool from the sender, in exchange for
     * $n minus the fee worth of ether.
     * Exceptional conditions:
     *     Insufficient nomins in sender's wallet.
     *     Insufficient funds in the pool to pay sender.
     *     Price is stale. */
    function sell(uint n)
        public
    {
        uint proceeds = saleProceedsFiat(n);
        // Price staleness check occurs inside the call to fiatBalance
        require(fiatBalance() >= proceeds);
        // sub requires that the balance is greater than n
        balances[msg.sender] = safeSub(balances[msg.sender], n);
        pool = safeAdd(pool, n);
        msg.sender.transfer(proceeds);
        Sale(msg.sender, n, proceeds);
    }

    /* Update the current ether price and update the last updated time,
     * refreshing the price staleness.
     * Exceptional conditions:
     *     Not called by the oracle. */
    function setPrice(uint price)
        public
        onlyOracle
    {
        etherPrice = price;
        lastPriceUpdate = now;
        PriceUpdate(price);
    }

    /* Update the period after which the price will be considered stale.
     * Exceptional conditions:
     *     Not called by the owner. */
    function setStalePeriod(uint period)
        public
        onlyOwner
    {
        stalePeriod = period;
        StalePeriodUpdate(period);
    }

    /* True iff the current block timestamp is later than the time
     * the price was last updated, plus the stale period. */
    function priceIsStale()
        public
        view
        returns (bool)
    {
        return lastPriceUpdate + stalePeriod < now;
    }

    /* Lock nomin purchase function in preparation for destroying the contract.
     * While the contract is under liquidation, users may sell nomins back to the system.
     * After liquidation period has terminated, the contract may be self-destructed,
     * returning all remaining ether to the beneficiary address.
     * Exceptional cases:
     *     Not called by contract owner;
     *     contract already in liquidation;
     */
    function liquidate()
        public
        onlyOwner
        notLiquidating
    {
        liquidationTimestamp = now;
        Liquidation();
    }

    /* Extend the liquidation period. It may only get longer,
     * not shorter, and it may not be extended past the liquidation max. */
    function extendLiquidationPeriod(uint extension)
        public
        onlyOwner
    {
        require(liquidationPeriod + extension <= maxLiquidationPeriod);
        liquidationPeriod += extension;
        LiquidationExtended(extension);
    }
    
    /* True iff the liquidation block is earlier than the current block.*/
    function isLiquidating()
        public
        view
        returns (bool)
    {
        return liquidationTimestamp <= now;
    }
    
    /* Destroy this contract, returning all funds back to the beneficiary
     * wallet, may only be called after the contract has been in
     * liquidation for at least liquidationPeriod.
     * Exceptional cases:
     *     Not called by contract owner.
     *     Contract is not in liquidation.
     *     Contract has not been in liquidation for at least liquidationPeriod.
     */
    function selfDestruct()
        public
        onlyOwner
    {
        require(isLiquidating() &&
                liquidationTimestamp + liquidationPeriod < now);
        SelfDestructed();
        selfdestruct(beneficiary);
    }

    /* New nomins were issued into the pool. */
    event Issuance(uint nominsIssued, uint collateralDeposited);

    /* Nomins in the pool were destroyed. */
    event Burning(uint nominsBurned);

    /* A purchase of nomins was made, and how much ether was provided to buy them. */
    event Purchase(address buyer, uint nomins, uint eth);

    /* A sale of nomins was made, and how much ether they were sold for. */
    event Sale(address seller, uint nomins, uint eth);

    /* setPrice() was called by the oracle to update the price. */
    event PriceUpdate(uint newPrice);

    /* setStalePeriod() was called by the owner. */
    event StalePeriodUpdate(uint newPeriod);

    /* Liquidation was initiated. */
    event Liquidation();

    /* Liquidation was extended. */
    event LiquidationExtended(uint extension);

    /* The contract has self-destructed. */
    event SelfDestructed();
}