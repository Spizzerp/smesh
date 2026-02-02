import Foundation
import WebKit
import JavaScriptCore

// MARK: - WebView Bridge for JavaScript SDK Execution

/// Bridge for executing JavaScript SDKs that require WASM support
/// Used by ShadowWire for Bulletproof proof generation
@MainActor
public final class WebViewBridge: NSObject {

    // MARK: - Properties

    private var webView: WKWebView?
    private var isInitialized = false
    private var pendingCallbacks: [String: CheckedContinuation<JSResult, Error>] = [:]
    private var pageLoadContinuation: CheckedContinuation<Void, Never>?

    /// The bundled JavaScript to execute
    private let bundledJS: String

    /// Name of the global object exposed by the SDK
    private let globalObjectName: String

    /// Timeout for JavaScript operations
    private let operationTimeout: TimeInterval

    // MARK: - Types

    /// Result from JavaScript execution
    /// Note: Using @unchecked Sendable because [String: Any] contains non-Sendable Any,
    /// but we control the data flow and ensure safe crossing of actor boundaries
    public struct JSResult: @unchecked Sendable {
        public let success: Bool
        public let data: [String: Any]?
        public let error: String?

        public init(success: Bool, data: [String: Any]? = nil, error: String? = nil) {
            self.success = success
            self.data = data
            self.error = error
        }
    }

    // MARK: - Initialization

    /// Initialize the WebView bridge
    /// - Parameters:
    ///   - bundledJS: The JavaScript SDK bundle to load
    ///   - globalObjectName: Name of the global object (e.g., "shadowWire", "privacyCash")
    ///   - operationTimeout: Timeout for operations in seconds
    public init(bundledJS: String, globalObjectName: String, operationTimeout: TimeInterval = 60) {
        self.bundledJS = bundledJS
        self.globalObjectName = globalObjectName
        self.operationTimeout = operationTimeout
        super.init()
    }

    // MARK: - Lifecycle

