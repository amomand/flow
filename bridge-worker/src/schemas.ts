import { z } from "zod";
import contract from "./patch-operations.json";

export const UUID = z.string().uuid();
export const ISO_DATE = z.string().refine((value) => !Number.isNaN(Date.parse(value)), {
  message: "must be an ISO 8601 date-time",
});
export const CONTENT_HASH = z.string().regex(/^c1-[0-9a-f]{16}$/);
const STATE_HASH = z.string().regex(/^s1-[0-9a-f]{16}$/);
const phase = z.enum(["base", "peak", "deload"]);

const phaseOverride = z.object({
  sets: z.number().int().min(1).max(10).optional(),
  reps: z.number().int().min(1).max(100).optional(),
  durationSeconds: z.number().int().min(1).max(3600).optional(),
}).strict();

export const exerciseSchema = z.object({
  id: UUID,
  name: z.string().trim().min(1).max(200),
  sets: z.number().int().min(1).max(10),
  reps: z.number().int().min(1).max(100),
  durationSeconds: z.number().int().min(1).max(3600).optional(),
  restBetweenSetsSeconds: z.number().int().min(0).max(900),
  restAfterExerciseSeconds: z.number().int().min(0).max(900),
  notes: z.string().max(500),
  perSide: z.boolean(),
  // Swift omits this key when the dictionary is empty.
  phaseOverrides: z.record(z.string(), phaseOverride).default({}),
}).strict();

/**
 * The most a routine can hold and still fit in a snapshot.
 *
 * Declared here and used by both `routineSchema` and the patch validator, so
 * the shape a snapshot will carry and the shape a patch may produce cannot
 * drift apart. If they did, a patch would be accepted, applied, and the
 * routine would then silently fail to upload, dropping out of the coach's
 * view entirely rather than failing anywhere visible.
 */
export const MAX_SECTIONS = 50;
export const MAX_EXERCISES_PER_SECTION = 100;
/**
 * And the most routines a snapshot carries. `createRoutine` is the first
 * operation that can grow the count, and passing this is worse than the other
 * ceilings: the next upload fails whole, so the coach stops seeing anything
 * at all rather than losing one routine.
 */
export const MAX_ROUTINES = 50;

export const routineSchema = z.object({
  id: UUID,
  name: z.string().trim().min(1).max(200),
  sections: z.array(z.object({
    id: UUID,
    name: z.string().trim().min(1).max(200),
    exercises: z.array(exerciseSchema).max(MAX_EXERCISES_PER_SECTION),
  }).strict()).max(MAX_SECTIONS),
  currentPhase: phase,
}).strict();

const adjustment = z.object({
  id: UUID,
  exerciseId: UUID,
  exerciseName: z.string().max(200),
  field: z.string().max(100),
  oldValue: z.number().int(),
  newValue: z.number().int(),
}).strict();
const setNote = z.object({
  exerciseId: UUID,
  exerciseName: z.string().max(200),
  setNumber: z.number().int().positive(),
  side: z.enum(["left", "right"]).optional(),
  rating: z.enum(["fail", "good", "easy"]),
}).strict();
const healthMetrics = z.object({
  durationSeconds: z.number().optional(),
  activeEnergyKilocalories: z.number().optional(),
  appleExerciseTimeSeconds: z.number().optional(),
  averageHeartRate: z.number().optional(),
  maxHeartRate: z.number().optional(),
  workoutEffortScore: z.number().optional(),
  estimatedWorkoutEffortScore: z.number().optional(),
  averageMETs: z.number().optional(),
}).strict();
const strengthSummary = z.object({
  date: ISO_DATE,
  routineId: UUID,
  routineName: z.string().max(200),
  phase,
  durationSeconds: z.number().nonnegative(),
  ratings: z.object({
    failed: z.number().int().nonnegative(),
    good: z.number().int().nonnegative(),
    easy: z.number().int().nonnegative(),
  }).strict(),
  adjustmentDecision: z.enum(["none", "proposed", "applied", "skipped"]),
  proposedAdjustments: z.array(adjustment).max(100),
  appliedAdjustments: z.array(adjustment).max(100),
  notableFailures: z.array(setNote).max(100),
  notableEasySets: z.array(setNote).max(100),
  appleWatchMetrics: healthMetrics.optional(),
}).strict();
const cardioSummary = z.object({
  date: ISO_DATE,
  activity: z.enum(["running", "cycling"]),
  distanceMetres: z.number().nonnegative(),
  durationSeconds: z.number().nonnegative(),
  elevationGainMetres: z.number().optional(),
  averageHeartRate: z.number().optional(),
  maxHeartRate: z.number().optional(),
}).strict();

