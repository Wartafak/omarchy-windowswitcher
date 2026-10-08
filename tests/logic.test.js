// Unit tests for SwitcherLogic.js — run with:  node --test tests/
// No dependencies (uses only node:test + node:assert).

const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const L = require("../SwitcherLogic.js")

describe("parseAction", () => {
  it("parses the action field", () => {
    assert.equal(L.parseAction('{"action": "cycle"}'), "cycle")
    assert.equal(L.parseAction('{"action": "cycleBack"}'), "cycleBack")
    assert.equal(L.parseAction('{"action": "confirm"}'), "confirm")
  })
  it("defaults to empty string", () => {
    assert.equal(L.parseAction("{}"), "")
    assert.equal(L.parseAction(""), "")
    assert.equal(L.parseAction(null), "")
    assert.equal(L.parseAction("not json"), "")
    assert.equal(L.parseAction('{"action": null}'), "")
  })
})

describe("cycle dispatch", () => {
  it("recognises cycle actions only", () => {
    assert.equal(L.isCycleAction("cycle"), true)
    assert.equal(L.isCycleAction("cycleBack"), true)
    assert.equal(L.isCycleAction("confirm"), false)
    assert.equal(L.isCycleAction(""), false)
  })
  it("maps to deltas", () => {
    assert.equal(L.advanceDelta("cycle"), 1)
    assert.equal(L.advanceDelta("cycleBack"), -1)
  })
})

describe("confirmAllowed", () => {
  it("requires opened AND armed (truth table)", () => {
    assert.equal(L.confirmAllowed(true, true), true)
    assert.equal(L.confirmAllowed(true, false), false)
    assert.equal(L.confirmAllowed(false, true), false)
    assert.equal(L.confirmAllowed(false, false), false)
  })
})

describe("freshIndex", () => {
  it("quick Super+Tab lands on last focused (index 1)", () => {
    assert.equal(L.freshIndex("cycle", 4), 1)
  })
  it("Shift+Tab starts from the far end", () => {
    assert.equal(L.freshIndex("cycleBack", 4), 3)
  })
  it("single window stays at 0", () => {
    assert.equal(L.freshIndex("cycle", 1), 0)
    assert.equal(L.freshIndex("cycleBack", 1), 0)
  })
  it("non-cycle actions start at 0", () => {
    assert.equal(L.freshIndex("", 4), 0)
    assert.equal(L.freshIndex("confirm", 4), 0)
  })
})

describe("stepIndex", () => {
  it("wraps forward and backward", () => {
    assert.equal(L.stepIndex(3, 1, 4, true), 0)
    assert.equal(L.stepIndex(0, -1, 4, true), 3)
    assert.equal(L.stepIndex(1, 1, 4, true), 2)
  })
  it("jumps to the far end when the cursor is not active yet", () => {
    assert.equal(L.stepIndex(0, 1, 4, false), 0)
    assert.equal(L.stepIndex(0, -1, 4, false), 3)
  })
  it("reports empty lists", () => {
    assert.equal(L.stepIndex(0, 1, 0, true), -1)
  })
})

describe("clampIndex / inRange", () => {
  it("clamps", () => {
    assert.equal(L.clampIndex(9, 4), 3)
    assert.equal(L.clampIndex(-2, 4), 0)
    assert.equal(L.clampIndex(2, 4), 2)
    assert.equal(L.clampIndex(0, 0), 0)
  })
  it("ranges", () => {
    assert.equal(L.inRange(0, 3), true)
    assert.equal(L.inRange(2, 3), true)
    assert.equal(L.inRange(3, 3), false)
    assert.equal(L.inRange(-1, 3), false)
  })
})

describe("mruTouch", () => {
  it("moves the touched window to the front", () => {
    assert.deepEqual(L.mruTouch(["a", "b", "c"], "b", ["a", "b", "c"]), ["b", "a", "c"])
  })
  it("inserts unknown windows at the front", () => {
    assert.deepEqual(L.mruTouch(["a"], "z", ["a", "z"]), ["z", "a"])
  })
  it("drops dead entries (closed windows are never retained)", () => {
    assert.deepEqual(L.mruTouch(["a", "gone", "b"], "b", ["a", "b"]), ["b", "a"])
  })
  it("ignores falsy touches", () => {
    assert.deepEqual(L.mruTouch(["a"], null, ["a"]), ["a"])
  })
  it("caps length (no unbounded growth)", () => {
    const live = Array.from({ length: 100 }, (_, i) => "w" + i)
    const out = L.mruTouch([], "w0", live, 64)
    assert.ok(out.length <= 64)
    const big = L.mruTouch(live.slice().reverse(), "w0", live, 64)
    assert.equal(big.length, 64)
    assert.equal(big[0], "w0")
  })
})

