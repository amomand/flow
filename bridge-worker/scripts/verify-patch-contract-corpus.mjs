import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

const corpusUrl = new URL("../src/patch-contract-corpus.json", import.meta.url);
const digestUrl = new URL("../src/patch-contract-corpus.sha256", import.meta.url);
const [corpus, recorded] = await Promise.all([
  readFile(corpusUrl),
  readFile(digestUrl, "utf8"),
]);
const actual = createHash("sha256").update(corpus).digest("hex");
const expected = recorded.trim().split(/\s+/)[0];

assert.equal(actual, expected, "patch contract corpus changed; record a new matrix deliberately before updating its digest");
console.log(`patch contract corpus ${actual}`);