export const coachContextSchema = z.object({
  schemaVersion: z.literal(2),
  generatedAt: ISO_DATE,
  app: z.literal("Flow"),
  routines: z.array(routineSchema).max(MAX_ROUTINES),
  currentPhaseByRoutineId: z.record(z.string(), phase),
  routineContentHashByRoutineId: z.record(z.string(), CONTENT_HASH),
  routineStateHashByRoutineId: z.record(z.string(), STATE_HASH),
  recentStrengthSummary: z.array(strengthSummary).max(50),
  recentCardioSummary: z.array(cardioSummary).max(50),
  constraints: z.object({ notes: z.string().max(2000).optional() }).strict().optional(),
}).strict();

const dataTierSchema = z.enum([
  "routines",
  "strengthHistory",
  "cardioHistory",
  "healthMetrics",
]);

export const sharingProfileSchema = z.object({
  schemaVersion: z.literal(1),
  dataTiers: z.array(dataTierSchema).max(4).superRefine((tiers, issue) => {
    if (new Set(tiers).size !== tiers.length) {
      issue.addIssue({ code: "custom", message: "data tiers must not contain duplicates" });
    }
  }),
}).strict();

/**
 * What the Flow build that produced this snapshot can apply. Optional: builds
 * that predate capability advertisement send no such field, and the bridge
 * falls back to the schema 2 baseline for them rather than assuming they can
 * apply anything newer.
 *
 * Deliberately not `.strict()`, unlike every other schema here. This is the
 * one field a newer Flow build is expected to grow, and the bridge and the app
 * ship on separate cycles: a strict schema here would mean that the first app
 * build to add a capability field could not upload a snapshot at all until the
 * bridge caught up. Unknown keys are dropped and the known ones still read.
 */
export const deviceCapabilitiesSchema = z.object({
  patchSchemaVersions: z.array(z.number().int()).min(1).max(16),
  operationKinds: z.array(z.string().max(64)).max(64),
});

export const snapshotEnvelopeSchema = z.object({
  contextId: UUID,
  createdAt: ISO_DATE,
  expiresAt: ISO_DATE,
  sharingProfile: sharingProfileSchema,
  deviceCapabilities: deviceCapabilitiesSchema.optional(),
  context: coachContextSchema,
}).strict().superRefine((envelope, issue) => {
  const dataTiers = new Set(envelope.sharingProfile.dataTiers);
  if (!dataTiers.has("routines") && envelope.context.routines.length > 0) {
    issue.addIssue({ code: "custom", path: ["context", "routines"], message: "routines were not shared" });
  }
  if (!dataTiers.has("strengthHistory") && envelope.context.recentStrengthSummary.length > 0) {
    issue.addIssue({ code: "custom", path: ["context", "recentStrengthSummary"], message: "strength history was not shared" });
  }
  if (!dataTiers.has("cardioHistory") && envelope.context.recentCardioSummary.length > 0) {
    issue.addIssue({ code: "custom", path: ["context", "recentCardioSummary"], message: "cardio summaries were not shared" });
  }
  const hasHealth = envelope.context.recentStrengthSummary.some((entry) => entry.appleWatchMetrics !== undefined)
    || envelope.context.recentCardioSummary.some((entry) => entry.averageHeartRate !== undefined || entry.maxHeartRate !== undefined);
  if (!dataTiers.has("healthMetrics") && hasHealth) {
    issue.addIssue({ code: "custom", path: ["context"], message: "health metrics were not shared" });
  }
});

/**
 * Every operation kind this build accepts, mapped to the schema version that
 * introduced it. A patch may only use operations its declared schema version
 * knows about, so "schema 2" names one fixed operation set and the capability
 * list can mean something.
 *
 * Read from `patch-operations.json` rather than written out here, because the
 * Swift patcher has to agree operation for operation and a list maintained by
 * hand in two languages drifts. FlowTests asserts the app against the same
 * file.
 */
export const OPERATION_KIND_MIN_SCHEMA = contract.operationKindMinimumSchema;

/** Still a union of literal kinds: TypeScript reads the JSON keys precisely. */
export type OperationKind = keyof typeof OPERATION_KIND_MIN_SCHEMA;
export const OPERATION_KINDS = Object.keys(OPERATION_KIND_MIN_SCHEMA) as OperationKind[];
export const PATCH_SCHEMA_VERSIONS: number[] = contract.patchSchemaVersions;

/**
 * A section arriving with a patch. No exercises: a section a patch adds is
 * always empty, and carrying exercises here would be a second, unvalidated
 * route for adding them. Fill it with `addExercise` later in the same patch.
 */
const newSectionSchema = z.object({
  id: UUID,
  name: z.string().trim().min(1).max(200),
}).strict();

