import { test } from "node:test";
import assert from "node:assert/strict";
import { formatDuration, parseDuration } from "../src/duration.js";

test("formats minutes and seconds", () => {
  assert.equal(formatDuration(125000), "2 minutes, 5 seconds");
});

test("parses units", () => {
  assert.equal(parseDuration("90s"), 90000);
  assert.equal(parseDuration("2h"), 7200000);
});
