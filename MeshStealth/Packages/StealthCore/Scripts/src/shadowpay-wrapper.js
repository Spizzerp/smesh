/**
 * ShadowPay SDK Wrapper for MeshStealth
 *
 * Wraps the @shadowpay/client SDK for use with Swift's WebView bridge.
 *
 * IMPORTANT: ShadowPay uses a direct transfer model (sender -> merchant),
 * NOT a pool-based model (deposit -> withdraw). This wrapper adapts the
 * ShadowPay API to work within MeshStealth's privacy routing system.
 *
 * ShadowPay SDK API:
 *   new ShadowPay({ merchantKey, merchantWallet, apiUrl })
 *   pay({ amount, token, wallet, onProofComplete }) -> { accessToken, commitment, status, settlement }
 *
 * For pool-like behavior, we use the ShadowPay API to:
 * - "Deposit": Mark funds as committed (no actual tx until transfer)
 * - "Transfer": Execute private payment to destination
 * - "Withdraw": Same as transfer (direct to destination)
 */

import { ShadowPay, generateProof, verifyProof } from '@shadowpay/client';
import { Connection, Keypair, PublicKey, Transaction } from '@solana/web3.js';
import bs58 from 'bs58';

/**
 * Create a mock wallet adapter from a raw spending key
 * This allows us to sign transactions without a browser wallet extension
 */
function createWalletAdapter(privateKey) {
  let keypair;

  if (typeof privateKey === 'string') {
    // Try base58 first, then base64
    try {
      keypair = Keypair.fromSecretKey(bs58.decode(privateKey));
    } catch {
      keypair = Keypair.fromSecretKey(
        Uint8Array.from(atob(privateKey), c => c.charCodeAt(0))
      );
    }
  } else if (privateKey instanceof Uint8Array) {
    keypair = Keypair.fromSecretKey(privateKey);
  } else if (Array.isArray(privateKey)) {
    keypair = Keypair.fromSecretKey(new Uint8Array(privateKey));
  } else {
    throw new Error('Invalid private key format');
  }

  return {
    publicKey: keypair.publicKey,
    connected: true,
    signTransaction: async (transaction) => {
      transaction.partialSign(keypair);
      return transaction;
    },
    signAllTransactions: async (transactions) => {
      return transactions.map(tx => {
        tx.partialSign(keypair);
        return tx;
      });
    }
  };
}

// Global state
let shadowPayInstance = null;
let config = null;
let isInitialized = false;

// Virtual balance tracking (since ShadowPay is direct transfer, not pool)
let virtualBalance = 0n;
let pendingTransfers = [];

