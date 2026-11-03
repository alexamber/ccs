import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

function popup() {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      value: "", innerHTML: "", textContent: "", hidden: true,
      classList: { toggle() {}, add() {}, remove() {} },
      addEventListener() {}, querySelector() { return null; }, focus() {},
    });
    return elements.get(id);
  };
  const messages = [];
  const context = vm.createContext({
    document: { getElementById: element, querySelectorAll: () => [], addEventListener() {} },
    window: { addEventListener() {} },
    webkit: { messageHandlers: { ccs: { postMessage: message => messages.push(message) } } },
  });
  const lua = readFileSync(new URL("../hammerspoon/ccs.lua", import.meta.url), "utf8");
  const code = lua.match(/<script>([\s\S]*?)<\/script>/)[1]
    .replaceAll("__VIEW__", "recent").replaceAll("__DAYS__", "7");
  vm.runInContext(code, context);
  return { run: code => vm.runInContext(code, context), messages, element };
}

const session = (id, overrides = {}) => ({
  id, title: id, name: null, dir: "~/work", status: "closed", mtime: Date.now() / 1000,
  recap: "", last: "", turns: 1, cost: null, large: false, ...overrides,
});

test("opening again clears old rows and unfinished confirmation", () => {
  const p = popup();
  p.run(`setData(${JSON.stringify([session("old", { large: true })])}); openRow(0); reset()`);
  assert.equal(p.run("items.length"), 0);
  assert.equal(p.run("asking"), null);
  assert.equal(p.messages.length, 0);
});

test("search, age range, and known live-session exceptions work together", () => {
  const p = popup();
  const old = Date.now() / 1000 - 40 * 86400;
  p.run(`setData(${JSON.stringify([session("closed", { mtime: old }), session("live", { status: "idle", mtime: old })])})`);
  assert.equal(p.run("items.length"), 1);
  p.run('q.value = "LIVE"; render()');
  assert.equal(p.run("items[0].id"), "live");
  p.run('q.value = ""; days = 0; render()');
  assert.equal(p.run("items.length"), 2);
});

test("refresh preserves selection and escaped titles cannot add markup", () => {
  const p = popup();
  p.run(`setData(${JSON.stringify([session("a"), session("b")])}); sel = 1`);
  p.run(`setData(${JSON.stringify([session("new", { title: '<img src=x onerror="bad()">' }), session("a"), session("b")])})`);
  assert.equal(p.run("items[sel].id"), "b");
  assert.match(p.element("list").innerHTML, /&lt;img/);
  assert.doesNotMatch(p.element("list").innerHTML, /<img/);
});

test("large-session activation waits for an explicit choice", () => {
  const p = popup();
  p.run(`setData(${JSON.stringify([session("large", { large: true })])}); openRow(0)`);
  assert.equal(p.messages.length, 0);
  p.run("answer(true)");
  assert.equal(p.messages.length, 1);
  assert.equal(p.messages[0].id, "large");
  assert.equal(p.messages[0].fresh, true);
});
