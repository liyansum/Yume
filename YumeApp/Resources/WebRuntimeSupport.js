// Yume-owned Web host support. Runs at document start, before game scripts.
// Keep this file executable in the Node fault-injection harness as well.
(function () {
    "use strict";
    if (window.__yumeRuntimeSupport) return;
    window.__yumeRuntimeSupport = true;
    const bridge = window.webkit?.messageHandlers?.yumeDiagnostics;
    const text = value => {
        try {
            if (value instanceof Error) return value.stack || value.message;
            if (typeof value === "string") return value;
            return JSON.stringify(value) ?? String(value);
        } catch (_) { return String(value); }
    };
    let sequence = 0;
    let windowStart = Date.now();
    let messageCount = 0;
    let dropped = 0;
    const send = payload => {
        if (Date.now() - windowStart >= 1000) {
            if (dropped) bridge?.postMessage({kind: "log-throttled", message: String(dropped)});
            windowStart = Date.now(); messageCount = 0; dropped = 0;
        }
        if (++messageCount > 60) { dropped++; return; }
        try {
            payload.sequence = ++sequence;
            for (const key of Object.keys(payload)) payload[key] = text(payload[key]).slice(0, 4000);
            bridge?.postMessage(payload);
        } catch (_) { /* Diagnostics must never break a game. */ }
    };
    for (const level of ["log", "info", "warn", "error", "debug"]) {
        const original = console[level]?.bind(console);
        console[level] = (...args) => {
            send({kind: `console-${level}`, message: args.map(text).join(" ")});
            original?.(...args);
        };
    }
    window.addEventListener("error", event => {
        const resource = event.target;
        send({kind: resource && resource !== window ? "resource-error" : "error",
            message: event.message || resource?.src || resource?.href || "Resource failed",
            source: event.filename || "", line: event.lineno || 0,
            column: event.colno || 0, stack: event.error?.stack || ""});
    }, true);
    window.addEventListener("unhandledrejection", event => send({
        kind: "unhandled-rejection", message: text(event.reason), stack: event.reason?.stack || ""
    }));
    document.addEventListener("webglcontextlost", event => {
        // Ask WebKit to restore the context; the game's own listeners rebuild resources.
        event.preventDefault();
        send({kind: "context-lost", message: event.statusMessage || "WebGL context lost"});
    }, true);
    document.addEventListener("webglcontextrestored", () => send({kind: "context-restored", message: "WebGL restored"}), true);

    const held = new Map();
    const keyInfo = {
        37: ["ArrowLeft", "ArrowLeft"], 38: ["ArrowUp", "ArrowUp"],
        39: ["ArrowRight", "ArrowRight"], 40: ["ArrowDown", "ArrowDown"],
        90: ["z", "KeyZ"], 88: ["x", "KeyX"], 13: ["Enter", "Enter"], 27: ["Escape", "Escape"]
    };
    const dispatchKey = (target, keyCode, pressed) => {
        const [key, code] = keyInfo[keyCode] || ["", ""];
        const event = new KeyboardEvent(pressed ? "keydown" : "keyup", {
            key, code, keyCode, which: keyCode, bubbles: true, composed: true, cancelable: true
        });
        // Some WebKit versions ignore legacy initializer fields used by RPG Maker.
        for (const property of ["keyCode", "which"]) {
            if (event[property] !== keyCode) Object.defineProperty(event, property, {value: keyCode});
        }
        target.dispatchEvent(event);
    };
    window.__yumeSetKey = (keyCode, pressed) => {
        if (pressed) {
            if (held.has(keyCode)) return;
            let target = document.activeElement;
            if (!target || target === document.body || target === document.documentElement) {
                target = document.querySelector("ruffle-player, canvas") || document;
            }
            target.focus?.({preventScroll: true});
            held.set(keyCode, target);
            dispatchKey(target, keyCode, true);
        } else {
            const target = held.get(keyCode);
            if (!target) return;
            held.delete(keyCode);
            dispatchKey(target, keyCode, false);
        }
    };
    const releaseKeys = () => Array.from(held.keys()).forEach(key => window.__yumeSetKey(key, false));
    window.addEventListener("blur", releaseKeys);
    window.addEventListener("pagehide", releaseKeys);
    window.addEventListener("yumepause", releaseKeys);

    // Stock MZ uses localForage/IndexedDB. The loopback port changes each
    // launch, so that origin's IndexedDB cannot be the save library. Select
    // localForage's own localStorage driver to preserve its serialization and
    // Promise semantics while using Yume's portable per-game save bridge.
    if (window.__yumeEngineID === "rpg-maker-mz") {
        const configure = library => {
            if (!library || library.__yumeDriver || !library.LOCALSTORAGE) return library;
            Object.defineProperty(library, "__yumeDriver", {value: true});
            const setDriver = library.setDriver;
            library.setDriver = function (_drivers, success, failure) {
                return setDriver.call(this, this.LOCALSTORAGE, success, failure);
            };
            const createInstance = library.createInstance;
            if (createInstance) library.createInstance = function (options) {
                return configure(createInstance.call(this, options));
            };
            library.setDriver(library.LOCALSTORAGE).catch(error => send({
                kind: "storage-error", message: text(error)
            }));
            send({kind: "storage-driver", message: "localForage -> per-game localStorage"});
            return library;
        };
        let library = configure(window.localforage);
        Object.defineProperty(window, "localforage", {
            configurable: true, enumerable: true,
            get: () => library, set: value => { library = configure(value); }
        });
    }

    // Observe an actual draw submission; document load and window creation
    // are separate milestones. This does not claim the frame is non-black.
    let firstDraw = false;
    const observeDraw = (prototype, method) => {
        const original = prototype?.[method];
        if (!original) return;
        prototype[method] = function (...args) {
            const result = original.apply(this, args);
            if (!firstDraw && this.canvas?.width > 0 && this.canvas?.height > 0 && this.canvas?.isConnected) {
                firstDraw = true;
                send({kind: "first-frame", message: "draw submitted", source: method,
                    viewport: `${this.canvas.width}x${this.canvas.height}`});
            }
            return result;
        };
    };
    for (const method of ["drawImage", "fillRect", "fillText", "putImageData"]) observeDraw(window.CanvasRenderingContext2D?.prototype, method);
    for (const type of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
        for (const method of ["drawArrays", "drawElements", "drawArraysInstanced", "drawElementsInstanced"]) observeDraw(type?.prototype, method);
    }
    const snapshot = () => {
        const scene = window.SceneManager?._scene;
        send({kind: "runtime-snapshot", message: location.href, readyState: document.readyState,
            scene: scene?.constructor?.name || "", sceneReady: scene?.isReady?.() ?? "unknown",
            canvasCount: document.querySelectorAll("canvas").length,
            bodyChildren: document.body?.children.length ?? -1,
            viewport: `${innerWidth}x${innerHeight}@${devicePixelRatio}`, firstDraw});
    };
    document.addEventListener("DOMContentLoaded", () => { send({kind: "dom-content-loaded", message: location.href}); snapshot(); }, {once: true});
    window.addEventListener("load", () => { send({kind: "window-loaded", message: location.href}); snapshot(); }, {once: true});
    document.addEventListener("visibilitychange", () => {
        if (document.hidden) releaseKeys();
        send({kind: "visibility-changed", message: document.visibilityState});
    });
    // Report initialization after navigation too: JS boot, asynchronous assets
    // and the game scene often start well after WKNavigationDelegate.didFinish.
    let samples = 0;
    const timer = setInterval(() => {
        try { snapshot(); } catch (error) { send({kind: "snapshot-error", message: text(error)}); }
        if (++samples >= 30) clearInterval(timer);
    }, 2000);
    send({kind: "bridge-ready", message: location.href, userAgent: navigator.userAgent});
})();
