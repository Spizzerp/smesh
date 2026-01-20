/**
 * Privacy Cash SDK Bundle Script
 *
 * Bundles the Privacy Cash SDK wrapper for use in iOS WebView/JSContext
 *
 * Note: The Privacy Cash SDK has Node.js dependencies (fs, path, node-localstorage).
 * We create a browser-compatible bundle by:
 * 1. Shimming fs/path with empty modules (storage handled via localforage)
 * 2. Using localforage instead of node-localstorage
 * 3. Polyfilling crypto/buffer/stream
 */

import * as esbuild from 'esbuild';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const outfile = path.resolve(__dirname, '../Sources/StealthCore/Privacy/Resources/privacycash-bundle.js');

// Ensure output directory exists
const outDir = path.dirname(outfile);
if (!fs.existsSync(outDir)) {
  fs.mkdirSync(outDir, { recursive: true });
}

// Create shim files for Node.js modules
const shimsDir = path.resolve(__dirname, 'shims');
if (!fs.existsSync(shimsDir)) {
  fs.mkdirSync(shimsDir, { recursive: true });
}

// Empty fs shim
fs.writeFileSync(path.resolve(shimsDir, 'fs.js'), `
// Browser shim for fs module
export default {};
export const readFileSync = () => '';
export const writeFileSync = () => {};
export const existsSync = () => false;
export const mkdirSync = () => {};
export const readdirSync = () => [];
export const statSync = () => ({ isDirectory: () => false, isFile: () => false, size: 0 });
export const unlinkSync = () => {};
export const rmdirSync = () => {};
export const promises = {
  readFile: async () => '',
  writeFile: async () => {},
  mkdir: async () => {},
  readdir: async () => [],
  stat: async () => ({ isDirectory: () => false }),
  unlink: async () => {},
  rmdir: async () => {}
};
`);

// Path shim using path-browserify
fs.writeFileSync(path.resolve(shimsDir, 'path.js'), `
export { default } from 'path-browserify';
export * from 'path-browserify';
`);

// node:path shim
fs.writeFileSync(path.resolve(shimsDir, 'node-path.js'), `
export { default } from 'path-browserify';
export * from 'path-browserify';
`);

// LocalStorage shim using in-memory storage
fs.writeFileSync(path.resolve(shimsDir, 'node-localstorage.js'), `
// In-memory localStorage shim for browser/JSContext
class LocalStorage {
  constructor() {
    this._data = {};
  }
  getItem(key) { return this._data[key] || null; }
  setItem(key, value) { this._data[key] = String(value); }
  removeItem(key) { delete this._data[key]; }
  clear() { this._data = {}; }
  key(n) { return Object.keys(this._data)[n] || null; }
  get length() { return Object.keys(this._data).length; }
}
export { LocalStorage };
export default { LocalStorage };
`);

console.log('[Privacy Cash Bundler] Starting bundle...');
console.log('[Privacy Cash Bundler] Entry: src/privacycash-wrapper.js');
console.log('[Privacy Cash Bundler] Output:', outfile);

try {
  const result = await esbuild.build({
    entryPoints: [path.resolve(__dirname, 'src/privacycash-wrapper.js')],
    bundle: true,
    outfile: outfile,
    format: 'iife',
    globalName: 'PrivacyCashBundle',
    platform: 'browser',
    target: ['es2020'],
    minify: false, // Keep readable for debugging
    sourcemap: false,
    // Define globals for browser environment
    define: {
      'process.env.NODE_ENV': '"production"',
      'global': 'globalThis',
      'process.browser': 'true',
    },
    // Handle Node.js built-ins with shims
    alias: {
      'fs': path.resolve(shimsDir, 'fs.js'),
      'path': 'path-browserify',
      'node:path': path.resolve(shimsDir, 'node-path.js'),
      'node-localstorage': path.resolve(shimsDir, 'node-localstorage.js'),
      'crypto': 'crypto-browserify',
      'stream': 'stream-browserify',
      'buffer': 'buffer',
    },
    // Inject Buffer and process globals
    inject: [],
    // Log level
    logLevel: 'info',
    // Handle dynamic requires
    packages: 'bundle',
    // Banner with metadata
    banner: {
      js: `/**
 * Privacy Cash SDK Bundle for MeshStealth
 * Generated: ${new Date().toISOString()}
 *
 * This bundle wraps the privacycash SDK (v1.1.10) for use with
 * Swift's JavaScriptCore bridge.
 *
 * Usage:
 *   privacyCash.init({ rpcEndpoint, network, owner })
 *   privacyCash.deposit({ amount })
 *   privacyCash.withdraw({ amount, recipientAddress })
 *   privacyCash.getPrivateBalance()
 *
 * Prize Target: $6,000 (Privacy Cash track)
 */
`
    },
    // Footer to ensure global export
    footer: {
      js: `
// Ensure global export for JavaScriptCore
if (typeof globalThis !== 'undefined' && typeof PrivacyCashBundle !== 'undefined') {
  globalThis.privacyCash = PrivacyCashBundle.privacyCash || PrivacyCashBundle.default || PrivacyCashBundle;
}
if (typeof window !== 'undefined' && typeof PrivacyCashBundle !== 'undefined') {
  window.privacyCash = PrivacyCashBundle.privacyCash || PrivacyCashBundle.default || PrivacyCashBundle;
}
if (typeof this !== 'undefined' && typeof PrivacyCashBundle !== 'undefined') {
  this.privacyCash = PrivacyCashBundle.privacyCash || PrivacyCashBundle.default || PrivacyCashBundle;
}
console.log('[PrivacyCash] SDK bundle loaded');
`
    }
  });

  console.log('[Privacy Cash Bundler] Bundle complete!');
  console.log('[Privacy Cash Bundler] Output size:', fs.statSync(outfile).size, 'bytes');

  if (result.warnings.length > 0) {
    console.log('[Privacy Cash Bundler] Warnings:', result.warnings);
  }
} catch (error) {
  console.error('[Privacy Cash Bundler] Build failed:', error);
  process.exit(1);
}