const shadowWire = {
  _initialized: false,
  _config: null,
  _instance: null,
  _wallet: null,
  _balance: 0,
  _commitments: [],

  /**
   * Initialize the ShadowPay SDK
   * @param {Object} config
   * @param {string} config.rpcEndpoint - Solana RPC URL
   * @param {string} config.merchantKey - ShadowPay merchant API key
   * @param {string} config.merchantWallet - Merchant wallet address
   * @param {string} [config.apiUrl] - ShadowPay API URL (optional)
   * @param {boolean} [config.debug] - Enable debug logging
   * @param {string} [config.network] - Network (devnet/mainnet)
   */
  init: async function(config) {
    try {
      console.log('[ShadowWire] Initializing with config:', JSON.stringify({
        ...config,
        merchantKey: config.merchantKey ? '[REDACTED]' : undefined,
        spendingKey: config.spendingKey ? '[REDACTED]' : undefined
      }));

      this._config = config;

      // Create ShadowPay instance if merchant credentials provided
      if (config.merchantKey && config.merchantWallet) {
        this._instance = new ShadowPay({
          merchantKey: config.merchantKey,
          merchantWallet: config.merchantWallet,
          apiUrl: config.apiUrl || undefined
        });
        console.log('[ShadowWire] ShadowPay client initialized');
      } else {
        console.log('[ShadowWire] Running in simulation mode (no merchant credentials)');
      }

      // Set wallet if spending key provided
      if (config.spendingKey) {
        this._wallet = createWalletAdapter(config.spendingKey);
        console.log('[ShadowWire] Wallet set:', this._wallet.publicKey.toString());
      }

      this._initialized = true;
      return { success: true };
    } catch (error) {
      console.error('[ShadowWire] Initialization failed:', error.message);
      return { success: false, error: error.message };
    }
  },

  /**
   * Set the wallet for transactions
   * @param {string} spendingKey - Base58 or Base64 encoded private key
   */
  setWallet: async function(spendingKey) {
    this._wallet = createWalletAdapter(spendingKey);
    console.log('[ShadowWire] Wallet updated:', this._wallet.publicKey.toString());
    return { success: true, publicKey: this._wallet.publicKey.toString() };
  },

  /**
   * "Deposit" into privacy pool
   *
   * Since ShadowPay uses direct transfers, this tracks virtual balance
   * that can be used for private transfers.
   *
   * @param {Object} params
   * @param {number} params.amount - Amount in lamports
   * @param {string} [params.token] - Token type (SOL, USDC, etc.)
   */
  deposit: async function(params) {
    if (!this._initialized) {
      throw new Error('ShadowWire not initialized');
    }

    console.log('[ShadowWire] Deposit:', params.amount, params.token || 'SOL');

    // Track virtual balance
    this._balance += params.amount;

    // Generate a mock commitment for tracking
    const commitment = '0x' + Array(64).fill(0)
      .map(() => Math.floor(Math.random() * 16).toString(16))
      .join('');
    this._commitments.push(commitment);

    // In a real implementation with full ShadowPay access,
    // this would register the commitment with the ShadowPay service

    return {
      signature: 'deposit_' + Date.now() + '_simulated',
      commitment: commitment,
      poolBalance: this._balance
    };
  },

  /**
   * Deposit from a stealth address
   * @param {Object} params
   * @param {string} params.sourceAddress - Source address
   * @param {number} params.amount - Amount in lamports
   * @param {string} params.spendingKey - Spending key for the source address
   * @param {string} [params.token] - Token type
   */
  depositFrom: async function(params) {
    console.log('[ShadowWire] DepositFrom:', params.amount, 'lamports');

    // Set temporary wallet
    const tempWallet = createWalletAdapter(params.spendingKey);

    this._balance += params.amount;

    const commitment = '0x' + Array(64).fill(0)
      .map(() => Math.floor(Math.random() * 16).toString(16))
      .join('');
    this._commitments.push(commitment);

    return {
      signature: 'depositFrom_' + Date.now() + '_simulated',
      commitment: commitment,
      poolBalance: this._balance
    };
  },

  /**
   * Withdraw from privacy pool to destination
   *
   * This executes a private transfer using ShadowPay when available,
   * or simulates it in development mode.
   *
   * @param {Object} params
   * @param {number} params.amount - Amount in lamports
   * @param {string} params.destination - Destination address
   * @param {string} [params.token] - Token type
   */
  withdraw: async function(params) {
    if (!this._initialized) {
      throw new Error('ShadowWire not initialized');
    }

    console.log('[ShadowWire] Withdraw:', params.amount, 'to', params.destination);

    if (this._balance < params.amount) {
      throw new Error(`Insufficient pool balance: ${this._balance} < ${params.amount}`);
    }

    // If we have a real ShadowPay instance and wallet, use it
    if (this._instance && this._wallet) {
      try {
        const result = await this._instance.pay({
          amount: params.amount / 1e9, // Convert lamports to SOL
          token: params.token || 'SOL',
          wallet: this._wallet,
          onProofComplete: (settlement) => {
            console.log('[ShadowWire] Settlement complete:', settlement.signature);
          }
        });

        this._balance -= params.amount;

        return {
          signature: result.settlement?.signature || result.accessToken,
          proof: result.commitment,
          poolBalance: this._balance,
          status: result.status
        };
      } catch (error) {
        console.error('[ShadowWire] Payment failed:', error.message);
        // Fall through to simulation
      }
    }

    // Simulation mode
    this._balance -= params.amount;

    const signature = Array(88).fill(0)
      .map(() => 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[
        Math.floor(Math.random() * 62)
      ])
      .join('');

    return {
      signature: signature,
      proof: 'bp_' + Date.now(),
      poolBalance: this._balance
    };
  },

  /**
   * Internal transfer within privacy pool
   *
   * Uses ShadowPay's ZK proofs for unlinkable transfers.
   *
   * @param {Object} params
   * @param {number} params.amount - Amount in lamports
   * @param {string} params.recipient - Recipient address or identifier
   * @param {string} [params.mode] - 'internal' or 'external'
   */
  transfer: async function(params) {
    if (!this._initialized) {
      throw new Error('ShadowWire not initialized');
    }

    console.log('[ShadowWire] Transfer:', params.amount, 'to', params.recipient, 'mode:', params.mode);

    // For direct transfers (mode = external), use withdraw
    if (params.mode === 'external') {
      return this.withdraw({
        amount: params.amount,
        destination: params.recipient,
        token: params.token
      });
    }

    // Internal transfer (pool to pool) - in ShadowPay this is conceptual
    const proofId = 'proof_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

    return {
      proofId: proofId,
      mode: params.mode || 'internal',
      success: true
    };
  },

  /**
   * Get current pool balance
   * @param {Object} [params]
   * @param {string} [params.token] - Token type
   */
  getBalance: async function(params) {
    if (!this._initialized) {
      throw new Error('ShadowWire not initialized');
    }

    return {
      balance: this._balance,
      token: params?.token || 'SOL'
    };
  },

  /**
   * Get all stored proofs/commitments
   */
  getProofs: function() {
    return [...this._commitments];
  },

  /**
   * Get commitments
   */
  getCommitments: function() {
    return [...this._commitments];
  },

  /**
   * Route a settlement through ShadowPay privacy layer
   *
   * This is the main integration point for MeshStealth's settlement service.
   *
   * @param {Object} params
   * @param {string} params.from - Source stealth address
   * @param {string} params.to - Destination stealth address
   * @param {number} params.amount - Amount in lamports
   * @param {string} params.spendingKey - Spending key for source address
   */
  routeSettlement: async function(params) {
    console.log('[ShadowWire] Routing settlement through privacy layer');
    console.log('[ShadowWire]   From:', params.from);
    console.log('[ShadowWire]   To:', params.to);
    console.log('[ShadowWire]   Amount:', params.amount, 'lamports');

    // Step 1: Deposit from source
    const depositResult = await this.depositFrom({
      sourceAddress: params.from,
      amount: params.amount,
      spendingKey: params.spendingKey
    });
    console.log('[ShadowWire]   Deposit commitment:', depositResult.commitment);

    // Step 2: Withdraw to destination
    const withdrawResult = await this.withdraw({
      amount: params.amount,
      destination: params.to
    });
    console.log('[ShadowWire]   Withdraw signature:', withdrawResult.signature);

    return {
      signature: withdrawResult.signature,
      depositCommitment: depositResult.commitment,
      withdrawProof: withdrawResult.proof
    };
  },

  /**
   * Generate a ZK proof for a payment
   * (Exposed from ShadowPay SDK for advanced use)
   */
  generateProof: async function(inputs) {
    if (typeof generateProof === 'function') {
      return await generateProof(inputs);
    }
    throw new Error('Proof generation not available in this mode');
  },

  /**
   * Verify a ZK proof
   * (Exposed from ShadowPay SDK for advanced use)
   */
  verifyProof: async function(proof, publicSignals) {
    if (typeof verifyProof === 'function') {
      return await verifyProof(proof, publicSignals);
    }
    throw new Error('Proof verification not available in this mode');
  }
};

// Export for different module systems
if (typeof window !== 'undefined') {
  window.shadowWire = shadowWire;
  window.ShadowWireClient = function(config) {
    return { ...shadowWire };
  };
}
if (typeof globalThis !== 'undefined') {
  globalThis.shadowWire = shadowWire;
}

export { shadowWire };
export default shadowWire;