const operationKinds = z.enum(OPERATION_KINDS as [OperationKind, ...OperationKind[]]);
const operationSchema = z.object({
  kind: operationKinds,
  exerciseId: UUID.optional(),
  sectionId: UUID.optional(),
  targetSectionId: UUID.optional(),
  afterSectionId: UUID.optional(),
  afterExerciseId: UUID.optional(),
  section: newSectionSchema.optional(),
  phase: phase.optional(),
  expectedIntValue: z.number().int().optional(),
  newIntValue: z.number().int().optional(),
  expectedStringValue: z.string().optional(),
  newStringValue: z.string().optional(),
  expectedPhaseOverride: phaseOverride.optional(),
  newPhaseOverride: phaseOverride.optional(),
  removePhaseOverride: z.boolean().optional(),
  exercise: exerciseSchema.optional(),
  routine: routineSchema.optional(),
}).strict();

export const routinePatchSchema = z.object({
  // Read from the shared contract rather than spelled out as literals, so
  // adding a version there cannot leave this rejecting it.
  schemaVersion: z.number().int().refine((version) => PATCH_SCHEMA_VERSIONS.includes(version), {
    message: `must be one of ${PATCH_SCHEMA_VERSIONS.join(", ")}`,
  }),
  // Absent in schema 2, where every patch edited a routine that existed.
  target: z.enum(["existingRoutine", "newRoutine"]).default("existingRoutine"),
  routineId: UUID.optional(),
  baseContentHash: CONTENT_HASH.optional(),
  exportedAt: ISO_DATE.optional(),
  rationale: z.string().trim().min(1).max(2000),
  operations: z.array(operationSchema).min(1).max(50),
}).strict().superRefine((patch, issue) => {
  // The two branches need different fields, so the discriminator is what
  // keeps both of them strict rather than making the anchor optional for
  // everyone and hoping.
  if (patch.target === "newRoutine") {
    if (patch.routineId !== undefined) {
      issue.addIssue({ code: "custom", path: ["routineId"], message: "a newRoutine patch anchors to nothing and carries no routineId" });
    }
    if (patch.baseContentHash !== undefined) {
      issue.addIssue({ code: "custom", path: ["baseContentHash"], message: "a newRoutine patch anchors to nothing and carries no baseContentHash" });
    }
    return;
  }
  if (patch.routineId === undefined) {
    issue.addIssue({ code: "custom", path: ["routineId"], message: "required unless target is newRoutine" });
  }
  if (patch.baseContentHash === undefined) {
    issue.addIssue({ code: "custom", path: ["baseContentHash"], message: "required unless target is newRoutine" });
  }
});

export const patchEnvelopeSchema = z.object({
  contextId: UUID,
  patch: z.unknown(),
}).strict();

export const acknowledgementSchema = z.object({
  status: z.enum(["pulled", "applied", "rejected", "stale"]),
}).strict();

export type CoachContext = z.infer<typeof coachContextSchema>;
export type SnapshotEnvelope = z.infer<typeof snapshotEnvelopeSchema>;
export type Routine = z.infer<typeof routineSchema>;
export type RoutinePatch = z.infer<typeof routinePatchSchema>;
export type DeviceCapabilities = z.infer<typeof deviceCapabilitiesSchema>;
export type PatchProblem = { path: string; message: string };
export type Capabilities = {
  patchSchemaVersions: number[];
  operationKinds: OperationKind[];
  /** False when the snapshot came from a build that declares nothing. */
  deviceReported: boolean;
};

/**
 * What a build that predates capability advertisement is known to handle.
 * Every shipped Flow build understands schema 2 and its ten operations, so
 * this is the floor, never a guess upwards.
 */
const BASELINE: Capabilities = {
  patchSchemaVersions: [2],
  operationKinds: OPERATION_KINDS.filter((kind) => OPERATION_KIND_MIN_SCHEMA[kind] <= 2),
  deviceReported: false,
};

/**
 * What the coach may actually propose against one snapshot: the intersection
 * of what this bridge validates and what the device that sent the snapshot
 * says it can apply. Advertising the bridge's own list alone would just move
 * the discover-by-rejection problem one step later, to a phone on an older
 * build.
 */
export function effectiveCapabilities(device: DeviceCapabilities | null | undefined): Capabilities {
  if (!device) return { ...BASELINE, operationKinds: [...BASELINE.operationKinds] };
  const patchSchemaVersions = PATCH_SCHEMA_VERSIONS.filter((version) => device.patchSchemaVersions.includes(version));
  const declared = new Set(device.operationKinds);
  return {
    patchSchemaVersions,
    // An operation stays available in every version after the one that
    // introduced it, so this asks whether any agreed version is new enough,
    // not whether the introducing version is itself on the list.
    operationKinds: OPERATION_KINDS.filter((kind) =>
      declared.has(kind) && patchSchemaVersions.some((version) => version >= OPERATION_KIND_MIN_SCHEMA[kind])),
    deviceReported: true,
  };
}

