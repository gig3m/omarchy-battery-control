const assert = require("node:assert/strict")
const test = require("node:test")
const M = require("../Model.js")

test("parseGdbusBoolean reads only exact gdbus booleans", () => {
  assert.equal(M.parseGdbusBoolean("(<true>,)\n"), true)
  assert.equal(M.parseGdbusBoolean("(<false>,)"), false)
  assert.equal(M.parseGdbusBoolean("Error: (<true>,) not really"), null)
  assert.equal(M.parseGdbusBoolean(""), null)
})

test("appendSample keeps a 10 minute window and skips bad readings", () => {
  let s = []
  s = M.appendSample(s, 5, 0, 600)
  s = M.appendSample(s, NaN, 10, 600)
  s = M.appendSample(s, -1, 20, 600)
  s = M.appendSample(s, 7, 601, 600)
  assert.deepEqual(s, [{ t: 601, w: 7 }])
})

test("parseTopApps bounds rows and names, ignores markup-free junk", () => {
  const raw = "quickshell\t19.1\npipewire\t9.3\nbad line\nclaude\t3.4\nextra\t1.0\n" + "x".repeat(80) + "\t2\n"
  const rows = M.parseTopApps(raw, 3)
  assert.equal(rows.length, 3)
  assert.deepEqual(rows[0], { name: "quickshell", cpu: 19.1 })
  assert.equal(M.parseTopApps("x".repeat(80) + "\t2", 3)[0].name.length, 40)
  assert.deepEqual(M.parseTopApps("chrome\tnope", 3), [])
  // Names are passed through as-is; the panel renders them as PlainText.
  assert.equal(M.parseTopApps("<b>x</b>\t1", 3)[0].name, "<b>x</b>")
})

test("parseChargeLimit", () => {
  assert.deepEqual(M.parseChargeLimit("(<true>,)\n(<false>,)\n(<uint32 80>,)\n"), { supported: true, enabled: false, end: 80 })
  assert.equal(M.parseChargeLimit("(<true>,)\n\n(<uint32 80>,)\n"), null)
  assert.equal(M.parseChargeLimit("(<true>,)\n(<true>,)\n(<uint32 0>,)"), null)
  assert.equal(M.parseChargeLimit(""), null)
})
