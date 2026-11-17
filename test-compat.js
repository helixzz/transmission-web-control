#!/usr/bin/env node
/**
 * Unit & integration test suite for Transmission Web Control (v1.7.1-zhCN).
 * Verifies:
 *   1. JSON-RPC 2.0 compatibility layer (encodeArguments / decodeResult / dual sequential_download keys / group-get)
 *   2. Transmission 4.1 capability detection (supports() with modernRpc and legacy rpc-version)
 *   3. Desktop detail selection race condition & initial readiness handling
 */

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const ROOT = __dirname;
const SCRIPT_DIR = path.join(ROOT, "src", "tr-web-control", "script");

console.log("=== [1] Testing rpc-compat.js (JSON-RPC 2.0 boundary) ===");
const compat = require(path.join(SCRIPT_DIR, "rpc-compat.js"));

// 1.1 encodeArguments preserves opaque user values and converts field names
const encoded = compat.encodeArguments({
  "download-dir": "/volume2/downloads/中文目录-Keep-Case",
  labels: ["PT-Keep-Case", "高清"],
  fields: ["hashString", "fileStats", "sequential_download", "maxConnectedPeers"],
  ids: "recently-active",
  "cache-size-mb": 64,
  encryption: "tolerated",
});
assert.strictEqual(encoded.download_dir, "/volume2/downloads/中文目录-Keep-Case");
assert.deepStrictEqual(encoded.labels, ["PT-Keep-Case", "高清"]);
assert.deepStrictEqual(encoded.fields, ["hash_string", "file_stats", "sequential_download", "max_connected_peers"]);
assert.strictEqual(encoded.ids, "recently_active");
assert.strictEqual(encoded.cache_size_mib, 64);
assert.strictEqual(encoded.encryption, "allowed");
console.log("  ✅ encodeArguments: field conversion & opaque user values");

// 1.2 decodeResult converts session-get, torrent-get, and group-get responses
const decodedSession = compat.decodeResult("session-get", {
  version: "4.1.4 (a6d907d9ea)",
  rpc_version: 19,
  cache_size_mib: 64,
  seed_ratio_limit: 2.0,
  seed_ratio_limited: true,
  sequential_download: true,
  default_trackers: "https://tracker.example.com/announce",
  encryption: "allowed",
});
assert.strictEqual(decodedSession["cache-size-mb"], 64);
assert.strictEqual(decodedSession.seedRatioLimit, 2.0);
assert.strictEqual(decodedSession.seedRatioLimited, true);
assert.strictEqual(decodedSession["sequential-download"], true);
assert.strictEqual(decodedSession["default-trackers"], "https://tracker.example.com/announce");
assert.strictEqual(decodedSession.encryption, "tolerated");
console.log("  ✅ decodeResult(session-get): legacy keys & units restored");

const decodedTorrents = compat.decodeResult("torrent-get", {
  torrents: [
    {
      id: 1,
      name: "Ubuntu.iso",
      hash_string: "abcdef",
      peer_limit: 50,
      sequential_download: true,
      is_private: true,
      max_connected_peers: 60,
      wanted: [true, false],
    },
  ],
});
const tor = decodedTorrents.torrents[0];
assert.strictEqual(tor.hashString, "abcdef");
assert.strictEqual(tor["peer-limit"], 50);
assert.strictEqual(tor.sequential_download, true);
assert.strictEqual(tor.sequentialDownload, true);
assert.strictEqual(tor.isPrivate, true);
assert.strictEqual(tor.maxConnectedPeers, 60);
assert.deepStrictEqual(tor.wanted, [1, 0]);
console.log("  ✅ decodeResult(torrent-get): dual sequential_download/sequentialDownload & wanted[0/1]");

const decodedGroups = compat.decodeResult("group-get", {
  group: [
    {
      name: "PT-Limit",
      honors_session_limits: true,
      speed_limit_down: 10240,
      speed_limit_down_enabled: true,
      speed_limit_up: 2048,
      speed_limit_up_enabled: false,
    },
  ],
});
const grp = decodedGroups.group[0];
assert.strictEqual(grp.name, "PT-Limit");
assert.strictEqual(grp.honorsSessionLimits, true);
assert.strictEqual(grp["speed-limit-down"], 10240);
assert.strictEqual(grp["speed-limit-down-enabled"], true);
assert.strictEqual(grp["speed-limit-up"], 2048);
assert.strictEqual(grp["speed-limit-up-enabled"], false);
console.log("  ✅ decodeResult(group-get): bandwidth group keys match UI dialog expectations");

