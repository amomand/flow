import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const schemaUrl = new URL("../chatgpt/openapi.json", import.meta.url);
const contractUrl = new URL("../src/patch-operations.json", import.meta.url);
const schema = JSON.parse(await readFile(schemaUrl, "utf8"));
const contract = JSON.parse(await readFile(contractUrl, "utf8"));

const schemas = schema.components.schemas;
const actions = [
  ["/coach-context", "get", "get_flow_coach_context", undefined],
  ["/routines", "get", "list_flow_routines", undefined],
  ["/routines/{routineId}", "get", "get_flow_routine", undefined],
  ["/training-summary", "get", "get_flow_training_summary", undefined],
  ["/patches/validate", "post", "validate_flow_routine_patch", false],
  ["/pending-patches", "post", "create_pending_flow_routine_patch", true],
];

assert.equal(schema.openapi, "3.1.0");
assert.match(schema.servers[0].url, /^https:\/\/[^/]+\/actions$/);
assert.equal(new URL(schema.servers[0].url).protocol, "https:");
assert.deepEqual(schema.security, [{ FlowCoachBearer: [] }]);
assert.deepEqual(schema.components.securitySchemes.FlowCoachBearer, {
  type: "http",
  scheme: "bearer",
  description: "The person-specific FLOW_COACH_ACTIONS_SECRET configured in this private GPT",
});

const operationIds = new Set();
for (const [path, method, operationId, consequential] of actions) {
  const operation = schema.paths[path]?.[method];
  assert.ok(operation, `missing ${method.toUpperCase()} ${path}`);
  assert.equal(operation.operationId, operationId);
  assert.ok(!operationIds.has(operationId), `duplicate operationId ${operationId}`);
  operationIds.add(operationId);
  assert.ok(operation.summary.length <= 300, `${operationId} summary exceeds the Actions limit`);
  assert.ok((operation.description?.length ?? 0) <= 300, `${operationId} description exceeds the Actions limit`);
  if (consequential !== undefined) assert.equal(operation["x-openai-isConsequential"], consequential);
  for (const parameter of operation.parameters ?? []) {
    if ("$ref" in parameter) continue;
    assert.ok((parameter.description?.length ?? 0) <= 700, `${operationId} parameter description exceeds the Actions limit`);
  }
}
assert.ok(
  schema.components.parameters.ContextId.description.length <= 700,
  "shared contextId parameter description exceeds the Actions limit",
);

function assertLocalReferences(value, path = "$") {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertLocalReferences(entry, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  if ("$ref" in value) {
    assert.match(value.$ref, /^#\/components\/(schemas|responses|parameters)\/[^/]+$/, `unsupported reference at ${path}`);
    const [, , group, name] = value.$ref.split("/");
    assert.ok(schema.components[group]?.[name], `missing ${value.$ref} referenced at ${path}`);
  }
  for (const [key, entry] of Object.entries(value)) assertLocalReferences(entry, `${path}.${key}`);
}
assertLocalReferences(schema);

assert.deepEqual(
  schemas.FlowRoutinePatch.properties.schemaVersion.enum,
  contract.patchSchemaVersions,
  "patch schema versions drifted from src/patch-operations.json",
);
assert.deepEqual(
  schemas.PatchOperation.properties.kind.enum,
  Object.keys(contract.operationKindMinimumSchema),
  "operation kinds drifted from src/patch-operations.json",
);
assert.deepEqual(
  schemas.PatchOperation.properties.kind["x-flow-operationMinimumSchema"],
  contract.operationKindMinimumSchema,
  "operation minimum schema versions drifted from src/patch-operations.json",
);

const bounds = contract.stringBoundsUtf16;
assert.equal(schemas.Routine.properties.name.maxLength, bounds.name);
assert.equal(schemas.RoutineSummary.properties.name.maxLength, bounds.name);
assert.equal(schemas.Section.properties.name.maxLength, bounds.name);
assert.equal(schemas.NewSection.properties.name.maxLength, bounds.name);
assert.equal(schemas.Exercise.properties.name.maxLength, bounds.name);
assert.equal(schemas.Exercise.properties.notes.maxLength, bounds.exerciseNotes);
assert.equal(schemas.ProposedRoutine.properties.name.maxLength, bounds.proposedRoutineName);
assert.equal(schemas.PatchOperation.properties.newStringValue.maxLength, bounds.exerciseNotes);
assert.equal(schemas.CoachContextSummary.properties.constraints.properties.notes.maxLength, bounds.constraintsNotes);

assert.deepEqual(
  schema.paths["/training-summary"].get.responses["200"].content["application/json"].schema.required,
  ["contextId", "recentStrengthSummary", "recentCardioSummary"],
);
assert.ok(schemas.CoachContextSummary.required.includes("recentStrengthCount"));
assert.ok(schemas.CoachContextSummary.required.includes("recentCardioCount"));
assert.ok(schemas.CoachContextSummary.required.includes("capabilities"));
assert.ok(schemas.CoachContextSummary.required.includes("advisory"));
assert.equal(schemas.PatchMetadata.properties.provenance.const, "chatgpt-actions");

const serialized = JSON.stringify(schema);
assert.ok(!serialized.includes("X-Flow-Coach-Key"), "custom Actions headers are not supported");
assert.ok(!serialized.includes("assistantProvider"), "the Worker returns provenance, not assistantProvider");
assert.ok(!serialized.includes('"const":2,"routineId"'), "the patch schema must not be pinned to schema 2");

console.log(
  `ChatGPT Actions contract verified: ${actions.length} actions, ` +
  `${contract.patchSchemaVersions.length} patch schemas, ` +
  `${Object.keys(contract.operationKindMinimumSchema).length} operation kinds.`,
);
