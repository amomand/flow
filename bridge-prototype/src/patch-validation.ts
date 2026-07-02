/**
 * Structured (non-throwing) validation of a candidate FlowRoutinePatch
 * against a stored coach context, mirroring the checks
 * `FlowRoutinePatcher.preview` / `.apply` perform in
 * Flow/Coach/FlowRoutinePatch.swift.
 *
 * This is deliberately a *shape and value* validator, not a full apply
 * simulation. Flow remains the sole authority for semantic validation
 * (mismatched "expected" before-values, whether an operation would empty a
 * routine, grafting onto live app state) — see the validation-split note in
 * bridge-prototype/README.md. The bridge only rejects patches that are
 * malformed, target the wrong schema, target an unknown routine/exercise/
 * section, are stale against the stored content hash, or carry out-of-range
 * values. Every other decision is Flow's at preview/apply time.
 */
import {
  flowRoutinePatchSchema,
  patchOperationSchema,
  type FlowRoutinePatch,
  type PatchOperation,
  type Routine,
} from "./flow-types.js";

export interface PatchProblem {
  /** JSON-pointer-ish path into the patch payload, e.g. "operations[0].newIntValue". */
  path: string;
  message: string;
}

export interface PatchValidationResult {
  valid: boolean;
  problems: PatchProblem[];
}

export interface RoutineLookup {
  /** Look up a stored routine by id. */
  getRoutine(routineId: string): Routine | undefined;
  /** Look up the stored content hash (`c1-...`) for a routine id. */
  getContentHash(routineId: string): string | undefined;
}

const INT_RANGES: Record<string, { min: number; max: number; field: string }> = {
  replaceExerciseReps: { min: 1, max: 100, field: "reps" },
  replaceExerciseSets: { min: 1, max: 10, field: "sets" },
  replaceTimedDuration: { min: 1, max: 3600, field: "durationSeconds" },
  replaceRestBetweenSets: { min: 0, max: 900, field: "restBetweenSetsSeconds" },
  replaceRestAfterExercise: { min: 0, max: 900, field: "restAfterExerciseSeconds" },
};

function findExercise(
  routine: Routine,
  exerciseId: string
): { sectionIndex: number; exerciseIndex: number } | undefined {
  for (let sectionIndex = 0; sectionIndex < routine.sections.length; sectionIndex++) {
    const exercises = routine.sections[sectionIndex]?.exercises ?? [];
    const exerciseIndex = exercises.findIndex((exercise) => exercise.id === exerciseId);
    if (exerciseIndex !== -1) {
      return { sectionIndex, exerciseIndex };
    }
  }
  return undefined;
}

function findSectionIndex(routine: Routine, sectionId: string): number {
  return routine.sections.findIndex((section) => section.id === sectionId);
}

/**
 * Validates one operation's shape against Flow's per-kind field and range
 * rules (FlowRoutinePatch.swift `apply`). Assumes the routine exists; the
 * caller resolves routine-level problems (unknown routine, stale hash)
 * separately so every operation problem can carry the same routine context.
 */
