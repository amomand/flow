/**
 * Zod schemas mirroring Flow's Swift routine-exchange contract byte-for-byte:
 *
 *   - Flow/Models/Routine.swift              (Routine, Section, ExerciseBlock, WorkoutPhase, PhaseOverride)
 *   - Flow/Coach/FlowCoachContext.swift       (FlowCoachContext schema 2 and its summary structs)
 *   - Flow/Coach/FlowRoutinePatch.swift       (FlowRoutinePatch schema 2 and FlowRoutinePatchOperation)
 *   - Flow/Coach/FlowRoutineExchange.swift    (encoder conventions: ISO8601 dates, sorted keys, c1-/s1- hashes)
 *
 * Field names, casing, optionality, and numeric ranges are kept identical to
 * the Swift `Codable` shapes so a payload produced here round-trips through
 * Flow's decoders unchanged. This file has no server logic; it is the shared
 * vocabulary every tool module imports.
 */
import { z } from "zod";

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/** Swift `UUID` encodes as an uppercase-hyphenated string; accept any casing on the way in. */
export const uuidSchema = z.string().uuid();

/** Swift `Date` with `.iso8601` strategy encodes/decodes as an ISO-8601 string. */
export const iso8601Schema = z.string().refine(
  (value) => !Number.isNaN(Date.parse(value)),
  { message: "must be an ISO 8601 date-time string" }
);

/** `FlowRoutineRevision.contentHash` — `"c1-" + 16 hex chars` (FNV-1a, %016llx). */
export const contentHashSchema = z
  .string()
  .regex(/^c1-[0-9a-f]{16}$/, "must look like c1-<16 hex chars>");

/** `FlowRoutineRevision.stateHash` — `"s1-" + 16 hex chars`. */
export const stateHashSchema = z
  .string()
  .regex(/^s1-[0-9a-f]{16}$/, "must look like s1-<16 hex chars>");

export const workoutPhaseSchema = z.enum(["base", "peak", "deload"]);
export type WorkoutPhase = z.infer<typeof workoutPhaseSchema>;

// ---------------------------------------------------------------------------
// Routine (Flow/Models/Routine.swift)
// ---------------------------------------------------------------------------

/** Mirrors `PhaseOverride`: every field optional, at least conceptually sparse. */
export const phaseOverrideSchema = z.object({
  sets: z.number().int().min(1).max(10).optional(),
  reps: z.number().int().min(1).max(100).optional(),
  durationSeconds: z.number().int().min(1).max(3600).optional(),
});
export type PhaseOverride = z.infer<typeof phaseOverrideSchema>;

/**
 * Mirrors `ExerciseBlock.phaseOverrides`: `[WorkoutPhase: PhaseOverride]` in
 * Swift, encoded as a plain string-keyed JSON object. Swift's decoder maps
 * each key through `WorkoutPhase(rawValue:)` and silently drops keys that
 * don't match a case (Routine.swift `init(from:)`), so this mirrors that
 * with a permissive string-keyed record rather than an exact `peak |
 * deload` key type — a stray key should not fail the whole payload here
 * either. `base` is a valid dictionary key in principle but never used in
 * practice (`replacePhaseOverride` rejects it); nothing enforces that at
 * this layer, matching Swift's decode-time permissiveness.
 */
export const phaseOverridesSchema = z.record(z.string(), phaseOverrideSchema);

/** Mirrors `ExerciseBlock`. */
export const exerciseBlockSchema = z.object({
  id: uuidSchema,
  name: z.string().min(1),
  sets: z.number().int().min(1).max(10),
  reps: z.number().int().min(1).max(100),
  durationSeconds: z.number().int().min(1).max(3600).optional(),
  restBetweenSetsSeconds: z.number().int().min(0).max(900),
  restAfterExerciseSeconds: z.number().int().min(0).max(900),
  notes: z.string().max(500),
  perSide: z.boolean(),
  phaseOverrides: phaseOverridesSchema.default({}),
});
export type ExerciseBlock = z.infer<typeof exerciseBlockSchema>;