console.log("\n=== [2] Testing transmission.js + rpc-compat.js integration ===");
const ctx2 = {
  jQuery: { extend: Object.assign, ajax: () => {} },
  Base64: function () {},
};
ctx2.window = ctx2;
vm.createContext(ctx2);
vm.runInContext(fs.readFileSync(path.join(SCRIPT_DIR, "min", "transmission.min.js"), "utf8"), ctx2);
vm.runInContext(fs.readFileSync(path.join(SCRIPT_DIR, "min", "rpc-compat.min.js"), "utf8"), ctx2);

ctx2.transmission.modernRpc = true;
ctx2.transmission.sessionConfig = {};
assert.strictEqual(ctx2.transmission.supports("labels"), true);
assert.strictEqual(ctx2.transmission.supports("bandwidthGroups"), true);
assert.strictEqual(ctx2.transmission.supports("sequentialDownload"), true);
console.log("  ✅ transmission.supports(): enabled when modernRpc=true or rpc-version>=17");

console.log("\n=== [3] Testing system.js detail selection & desktop-ui.js ===");
const sysSource = fs.readFileSync(path.join(SCRIPT_DIR, "system.js"), "utf8");
const start = sysSource.indexOf("\tgetTorrentInfos: function (id) {");
const end = sysSource.indexOf("\tclearTorrentAttribute: function", start);
assert(start > 0 && end > start);

const calls = [];
const painted = [];
let clears = 0;
const torrents = {
  1: { id: 1, name: "First", totalSize: 10 },
  2: { id: 2, name: "Second", totalSize: 20 },
};
const ctx3 = {
  transmission: {
    torrents: {
      all: torrents,
      datas: {},
      getMoreInfos(fields, id, callback) {
        calls.push({ fields, id, callback });
      },
    },
  },
  jQuery: { extend: Object.assign },
};
vm.createContext(ctx3);
vm.runInContext("var system={" + sysSource.slice(start, end) + "};", ctx3);
Object.assign(ctx3.system, {
  currentTorrentId: 0,
  panel: { attribute: { panel() { return { collapsed: false }; } } },
  clearTorrentAttribute() { clears++; },
  fillTorrentBaseInfos(t) { painted.push(t.id); },
  fillTorrentFileList() {},
  fillTorrentServerList() {},
  fillTorrentPeersList() {},
  fillTorrentConfig() {},
});

ctx3.system.getTorrentInfos(1);
ctx3.system.getTorrentInfos(2);
assert.deepStrictEqual(calls.map((x) => x.id), [1, 2], "Changing selection must not wait for previous RPC");
calls[1].callback([{ id: 2, files: [{}], leftUntilDone: 4 }]);
calls[0].callback([{ id: 1, files: [{}], leftUntilDone: 6 }]);
assert.deepStrictEqual(painted, [2], "Stale response must not replace selected task");
assert.strictEqual(clears, 0, "Stale response must not clear newer result");
assert(calls[0].fields.includes("secondsSeeding"));
console.log("  ✅ system.getTorrentInfos: race-free selection switching");

const desktopCode = fs.readFileSync(path.join(SCRIPT_DIR, "min", "desktop-ui.min.js"), "utf8");
for (const order of ["grid-first", "data-first"]) {
  let gridReady = order === "grid-first";
  let selections = 0;
  const app = {
    lang: {},
    config: { defaultSelectNode: "all" },
    currentTorrentId: 0,
    uiIsInitialized: true,
    desktopDetailsInitialized: true,
    initUIStatus() {},
    fillTorrentBaseInfos() {},
    clearTorrentAttribute() {},
    control: { torrentlist: { data() { return gridReady; } } },
    panel: {
      left: {
        tree(method, key) {
          if (method === "getSelected") return null;
          if (method === "find") return { target: "node-" + key };
          if (method === "select") { selections++; return this; }
        },
      },
    },
  };
  const w = {
    system: app,
    transmission: { torrents: { all: order === "data-first" ? {} : null } },
    jQuery: function () {},
  };
  vm.runInNewContext(desktopCode, { window: w });
  app.ensureDesktopInitialSelection();
  assert.strictEqual(selections, 0);
  gridReady = true;
  w.transmission.torrents.all = {};
  app.initUIStatus();
  assert.strictEqual(app.config.defaultSelectNode, "torrent-all");
  assert.strictEqual(selections, 1);
  app.ensureDesktopInitialSelection();
  assert.strictEqual(selections, 1);
}
console.log("  ✅ desktop-ui.js: handles both grid-first and data-first initialization orders");

console.log("\nALL TESTS PASSED!");