function validateOperation(
  operation: PatchOperation,
  index: number,
  routine: Routine
): PatchProblem[] {
  const problems: PatchProblem[] = [];
  const path = (suffix: string) => `operations[${index}].${suffix}`;

  const requireExercise = (): { sectionIndex: number; exerciseIndex: number } | undefined => {
    if (!operation.exerciseId) {
      problems.push({ path: path("exerciseId"), message: "exerciseId is required for this operation kind" });
      return undefined;
    }
    const location = findExercise(routine, operation.exerciseId);
    if (!location) {
      problems.push({
        path: path("exerciseId"),
        message: `no exercise matches ${operation.exerciseId} in this routine`,
      });
      return undefined;
    }
    return location;
  };

  const requireIntInRange = (kind: keyof typeof INT_RANGES) => {
    const range = INT_RANGES[kind];
    if (!range) return;
    if (operation.newIntValue === undefined) {
      problems.push({ path: path("newIntValue"), message: "newIntValue is required for this operation kind" });
      return;
    }
    if (operation.newIntValue < range.min || operation.newIntValue > range.max) {
      problems.push({
        path: path("newIntValue"),
        message: `${range.field} must be between ${range.min} and ${range.max}`,
      });
    }
    if (operation.expectedIntValue === undefined) {
      problems.push({
        path: path("expectedIntValue"),
        message: "expectedIntValue is required for this operation kind",
      });
    }
  };

  switch (operation.kind) {
    case "replaceExerciseReps": {
      const location = requireExercise();
      requireIntInRange("replaceExerciseReps");
      if (location) {
        const exercise = routine.sections[location.sectionIndex]?.exercises[location.exerciseIndex];
        if (exercise?.durationSeconds !== undefined) {
          problems.push({
            path: path("kind"),
            message: "exercise is timed; use replaceTimedDuration instead of replaceExerciseReps",
          });
        }
      }
      break;
    }
    case "replaceExerciseSets": {
      requireExercise();
      requireIntInRange("replaceExerciseSets");
      break;
    }
    case "replaceTimedDuration": {
      const location = requireExercise();
      requireIntInRange("replaceTimedDuration");
      if (location) {
        const exercise = routine.sections[location.sectionIndex]?.exercises[location.exerciseIndex];
        if (exercise?.durationSeconds === undefined) {
          problems.push({ path: path("kind"), message: "exercise is not timed; has no durationSeconds to replace" });
        }
      }
      break;
    }
    case "replaceRestBetweenSets": {
      requireExercise();
      requireIntInRange("replaceRestBetweenSets");
      break;
    }
    case "replaceRestAfterExercise": {
      requireExercise();
      requireIntInRange("replaceRestAfterExercise");
      break;
    }
    case "updateExerciseNotes": {
      requireExercise();
      if (operation.newStringValue === undefined) {
        problems.push({ path: path("newStringValue"), message: "newStringValue is required for this operation kind" });
      } else if (operation.newStringValue.length > 500) {
        problems.push({ path: path("newStringValue"), message: "notes must be 500 characters or fewer" });
      }
      if (operation.expectedStringValue === undefined) {
        problems.push({
          path: path("expectedStringValue"),
          message: "expectedStringValue is required for this operation kind",
        });
      }
      break;
    }
    case "addExercise": {
      if (!operation.sectionId) {
        problems.push({ path: path("sectionId"), message: "sectionId is required for addExercise" });
      } else if (findSectionIndex(routine, operation.sectionId) === -1) {
        problems.push({ path: path("sectionId"), message: `no section matches ${operation.sectionId}` });
      }
      if (!operation.exercise) {
        problems.push({ path: path("exercise"), message: "exercise is required for addExercise" });
      } else {
        const exercise = operation.exercise;
        if (exercise.name.trim().length === 0) {
          problems.push({ path: path("exercise.name"), message: "exercise.name must not be empty" });
        }
        if (exercise.sets < 1 || exercise.sets > 10) {
          problems.push({ path: path("exercise.sets"), message: "exercise.sets must be between 1 and 10" });
        }
        if (exercise.reps < 1 || exercise.reps > 100) {
          problems.push({ path: path("exercise.reps"), message: "exercise.reps must be between 1 and 100" });
        }
        if (
          exercise.durationSeconds !== undefined &&
          (exercise.durationSeconds < 1 || exercise.durationSeconds > 3600)
        ) {
          problems.push({
            path: path("exercise.durationSeconds"),
            message: "exercise.durationSeconds must be between 1 and 3600",
          });
        }
        if (exercise.restBetweenSetsSeconds < 0 || exercise.restBetweenSetsSeconds > 900) {
          problems.push({
            path: path("exercise.restBetweenSetsSeconds"),
            message: "exercise.restBetweenSetsSeconds must be between 0 and 900",
          });
        }
        if (exercise.restAfterExerciseSeconds < 0 || exercise.restAfterExerciseSeconds > 900) {
          problems.push({
            path: path("exercise.restAfterExerciseSeconds"),
            message: "exercise.restAfterExerciseSeconds must be between 0 and 900",
          });
        }
        if (exercise.notes.length > 500) {
          problems.push({ path: path("exercise.notes"), message: "exercise.notes must be 500 characters or fewer" });
        }
        if (findExercise(routine, exercise.id)) {
          problems.push({
            path: path("exercise.id"),
            message: `exercise id ${exercise.id} already exists in this routine`,
          });
        }
      }
      if (operation.afterExerciseId && !findExercise(routine, operation.afterExerciseId)) {
        problems.push({
          path: path("afterExerciseId"),
          message: `no exercise matches ${operation.afterExerciseId}`,
        });
      }
      break;
    }
    case "removeExercise": {
      requireExercise();
      if (operation.expectedStringValue === undefined) {
        problems.push({
          path: path("expectedStringValue"),
          message: "expectedStringValue (the exercise name) is required for removeExercise",
        });
      }
      break;
    }
    case "moveExercise": {
      requireExercise();
      if (!operation.targetSectionId) {
        problems.push({ path: path("targetSectionId"), message: "targetSectionId is required for moveExercise" });
      } else if (findSectionIndex(routine, operation.targetSectionId) === -1) {
        problems.push({ path: path("targetSectionId"), message: `no section matches ${operation.targetSectionId}` });
      }
      if (operation.afterExerciseId && !findExercise(routine, operation.afterExerciseId)) {
        problems.push({
          path: path("afterExerciseId"),
          message: `no exercise matches ${operation.afterExerciseId}`,
        });
      }
      break;
    }
    case "replacePhaseOverride": {
      requireExercise();
      if (!operation.phase) {
        problems.push({ path: path("phase"), message: "phase is required for replacePhaseOverride" });
      } else if (operation.phase === "base") {
        problems.push({ path: path("phase"), message: "base does not use phase overrides" });
      }
      if (operation.removePhaseOverride !== true && !operation.newPhaseOverride) {
        problems.push({
          path: path("newPhaseOverride"),
          message: "newPhaseOverride is required unless removePhaseOverride is true",
        });
      }
      if (operation.newPhaseOverride) {
        const override = operation.newPhaseOverride;
        if (override.sets !== undefined && (override.sets < 1 || override.sets > 10)) {
          problems.push({ path: path("newPhaseOverride.sets"), message: "phaseOverride.sets must be between 1 and 10" });
        }
        if (override.reps !== undefined && (override.reps < 1 || override.reps > 100)) {
          problems.push({ path: path("newPhaseOverride.reps"), message: "phaseOverride.reps must be between 1 and 100" });
        }
        if (
          override.durationSeconds !== undefined &&
          (override.durationSeconds < 1 || override.durationSeconds > 3600)
        ) {
          problems.push({
            path: path("newPhaseOverride.durationSeconds"),
            message: "phaseOverride.durationSeconds must be between 1 and 3600",
          });
        }
      }
      break;
    }
  }

  return problems;
}

