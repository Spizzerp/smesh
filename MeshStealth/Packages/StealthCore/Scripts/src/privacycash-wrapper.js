/**
 * Privacy Cash SDK Wrapper for MeshStealth
 *
 * Wraps the privacycash SDK for use with Swift's JavaScriptCore bridge.
 *
 * SDK API:
 *   deposit({ lamports }) -> { tx }
 *   withdraw({ lamports, recipientAddress }) -> { tx, recipient, amount_in_lamports }
 *   getPrivateBalance() -> { lamports }
 *   depositSPL({ base_units, mintAddress }) -> { tx }
 *   withdrawSPL({ base_units, mintAddress, recipientAddress }) -> { tx, recipient, base_units }
 *   getPrivateBalanceSpl(mintAddress) -> { base_units, amount, lamports }
 */

import { PrivacyCash } from 'privacycash';
import { Keypair } from '@solana/web3.js';
import bs58 from 'bs58';

// Global instance holder
let pcInstance = null;
let isInitialized = false;

/**
 * Create a Keypair from various input formats
 * @param {string|number[]|Uint8Array} owner - Private key in various formats
 * @returns {Keypair}
 */
function parseOwner(owner) {
  if (typeof owner === 'string') {
    // Check if it's base58 encoded
    try {
      const decoded = bs58.decode(owner);
      return Keypair.fromSecretKey(decoded);
    } catch {
      // Maybe it's base64
      try {
        const decoded = Uint8Array.from(atob(owner), c => c.charCodeAt(0));
        return Keypair.fromSecretKey(decoded);
      } catch {
        throw new Error('Invalid owner format: expected base58 or base64 encoded private key');
      }
    }
  } else if (Array.isArray(owner)) {
    return Keypair.fromSecretKey(new Uint8Array(owner));
  } else if (owner instanceof Uint8Array) {
    return Keypair.fromSecretKey(owner);
  }
  throw new Error('Invalid owner format');
}

