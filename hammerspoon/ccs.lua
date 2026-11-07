-- Optional Spotlight-style ccs switcher for Hammerspoon.
-- Install/configure with `ccs --install-hotkey`; Option-Space opens the picker, and pressing it
-- again starts a new session in a dated folder.

local M = {}

local HTML = [==[
<!doctype html>
<html><head><meta charset="utf-8">
<style>
:root { --bg: rgba(248,248,250,.97); --fg: #1d1d1f; --muted: #6e6e73; --sel: rgba(0,122,255,.13);
        --line: rgba(0,0,0,.08); --chip: rgba(0,0,0,.06); --accent: #007aff; --large: #a550d6; }
@media (prefers-color-scheme: dark) {
  :root { --bg: rgba(32,32,34,.97); --fg: #f5f5f7; --muted: #98989d; --sel: rgba(10,132,255,.28);
          --line: rgba(255,255,255,.09); --chip: rgba(255,255,255,.08); --accent: #0a84ff; --large: #bf5af2; }
}
html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; color: var(--fg);
             font: 13px -apple-system, BlinkMacSystemFont, sans-serif; -webkit-user-select: none; cursor: default; }
#panel { position: absolute; inset: 0; display: flex; flex-direction: column; overflow: hidden;
         background: var(--bg); border: 1px solid var(--line); border-radius: 12px; }
#q { border: 0; outline: 0; background: transparent; color: var(--fg); font: 15px -apple-system, sans-serif;
     padding: 13px 16px 9px; }
#q::placeholder { color: var(--muted); }
#bar { display: flex; align-items: center; gap: 10px; padding: 0 12px 9px; font-size: 11px; color: var(--muted);
       border-bottom: 1px solid var(--line); }