/**
 * Validates a raw (`unknown`) payload as a FlowRoutinePatch schema 2 against
 * the routines known to `lookup`. Never throws — every failure mode becomes
 * a `PatchProblem` entry. This is what both `validate_flow_routine_patch`
 * and `create_pending_routine_patch` call.
 */
export function validateFlowRoutinePatch(
  rawPatch: unknown,
  lookup: RoutineLookup
): PatchValidationResult & { patch?: FlowRoutinePatch } {
  const problems: PatchProblem[] = [];

  const parsed = flowRoutinePatchSchema.safeParse(rawPatch);
  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      problems.push({ path: issue.path.join(".") || "(root)", message: issue.message });
    }
    // A schema failure on schemaVersion/required fields is fatal; there is no
    // well-typed patch to run routine-aware checks against.
    return { valid: false, problems };
  }
  const patch = parsed.data;

  const routine = lookup.getRoutine(patch.routineId);
  if (!routine) {
    problems.push({ path: "routineId", message: `no stored routine matches ${patch.routineId}` });
    return { valid: false, problems, patch };
  }

  const storedHash = lookup.getContentHash(patch.routineId);
  if (storedHash !== undefined && storedHash !== patch.baseContentHash) {
    problems.push({
      path: "baseContentHash",
      message: `patch is stale: expected ${storedHash}, patch carries ${patch.baseContentHash}`,
    });
  }

  patch.operations.forEach((operation, index) => {
    // Re-validate each operation with zod first so a structurally odd
    // operation (e.g. extra fields under strict mode) surfaces per-index.
    const opResult = patchOperationSchema.safeParse(operation);
    if (!opResult.success) {
      for (const issue of opResult.error.issues) {
        problems.push({ path: `operations[${index}].${issue.path.join(".")}`, message: issue.message });
      }
      return;
    }
    problems.push(...validateOperation(operation, index, routine));
  });

  return { valid: problems.length === 0, problems, patch };
}