// Export the wrapper object for Swift bridge
const privacyCash = {
  _initialized: false,
  _config: null,
  _instance: null,

  /**
   * Initialize the Privacy Cash SDK
   * @param {Object} config - Configuration object
   * @param {string} config.rpcEndpoint - Solana RPC URL
   * @param {string} config.network - Network name (devnet/mainnet)
   * @param {string} [config.owner] - Private key (base58 or base64)
   * @returns {Object} { success: boolean, error?: string }
   */
  init: async function(config) {
    try {
      console.log('[PrivacyCash] Initializing with config:', JSON.stringify({
        ...config,
        owner: config.owner ? '[REDACTED]' : undefined
      }));

      // Validate required config
      if (!config.rpcEndpoint) {
        throw new Error('rpcEndpoint is required');
      }

      this._config = config;

      // If owner key provided, create instance
      if (config.owner) {
        const keypair = parseOwner(config.owner);

        this._instance = new PrivacyCash({
          RPC_url: config.rpcEndpoint,
          owner: keypair,
          enableDebug: config.debug || false
        });

        console.log('[PrivacyCash] SDK instance created with wallet:', keypair.publicKey.toString());
      } else {
        console.log('[PrivacyCash] SDK initialized without wallet (read-only mode)');
      }

      this._initialized = true;
      return { success: true };
    } catch (error) {
      console.error('[PrivacyCash] Initialization failed:', error.message);
      return { success: false, error: error.message };
    }
  },

  /**
   * Set the wallet/owner for transactions
   * @param {string} owner - Private key (base58 or base64)
   */
  setOwner: async function(owner) {
    if (!this._initialized) {
      throw new Error('PrivacyCash not initialized');
    }

    const keypair = parseOwner(owner);

    this._instance = new PrivacyCash({
      RPC_url: this._config.rpcEndpoint,
      owner: keypair,
      enableDebug: this._config.debug || false
    });

    console.log('[PrivacyCash] Wallet updated:', keypair.publicKey.toString());
    return { success: true, publicKey: keypair.publicKey.toString() };
  },

  /**
   * Deposit SOL into Privacy Cash pool
   * @param {Object} params - Deposit parameters
   * @param {number} params.amount - Amount in lamports
   * @returns {Object} { signature, commitment? }
   */
  deposit: async function(params) {
    if (!this._initialized || !this._instance) {
      throw new Error('PrivacyCash not initialized or no wallet set');
    }

    console.log('[PrivacyCash] Depositing:', params.amount, 'lamports');

    const result = await this._instance.deposit({
      lamports: params.amount
    });

    console.log('[PrivacyCash] Deposit result:', result);

    return {
      signature: result.tx,
      commitment: null // Privacy Cash doesn't return commitment
    };
  },

  /**
   * Deposit from a stealth address (using provided spending key)
   * @param {Object} params
   * @param {string} params.sourceAddress - Source address (unused, key determines address)
   * @param {number} params.amount - Amount in lamports
   * @param {string} params.spendingKey - Base64 encoded spending key
   */
  depositFrom: async function(params) {
    if (!this._initialized) {
      throw new Error('PrivacyCash not initialized');
    }

    console.log('[PrivacyCash] Depositing from stealth address:', params.amount, 'lamports');

    // Create a temporary instance with the spending key
    const keypair = parseOwner(params.spendingKey);

    const tempInstance = new PrivacyCash({
      RPC_url: this._config.rpcEndpoint,
      owner: keypair,
      enableDebug: this._config.debug || false
    });

    const result = await tempInstance.deposit({
      lamports: params.amount
    });

    return {
      signature: result.tx,
      commitment: null
    };
  },

  /**
   * Deposit SPL token into Privacy Cash pool
   * @param {Object} params
   * @param {number} params.amount - Amount in base units
   * @param {string} params.mint - Token mint address
   */
  depositSPL: async function(params) {
    if (!this._initialized || !this._instance) {
      throw new Error('PrivacyCash not initialized or no wallet set');
    }

    console.log('[PrivacyCash] Depositing SPL:', params.amount, 'base units of', params.mint);

    const result = await this._instance.depositSPL({
      base_units: params.amount,
      mintAddress: params.mint
    });

    return {
      signature: result.tx,
      commitment: null,
      mint: params.mint
    };
  },

  /**
   * Withdraw SOL from Privacy Cash pool
   * @param {Object} params
   * @param {number} params.amount - Amount in lamports
   * @param {string} params.recipientAddress - Destination address
   */
  withdraw: async function(params) {
    if (!this._initialized || !this._instance) {
      throw new Error('PrivacyCash not initialized or no wallet set');
    }

    console.log('[PrivacyCash] Withdrawing:', params.amount, 'lamports to', params.recipientAddress);

    const result = await this._instance.withdraw({
      lamports: params.amount,
      recipientAddress: params.recipientAddress
    });

    console.log('[PrivacyCash] Withdraw result:', result);

    return {
      signature: result.tx,
      destination: result.recipient,
      amount: result.amount_in_lamports,
      fee: result.fee_in_lamports,
      isPartial: result.isPartial
    };
  },

  /**
   * Withdraw SPL token from Privacy Cash pool
   * @param {Object} params
   * @param {number} params.amount - Amount in base units
   * @param {string} params.mint - Token mint address
   * @param {string} params.recipientAddress - Destination address
   */
  withdrawSPL: async function(params) {
    if (!this._initialized || !this._instance) {
      throw new Error('PrivacyCash not initialized or no wallet set');
    }

    console.log('[PrivacyCash] Withdrawing SPL:', params.amount, 'base units to', params.recipientAddress);

    const result = await this._instance.withdrawSPL({
      base_units: params.amount,
      mintAddress: params.mint,
      recipientAddress: params.recipientAddress
    });

    return {
      signature: result.tx,
      destination: result.recipient,
      amount: result.base_units,
      fee: result.fee_base_units,
      isPartial: result.isPartial,
      mint: params.mint
    };
  },

  /**
   * Transfer within privacy pool (internal)
   * Note: Privacy Cash doesn't have direct internal transfers
   * This is implemented as deposit + withdraw
   */
  transfer: async function(params) {
    console.log('[PrivacyCash] Internal transfer not directly supported');
    console.log('[PrivacyCash] Use deposit + withdraw for transfers');

    return {
      transactionId: null,
      success: false,
      error: 'Direct internal transfers not supported. Use deposit + withdraw.'
    };
  },

  /**
   * Get SOL balance in privacy pool
   */
  getPrivateBalance: async function(params) {
    if (!this._initialized || !this._instance) {
      throw new Error('PrivacyCash not initialized or no wallet set');
    }

    const result = await this._instance.getPrivateBalance();
    console.log('[PrivacyCash] Private balance:', result.lamports, 'lamports');

    return {
      balance: result.lamports
    };
  },

  /**
   * Get SPL token balance in privacy pool
   * @param {Object} params
   * @param {string} params.mint - Token mint address
   */
  getPrivateBalanceSPL: async function(params) {
    if (!this._initialized || !this._instance) {
      throw new Error('PrivacyCash not initialized or no wallet set');
    }

    const result = await this._instance.getPrivateBalanceSpl(params.mint);
    console.log('[PrivacyCash] Private SPL balance:', result.base_units, 'base units');

    return {
      balance: result.base_units,
      amount: result.amount,
      lamports: result.lamports
    };
  },

  /**
   * Clear the local UTXO cache
   */
  clearCache: async function() {
    if (this._instance) {
      await this._instance.clearCache();
    }
    return { success: true };
  }
};

// Export for different module systems
if (typeof window !== 'undefined') {
  window.privacyCash = privacyCash;
}
if (typeof globalThis !== 'undefined') {
  globalThis.privacyCash = privacyCash;
}

export { privacyCash };
export default privacyCash;
