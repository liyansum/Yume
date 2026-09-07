#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "YumeApp/Resources/WebRuntimeSupport.js"), "utf8");
function host(engine = "rpg-maker-mv") {
    const messages = [], inputs = [], listeners = {}, timers = [];
    const canvas = {width: 816, height: 624, isConnected: true, focus() {}, dispatchEvent(event) { inputs.push(event); }};
    class Context2D { constructor() { this.canvas = canvas; } drawImage() {} }
    class KeyboardEvent { constructor(type, options) { this.type = type; Object.assign(this, options); } }
    const document = {body: {children: []}, documentElement: {}, activeElement: canvas, readyState: "loading",
        addEventListener(type, callback) { listeners[type] = callback; },
        querySelector() { return canvas; }, querySelectorAll() { return [canvas]; }};
    const context = {document, KeyboardEvent, CanvasRenderingContext2D: Context2D,
        location: {href: "http://127.0.0.1:32123/index.html"}, navigator: {userAgent: "test"},
        innerWidth: 816, innerHeight: 624, devicePixelRatio: 2, __yumeEngineID: engine,
        console: Object.fromEntries(["log", "info", "warn", "error", "debug"].map(key => [key, () => {}])),
        webkit: {messageHandlers: {yumeDiagnostics: {postMessage(value) { messages.push(value); }}}},
        addEventListener(type, callback) { listeners[type] = callback; },
        setInterval(callback) { timers.push(callback); return timers.length; }, clearInterval() {}};
    context.window = context;
    vm.createContext(context);
    vm.runInContext(source, context);
    return {context, canvas, messages, inputs, listeners, timers, Context2D};
}
{
    const h = host();
    h.context.__yumeSetKey(38, true);
    assert.deepEqual(h.inputs.map(event => event.type), ["keydown"], "a held key must survive frame polling");
    assert.equal(h.inputs[0].code, "ArrowUp");
    assert.equal(h.inputs[0].keyCode, 38);
    h.context.__yumeSetKey(38, true);
    assert.equal(h.inputs.length, 1, "SwiftUI updates cannot create repeated downs");
    h.context.__yumeSetKey(90, true);
    h.listeners.yumepause();
    assert.deepEqual(h.inputs.map(event => event.type), ["keydown", "keydown", "keyup", "keyup"]);
    h.context.__yumeSetKey(38, false);
    assert.equal(h.inputs.length, 4, "a late release after pause is idempotent");
    h.listeners.load();
    assert.ok(!h.messages.some(message => message.kind === "first-frame"), "DOM load must not masquerade as rendering");
    h.canvas.isConnected = false;
    new h.Context2D().drawImage();
    assert.ok(!h.messages.some(message => message.kind === "first-frame"), "offscreen assets do not count as presentation");
    h.canvas.isConnected = true;
    new h.Context2D().drawImage();
    new h.Context2D().drawImage();
    assert.equal(h.messages.filter(message => message.kind === "first-frame").length, 1);
    h.context.console.error(undefined);
    assert.ok(h.messages.some(message => message.kind === "console-error" && message.message === "undefined"));
    let prevented = false;
    h.listeners.webglcontextlost({preventDefault() { prevented = true; }});
    assert.ok(prevented);
    assert.ok(h.messages.some(message => message.kind === "context-lost"));
    for (let i = 0; i < 10000; i++) h.context.console.log("flood");
    assert.ok(h.messages.length <= 60, "game logs must be bounded before crossing the native bridge");
}
{
    const h = host("rpg-maker-mz");
    const selected = [];
    const library = () => ({LOCALSTORAGE: "localStorageWrapper", INDEXEDDB: "asyncStorage",
        setDriver(driver) { selected.push(driver); return Promise.resolve(); },
        createInstance() { return library(); }});
    h.context.localforage = library();
    h.context.localforage.setDriver("asyncStorage");
    h.context.localforage.createInstance().setDriver(["asyncStorage"]);
    assert.deepEqual(selected, Array(4).fill("localStorageWrapper"), "MZ instances and explicit driver switches must use the per-game save library");
}
{
    // Exercise the actual injected Storage implementation, including quota
    // rollback, bracket assignment and restoring a previous session's values.
    const swift = fs.readFileSync(path.join(root, "YumeApp/Features/Player/GamePlayerView.swift"), "utf8");
    const start = swift.indexOf('        let source = """', swift.indexOf("final class GameLocalStorageBridge"));
    const end = swift.indexOf('        """', start + 29);
    let script = swift.slice(start + '        let source = """'.length, end)
        .replace('\\(json)', JSON.stringify({existing: "save"}))
        .replaceAll('\\(Self.maximumStoreByteCount)', '256')
        .replaceAll('\\(Self.maximumKeyByteCount)', '32')
        .replaceAll('\\(Self.maximumValueByteCount)', '128')
        .replaceAll('\\(Self.messageName)', 'yumeStorage');
    const messages = [];
    const context = {TextEncoder, DOMException, webkit: {messageHandlers: {yumeStorage: {postMessage(m) { messages.push(m); }}}}};
    context.window = context;
    vm.createContext(context);
    vm.runInContext(script, context);
    const storage = context.localStorage;
    assert.equal(storage.existing, "save");
    storage.slot = "checkpoint";
    assert.equal(storage.getItem("slot"), "checkpoint");
    assert.deepEqual(Object.keys(storage).sort(), ["existing", "slot"]);
    assert.throws(() => storage.setItem("slot", "x".repeat(129)), /quota/i);
    assert.equal(storage.slot, "checkpoint");
    storage.setItem("__proto__", "prototype-safe");
    assert.equal(storage.getItem("__proto__"), "prototype-safe");
    delete storage.slot;
    assert.equal(storage.getItem("slot"), null);
    assert.equal(messages.at(-1).op, "remove");
}
console.log("Web runtime fault-injection checks passed (input, first frame, errors, log limits, MZ driver, Storage).");