.seg { display: flex; padding: 2px; border-radius: 6px; background: var(--chip); }
.seg span { padding: 2px 8px; border-radius: 4px; }
.seg span.on { background: var(--accent); color: #fff; }
#count { margin-left: auto; }
#list { flex: 1; overflow-y: auto; padding: 4px 6px 6px; }
.group { padding: 9px 10px 3px; font-size: 11px; font-weight: 600; color: var(--muted); }
.row { display: flex; align-items: center; gap: 10px; padding: 5px 10px; border-radius: 7px; }
.row.sel { background: var(--sel); }
.dot { flex: none; width: 8px; height: 8px; border-radius: 50%; box-sizing: border-box; }
.dot.idle { background: #30d158; }
.dot.busy { background: #ff9f0a; }
.dot.closed { border: 1.5px solid var(--muted); }
.dot.unknown { border: 1.5px dashed var(--large); }
.main { flex: 1; min-width: 0; }
.title, .sub { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.sub { margin-top: 1px; font-size: 11px; color: var(--muted); }
.weight, .age { flex: none; font-size: 11px; color: var(--muted); font-variant-numeric: tabular-nums; }
.age { width: 30px; text-align: right; }
.weight.large { color: var(--large); font-weight: 600; }
#ask { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
       background: rgba(0,0,0,.28); border-radius: 12px; }
#ask[hidden] { display: none; }
.box { width: 430px; padding: 16px 18px 12px; border-radius: 10px; background: var(--bg); border: 1px solid var(--line);
       box-shadow: 0 8px 30px rgba(0,0,0,.3); }
#askTitle { font-weight: 600; color: var(--large); }
#askText { margin: 6px 0 14px; color: var(--muted); line-height: 1.4; }
.choices { display: flex; gap: 8px; }
.choices button { font: 13px -apple-system, sans-serif; padding: 5px 12px; border-radius: 6px; border: 1px solid var(--line);
                  background: var(--chip); color: var(--fg); }
.choices button.on { background: var(--accent); border-color: var(--accent); color: #fff; }
.hint { margin-top: 10px; font-size: 11px; color: var(--muted); }
#keys { display: flex; justify-content: center; gap: 14px; padding: 7px 12px; border-top: 1px solid var(--line);
        font-size: 11px; color: var(--muted); white-space: nowrap; overflow: hidden; }
kbd { display: inline-block; min-width: 14px; margin-right: 3px; padding: 0 4px; border-radius: 4px; text-align: center;
      font: 10px -apple-system, sans-serif; line-height: 16px; background: var(--chip); border: 1px solid var(--line); color: var(--fg); }
kbd + kbd { margin-left: -1px; }
.empty { padding: 24px; text-align: center; color: var(--muted); }
</style></head>
<body><div id="panel">
<input id="q" placeholder="Search sessions" autocomplete="off" spellcheck="false">
<div id="bar">
  <div class="seg" id="views"><span data-view="recent">Recent</span><span data-view="folders">Folders</span></div>
  <div class="seg" id="ranges"><span data-days="1">1d</span><span data-days="3">3d</span><span data-days="7">7d</span><span data-days="30">30d</span><span data-days="0">All</span></div>
  <span id="count"></span>
</div>
<div id="list"></div>
<div id="keys"><span><kbd>Tab</kbd> Recent / Folders</span><span><kbd>⌘←</kbd><kbd>⌘→</kbd> Range</span><span><kbd>↵</kbd> Open</span><span><kbd>⇧↵</kbd> New here</span><span><kbd>⌥Space</kbd> New session</span><span><kbd>esc</kbd> Close</span></div>
<div id="ask" hidden><div class="box">
  <div id="askTitle"></div><div id="askText"></div>
  <div class="choices"><button data-fresh="1">Start clean here</button><button data-fresh="0">Resume</button></div>
  <div class="hint">←→ choose · ↵ confirm · esc cancel</div>
</div></div>
</div>
<script>
const WINDOWS = [1, 3, 7, 30, 0];
let all = [], items = [], sel = 0, view = "__VIEW__", days = __DAYS__;
const q = document.getElementById("q"), list = document.getElementById("list");
const post = m => webkit.messageHandlers.ccs.postMessage(m);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));
const kind = s => ["idle", "closed", "unknown"].includes(s) ? s : "busy";
const age = s => {
  const seconds = Math.max(0, Date.now() / 1000 - s.mtime);
  for (const [unit, size] of [["d", 86400], ["h", 3600], ["m", 60]])
    if (seconds >= size) return `${Math.floor(seconds / size)}${unit}`;
  return "now";
};
const ago = s => age(s) === "now" ? "just now" : `${age(s)} ago`;
const askEl = document.getElementById("ask"), buttons = [...document.querySelectorAll(".choices button")];
let asking = null, pick = 0;

function visible() {
  const cutoff = days ? Date.now() / 1000 - days * 86400 : 0, text = q.value.toLowerCase();
  const found = all.filter(s => (!["closed", "unknown"].includes(s.status) || s.mtime >= cutoff) &&
    (!text || [s.title, s.name, s.dir, s.recap, s.last, s.status].join(" ").toLowerCase().includes(text)));
  if (view !== "folders") return found;
  const latest = Object.create(null);
  found.forEach(s => { latest[s.dir] = Math.max(latest[s.dir] || 0, s.mtime); });
  return found.sort((a, b) => latest[b.dir] - latest[a.dir] || a.dir.localeCompare(b.dir) || b.mtime - a.mtime);
}

function render() {
  items = visible();
  sel = Math.max(0, Math.min(sel, items.length - 1));
  let html = "", group = null;
  items.forEach((s, i) => {
    if (view === "folders" && s.dir !== group) { group = s.dir; html += `<div class="group">${esc(s.dir)}</div>`; }
    const sub = [s.name && `[${s.name}]`, view === "recent" && s.dir, s.recap].filter(Boolean).join(" · ");
    html += `<div class="row${i === sel ? " sel" : ""}" data-i="${i}" title="${esc(s.status)}">` +
      `<span class="dot ${kind(s.status)}"></span><div class="main"><div class="title">${esc(s.title || s.id)}</div>` +
      `<div class="sub">${esc(sub)}</div></div>` +
      `<span class="weight${s.large ? " large" : ""}">${s.turns}p${s.cost ? ` · $${Math.round(s.cost)}` : ""}</span>` +
      `<span class="age">${esc(age(s))}</span></div>`;
  });
  list.innerHTML = html || '<div class="empty">No sessions in this range</div>';
  document.querySelectorAll("#views span").forEach(e => e.classList.toggle("on", e.dataset.view === view));
  document.querySelectorAll("#ranges span").forEach(e => e.classList.toggle("on", +e.dataset.days === days));
  document.getElementById("count").textContent = `${items.length} sessions`;
  const row = list.querySelector(".row.sel");
  if (row) row.scrollIntoView({block: "nearest"});
}

function setData(data) {
  const id = items[sel]?.id;
  all = data;
  const index = visible().findIndex(s => s.id === id);
  if (index >= 0) sel = index;
  render();
}
function reset() {
  closeAsk(); all = []; q.value = ""; sel = 0; render();
  list.innerHTML = '<div class="empty">Loading sessions…</div>'; q.focus();
}
function selectRow(index) {
  list.querySelector(".row.sel")?.classList.remove("sel");
  sel = Math.max(0, Math.min(index, items.length - 1));
  const row = list.querySelector(`[data-i="${sel}"]`);
  row?.classList.add("sel"); row?.scrollIntoView({block: "nearest"});
}
function openRow(i, fresh = false) {
  const s = items[i];
  if (!s) return;
  if (s.large && !fresh) return ask(s);
  post({action: "activate", id: s.id, fresh});
}
function ask(s) {
  asking = s; pick = 0;
  document.getElementById("askTitle").textContent =
    `Large session: ${s.turns} prompts${s.cost ? ` · $${Math.round(s.cost)}` : ""} · active ${ago(s)}`;
  document.getElementById("askText").textContent =
    `Resuming carries its whole conversation into every new prompt. A clean session starts empty in ${s.dir}.`;
  buttons.forEach((b, i) => b.classList.toggle("on", i === pick));
  askEl.hidden = false;
}
function closeAsk() { asking = null; askEl.hidden = true; q.focus(); }
function answer(fresh) { const s = asking; closeAsk(); if (s) post({action: "activate", id: s.id, fresh}); }
function onEscape() { if (asking) closeAsk(); else post({action: "close"}); }
function cycle(step) { days = WINDOWS[(WINDOWS.indexOf(days) + step + WINDOWS.length) % WINDOWS.length]; sel = 0; render(); }

q.addEventListener("input", () => { sel = 0; render(); });
document.addEventListener("keydown", e => {
  if (asking) {
    if (["ArrowLeft", "ArrowRight", "Tab"].includes(e.key)) { pick = 1 - pick; buttons.forEach((b, i) => b.classList.toggle("on", i === pick)); }
    else if (e.key === "Enter") answer(pick === 0);
    else if (e.key === "n") answer(true);
    else if (e.key === "r") answer(false);
    else if (e.key === "Escape") closeAsk();
    e.preventDefault();
    return;
  }
  const moves = {ArrowDown: 1, ArrowUp: -1, PageDown: 10, PageUp: -10};
  if (e.key in moves) selectRow(sel + moves[e.key]);
  else if (e.key === "Enter") openRow(sel, e.shiftKey);
  else if (e.key === "Escape") onEscape();
  else if (e.key === "Tab") { view = view === "recent" ? "folders" : "recent"; sel = 0; render(); }
  else if (e.metaKey && (e.key === "ArrowLeft" || e.key === "ArrowRight")) cycle(e.key === "ArrowRight" ? 1 : -1);
  else return;
  e.preventDefault();
});
list.addEventListener("mousemove", e => { const r = e.target.closest(".row"); if (r && +r.dataset.i !== sel) selectRow(+r.dataset.i); });
list.addEventListener("click", e => { const r = e.target.closest(".row"); if (r) openRow(+r.dataset.i); });
document.getElementById("views").addEventListener("click", e => { if (e.target.dataset.view) { view = e.target.dataset.view; render(); q.focus(); } });
document.getElementById("ranges").addEventListener("click", e => { if (e.target.dataset.days) { days = +e.target.dataset.days; render(); q.focus(); } });
buttons.forEach(b => b.addEventListener("click", () => answer(b.dataset.fresh === "1")));
window.addEventListener("focus", () => { if (!asking) q.focus(); });
window.addEventListener("blur", () => post({action: "blur"}));
render();
</script></body></html>
]==]

