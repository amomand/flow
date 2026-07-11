import { z } from "zod";

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

export const routineSchema = z.object({
  id: UUID,
  name: z.string().trim().min(1).max(200),
  sections: z.array(z.object({
    id: UUID,
    name: z.string().trim().min(1).max(200),
    exercises: z.array(exerciseSchema).max(100),
  }).strict()).max(50),
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
  routines: z.array(routineSchema).max(50),
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

export const snapshotEnvelopeSchema = z.object({
  contextId: UUID,
  createdAt: ISO_DATE,
  expiresAt: ISO_DATE,
  sharingProfile: sharingProfileSchema,
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

const operationKinds = z.enum([
  "replaceExerciseReps", "replaceExerciseSets", "replaceTimedDuration",
  "replaceRestBetweenSets", "replaceRestAfterExercise", "updateExerciseNotes",
  "addExercise", "removeExercise", "moveExercise", "replacePhaseOverride",
]);
const operationSchema = z.object({
  kind: operationKinds,
  exerciseId: UUID.optional(),
  sectionId: UUID.optional(),
  targetSectionId: UUID.optional(),
  afterExerciseId: UUID.optional(),
  phase: phase.optional(),
  expectedIntValue: z.number().int().optional(),
  newIntValue: z.number().int().optional(),
  expectedStringValue: z.string().optional(),
  newStringValue: z.string().optional(),
  expectedPhaseOverride: phaseOverride.optional(),
  newPhaseOverride: phaseOverride.optional(),
  removePhaseOverride: z.boolean().optional(),
  exercise: exerciseSchema.optional(),
}).strict();

export const routinePatchSchema = z.object({
  schemaVersion: z.literal(2),
  routineId: UUID,
  baseContentHash: CONTENT_HASH,
  exportedAt: ISO_DATE.optional(),
  rationale: z.string().trim().min(1).max(2000),
  operations: z.array(operationSchema).min(1).max(50),
}).strict();

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
export type PatchProblem = { path: string; message: string };

function findExercise(routine: Routine, id: string | undefined) {
  if (!id) return undefined;
  for (const section of routine.sections) {
    const exercise = section.exercises.find((candidate) => candidate.id === id);
    if (exercise) return { exercise, section };
  }
  return undefined;
}

export function validatePatch(raw: unknown, context: CoachContext): {
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
  const routine = context.routines.find((candidate) => candidate.id === patch.routineId);
  if (!routine) return { valid: false, patch, problems: [{ path: "routineId", message: "routine is absent from this snapshot" }] };
  if (context.routineContentHashByRoutineId[patch.routineId] !== patch.baseContentHash) {
    problems.push({ path: "baseContentHash", message: "patch does not match this snapshot's routine content hash" });
  }
  const sectionIds = new Set(routine.sections.map((section) => section.id));
  const ranges: Record<string, [number, number]> = {
    replaceExerciseReps: [1, 100], replaceExerciseSets: [1, 10], replaceTimedDuration: [1, 3600],
    replaceRestBetweenSets: [0, 900], replaceRestAfterExercise: [0, 900],
  };
  patch.operations.forEach((operation, index) => {
    const path = (field: string) => `operations.${index}.${field}`;
    const needsExercise = !["addExercise"].includes(operation.kind);
    const located = findExercise(routine, operation.exerciseId);
    if (needsExercise && !located) problems.push({ path: path("exerciseId"), message: "exercise is required and must exist in this routine" });
    const range = ranges[operation.kind];
    if (range) {
      if (operation.expectedIntValue === undefined) problems.push({ path: path("expectedIntValue"), message: "expectedIntValue is required" });
      if (operation.newIntValue === undefined || operation.newIntValue < range[0] || operation.newIntValue > range[1]) {
        problems.push({ path: path("newIntValue"), message: `newIntValue must be between ${range[0]} and ${range[1]}` });
      }
    }
    if (operation.kind === "replaceTimedDuration" && located?.exercise.durationSeconds === undefined) problems.push({ path: path("kind"), message: "exercise is not timed" });
    if (operation.kind === "replaceExerciseReps" && located?.exercise.durationSeconds !== undefined) problems.push({ path: path("kind"), message: "timed exercise requires replaceTimedDuration" });
    if (operation.kind === "updateExerciseNotes" && (operation.expectedStringValue === undefined || operation.newStringValue === undefined || operation.newStringValue.length > 500)) problems.push({ path: path("newStringValue"), message: "expected and new notes are required; new notes may not exceed 500 characters" });
    if (operation.kind === "removeExercise" && operation.expectedStringValue === undefined) problems.push({ path: path("expectedStringValue"), message: "expected exercise name is required" });
    if (operation.kind === "addExercise") {
      if (!operation.sectionId || !sectionIds.has(operation.sectionId)) problems.push({ path: path("sectionId"), message: "target section must exist" });
      if (!operation.exercise) problems.push({ path: path("exercise"), message: "exercise is required" });
      if (operation.exercise && findExercise(routine, operation.exercise.id)) problems.push({ path: path("exercise.id"), message: "exercise id already exists" });
    }
    if (operation.kind === "moveExercise" && (!operation.targetSectionId || !sectionIds.has(operation.targetSectionId))) problems.push({ path: path("targetSectionId"), message: "target section must exist" });
    if (operation.afterExerciseId && !findExercise(routine, operation.afterExerciseId)) problems.push({ path: path("afterExerciseId"), message: "anchor exercise must exist" });
    if (operation.kind === "replacePhaseOverride") {
      if (!operation.phase || operation.phase === "base") problems.push({ path: path("phase"), message: "peak or deload phase is required" });
      if (operation.removePhaseOverride !== true && !operation.newPhaseOverride) problems.push({ path: path("newPhaseOverride"), message: "new override is required unless removing" });
    }
  });
  return { valid: problems.length === 0, problems, patch };
}