describe("mruSync", () => {
  it("prunes dead and appends new as least recent", () => {
    assert.deepEqual(L.mruSync(["a", "gone", "b"], ["a", "b", "c"]), ["a", "b", "c"])
  })
  it("keeps recency order otherwise", () => {
    assert.deepEqual(L.mruSync(["b", "a"], ["a", "b"]), ["b", "a"])
  })
  it("stays bounded", () => {
    const live = Array.from({ length: 100 }, (_, i) => "w" + i)
    assert.ok(L.mruSync(live, live, 64).length <= 64)
  })
})

describe("syncKnown", () => {
  it("keeps survivors in order and appends new windows", () => {
    assert.deepEqual(L.syncKnown(["a", "gone"], ["a", "b"]), ["a", "b"])
    assert.deepEqual(L.syncKnown([], ["x", "y"]), ["x", "y"])
    assert.deepEqual(L.syncKnown(["a"], []), [])
  })
})

describe("orderRows", () => {
  const skipSpecial = (t) => t.special
  it("prefers MRU order and appends missing known windows", () => {
    const mru = ["b", "a"]
    const known = ["a", "b", "c"]
    assert.deepEqual(L.orderRows(mru, known, skipSpecial), ["b", "a", "c"])
  })
  it("lists most-recently-focused windows first", () => {
    // MRU head = active window; recency order is the display order.
    const mru = ["current", "last", "older"]
    assert.deepEqual(L.orderRows(mru, ["older", "last", "current"], () => false), ["current", "last", "older"])
  })
  it("falls back to creation order when MRU is empty", () => {
    assert.deepEqual(L.orderRows([], ["a", "b"], skipSpecial), ["a", "b"])
  })
  it("skips special workspaces and dedupes", () => {
    const mru = ["s", "a", "a", null]
    const known = ["a", "s"]
    assert.deepEqual(
      L.orderRows(mru, known, (t) => t === "s"),
      ["a"]
    )
  })
})

describe("wsOrderValue / orderBarEntries", () => {
  it("prefers the numeric workspace id", () => {
    assert.equal(L.wsOrderValue(2, "2"), 2)
    assert.equal(L.wsOrderValue("10", "x"), 10)
  })
  it("parses numeric workspace names when the id is missing", () => {
    assert.equal(L.wsOrderValue(undefined, "3"), 3)
    assert.equal(L.wsOrderValue(null, "3"), 3)
  })
  it("sorts named workspaces last", () => {
    assert.equal(L.wsOrderValue(undefined, "web") > 1000, true)
    assert.ok(L.wsOrderValue(99, "99") < L.wsOrderValue(undefined, "web"))
  })
  it("orders bar entries by workspace, stable within a workspace", () => {
    const entries = [
      { id: "b-ws2", wsId: 2, wsName: "2", pos: 0 },
      { id: "a-ws1-second", wsId: 1, wsName: "1", pos: 2 },
      { id: "c-ws1-first", wsId: 1, wsName: "1", pos: 1 },
      { id: "d-named", wsId: undefined, wsName: "web", pos: 3 }
    ]
    const out = L.orderBarEntries(entries).map((e) => e.id)
    assert.deepEqual(out, ["c-ws1-first", "a-ws1-second", "b-ws2", "d-named"])
  })
  it("does not mutate the input array", () => {
    const entries = [
      { id: "b", wsId: 2, wsName: "2", pos: 0 },
      { id: "a", wsId: 1, wsName: "1", pos: 1 }
    ]
    L.orderBarEntries(entries)
    assert.deepEqual(entries.map((e) => e.id), ["b", "a"])
  })
})