local WIDTH, HEIGHT = 640, 440

local env, ccsPath, panel, escape, watcher, hotkey, refreshTimer
local tasks, ready, generation, listing = {}, false, 0, false

-- Hammerspoon starts with a minimal PATH, so borrow the login shell's PATH once
-- to find ccs and the claude command it calls.
local function loadEnv()
  if env then return true end
  -- hs.execute(cmd, true) wraps cmd in double quotes, so the outer /bin/sh would expand these variables
  -- from Hammerspoon's own environment; single-quoting hands them to the login shell instead.
  local probe = [[printf '@@%s@@%s@@%s@@' "$PATH" "$(/usr/bin/which ccs)" "$CCS_NEW_DIR"]]
  local out = hs.execute((os.getenv("SHELL") or "/bin/zsh") .. " -l -i -c '" .. probe:gsub("'", [['\'']]) .. "'") or ""
  local path, bin, newDir = out:match("@@(.-)@@(.-)@@(.-)@@")
  if not bin or bin == "" then
    hs.alert.show("ccs was not found on your shell PATH")
    return false
  end
  env = { PATH = path, HOME = os.getenv("HOME"), USER = os.getenv("USER"),
          LANG = "en_US.UTF-8", TMPDIR = os.getenv("TMPDIR"), CCS_NEW_DIR = newDir ~= "" and newDir or nil }
  ccsPath = bin
  return true
end

local function run(args, onDone)
  local task
  task = hs.task.new(ccsPath, function(code, out, err)
    if tasks[task] then tasks[task]:stop() end
    tasks[task] = nil
    onDone(code, out, err)
  end, args)
  if not task then onDone(1, "", "Could not create ccs process"); return end
  tasks[task] = hs.timer.doAfter(25, function() task:terminate() end)
  if not task:setEnvironment(env):start() then
    tasks[task]:stop(); tasks[task] = nil
    onDone(1, "", "Could not start ccs; check its path and Python installation")
  end
