const IContract = require("./IContract");

const feeModule = require("../interfaces").feeModule;

class FeeModuleContract extends IContract {
  constructor(params) {
    super({ abi: feeModule, ...params });
    this.contractName = "FeeModule";
  }

  /**
   * Set fee schedules for a market (100-element arrays, one per price-point bucket).
   * @param {object} params
   * @param {number|string} params.marketId
   * @param {number[]}      params.makerFeeBps  Array of 100 uint16 values (BPS)
   * @param {number[]}      params.takerFeeBps  Array of 100 uint16 values (BPS)
   */
  async setMarketFees({ marketId, makerFeeBps, takerFeeBps }) {
    return await this.__sendTx(this.getContract().methods.setMarketFees(marketId, makerFeeBps, takerFeeBps));
  }

  async matchOrdersWithFees({ maker, makerSig, taker, takerSig, fillAmount }) {
    return await this.__sendTx(this.getContract().methods.matchOrdersWithFees(maker, makerSig, taker, takerSig, fillAmount));
  }

  /**
   * Withdraw a specific amount of accrued fees for a token to the specified address.
   * Only callable by a fee-admin.
   * @param {string} token   ERC-20 collateral address
   * @param {string} to      Recipient wallet address
   * @param {string|number} amount  Amount to withdraw (smallest unit)
   */
  async withdrawFees(token, to, amount) {
    return await this.__sendTx(this.getContract().methods.withdrawFees(token, to, amount));
  }

  /**
   * Read total accrued (unclaimed) fees for a token.
   * @param {string} token  ERC-20 collateral address
   * @returns {Promise<string>} amount in smallest unit
   */
  async accruedFees(token) {
    return await this.getContract().methods.accruedFees(token).call();
  }

  /**
   * Get the full 100-element maker fee schedule for a market.
   * @param {number|string} marketId
   * @returns {Promise<number[]>} Array of 100 uint16 BPS values
   */
  async getMarketMakerFees(marketId) {
    return await this.getContract().methods.getMarketMakerFees(marketId).call();
  }

  /**
   * Get the full 100-element taker fee schedule for a market.
   * @param {number|string} marketId
   * @returns {Promise<number[]>} Array of 100 uint16 BPS values
   */
  async getMarketTakerFees(marketId) {
    return await this.getContract().methods.getMarketTakerFees(marketId).call();
  }

  /**
   * Get (makerBps, takerBps) for a specific price.
   * @param {number|string} marketId
   * @param {string} price  Price in 1e18 precision
   * @returns {Promise<{makerBps: number, takerBps: number}>}
   */
  async getFeesAtPrice(marketId, price) {
    return await this.getContract().methods.getFeesAtPrice(marketId, price).call();
  }
}

module.exports = FeeModuleContract;