describe("pickBarWs", () => {
  it("prefers the hyprctl-resolved workspace name", () => {
    assert.deepEqual(L.pickBarWs("2", 9, "9"), { wsId: undefined, wsName: "2" })
  })
  it("falls back to the QML id/name pair when unresolved", () => {
    assert.deepEqual(L.pickBarWs("", 9, "9"), { wsId: 9, wsName: "9" })
    assert.deepEqual(L.pickBarWs(null, undefined, ""), { wsId: undefined, wsName: "" })
  })
  it("sorts by the authoritative name when QML fields are empty", () => {
    const rows = [
      { wsId: undefined, wsName: "", pos: 0 },
      { wsId: undefined, wsName: "", pos: 1 }
    ]
    const picked = [
      L.pickBarWs("3", rows[0].wsId, rows[0].wsName),
      L.pickBarWs("2", rows[1].wsId, rows[1].wsName)
    ]
    const entries = picked.map((p, i) => ({ wsId: p.wsId, wsName: p.wsName, pos: i }))
    assert.deepEqual(L.orderBarEntries(entries).map((e) => e.pos), [1, 0])
  })
})

describe("matchRowAddrs", () => {
  const clients = [
    { cls: "foot", title: "one", ws: "1", wsLabel: "1", address: "0x1" },
    { cls: "foot", title: "two", ws: "2", wsLabel: "2", address: "0x2" }
  ]
  it("matches exact class+title+workspace first", () => {
    const res = L.matchRowAddrs(
      [{ cls: "foot", ttl: "two", ws: "2" }],
      clients
    )
    assert.deepEqual(res.addrs, ["0x2"])
    assert.deepEqual(res.wsNames, ["2"])
  })
  it("falls back to class+title when the workspace differs", () => {
    const res = L.matchRowAddrs(
      [{ cls: "foot", ttl: "two", ws: "9" }],
      clients
    )
    assert.deepEqual(res.addrs, ["0x2"])
  })
  it("resolves duplicates deterministically (first unmatched wins)", () => {
    const dupes = [
      { cls: "foot", title: "same", ws: "1", wsLabel: "1", address: "0xA" },
      { cls: "foot", title: "same", ws: "1", wsLabel: "1", address: "0xB" }
    ]
    const res = L.matchRowAddrs(
      [
        { cls: "foot", ttl: "same", ws: "1" },
        { cls: "foot", ttl: "same", ws: "1" }
      ],
      dupes
    )
    assert.deepEqual(res.addrs, ["0xA", "0xB"])
  })
  it("yields empty strings when nothing matches", () => {
    const res = L.matchRowAddrs([{ cls: "nope", ttl: "x", ws: "1" }], clients)
    assert.deepEqual(res.addrs, [""])
    assert.deepEqual(res.wsNames, [""])
  })
  it("prefers the display workspace label when present", () => {
    const res = L.matchRowAddrs(
      [{ cls: "foot", ttl: "one", ws: "1" }],
      [{ cls: "foot", title: "one", ws: "1", wsLabel: "one", address: "0x1" }]
    )
    assert.deepEqual(res.wsNames, ["one"])
  })
})

describe("seedOrder", () => {
  it("sorts by focusHistoryID ascending", () => {
    const live = [
      { cls: "a", ttl: "1" },
      { cls: "b", ttl: "2" },
      { cls: "c", ttl: "3" }
    ]
    const clients = [
      { cls: "c", title: "3", fid: 0 },
      { cls: "a", title: "1", fid: 5 },
      { cls: "b", title: "2", fid: 2 }
    ]
    assert.deepEqual(L.seedOrder(live, clients), [2, 1, 0])
  })
  it("parks unmatched windows last, stably", () => {
    const live = [
      { cls: "x", ttl: "new" },
      { cls: "a", ttl: "1" }
    ]
    const clients = [{ cls: "a", title: "1", fid: 3 }]
    assert.deepEqual(L.seedOrder(live, clients), [1, 0])
  })
  it("treats missing focusHistoryID as least recent", () => {
    const live = [
      { cls: "a", ttl: "1" },
      { cls: "b", ttl: "2" }
    ]
    const clients = [
      { cls: "a", title: "1" },
      { cls: "b", title: "2", fid: 0 }
    ]
    assert.deepEqual(L.seedOrder(live, clients), [1, 0])
  })
})
