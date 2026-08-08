import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

const corpusUrl = new URL("../src/patch-contract-corpus.json", import.meta.url);
const digestUrl = new URL("../src/patch-contract-corpus.sha256", import.meta.url);
const APPROVED_SHA256 = "b3819b1b5fa809d702fc5934672399ec6f3c5fd6494036b5f506353ce4bac619";
const [corpus, recorded] = await Promise.all([
  readFile(corpusUrl),
  readFile(digestUrl, "utf8"),
]);
const actual = createHash("sha256").update(corpus).digest("hex");
const recordedDigest = recorded.trim().split(/\s+/)[0];

assert.equal(recordedDigest, APPROVED_SHA256, "the recorded corpus digest changed without updating the approved baseline check");
assert.equal(actual, APPROVED_SHA256, "patch contract corpus changed; record and review a new baseline before updating the approved digest");
console.log(`patch contract corpus ${actual}`);