type Exercise = z.infer<typeof exerciseSchema>;

/**
 * The routine as the operations walked so far have left it.
 *
 * Validation used to check every reference against the immutable snapshot,
 * which is wrong for any patch that builds on itself: `addSection` followed by
 * `addExercise` into that section is the whole point of adding sections, and
 * `addExercise` followed by `moveExercise` was already being rejected for an
 * exercise the patch itself had just created. The app has never had this
 * problem, because it applies operations one after another to a mutable copy;
 * this is the validator catching up with what apply already does.
 *
 * Effects are recorded whenever the operation carries the ids that define
 * them, even if the operation has other problems. The alternative is a single
 * bad operation turning every later reference into a second, misleading
 * problem about something that does not exist.
 */
function workingRoutine(routine: Routine) {
  const sectionIds = new Set(routine.sections.map((section) => section.id));
  const exercises = new Map<string, { exercise: Exercise; sectionId: string }>();
  for (const section of routine.sections) {
    for (const exercise of section.exercises) exercises.set(exercise.id, { exercise, sectionId: section.id });
  }
  return { sectionIds, exercises };
}

type WorkingRoutine = ReturnType<typeof workingRoutine>;

/**
 * The exercise field each numeric replace reads and writes, with the range the
 * new value has to sit in.
 *
 * Field and range together, because they are the same fact: an operation that
 * compares `expectedIntValue` against one field has to write `newIntValue`
 * back to that same field, or a second operation on it later in the patch
 * would read the snapshot's value while the app reads the first operation's
 * result.
 */
const NUMERIC_REPLACES = {
  replaceExerciseReps: { field: "reps", range: [1, 100], name: "reps" },
  replaceExerciseSets: { field: "sets", range: [1, 10], name: "sets" },
  replaceTimedDuration: { field: "durationSeconds", range: [1, 3600], name: "duration" },
  replaceRestBetweenSets: { field: "restBetweenSetsSeconds", range: [0, 900], name: "rest between sets" },
  replaceRestAfterExercise: { field: "restAfterExerciseSeconds", range: [0, 900], name: "rest after exercise" },
} as const satisfies Record<string, { field: keyof Exercise; range: readonly [number, number]; name: string }>;

/**
 * Replace one exercise in the working set with a changed copy.
 *
 * Copied rather than mutated: the working set holds the snapshot's own
 * exercise objects, and writing through them would edit the context the
 * caller passed in, leaving a rejected patch's half-applied values behind for
 * whatever reads that context next.
 */
function recordExerciseChange(working: WorkingRoutine, id: string, change: Partial<Exercise>): void {
  const entry = working.exercises.get(id);
  if (!entry) return;
  working.exercises.set(id, { exercise: { ...entry.exercise, ...change }, sectionId: entry.sectionId });
}

/** Notes as Flow shows them in a diff, so an empty value reads as something. */
function describeNotes(notes: string): string {
  return notes.length === 0 ? "[no notes]" : `"${notes}"`;
}

type PhaseOverride = z.infer<typeof phaseOverride>;

/**
 * Whether two overrides are the value Flow would call equal.
 *
 * Field by field rather than by shape, because JSON distinguishes an absent
 * key from an explicit `undefined` and Swift's struct does not. Absence is
 * still not emptiness: Flow compares `Optional<PhaseOverride>`, where no
 * override at all and an override with nothing set are different values, and
 * it never stores the empty one. Collapsing them here would accept an
 * expectation the phone refuses.
 */
function sameOverride(left: PhaseOverride | undefined, right: PhaseOverride | undefined): boolean {
  if (left === undefined || right === undefined) return left === right;
  return left.sets === right.sets && left.reps === right.reps && left.durationSeconds === right.durationSeconds;
}

/**
 * An added exercise's overrides as Flow will actually store them.
 *
 * `addExercise` drops empty overrides before inserting, and Flow's decoder
 * keeps `base`, `peak` and `deload` and silently drops every other key.
 * Neither is a rejection on the app's side, so the bridge mirrors both rather
 * than refusing: what matters is that the working copy holds what the phone
 * would hold, or a later operation in the same patch reads an override the app
 * has already thrown away.
 */
function storedOverrides(overrides: Record<string, PhaseOverride>): Record<string, PhaseOverride> {
  const kept: Record<string, PhaseOverride> = {};
  for (const [key, override] of Object.entries(overrides)) {
    if (!phase.safeParse(key).success) continue;
    if (Object.values(override).every((value) => value === undefined)) continue;
    kept[key] = override;
  }
  return kept;
}