end

local function hide()
  if not panel or not panel:isVisible() then return end
  generation = generation + 1
  if refreshTimer then refreshTimer:stop(); refreshTimer = nil end
  escape:exit()
  panel:hide()
end

local function refresh()
  if not ready or listing == generation or not panel or not panel:isVisible() then return end
  local request = generation
  listing = request
  run({ "--json", "--days", "0" }, function(code, out, err)
    if listing == request then listing = false end
    if request ~= generation or not panel or not panel:isVisible() then return end
    if code ~= 0 then
      panel:evaluateJavaScript("setData([])")
      hs.alert.show("ccs: " .. (err ~= "" and err or "listing failed"))
      return
    end
    local ok, data = pcall(hs.json.decode, out)
    if not ok or type(data) ~= "table" or not out:match("^%s*%[") then
      hs.alert.show("ccs returned invalid session data")
      return
    end
    panel:evaluateJavaScript("setData(" .. (next(data) and hs.json.encode(data) or "[]") .. ")")
  end)
end

local function onMessage(message)
  local m = message.body
  if type(m) ~= "table" then return end
  if m.action == "activate" then
    hide()
    if type(m.id) ~= "string" then return end
    local args = { "--activate", m.id }
    if m.fresh then table.insert(args, "--fresh") end
    run(args, function(code, out, err)
      if code ~= 0 then hs.alert.show("ccs: " .. (err ~= "" and err or out)) end
    end)
  elseif m.action == "close" or m.action == "blur" then
    hide()
  end
end

local function newSession()
  hide()
  run({ "--new" }, function(code, out, err)
    if code ~= 0 then hs.alert.show("ccs: " .. (err ~= "" and err or out)) end
  end)
end

function M.show()
  if not panel then return end
  if not loadEnv() then return end
  if panel:isVisible() then return newSession() end
  generation = generation + 1
  local f = hs.screen.mainScreen():frame()
  panel:frame({ x = f.x + (f.w - WIDTH) / 2, y = f.y + f.h * 0.18, w = WIDTH, h = HEIGHT })
  if ready then panel:evaluateJavaScript("reset()") end
  panel:show()
  escape:enter()
  refresh()
  refreshTimer = hs.timer.doEvery(5, refresh)
end

function M.stop()
  hide()
  generation = generation + 1
  if hotkey then hotkey:delete(); hotkey = nil end
  if watcher then watcher:stop(); watcher = nil end
  for task, timer in pairs(tasks) do timer:stop(); task:terminate() end
  tasks, listing = {}, false
  if panel then panel:delete(); panel = nil end
  if escape then escape:delete(); escape = nil end
  env, ready = nil, false
end

-- opts: mods (default {"alt"}), key (default "space"), days (1, 3, 7, 30 or 0 for all; default 7),
--       folders (start grouped by folder; default false)
function M.start(opts)
  M.stop()
  opts = opts or {}
  assert(opts.days == nil or opts.days == 0 or opts.days == 1 or opts.days == 3 or opts.days == 7 or opts.days == 30,
         "ccs days must be 1, 3, 7, 30, or 0")
  local html = HTML:gsub("__VIEW__", opts.folders and "folders" or "recent")
                   :gsub("__DAYS__", tostring(opts.days or 7))
  local controller = hs.webview.usercontent.new("ccs"):setCallback(onMessage)
  panel = hs.webview.new({ x = 0, y = 0, w = WIDTH, h = HEIGHT }, { developerExtrasEnabled = false }, controller)
    -- A non-activating panel takes keyboard input without activating Hammerspoon, which recent
    -- macOS versions refuse for apps the user did not click.
    :windowStyle({ "borderless", "nonactivating" })
    :transparent(true)
    :shadow(true)
    :allowTextEntry(true)
    :closeOnEscape(false)
    :deleteOnClose(false)
    :level(hs.drawing.windowLevels.modalPanel)
    :navigationCallback(function(action)
      if action == "didFinishNavigation" and panel then
        ready = true
        if panel:isVisible() then panel:evaluateJavaScript("reset()"); refresh() end
      end
    end)
    :html(html)
  -- If macOS refuses to give the panel keyboard focus, its own Escape and blur handling never run;
  -- these make sure it can still be dismissed.
  escape = hs.hotkey.modal.new()
  escape:bind({}, "escape", function() panel:evaluateJavaScript("onEscape()") end)
  escape:bind({ "cmd" }, "n", newSession)
  watcher = hs.application.watcher.new(function(name, event)
    if event == hs.application.watcher.activated and name ~= "Hammerspoon" then hide() end
  end):start()
  hotkey = hs.hotkey.bind(opts.mods or { "alt" }, opts.key or "space", M.show)
  return M
end

return M