/** Mirrors `Section`. */
export const sectionSchema = z.object({
  id: uuidSchema,
  name: z.string().min(1),
  exercises: z.array(exerciseBlockSchema),
});
export type Section = z.infer<typeof sectionSchema>;

/** Mirrors `Routine`. This is the full routine body returned by `get_routine`. */
export const routineSchema = z.object({
  id: uuidSchema,
  name: z.string().min(1),
  sections: z.array(sectionSchema),
  currentPhase: workoutPhaseSchema,
});
export type Routine = z.infer<typeof routineSchema>;

// ---------------------------------------------------------------------------
// FlowCoachContext summaries (Flow/Coach/FlowCoachContext.swift)
// ---------------------------------------------------------------------------

export const setRatingSchema = z.enum(["fail", "good", "easy"]);

export const workoutSideSchema = z.enum(["left", "right"]);

export const flowCoachRatingSummarySchema = z.object({
  failed: z.number().int().min(0),
  good: z.number().int().min(0),
  easy: z.number().int().min(0),
});

export const flowCoachSetNoteSchema = z.object({
  exerciseId: uuidSchema,
  exerciseName: z.string(),
  setNumber: z.number().int().min(1),
  side: workoutSideSchema.optional(),
  rating: setRatingSchema,
});

export const adjustmentDecisionSchema = z.enum(["none", "proposed", "applied", "skipped"]);

export const completedRoutineAdjustmentSchema = z.object({
  id: uuidSchema,
  exerciseId: uuidSchema,
  exerciseName: z.string(),
  field: z.string(),
  oldValue: z.number().int(),
  newValue: z.number().int(),
});

/**
 * Mirrors `FlowCoachStrengthMetrics`. Apple Watch / HealthKit-derived
 * *aggregates only* — no per-sample heart rate, no route data. Flow itself
 * never sends raw HealthKit objects across this boundary (see
 * FlowCoachContext.swift), and this schema cannot accept them even if a
 * caller tried.
 */
export const flowCoachStrengthMetricsSchema = z.object({
  durationSeconds: z.number().optional(),
  activeEnergyKilocalories: z.number().optional(),
  appleExerciseTimeSeconds: z.number().optional(),
  averageHeartRate: z.number().optional(),
  maxHeartRate: z.number().optional(),
  workoutEffortScore: z.number().optional(),
  estimatedWorkoutEffortScore: z.number().optional(),
  averageMETs: z.number().optional(),
});

/** Mirrors `FlowCoachStrengthSummary`. One completed strength workout, summarised. */
export const flowCoachStrengthSummarySchema = z.object({
  date: iso8601Schema,
  routineId: uuidSchema,
  routineName: z.string(),
  phase: workoutPhaseSchema,
  durationSeconds: z.number(),
  ratings: flowCoachRatingSummarySchema,
  adjustmentDecision: adjustmentDecisionSchema,
  proposedAdjustments: z.array(completedRoutineAdjustmentSchema),
  appliedAdjustments: z.array(completedRoutineAdjustmentSchema),
  notableFailures: z.array(flowCoachSetNoteSchema),
  notableEasySets: z.array(flowCoachSetNoteSchema),
  appleWatchMetrics: flowCoachStrengthMetricsSchema.optional(),
});
export type FlowCoachStrengthSummary = z.infer<typeof flowCoachStrengthSummarySchema>;

/**
 * Mirrors `FlowCoachCardioSummary`. Distance/duration/heart-rate aggregates
 * only — no route points, no pace buckets, no HealthKit workout UUID.
 */
export const flowCoachCardioSummarySchema = z.object({
  date: iso8601Schema,
  activity: z.enum(["running", "cycling"]),
  distanceMetres: z.number(),
  durationSeconds: z.number(),
  elevationGainMetres: z.number().optional(),
  averageHeartRate: z.number().optional(),
  maxHeartRate: z.number().optional(),
});
export type FlowCoachCardioSummary = z.infer<typeof flowCoachCardioSummarySchema>;