function describeOverride(override: PhaseOverride | undefined): string {
  if (!override) return "no override";
  const parts = [
    override.sets === undefined ? undefined : `${override.sets} sets`,
    override.reps === undefined ? undefined : `${override.reps} reps`,
    override.durationSeconds === undefined ? undefined : `${override.durationSeconds}s`,
  ].filter((part) => part !== undefined);
  return parts.length === 0 ? "an empty override" : parts.join(", ");
}

function countIn(working: WorkingRoutine, sectionId: string): number {
  let count = 0;
  for (const entry of working.exercises.values()) if (entry.sectionId === sectionId) count += 1;
  return count;
}

/**
 * What is wrong with an `afterExerciseId`, if anything. Flow inserts at the
 * anchor's index within the section being added to or moved into, so an
 * anchor that is absent, or present but in some other section, has no
 * position for the exercise to land after.
 */
function anchorProblem(
  working: WorkingRoutine,
  afterExerciseId: string | undefined,
  sectionId: string | undefined,
): string[] {
  if (!afterExerciseId) return [];
  const anchor = working.exercises.get(afterExerciseId);
  if (!anchor) return ["anchor exercise must exist"];
  if (sectionId && anchor.sectionId !== sectionId) return ["anchor exercise must be in the target section"];
  return [];
}

/**
 * A new routine arrives whole: exactly one `createRoutine` and nothing else.
 *
 * Not a create followed by a stream of `addExercise` operations, because the
 * preview would then have to render intermediate states of a routine that
 * never existed in any of them, and the person approving would be reading a
 * history rather than a routine.
 */
/**
 * Whether a proposed routine is the routine already in the snapshot.
 *
 * Sections and name, not phase: the phase is state the user owns once the
 * routine is theirs, and toggling it does not turn a retry into a revision.
 * Mirrors what the app compares, which is its content hash plus the name.
 */
function sameRoutineContent(existing: Routine, proposed: Routine): boolean {
  if (existing.name.trim() !== proposed.name.trim()) return false;
  const shape = (routine: Routine) => JSON.stringify(routine.sections.map((section) => ({
    id: section.id,
    name: section.name.trim(),
    exercises: section.exercises.map((exercise) => ({
      ...exercise,
      name: exercise.name.trim(),
      // Flow drops empty overrides before storing, so a draft carrying one is
      // still the same routine as the one that landed without it.
      phaseOverrides: Object.fromEntries(
        Object.entries(exercise.phaseOverrides ?? {})
          .filter(([, override]) => Object.values(override).some((value) => value !== undefined))
          .sort(([left], [right]) => left.localeCompare(right)),
      ),
    })),
  })));
  return shape(existing) === shape(proposed);
}

function validateCreate(
  patch: RoutinePatch,
  context: CoachContext,
  capabilities: Capabilities,
): PatchProblem[] {
  if (patch.operations.length !== 1 || patch.operations[0]!.kind !== "createRoutine") {
    return [{ path: "operations", message: "a newRoutine patch contains exactly one createRoutine operation" }];
  }
  const operation = patch.operations[0]!;
  if (!capabilities.operationKinds.includes("createRoutine")) {
    return [{ path: "operations.0.kind", message: "Flow does not report support for createRoutine" }];
  }
  if (OPERATION_KIND_MIN_SCHEMA.createRoutine > patch.schemaVersion) {
    return [{
      path: "operations.0.kind",
      message: `createRoutine was introduced in schema ${OPERATION_KIND_MIN_SCHEMA.createRoutine}; this patch declares schema ${patch.schemaVersion}`,
    }];
  }
  const routine = operation.routine;
  if (!routine) return [{ path: "operations.0.routine", message: "routine is required" }];

  const problems: PatchProblem[] = [];
  // Reported first, because the ordinary cause is a retry of a draft that
  // already landed rather than a patch that is wrong.
  //
  // The two cases need different advice, and getting it wrong is expensive.
  // "This id is taken" invites regenerating ids and re-proposing, which for a
  // draft that already landed manufactures a duplicate routine that the app
  // will accept, because every id in it is genuinely fresh. Compared
  // structurally on sections and name; the bridge cannot compute Flow's
  // content hash, but it holds both routines and that is enough.
  const collision = context.routines.find((existing) => existing.id === routine.id);
  if (collision) {
    return sameRoutineContent(collision, routine)
      ? [{
        path: "operations.0.routine.id",
        message: "this routine has already been applied in Flow; do not propose it again with new ids",
      }]
      : [{
        path: "operations.0.routine.id",
        message: `a different routine ("${collision.name}") already uses this id; generate a fresh routine id`,
      }];
  }
  if (context.routines.length >= MAX_ROUTINES) {
    return [{ path: "operations.0.routine", message: `a snapshot carries at most ${MAX_ROUTINES} routines, and there are already that many` }];
  }
  const name = routine.name.trim();
  if (!name || name.length > 100) {
    problems.push({ path: "operations.0.routine.name", message: "name must be 1 to 100 characters" });
  }
  if (routine.sections.length === 0) {
    problems.push({ path: "operations.0.routine.sections", message: "a routine needs at least one section" });
  }

  const sectionIds = new Set<string>();
  const exerciseIds = new Set<string>();
  // Checked across every routine in the snapshot, not just this one: whole
  // routine import has always reassigned ids on the way in, so globally fresh
  // ids are what the rest of the app already assumes.
  const idsElsewhere = new Set(
    context.routines.flatMap((existing) => existing.sections.flatMap((section) => section.exercises.map((entry) => entry.id))),
  );
  let totalExercises = 0;
  routine.sections.forEach((section, sectionIndex) => {
    const at = (field: string) => `operations.0.routine.sections.${sectionIndex}.${field}`;
    if (sectionIds.has(section.id)) problems.push({ path: at("id"), message: "section id is repeated in this routine" });
    sectionIds.add(section.id);
    if (section.exercises.length > MAX_EXERCISES_PER_SECTION) {
      problems.push({ path: at("exercises"), message: `a section may not hold more than ${MAX_EXERCISES_PER_SECTION} exercises` });
    }
    totalExercises += section.exercises.length;
    section.exercises.forEach((exercise, exerciseIndex) => {
      const path = `${at("exercises")}.${exerciseIndex}.id`;
      if (exerciseIds.has(exercise.id)) problems.push({ path, message: "exercise id is repeated in this routine" });
      if (idsElsewhere.has(exercise.id)) problems.push({ path, message: "exercise id already exists in another routine" });
      exerciseIds.add(exercise.id);
    });
  });
  if (totalExercises === 0) {
    problems.push({ path: "operations.0.routine.sections", message: "a routine needs at least one exercise" });
  }
  return problems;
}