    /// Initialize the WebView and load the SDK
    public func initialize() async throws {
        guard !isInitialized else { return }

        // Configure WebView
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Add message handler for callbacks
        let contentController = config.userContentController
        contentController.add(self, name: "nativeCallback")

        // Create WebView (hidden, just for JS execution)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        // Load blank page then inject SDK
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body>
            <script>
            // ============================================
            // Node.js Polyfills for WKWebView
            // Required by ShadowWire SDK (blake-hash, etc.)
            // ============================================

            // Buffer polyfill (comprehensive implementation)
            (function() {
                if (typeof Buffer !== 'undefined') return;

                function Buffer(arg, encodingOrOffset, length) {
                    if (typeof arg === 'number') {
                        return new Uint8Array(arg);
                    }
                    if (typeof arg === 'string') {
                        return Buffer.from(arg, encodingOrOffset);
                    }
                    if (ArrayBuffer.isView(arg) || arg instanceof ArrayBuffer) {
                        return new Uint8Array(arg);
                    }
                    if (Array.isArray(arg)) {
                        return new Uint8Array(arg);
                    }
                    return new Uint8Array(0);
                }

                Buffer.from = function(data, encoding) {
                    if (typeof data === 'string') {
                        encoding = encoding || 'utf8';
                        if (encoding === 'hex') {
                            var bytes = [];
                            for (var i = 0; i < data.length; i += 2) {
                                bytes.push(parseInt(data.substr(i, 2), 16));
                            }
                            return new Uint8Array(bytes);
                        } else if (encoding === 'base64') {
                            var binary = atob(data);
                            var bytes = new Uint8Array(binary.length);
                            for (var i = 0; i < binary.length; i++) {
                                bytes[i] = binary.charCodeAt(i);
                            }
                            return bytes;
                        } else {
                            // utf8
                            var encoder = new TextEncoder();
                            return encoder.encode(data);
                        }
                    }
                    if (ArrayBuffer.isView(data)) {
                        return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
                    }
                    if (data instanceof ArrayBuffer) {
                        return new Uint8Array(data);
                    }
                    if (Array.isArray(data)) {
                        return new Uint8Array(data);
                    }
                    return new Uint8Array(0);
                };

                Buffer.alloc = function(size, fill, encoding) {
                    var buf = new Uint8Array(size);
                    if (fill !== undefined) {
                        if (typeof fill === 'number') {
                            buf.fill(fill);
                        } else if (typeof fill === 'string') {
                            var fillBuf = Buffer.from(fill, encoding);
                            for (var i = 0; i < size; i++) {
                                buf[i] = fillBuf[i % fillBuf.length];
                            }
                        }
                    }
                    return buf;
                };

                Buffer.allocUnsafe = Buffer.alloc;
                Buffer.allocUnsafeSlow = Buffer.alloc;

                Buffer.isBuffer = function(obj) {
                    return obj instanceof Uint8Array;
                };

                Buffer.isEncoding = function(encoding) {
                    return ['utf8', 'utf-8', 'hex', 'base64', 'ascii', 'binary', 'latin1'].indexOf(encoding.toLowerCase()) !== -1;
                };

                Buffer.byteLength = function(string, encoding) {
                    if (typeof string !== 'string') {
                        return string.length || string.byteLength || 0;
                    }
                    return Buffer.from(string, encoding).length;
                };

                Buffer.concat = function(list, totalLength) {
                    if (!Array.isArray(list)) return new Uint8Array(0);
                    if (totalLength === undefined) {
                        totalLength = list.reduce(function(acc, buf) { return acc + buf.length; }, 0);
                    }
                    var result = new Uint8Array(totalLength);
                    var offset = 0;
                    for (var i = 0; i < list.length && offset < totalLength; i++) {
                        var buf = list[i];
                        result.set(buf.subarray(0, Math.min(buf.length, totalLength - offset)), offset);
                        offset += buf.length;
                    }
                    return result;
                };

                Buffer.compare = function(a, b) {
                    for (var i = 0; i < Math.min(a.length, b.length); i++) {
                        if (a[i] < b[i]) return -1;
                        if (a[i] > b[i]) return 1;
                    }
                    return a.length - b.length;
                };

                // Add instance methods to Uint8Array prototype for Buffer compatibility
                var proto = Uint8Array.prototype;

                if (!proto.toString || proto.toString === Object.prototype.toString) {
                    proto.toString = function(encoding) {
                        encoding = encoding || 'utf8';
                        if (encoding === 'hex') {
                            return Array.from(this).map(function(b) {
                                return b.toString(16).padStart(2, '0');
                            }).join('');
                        } else if (encoding === 'base64') {
                            var binary = '';
                            for (var i = 0; i < this.length; i++) {
                                binary += String.fromCharCode(this[i]);
                            }
                            return btoa(binary);
                        } else {
                            var decoder = new TextDecoder();
                            return decoder.decode(this);
                        }
                    };
                }

                if (!proto.write) {
                    proto.write = function(string, offset, length, encoding) {
                        offset = offset || 0;
                        var buf = Buffer.from(string, encoding);
                        length = length || buf.length;
                        for (var i = 0; i < length && offset + i < this.length; i++) {
                            this[offset + i] = buf[i];
                        }
                        return Math.min(length, buf.length);
                    };
                }

                if (!proto.copy) {
                    proto.copy = function(target, targetStart, sourceStart, sourceEnd) {
                        targetStart = targetStart || 0;
                        sourceStart = sourceStart || 0;
                        sourceEnd = sourceEnd || this.length;
                        for (var i = 0; i < sourceEnd - sourceStart; i++) {
                            target[targetStart + i] = this[sourceStart + i];
                        }
                        return sourceEnd - sourceStart;
                    };
                }

                if (!proto.equals) {
                    proto.equals = function(other) {
                        if (this.length !== other.length) return false;
                        for (var i = 0; i < this.length; i++) {
                            if (this[i] !== other[i]) return false;
                        }
                        return true;
                    };
                }

                if (!proto.readUInt32BE) {
                    proto.readUInt32BE = function(offset) {
                        return (this[offset] << 24) | (this[offset + 1] << 16) | (this[offset + 2] << 8) | this[offset + 3];
                    };
                }

                if (!proto.readUInt32LE) {
                    proto.readUInt32LE = function(offset) {
                        return this[offset] | (this[offset + 1] << 8) | (this[offset + 2] << 16) | (this[offset + 3] << 24);
                    };
                }

                if (!proto.writeUInt32BE) {
                    proto.writeUInt32BE = function(value, offset) {
                        this[offset] = (value >>> 24) & 0xff;
                        this[offset + 1] = (value >>> 16) & 0xff;
                        this[offset + 2] = (value >>> 8) & 0xff;
                        this[offset + 3] = value & 0xff;
                        return offset + 4;
                    };
                }

                if (!proto.writeUInt32LE) {
                    proto.writeUInt32LE = function(value, offset) {
                        this[offset] = value & 0xff;
                        this[offset + 1] = (value >>> 8) & 0xff;
                        this[offset + 2] = (value >>> 16) & 0xff;
                        this[offset + 3] = (value >>> 24) & 0xff;
                        return offset + 4;
                    };
                }

                window.Buffer = Buffer;
                console.log('[Polyfill] Buffer polyfill loaded');
            })();

            // Process polyfill
            if (typeof process === 'undefined') {
                window.process = {
                    env: { NODE_ENV: 'production' },
                    browser: true,
                    version: 'v18.0.0',
                    versions: { node: '18.0.0' },
                    platform: 'darwin',
                    nextTick: function(fn) { setTimeout(fn, 0); },
                    cwd: function() { return '/'; },
                    exit: function() {},
                    on: function() { return this; },
                    once: function() { return this; },
                    off: function() { return this; },
                    emit: function() { return false; }
                };
                console.log('[Polyfill] process polyfill loaded');
            }

            // Global polyfill
            if (typeof global === 'undefined') {
                window.global = window;
            }

            // ============================================
            // End of Polyfills
            // ============================================

            // Capture console.log and send to native for debugging
            (function() {
                var origLog = console.log;
                var origError = console.error;
                var origWarn = console.warn;

                function sendLog(level, args) {
                    try {
                        var msg = Array.prototype.slice.call(args).map(function(a) {
                            if (typeof a === 'object') {
                                try { return JSON.stringify(a); } catch(e) { return String(a); }
                            }
                            return String(a);
                        }).join(' ');
                        window.webkit.messageHandlers.nativeCallback.postMessage({
                            type: 'console',
                            level: level,
                            message: msg
                        });
                    } catch(e) {}
                    // Also call original
                    origLog.apply(console, args);
                }

                console.log = function() { sendLog('log', arguments); };
                console.error = function() { sendLog('error', arguments); };
                console.warn = function() { sendLog('warn', arguments); };
            })();

            // Native callback helper
            window.sendToNative = function(callbackId, success, data, error) {
                window.webkit.messageHandlers.nativeCallback.postMessage({
                    callbackId: callbackId,
                    success: success,
                    data: data,
                    error: error
                });
            };

            // Promise wrapper for native calls
            window.callNativeAsync = function(method, params) {
                return new Promise((resolve, reject) => {
                    const callbackId = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                    window._pendingCallbacks = window._pendingCallbacks || {};
                    window._pendingCallbacks[callbackId] = { resolve, reject };

                    // Execute method and handle result
                    try {
                        const result = method(params);
                        if (result && typeof result.then === 'function') {
                            result.then(data => {
                                window.sendToNative(callbackId, true, data, null);
                            }).catch(err => {
                                window.sendToNative(callbackId, false, null, err.message || String(err));
                            });
                        } else {
                            window.sendToNative(callbackId, true, result, null);
                        }
                    } catch (err) {
                        window.sendToNative(callbackId, false, null, err.message || String(err));
                    }
                });
            };

            console.log('[WebViewBridge] Native helpers initialized');
            </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)