export const flowCoachConstraintsSchema = z.object({
  notes: z.string().optional(),
});

/**
 * Mirrors `FlowCoachContext` (schema 2). This is the full export Flow
 * produces and what an override fixture file must contain. The MCP tool
 * `get_flow_coach_context` returns a *leaner* projection of this — see
 * `toLeanContext` in `src/context-store.ts`.
 */
export const flowCoachContextSchema = z.object({
  schemaVersion: z.literal(2),
  generatedAt: iso8601Schema,
  app: z.string(),
  routines: z.array(routineSchema),
  currentPhaseByRoutineId: z.record(z.string(), z.string()),
  routineContentHashByRoutineId: z.record(z.string(), contentHashSchema),
  routineStateHashByRoutineId: z.record(z.string(), stateHashSchema),
  recentStrengthSummary: z.array(flowCoachStrengthSummarySchema),
  recentCardioSummary: z.array(flowCoachCardioSummarySchema),
  constraints: flowCoachConstraintsSchema.optional(),
});
export type FlowCoachContext = z.infer<typeof flowCoachContextSchema>;

// ---------------------------------------------------------------------------
// FlowRoutinePatch (Flow/Coach/FlowRoutinePatch.swift)
// ---------------------------------------------------------------------------

export const patchOperationKindSchema = z.enum([
  "replaceExerciseReps",
  "replaceExerciseSets",
  "replaceTimedDuration",
  "replaceRestBetweenSets",
  "replaceRestAfterExercise",
  "updateExerciseNotes",
  "addExercise",
  "removeExercise",
  "moveExercise",
  "replacePhaseOverride",
]);
export type PatchOperationKind = z.infer<typeof patchOperationKindSchema>;

/**
 * Mirrors `FlowRoutinePatchOperation`. Swift declares every field beyond
 * `kind` as optional and relies on per-kind runtime checks in
 * `FlowRoutinePatcher.apply` (see FlowRoutinePatch.swift) rather than a
 * discriminated union — a JSON patch produced by an assistant only carries
 * the fields relevant to its `kind`. This schema follows the same shape so
 * the bridge accepts exactly what Flow accepts; `validatePatchOperation` in
 * `src/patch-validation.ts` applies the per-kind field/range checks Flow
 * enforces at apply time.
 */
export const patchOperationSchema = z.object({
  kind: patchOperationKindSchema,
  exerciseId: uuidSchema.optional(),
  sectionId: uuidSchema.optional(),
  targetSectionId: uuidSchema.optional(),
  afterExerciseId: uuidSchema.optional(),
  phase: workoutPhaseSchema.optional(),
  expectedIntValue: z.number().int().optional(),
  newIntValue: z.number().int().optional(),
  expectedStringValue: z.string().optional(),
  newStringValue: z.string().optional(),
  expectedPhaseOverride: phaseOverrideSchema.optional(),
  newPhaseOverride: phaseOverrideSchema.optional(),
  removePhaseOverride: z.boolean().optional(),
  exercise: exerciseBlockSchema.optional(),
});
export type PatchOperation = z.infer<typeof patchOperationSchema>;

/**
 * Mirrors `FlowRoutinePatch` (schema 2). `exportedAt` is optional in Swift
 * (`Date?`); `rationale` is required and unbounded there, but the bridge
 * additionally caps it for payload-size hygiene (see notes in README).
 */
export const flowRoutinePatchSchema = z.object({
  schemaVersion: z.literal(2),
  routineId: uuidSchema,
  baseContentHash: contentHashSchema,
  exportedAt: iso8601Schema.optional(),
  rationale: z.string().min(1),
  operations: z.array(patchOperationSchema).min(1),
});
export type FlowRoutinePatch = z.infer<typeof flowRoutinePatchSchema>;