export function validatePatch(raw: unknown, context: CoachContext, capabilities: Capabilities): {
  valid: boolean;
  problems: PatchProblem[];
  patch?: RoutinePatch;
} {
  const parsed = routinePatchSchema.safeParse(raw);
  if (!parsed.success) {
    return {
      valid: false,
      problems: parsed.error.issues.map((entry) => ({ path: entry.path.join(".") || "(root)", message: entry.message })),
    };
  }
  const patch = parsed.data;
  const problems: PatchProblem[] = [];
  // Checked before anything else: a patch the phone cannot apply is not
  // "mostly valid", and saying so here is the whole point of advertising
  // capabilities in the first place.
  if (!capabilities.patchSchemaVersions.includes(patch.schemaVersion)) {
    const supported = capabilities.patchSchemaVersions.length > 0
      ? `support for patch schema ${capabilities.patchSchemaVersions.join(", ")}`
      : "no patch schema version this bridge also supports";
    return {
      valid: false,
      patch,
      problems: [{ path: "schemaVersion", message: `Flow reports ${supported}; this patch declares ${patch.schemaVersion}` }],
    };
  }
  if (patch.target === "newRoutine") {
    const createProblems = validateCreate(patch, context, capabilities);
    return { valid: createProblems.length === 0, patch, problems: createProblems };
  }

  const routine = context.routines.find((candidate) => candidate.id === patch.routineId);
  if (!routine) return { valid: false, patch, problems: [{ path: "routineId", message: "routine is absent from this snapshot" }] };
  if (context.routineContentHashByRoutineId[patch.routineId!] !== patch.baseContentHash) {
    problems.push({ path: "baseContentHash", message: "patch does not match this snapshot's routine content hash" });
  }
  if (patch.operations.some((operation) => operation.kind === "createRoutine")) {
    return {
      valid: false,
      patch,
      problems: [{ path: "target", message: "createRoutine belongs to a patch with target newRoutine" }],
    };
  }
  const working = workingRoutine(routine);
  const startedWithExercises = working.exercises.size > 0;
  let workingName = routine.name;
  patch.operations.forEach((operation, index) => {
    const path = (field: string) => `operations.${index}.${field}`;
    if (!capabilities.operationKinds.includes(operation.kind)) {
      problems.push({ path: path("kind"), message: `Flow does not report support for ${operation.kind}` });
      return;
    }
    if (OPERATION_KIND_MIN_SCHEMA[operation.kind] > patch.schemaVersion) {
      problems.push({
        path: path("kind"),
        message: `${operation.kind} was introduced in schema ${OPERATION_KIND_MIN_SCHEMA[operation.kind]}; this patch declares schema ${patch.schemaVersion}`,
      });
      return;
    }
    const needsExercise = !["addExercise", "renameRoutine", "addSection"].includes(operation.kind);
    const located = operation.exerciseId ? working.exercises.get(operation.exerciseId) : undefined;
    if (needsExercise && !located) problems.push({ path: path("exerciseId"), message: "exercise is required and must exist in this routine" });
    const numeric = operation.kind in NUMERIC_REPLACES
      ? NUMERIC_REPLACES[operation.kind as keyof typeof NUMERIC_REPLACES]
      : undefined;
    // Whether the exercise is timed decides which operation may touch it at
    // all, so it is read before the numeric checks and reused by them: a
    // replaceTimedDuration against an untimed exercise has no current value to
    // compare an expectation with, and saying so twice helps nobody.
    const timed = located?.exercise.durationSeconds !== undefined;
    const wrongKindForExercise = (operation.kind === "replaceTimedDuration" && !timed)
      || (operation.kind === "replaceExerciseReps" && timed);
    // Both gated on the exercise existing: an absent exercise is already
    // reported above, and "exercise is not timed" about an exercise that is
    // not there sends the coach looking for the wrong thing.
    if (located && operation.kind === "replaceTimedDuration" && !timed) problems.push({ path: path("kind"), message: "exercise is not timed" });
    if (located && operation.kind === "replaceExerciseReps" && timed) problems.push({ path: path("kind"), message: "timed exercise requires replaceTimedDuration" });
    if (numeric) {
      const [low, high] = numeric.range;
      const current = located?.exercise[numeric.field];
      if (operation.expectedIntValue === undefined) {
        problems.push({ path: path("expectedIntValue"), message: `the current ${numeric.name} is required` });
      } else if (typeof current === "number" && !wrongKindForExercise && operation.expectedIntValue !== current) {
        // Flow refuses this as `beforeValueMismatch`. Compared against the
        // working copy rather than the snapshot, so a second operation on the
        // same field reads what the first one set, exactly as apply does.
        problems.push({
          path: path("expectedIntValue"),
          message: `${located!.exercise.name} has ${numeric.name} ${current} at this point in the patch`,
        });
      }
      const proposed = operation.newIntValue;
      if (proposed === undefined || proposed < low || proposed > high) {
        problems.push({ path: path("newIntValue"), message: `newIntValue must be between ${low} and ${high}` });
      } else if (located && !wrongKindForExercise) {
        recordExerciseChange(working, located.exercise.id, { [numeric.field]: proposed });
      }
    }
    if (operation.kind === "updateExerciseNotes") {
      const proposed = operation.newStringValue;
      if (operation.expectedStringValue === undefined || proposed === undefined || proposed.length > 500) {
        problems.push({ path: path("newStringValue"), message: "expected and new notes are required; new notes may not exceed 500 characters" });
      }
      if (operation.expectedStringValue !== undefined && located && operation.expectedStringValue !== located.exercise.notes) {
        problems.push({
          path: path("expectedStringValue"),
          message: `${located.exercise.name} has notes ${describeNotes(located.exercise.notes)} at this point in the patch`,
        });
      }
      if (located && proposed !== undefined && proposed.length <= 500) {
        recordExerciseChange(working, located.exercise.id, { notes: proposed });
      }
    }
    if (operation.kind === "removeExercise") {
      if (operation.expectedStringValue === undefined) {
        problems.push({ path: path("expectedStringValue"), message: "expected exercise name is required" });
      } else if (located && operation.expectedStringValue !== located.exercise.name) {
        problems.push({
          path: path("expectedStringValue"),
          message: `this exercise is named "${located.exercise.name}" at this point in the patch`,
        });
      }
      if (operation.exerciseId) working.exercises.delete(operation.exerciseId);
    }
    if (operation.kind === "addExercise") {
      if (!operation.sectionId || !working.sectionIds.has(operation.sectionId)) problems.push({ path: path("sectionId"), message: "target section must exist" });
      if (!operation.exercise) problems.push({ path: path("exercise"), message: "exercise is required" });
      if (operation.exercise && working.exercises.has(operation.exercise.id)) problems.push({ path: path("exercise.id"), message: "exercise id already exists" });
      if (operation.sectionId && countIn(working, operation.sectionId) >= MAX_EXERCISES_PER_SECTION) {
        problems.push({ path: path("sectionId"), message: `a section may not hold more than ${MAX_EXERCISES_PER_SECTION} exercises` });
      }
      // Resolved before the new exercise joins the working set, so it cannot
      // anchor on itself. Flow inserts at the anchor's position within the
      // target section, so an anchor in another section has no position to be
      // after and is refused there too.
      anchorProblem(working, operation.afterExerciseId, operation.sectionId)
        .forEach((message) => problems.push({ path: path("afterExerciseId"), message }));
      if (operation.exercise && operation.sectionId) {
        working.exercises.set(operation.exercise.id, {
          // Normalised on the way in, so a later operation in this patch reads
          // the exercise Flow will hold rather than the one the coach sent.
          exercise: { ...operation.exercise, phaseOverrides: storedOverrides(operation.exercise.phaseOverrides) },
          sectionId: operation.sectionId,
        });
      }
    }
    if (operation.kind === "addSection") {
      // Checked before the new id joins the working set, so a section cannot
      // anchor itself, matching the app where the insert happens after the
      // anchor is located.
      if (operation.afterSectionId && !working.sectionIds.has(operation.afterSectionId)) {
        problems.push({ path: path("afterSectionId"), message: "anchor section must exist" });
      }
      const section = operation.section;
      if (!section) {
        problems.push({ path: path("section"), message: "section is required" });
      } else {
        if (working.sectionIds.has(section.id)) problems.push({ path: path("section.id"), message: "section id already exists" });
        if (working.sectionIds.size >= MAX_SECTIONS) {
          problems.push({ path: path("section"), message: `a routine may not have more than ${MAX_SECTIONS} sections` });
        }
        working.sectionIds.add(section.id);
      }
    }
    if (operation.kind === "renameRoutine") {
      // The routine name is outside the content hash, so the expected value
      // is the only staleness guard a rename has. Compared against the name
      // as earlier operations have left it, not the snapshot's, so two
      // renames in one patch mean the same here as they do in the app.
      if (operation.expectedStringValue === undefined) {
        problems.push({ path: path("expectedStringValue"), message: "the current routine name is required" });
      } else if (operation.expectedStringValue !== workingName) {
        problems.push({ path: path("expectedStringValue"), message: `routine is named "${workingName}" at this point in the patch` });
      }
      const proposed = operation.newStringValue?.trim();
      if (!proposed || proposed.length > 100) {
        problems.push({ path: path("newStringValue"), message: "new name must be 1 to 100 characters" });
      } else {
        workingName = proposed;
      }
    }
    if (operation.kind === "moveExercise") {
      const target = operation.targetSectionId;
      if (!target || !working.sectionIds.has(target)) {
        problems.push({ path: path("targetSectionId"), message: "target section must exist" });
      }
      if (located) {
        // Flow lifts the exercise out before it looks for the anchor, so an
        // exercise cannot be moved after itself. Taking it out of the working
        // set first reproduces that.
        working.exercises.delete(located.exercise.id);
        anchorProblem(working, operation.afterExerciseId, target)
          .forEach((message) => problems.push({ path: path("afterExerciseId"), message }));
        const landsIn = target && working.sectionIds.has(target) ? target : located.sectionId;
        if (target && working.sectionIds.has(target) && countIn(working, target) >= MAX_EXERCISES_PER_SECTION) {
          problems.push({ path: path("targetSectionId"), message: `a section may not hold more than ${MAX_EXERCISES_PER_SECTION} exercises` });
        }
        working.exercises.set(located.exercise.id, { exercise: located.exercise, sectionId: landsIn });
      }
    }
    if (operation.kind === "replacePhaseOverride") {
      if (!operation.phase || operation.phase === "base") problems.push({ path: path("phase"), message: "peak or deload phase is required" });
      if (operation.removePhaseOverride !== true && !operation.newPhaseOverride) problems.push({ path: path("newPhaseOverride"), message: "new override is required unless removing" });
      const target = operation.phase && operation.phase !== "base" ? operation.phase : undefined;
      if (located && target) {
        const current = located.exercise.phaseOverrides[target];
        const removing = operation.removePhaseOverride === true;
        if (!sameOverride(current, operation.expectedPhaseOverride)) {
          problems.push({
            path: path("expectedPhaseOverride"),
            message: `${located.exercise.name} has ${describeOverride(current)} for the ${target} phase at this point in the patch`,
          });
        } else if (removing || operation.newPhaseOverride) {
          // Flow drops an override with nothing in it rather than storing it,
          // so removing and emptying land in the same place.
          const replacement = removing ? undefined : operation.newPhaseOverride;
          const phaseOverrides = { ...located.exercise.phaseOverrides };
          if (replacement && Object.values(replacement).some((value) => value !== undefined)) {
            phaseOverrides[target] = replacement;
          } else {
            delete phaseOverrides[target];
          }
          recordExerciseChange(working, located.exercise.id, { phaseOverrides });
        }
      }
    }
  });
  // The app refuses a patch that leaves a routine with nothing to do, and an
  // exercise always produces at least one step, so "no exercises left" is the
  // same condition it checks. Without this the bridge validates a patch the
  // phone then rejects, which is the discover-by-rejection loop capability
  // advertisement exists to close. A routine that was already empty is not
  // made worse by a patch, matching the app.
  if (startedWithExercises && working.exercises.size === 0) {
    problems.push({ path: "operations", message: "patch would leave the routine with no exercises" });
  }
  return { valid: problems.length === 0, problems, patch };
}