        // Wait for page to actually load using continuation
        DebugLogger.log("[WebViewBridge] Waiting for page load...")
        await withCheckedContinuation { continuation in
            self.pageLoadContinuation = continuation
        }
        DebugLogger.log("[WebViewBridge] Page load confirmed, waiting for DOM ready...")

        // Additional wait for DOM to be fully ready
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        // Inject the SDK bundle
        try await injectSDK()

        isInitialized = true
        DebugLogger.log("[WebViewBridge] Initialized with \(globalObjectName)")
    }

    /// Inject the SDK JavaScript using script element injection
    /// This handles large bundles better than evaluateJavaScript
    private func injectSDK() async throws {
        guard let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        // For large bundles, use script element injection instead of evaluateJavaScript
        // This avoids hitting size limits on the evaluateJavaScript method
        let bundleSize = bundledJS.count
        DebugLogger.log("[WebViewBridge] Injecting SDK bundle (\(bundleSize) chars)")

        if bundleSize > 500_000 {
            // Large bundle - use chunked injection via script element
            DebugLogger.log("[WebViewBridge] Using chunked injection for large bundle")
            try await injectLargeBundle()
        } else {
            // Small bundle - direct evaluation is fine
            do {
                let result = try await webView.evaluateJavaScript(bundledJS)
                DebugLogger.log("[WebViewBridge] SDK injected, result: \(String(describing: result))")
            } catch {
                DebugLogger.log("[WebViewBridge] Direct injection failed: \(error)")
                // Fallback to chunked injection
                try await injectLargeBundle()
            }
        }
    }

    /// Inject a large bundle by encoding as base64 and decoding in JS
    private func injectLargeBundle() async throws {
        guard let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        // Encode the bundle as base64 to safely pass through
        guard let bundleData = bundledJS.data(using: .utf8) else {
            throw PrivacyProtocolError.sdkLoadFailed("Failed to encode bundle as UTF-8")
        }
        let base64Bundle = bundleData.base64EncodedString()

        // Split into chunks if needed (very large strings can still cause issues)
        let chunkSize = 500_000 // 500KB chunks
        var chunks: [String] = []
        var index = base64Bundle.startIndex

        while index < base64Bundle.endIndex {
            let endIndex = base64Bundle.index(index, offsetBy: chunkSize, limitedBy: base64Bundle.endIndex) ?? base64Bundle.endIndex
            chunks.append(String(base64Bundle[index..<endIndex]))
            index = endIndex
        }

        DebugLogger.log("[WebViewBridge] Injecting bundle in \(chunks.count) chunk(s)")

        // First, set up the accumulator
        _ = try? await webView.evaluateJavaScript("window._sdkChunks = [];")

        // Send each chunk
        for (i, chunk) in chunks.enumerated() {
            let addChunk = "window._sdkChunks.push('\(chunk)');"
            _ = try? await webView.evaluateJavaScript(addChunk)
            DebugLogger.log("[WebViewBridge] Sent chunk \(i + 1)/\(chunks.count)")
        }

        // Decode and execute with error wrapper
        let executeScript = """
        (function() {
            try {
                var base64 = window._sdkChunks.join('');
                var decoded = atob(base64);
                delete window._sdkChunks;

                console.log('[WebViewBridge] Decoded script length: ' + decoded.length + ' chars');

                // Verify polyfills are available
                console.log('[WebViewBridge] Checking polyfills before bundle execution:');
                console.log('[WebViewBridge]   typeof Buffer: ' + (typeof Buffer));
                console.log('[WebViewBridge]   typeof window.Buffer: ' + (typeof window.Buffer));
                console.log('[WebViewBridge]   typeof process: ' + (typeof process));
                console.log('[WebViewBridge]   typeof global: ' + (typeof global));

                // Define Buffer inline if missing - must be in same script context as bundle
                if (typeof Buffer === 'undefined') {
                    console.log('[WebViewBridge] Buffer missing, defining inline polyfill...');

                    // First define as a local variable, then assign to window
                    var Buffer = function(arg, enc) {
                        if (typeof arg === 'number') return new Uint8Array(arg);
                        if (typeof arg === 'string') return Buffer.from(arg, enc);
                        if (arg instanceof ArrayBuffer || ArrayBuffer.isView(arg)) return new Uint8Array(arg);
                        if (Array.isArray(arg)) return new Uint8Array(arg);
                        return new Uint8Array(0);
                    };

                    Buffer.from = function(data, enc) {
                        if (typeof data === 'string') {
                            enc = enc || 'utf8';
                            if (enc === 'hex') {
                                var b = [];
                                for (var i = 0; i < data.length; i += 2) b.push(parseInt(data.substr(i, 2), 16));
                                return new Uint8Array(b);
                            } else if (enc === 'base64') {
                                var bin = atob(data), arr = new Uint8Array(bin.length);
                                for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
                                return arr;
                            } else {
                                return new TextEncoder().encode(data);
                            }
                        }
                        if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
                        if (data instanceof ArrayBuffer) return new Uint8Array(data);
                        if (Array.isArray(data)) return new Uint8Array(data);
                        return new Uint8Array(0);
                    };

                    Buffer.alloc = function(size, fill) {
                        var buf = new Uint8Array(size);
                        if (typeof fill === 'number') buf.fill(fill);
                        return buf;
                    };
                    Buffer.allocUnsafe = Buffer.alloc;
                    Buffer.allocUnsafeSlow = Buffer.alloc;
                    Buffer.isBuffer = function(obj) { return obj instanceof Uint8Array; };
                    Buffer.isEncoding = function(e) { return ['utf8','utf-8','hex','base64','ascii'].indexOf((e||'').toLowerCase()) !== -1; };
                    Buffer.byteLength = function(s, e) { return typeof s === 'string' ? Buffer.from(s, e).length : (s.length || s.byteLength || 0); };
                    Buffer.concat = function(list, len) {
                        if (!Array.isArray(list)) return new Uint8Array(0);
                        len = len === undefined ? list.reduce(function(a,b){return a+b.length;},0) : len;
                        var r = new Uint8Array(len), o = 0;
                        for (var i = 0; i < list.length && o < len; i++) {
                            r.set(list[i].subarray(0, Math.min(list[i].length, len-o)), o);
                            o += list[i].length;
                        }
                        return r;
                    };
                    Buffer.compare = function(a,b) {
                        for (var i = 0; i < Math.min(a.length, b.length); i++) {
                            if (a[i] < b[i]) return -1;
                            if (a[i] > b[i]) return 1;
                        }
                        return a.length - b.length;
                    };

                    // Add methods to Uint8Array prototype
                    var p = Uint8Array.prototype;
                    if (!p.readUInt32BE) p.readUInt32BE = function(o) { return (this[o]<<24)|(this[o+1]<<16)|(this[o+2]<<8)|this[o+3]; };
                    if (!p.readUInt32LE) p.readUInt32LE = function(o) { return this[o]|(this[o+1]<<8)|(this[o+2]<<16)|(this[o+3]<<24); };
                    if (!p.writeUInt32BE) p.writeUInt32BE = function(v,o) { this[o]=(v>>>24)&0xff; this[o+1]=(v>>>16)&0xff; this[o+2]=(v>>>8)&0xff; this[o+3]=v&0xff; return o+4; };
                    if (!p.writeUInt32LE) p.writeUInt32LE = function(v,o) { this[o]=v&0xff; this[o+1]=(v>>>8)&0xff; this[o+2]=(v>>>16)&0xff; this[o+3]=(v>>>24)&0xff; return o+4; };
                    if (!p.copy) p.copy = function(t,ts,ss,se) { ts=ts||0; ss=ss||0; se=se||this.length; for(var i=0;i<se-ss;i++) t[ts+i]=this[ss+i]; return se-ss; };
                    if (!p.equals) p.equals = function(o) { if(this.length!==o.length)return false; for(var i=0;i<this.length;i++)if(this[i]!==o[i])return false; return true; };
                    if (!p.slice) p.slice = function(s,e) { return this.subarray(s,e); };
                    if (!p.fill) p.fill = function(v,s,e) { s=s||0; e=e||this.length; for(var i=s;i<e;i++) this[i]=v; return this; };

                    // Make available globally - CRITICAL: must set window.Buffer so script element can see it
                    window.Buffer = Buffer;
                    if (typeof globalThis !== 'undefined') globalThis.Buffer = Buffer;
                    if (typeof global !== 'undefined') global.Buffer = Buffer;

                    console.log('[WebViewBridge] Buffer polyfill defined, typeof Buffer: ' + (typeof Buffer) + ', typeof window.Buffer: ' + (typeof window.Buffer));
                }

                // Also ensure process is defined
                if (typeof process === 'undefined') {
                    window.process = { env: { NODE_ENV: 'production' }, browser: true, version: 'v18.0.0' };
                    if (typeof globalThis !== 'undefined') globalThis.process = window.process;
                }
                if (typeof global === 'undefined') {
                    window.global = window;
                    if (typeof globalThis !== 'undefined') globalThis.global = window;
                }

                console.log('[WebViewBridge] After inline polyfill - typeof Buffer: ' + (typeof Buffer));

                // Wrap the entire bundle in try-catch for better error capture
                // This modification happens before injection
                var wrappedScript = 'try {\\n' + decoded + '\\n} catch(_bundleErr) { window._bundleLoadError = _bundleErr; console.log("[Bundle] Error: " + _bundleErr.message); console.log("[Bundle] Stack: " + (_bundleErr.stack || "").substring(0, 500)); }';

                console.log('[WebViewBridge] About to inject wrapped script');

                // Create and inject the script element
                var script = document.createElement('script');
                script.type = 'text/javascript';
                script.text = wrappedScript;
                document.head.appendChild(script);

                console.log('[WebViewBridge] Script element added to DOM');

                // Check for bundle load error
                if (window._bundleLoadError) {
                    var err = window._bundleLoadError;
                    console.log('[WebViewBridge] Bundle load error: ' + err.message);
                    console.log('[WebViewBridge] Error name: ' + err.name);
                    if (err.stack) {
                        console.log('[WebViewBridge] Stack trace:');
                        // Log stack in chunks for better readability
                        var stack = err.stack.substring(0, 800);
                        var lines = stack.split('\\n');
                        for (var i = 0; i < Math.min(lines.length, 10); i++) {
                            console.log('[WebViewBridge]   ' + lines[i]);
                        }
                    }
                    return { success: false, error: err.message };
                }

                // Check what was defined
                console.log('[WebViewBridge] After script execution:');
                console.log('[WebViewBridge]   typeof ShadowWireBundle: ' + (typeof ShadowWireBundle));
                console.log('[WebViewBridge]   typeof PrivacyCashBundle: ' + (typeof PrivacyCashBundle));
                console.log('[WebViewBridge]   typeof window.shadowWire: ' + (typeof window.shadowWire));
                console.log('[WebViewBridge]   typeof window.privacyCash: ' + (typeof window.privacyCash));

                // If ShadowWireBundle exists but shadowWire doesn't, try to extract
                if (typeof ShadowWireBundle !== 'undefined' && typeof window.shadowWire === 'undefined') {
                    console.log('[WebViewBridge] Attempting extraction from ShadowWireBundle...');
                    try {
                        var keys = Object.keys(ShadowWireBundle || {}).slice(0, 10);
                        console.log('[WebViewBridge] ShadowWireBundle keys: ' + keys.join(', '));

                        var sw = ShadowWireBundle.shadowWire || ShadowWireBundle.default || ShadowWireBundle;
                        if (sw && typeof sw.init === 'function') {
                            window.shadowWire = sw;
                            console.log('[WebViewBridge] Extracted shadowWire successfully');
                        } else {
                            console.log('[WebViewBridge] No init function found in extracted object');
                        }
                    } catch (extractErr) {
                        console.log('[WebViewBridge] Extraction error: ' + extractErr.message);
                    }
                }

                return { success: (typeof window.shadowWire !== 'undefined' || typeof window.privacyCash !== 'undefined') };
            } catch (e) {
                console.log('[WebViewBridge] Outer error: ' + e.message);
                return { success: false, error: e.message };
            }
        })();
        """

        do {
            let result = try await webView.evaluateJavaScript(executeScript)
            DebugLogger.log("[WebViewBridge] Large bundle execution result: \(String(describing: result))")
        } catch {
            DebugLogger.log("[WebViewBridge] Large bundle execution failed: \(error)")
            throw PrivacyProtocolError.sdkLoadFailed("Failed to inject large bundle: \(error.localizedDescription)")
        }

        // Give it time to execute - bundle footer code needs time to run
        // ShadowWire bundle has async initialization that needs extra time
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s (increased for async init)

        // Verify and ensure the global object is set
        let verifyScript = """
        (function() {
            try {
                var debug = [];
                var target = '\(globalObjectName)';
                debug.push('target: ' + target);

                // Check what globals are defined (safely)
                var hasSWB = (typeof ShadowWireBundle !== 'undefined');
                var hasPCB = (typeof PrivacyCashBundle !== 'undefined');
                var hasSW = (typeof window.shadowWire !== 'undefined');
                var hasPC = (typeof window.privacyCash !== 'undefined');

                debug.push('ShadowWireBundle=' + hasSWB);
                debug.push('PrivacyCashBundle=' + hasPCB);
                debug.push('window.shadowWire=' + hasSW);
                debug.push('window.privacyCash=' + hasPC);

                // Check if our target is already set
                var targetObj = window[target];
                debug.push('window.' + target + '=' + (typeof targetObj));

                // If not set, try to extract from bundles
                if (typeof targetObj === 'undefined') {
                    debug.push('extracting...');

                    if (target === 'shadowWire' && hasSWB) {
                        // The bundle's IIFE should have already set window.shadowWire
                        // If not, try to get it from the bundle object
                        if (typeof ShadowWireBundle === 'object') {
                            var keys = [];
                            try { keys = Object.keys(ShadowWireBundle).slice(0, 5); } catch(e) {}
                            debug.push('SWB.keys=' + keys.join(','));
                        }

                        // Look for shadowWire inside ShadowWireBundle
                        var sw = ShadowWireBundle.shadowWire || ShadowWireBundle.default || ShadowWireBundle;
                        if (sw && typeof sw.init === 'function') {
                            window.shadowWire = sw;
                            targetObj = sw;
                            debug.push('extracted from ShadowWireBundle');
                        }
                    }

                    if (target === 'privacyCash' && hasPCB) {
                        var pc = PrivacyCashBundle.privacyCash || PrivacyCashBundle.default || PrivacyCashBundle;
                        if (pc && typeof pc.init === 'function') {
                            window.privacyCash = pc;
                            targetObj = pc;
                            debug.push('extracted from PrivacyCashBundle');
                        }
                    }
                }

                // Final check
                var available = (typeof targetObj !== 'undefined' && typeof targetObj.init === 'function');
                debug.push('available=' + available);

                // If available, list the methods
                if (available && targetObj) {
                    var methods = [];
                    try {
                        for (var k in targetObj) {
                            if (typeof targetObj[k] === 'function') methods.push(k);
                        }
                        debug.push('methods=' + methods.slice(0, 8).join(','));
                    } catch(e) {}
                }

                return { available: available ? 1 : 0, debug: debug.join(' | ') };
            } catch (e) {
                return { available: 0, error: e.message, debug: 'exception: ' + e.message };
            }
        })();
        """

        do {
            let verifyResult = try await webView.evaluateJavaScript(verifyScript)
            DebugLogger.log("[WebViewBridge] Verification result: \(String(describing: verifyResult))")

            // Parse verification result and log debug info
            if let dict = verifyResult as? [String: Any] {
                if let debugInfo = dict["debug"] as? String {
                    DebugLogger.log("[WebViewBridge] Debug: \(debugInfo)")
                }
                if let error = dict["error"] as? String {
                    DebugLogger.log("[WebViewBridge] JS Error: \(error)")
                }
                let available = (dict["available"] as? Int) == 1
                if !available {
                    DebugLogger.log("[WebViewBridge] WARNING: Global object \(globalObjectName) not available after verification")
                }
            }
        } catch {
            DebugLogger.log("[WebViewBridge] Verification failed: \(error)")
        }
    }

    /// Shutdown and cleanup
    public func shutdown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nativeCallback")
        webView = nil
        isInitialized = false
        pendingCallbacks.removeAll()
    }

    // MARK: - JavaScript Execution

    /// Execute a JavaScript function on the SDK
    /// - Parameters:
    ///   - method: Method name on the global object (e.g., "deposit", "withdraw")
    ///   - params: Parameters as a dictionary (will be JSON encoded)
    /// - Returns: Result from the JavaScript execution
    public func execute(method: String, params: [String: Any]) async throws -> JSResult {
        guard isInitialized, let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        let callbackId = "cb_\(Date().timeIntervalSince1970)_\(UUID().uuidString.prefix(8))"

        // Convert params to JSON
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let paramsJSON = String(data: paramsData, encoding: .utf8) ?? "{}"

        // Build JavaScript to execute with better error handling
        let js = """
        (async function() {
            try {
                // Check if global object exists
                if (typeof window.\(globalObjectName) === 'undefined') {
                    console.log('[WebViewBridge] ERROR: window.\(globalObjectName) is undefined');
                    console.log('[WebViewBridge] Available globals:', Object.keys(window).filter(k => k.startsWith('shadow') || k.startsWith('Shadow')));
                    console.log('[WebViewBridge] typeof ShadowWireBundle:', typeof ShadowWireBundle);
                    if (typeof ShadowWireBundle !== 'undefined') {
                        console.log('[WebViewBridge] ShadowWireBundle keys:', Object.keys(ShadowWireBundle).slice(0, 10));
                    }
                    window.sendToNative('\(callbackId)', false, null, 'Global object window.\(globalObjectName) is undefined. Check SDK bundle export.');
                    return;
                }

                // Check if method exists
                if (typeof window.\(globalObjectName).\(method) !== 'function') {
                    console.log('[WebViewBridge] ERROR: window.\(globalObjectName).\(method) is not a function');
                    console.log('[WebViewBridge] Available methods:', Object.keys(window.\(globalObjectName)));
                    window.sendToNative('\(callbackId)', false, null, 'Method \(method) not found on window.\(globalObjectName)');
                    return;
                }

                const params = \(paramsJSON);
                const result = await window.\(globalObjectName).\(method)(params);
                window.sendToNative('\(callbackId)', true, result, null);
            } catch (err) {
                console.log('[WebViewBridge] Execution error:', err.message || String(err));
                window.sendToNative('\(callbackId)', false, null, err.message || String(err));
            }
        })();
        """

        // Execute with timeout
        return try await withTimeout(seconds: operationTimeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSResult, Error>) in
                Task { @MainActor in
                    self.pendingCallbacks[callbackId] = continuation

                    self.webView?.evaluateJavaScript(js) { _, error in
                        if let error = error {
                            if let continuation = self.pendingCallbacks.removeValue(forKey: callbackId) {
                                continuation.resume(throwing: PrivacyProtocolError.jsExecutionFailed(error.localizedDescription))
                            }
                        }
                        // Otherwise wait for callback
                    }
                }
            }
        }
    }

    /// Execute raw JavaScript
    /// - Parameter script: JavaScript to execute
    /// - Returns: Result from execution
    public func executeRaw(_ script: String) async throws -> Any? {
        guard isInitialized, let webView = webView else {
            throw PrivacyProtocolError.notInitialized
        }

        return try await webView.evaluateJavaScript(script)
    }

    // MARK: - Helpers

    /// Execute with a timeout
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PrivacyProtocolError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewBridge: WKScriptMessageHandler {
    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "nativeCallback",
              let body = message.body as? [String: Any] else {
            return
        }

        // Handle console log messages
        if let msgType = body["type"] as? String, msgType == "console" {
            let level = body["level"] as? String ?? "log"
            let msg = body["message"] as? String ?? ""
            DebugLogger.log("[WebView/\(level)] \(msg)")
            return
        }

        // Handle callback messages
        guard let callbackId = body["callbackId"] as? String else {
            return
        }

        let success = body["success"] as? Bool ?? false
        let data = body["data"] as? [String: Any]
        let error = body["error"] as? String

        let result = JSResult(success: success, data: data, error: error)

        Task { @MainActor in
            if let continuation = self.pendingCallbacks.removeValue(forKey: callbackId) {
                if success {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: PrivacyProtocolError.jsExecutionFailed(error ?? "Unknown error"))
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewBridge: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLogger.log("[WebViewBridge] Page loaded")
        Task { @MainActor in
            // Resume the page load continuation if waiting
            if let continuation = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                continuation.resume()
            }
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLogger.log("[WebViewBridge] Navigation failed: \(error)")
        Task { @MainActor in
            // Resume with error state (page still usable for some operations)
            if let continuation = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                continuation.resume()
            }
        }
    }
}

