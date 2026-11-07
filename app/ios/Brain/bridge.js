// Runs the Saved Scroll brain inside the app (JavaScriptCore): the same core.js, navigator.js and
// SavedScroll.js as Scriptable, loaded by Brain.swift into `__mods`. Swift provides a `native` object:
//   native.read(name) -> string|null            app files (index.txt, state.json, the export)
//   native.write(name, text)
//   native.newestExport() -> name|null          newest TikTok export the user imported
//   native.http(method, url, headersJson, timeoutSec) -> Promise<{status, url, body}>
//   native.token() -> string                    the engine's API key
//   native.now() -> ms
// Swift calls SSBridge.run(cmdJson) and gets a Promise of the JSON result.
var SSBridge = (function () {
  var ENGINE = "http://127.0.0.1:8787";

  function safeJson(s) { try { return JSON.parse(s); } catch (e) { return null; } }

  function makeEnv() {
    var store = {
      read: function (f) { var v = native.read(f); return v == null ? null : String(v); },
      write: function (f, s) { native.write(f, String(s)); },
      loadState: function () { return safeJson(native.read("state.json") || "{}") || {}; },
      saveState: function (s) { native.write("state.json", JSON.stringify(s)); },
      newestExport: function () { var n = native.newestExport(); return n ? String(n) : null; },
    };
    async function call(path, params, timeout) {
      var qs = Object.keys(params || {}).map(function (k) { return k + "=" + encodeURIComponent(params[k]); }).join("&");
      try {
        var r = await native.http("GET", ENGINE + path + (qs ? "?" + qs : ""), JSON.stringify({ "X-Token": native.token() }), timeout || 3);
        var j = r && r.body ? safeJson(r.body) : null;
        if (j && typeof j === "object") { j.base = ENGINE; return j; }
      } catch (e) {}
      return null;
    }
    var remote = {
      status: function () { return call("/status", {}, 1.5); },
      dive: function (p) { return call("/dive", p, 3); },
      stop: function () { return call("/stop", {}, 3); },
      // In the app the engine is always ours: "pairing" just confirms it answers.
      pair: async function () { var st = await call("/status", {}, 1.5); return st && st.ok ? { ok: true, token: native.token(), version: st.version, kind: st.kind } : null; },
    };
    async function resolveLink(url) {
      try { var r = await native.http("HEAD", url, "{}", 6); return (r && r.url) || url; } catch (e) { return url; }
    }
    return { core: __mods.core, nav: __mods.navigator, navigatorV2: __mods["navigator-v2"], store: store, remote: remote,
      resolveLink: resolveLink, now: native.now(), logRun: native.logRun && function (r) { native.logRun(JSON.stringify(r)); } };
  }

  async function run(cmdJson) {
    var cmd = typeof cmdJson === "string" ? safeJson(cmdJson) || { cmd: cmdJson } : cmdJson;
    var env = makeEnv();
    // The app is always the engine (no Switch Control path): make sure the brain knows it's connected.
    var st = env.store.loadState();
    if (!st.remote || !st.remote.app) {
      st.remote = { paired: true, app: true, version: "phone", at: env.now };
      env.store.saveState(st);
    }
    var m = __mods.SavedScroll;
    var res = cmd.cmd === "ui" ? await m.ui(cmd, env) : await m.main(cmd, env);
    return JSON.stringify(res);
  }

  // Swift can enter again while a promise waits on a network request. Serialize
  // read/modify/write transactions so a menu refresh cannot overwrite a jump.
  var tail = Promise.resolve();
  return { run: function (cmd) {
    var next = tail.then(function () { return run(cmd); });
    tail = next.catch(function () {});
    return next;
  } };
})();