// MARK: - JSContext Bridge for Pure JavaScript SDKs

/// Lighter-weight bridge using JavaScriptCore for SDKs that don't need WASM
/// Used by Privacy Cash
public actor JSContextBridge {

    // MARK: - Properties

    private var context: JSContext?
    private var isInitialized = false

    /// The bundled JavaScript to execute
    private let bundledJS: String

    /// Name of the global object exposed by the SDK
    private let globalObjectName: String

    // MARK: - Initialization

    /// Initialize the JSContext bridge
    /// - Parameters:
    ///   - bundledJS: The JavaScript SDK bundle to load
    ///   - globalObjectName: Name of the global object (e.g., "privacyCash")
    public init(bundledJS: String, globalObjectName: String) {
        self.bundledJS = bundledJS
        self.globalObjectName = globalObjectName
    }

    // MARK: - Lifecycle

    /// Initialize the context and load the SDK
    public func initialize() async throws {
        guard !isInitialized else { return }

        guard let context = JSContext() else {
            throw PrivacyProtocolError.sdkLoadFailed("Failed to create JSContext")
        }

        // Set up error handling
        context.exceptionHandler = { _, exception in
            DebugLogger.log("[JSContextBridge] JS Exception: \(exception?.toString() ?? "unknown")")
        }

        // Add console.log support
        let consoleLog: @convention(block) (String) -> Void = { message in
            DebugLogger.log("[JSContextBridge] console.log: \(message)")
        }
        context.setObject(consoleLog, forKeyedSubscript: "consoleLog" as NSString)
        context.evaluateScript("var console = { log: consoleLog, error: consoleLog, warn: consoleLog, info: consoleLog };")

        // Add Web API polyfills that don't exist in JavaScriptCore
        context.evaluateScript(Self.webAPIPolyfills)

        DebugLogger.log("[JSContextBridge] Injecting SDK bundle (\(bundledJS.count) chars)...")

        // Inject the SDK bundle
        context.evaluateScript(bundledJS)

        // Check for JS exceptions after bundle execution
        if let exception = context.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            DebugLogger.log("[JSContextBridge] Bundle execution error: \(errorMsg)")
            context.exception = nil
        }

        // Try to find the global object - check multiple locations
        var globalObj = context.objectForKeyedSubscript(globalObjectName)

        // If not found directly, try to extract from bundle namespace
        if globalObj == nil || globalObj!.isUndefined {
            DebugLogger.log("[JSContextBridge] \(globalObjectName) not found directly, trying extraction...")

            // For PrivacyCash bundle
            let extractScript = """
            (function() {
                console.log('[JSContextBridge] Attempting global extraction...');

                // Check if the bundle module is available
                if (typeof PrivacyCashBundle !== 'undefined') {
                    console.log('[JSContextBridge] Found PrivacyCashBundle');
                    var target = PrivacyCashBundle.privacyCash || PrivacyCashBundle.default || PrivacyCashBundle;
                    if (target && typeof target.init === 'function') {
                        this.privacyCash = target;
                        console.log('[JSContextBridge] Extracted privacyCash from PrivacyCashBundle');
                        return true;
                    }
                }

                // Check globalThis
                if (typeof globalThis !== 'undefined' && globalThis.\(globalObjectName)) {
                    this.\(globalObjectName) = globalThis.\(globalObjectName);
                    console.log('[JSContextBridge] Copied from globalThis');
                    return true;
                }

                return false;
            })();
            """

            context.evaluateScript(extractScript)
            globalObj = context.objectForKeyedSubscript(globalObjectName)
        }

        // Final verification
        guard let obj = globalObj, !obj.isUndefined else {
            DebugLogger.log("[JSContextBridge] ERROR: Global object '\(globalObjectName)' not found after loading SDK")

            // Debug: List available globals
            #if DEBUG
            let listGlobals = "Object.keys(this).filter(function(k) { return typeof this[k] === 'object' || typeof this[k] === 'function'; }).join(', ')"
            if let globals = context.evaluateScript(listGlobals)?.toString() {
                DebugLogger.log("[JSContextBridge] Available globals: \(globals)")
            }
            #endif

            throw PrivacyProtocolError.sdkLoadFailed("Global object '\(globalObjectName)' not found after loading SDK")
        }

        // Log available methods
        #if DEBUG
        if let methods = obj.objectForKeyedSubscript("init"), !methods.isUndefined {
            DebugLogger.log("[JSContextBridge] \(globalObjectName).init is available")
        } else {
            DebugLogger.log("[JSContextBridge] WARNING: \(globalObjectName).init not found!")
        }
        #endif

        self.context = context
        isInitialized = true
        DebugLogger.log("[JSContextBridge] Initialized successfully with \(globalObjectName)")
    }

    /// Shutdown and cleanup
    public func shutdown() {
        context = nil
        isInitialized = false
    }

    // MARK: - JavaScript Execution

    /// Execute a function on the SDK
    /// - Parameters:
    ///   - method: Method name on the global object
    ///   - params: Parameters as a dictionary
    /// - Returns: Result from the JavaScript execution wrapped in JSResult
    public func execute(method: String, params: [String: Any]) async throws -> WebViewBridge.JSResult {
        guard isInitialized, let context = context else {
            throw PrivacyProtocolError.notInitialized
        }

        // Get the global object
        guard let globalObj = context.objectForKeyedSubscript(globalObjectName),
              !globalObj.isUndefined else {
            throw PrivacyProtocolError.notInitialized
        }

        // Get the method
        guard let methodFunc = globalObj.objectForKeyedSubscript(method),
              !methodFunc.isUndefined else {
            throw PrivacyProtocolError.jsExecutionFailed("Method '\(method)' not found")
        }

        // Convert params to JSValue
        let paramsValue = JSValue(object: params, in: context)

        // Call the method
        let result = methodFunc.call(withArguments: [paramsValue as Any])

        // Check for exception
        if let exception = context.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            context.exception = nil
            return WebViewBridge.JSResult(success: false, data: nil, error: errorMsg)
        }

        // Convert result to dictionary if possible
        let data = result?.toObject() as? [String: Any]
        return WebViewBridge.JSResult(success: true, data: data, error: nil)
    }

    /// Execute raw JavaScript
    /// - Parameter script: JavaScript to execute
    /// - Returns: Result from execution wrapped in JSResult
    public func executeRaw(_ script: String) async throws -> WebViewBridge.JSResult {
        guard isInitialized, let context = context else {
            throw PrivacyProtocolError.notInitialized
        }

        let result = context.evaluateScript(script)

        if let exception = context.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            context.exception = nil
            return WebViewBridge.JSResult(success: false, data: nil, error: errorMsg)
        }

        let data = result?.toObject() as? [String: Any]
        return WebViewBridge.JSResult(success: true, data: data, error: nil)
    }

    // MARK: - Web API Polyfills

    /// Polyfills for Web APIs that don't exist in JavaScriptCore
    /// Required for SDK bundles that use TextEncoder, TextDecoder, crypto, etc.
    private static let webAPIPolyfills = """
    // TextEncoder polyfill for JavaScriptCore
    if (typeof TextEncoder === 'undefined') {
        function TextEncoder() {}
        TextEncoder.prototype.encode = function(str) {
            var arr = [];
            for (var i = 0; i < str.length; i++) {
                var c = str.charCodeAt(i);
                if (c < 128) {
                    arr.push(c);
                } else if (c < 2048) {
                    arr.push((c >> 6) | 192);
                    arr.push((c & 63) | 128);
                } else if (c < 65536) {
                    arr.push((c >> 12) | 224);
                    arr.push(((c >> 6) & 63) | 128);
                    arr.push((c & 63) | 128);
                } else {
                    arr.push((c >> 18) | 240);
                    arr.push(((c >> 12) & 63) | 128);
                    arr.push(((c >> 6) & 63) | 128);
                    arr.push((c & 63) | 128);
                }
            }
            return new Uint8Array(arr);
        };
        this.TextEncoder = TextEncoder;
    }

    // TextDecoder polyfill for JavaScriptCore
    if (typeof TextDecoder === 'undefined') {
        function TextDecoder(encoding) {
            this.encoding = encoding || 'utf-8';
        }
        TextDecoder.prototype.decode = function(bytes) {
            if (!bytes) return '';
            var arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
            var result = '';
            var i = 0;
            while (i < arr.length) {
                var c = arr[i];
                if (c < 128) {
                    result += String.fromCharCode(c);
                    i++;
                } else if ((c & 224) === 192) {
                    result += String.fromCharCode(((c & 31) << 6) | (arr[i + 1] & 63));
                    i += 2;
                } else if ((c & 240) === 224) {
                    result += String.fromCharCode(((c & 15) << 12) | ((arr[i + 1] & 63) << 6) | (arr[i + 2] & 63));
                    i += 3;
                } else {
                    var cp = ((c & 7) << 18) | ((arr[i + 1] & 63) << 12) | ((arr[i + 2] & 63) << 6) | (arr[i + 3] & 63);
                    result += String.fromCodePoint(cp);
                    i += 4;
                }
            }
            return result;
        };
        this.TextDecoder = TextDecoder;
    }

    // atob/btoa polyfills for JavaScriptCore
    if (typeof atob === 'undefined') {
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
        this.atob = function(input) {
            var str = String(input).replace(/=+$/, '');
            var output = '';
            for (var bc = 0, bs, buffer, idx = 0; buffer = str.charAt(idx++);
                ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ?
                output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
                buffer = chars.indexOf(buffer);
            }
            return output;
        };
        this.btoa = function(input) {
            var str = String(input);
            var output = '';
            for (var block, charCode, idx = 0, map = chars;
                str.charAt(idx | 0) || (map = '=', idx % 1);
                output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
                charCode = str.charCodeAt(idx += 3/4);
                block = block << 8 | charCode;
            }
            return output;
        };
    }

    // crypto.getRandomValues polyfill (basic, not cryptographically secure)
    if (typeof crypto === 'undefined') {
        this.crypto = {
            getRandomValues: function(array) {
                for (var i = 0; i < array.length; i++) {
                    array[i] = Math.floor(Math.random() * 256);
                }
                return array;
            }
        };
    }

    // globalThis polyfill
    if (typeof globalThis === 'undefined') {
        this.globalThis = this;
    }

    // URL polyfill (basic)
    if (typeof URL === 'undefined') {
        function URL(url, base) {
            this.href = url;
            this.origin = '';
            this.protocol = '';
            this.host = '';
            this.pathname = url;
            this.search = '';
            this.hash = '';
        }
        URL.prototype.toString = function() { return this.href; };
        this.URL = URL;
    }

    // fetch polyfill stub (logs warning)
    if (typeof fetch === 'undefined') {
        this.fetch = function(url, options) {
            console.log('[Polyfill] fetch called but not available in JSContext: ' + url);
            return Promise.reject(new Error('fetch is not available in JavaScriptCore'));
        };
    }

    // setTimeout/setInterval stubs
    if (typeof setTimeout === 'undefined') {
        this.setTimeout = function(fn, delay) {
            // Immediate execution in JSContext (no real timer support)
            fn();
            return 0;
        };
        this.clearTimeout = function() {};
        this.setInterval = function(fn, delay) { return 0; };
        this.clearInterval = function() {};
    }

    // process polyfill (Node.js global)
    if (typeof process === 'undefined') {
        this.process = {
            env: {
                NODE_ENV: 'production'
            },
            browser: true,
            version: 'v18.0.0',
            versions: { node: '18.0.0' },
            platform: 'darwin',
            nextTick: function(fn) {
                if (typeof setTimeout !== 'undefined') {
                    setTimeout(fn, 0);
                } else {
                    fn();
                }
            },
            cwd: function() { return '/'; },
            exit: function() {},
            on: function() { return this; },
            once: function() { return this; },
            off: function() { return this; },
            emit: function() { return false; },
            listeners: function() { return []; },
            removeListener: function() { return this; },
            removeAllListeners: function() { return this; }
        };
    }

    // Buffer polyfill stub (many Node.js libs expect this)
    if (typeof Buffer === 'undefined') {
        this.Buffer = {
            from: function(data, encoding) {
                if (typeof data === 'string') {
                    var encoder = new TextEncoder();
                    return encoder.encode(data);
                }
                return new Uint8Array(data);
            },
            alloc: function(size) {
                return new Uint8Array(size);
            },
            isBuffer: function(obj) {
                return obj instanceof Uint8Array;
            },
            concat: function(list) {
                var totalLength = list.reduce(function(acc, arr) { return acc + arr.length; }, 0);
                var result = new Uint8Array(totalLength);
                var offset = 0;
                list.forEach(function(arr) {
                    result.set(arr, offset);
                    offset += arr.length;
                });
                return result;
            }
        };
    }

    console.log('[Polyfill] Web API polyfills loaded for JavaScriptCore');
    """
}
