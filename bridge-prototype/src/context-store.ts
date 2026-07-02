/**
 * In-memory store for the latest Flow coach context, plus the lean
 * projection `get_flow_coach_context` returns.
 *
 * Prototype-only: a real bridge (#37/#38) replaces this with whatever the
 * managed/serverless storage decision lands on. The shape of what is stored
 * and returned — full FlowCoachContext in, lean summary out — should carry
 * forward.
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  flowCoachContextSchema,
  type FlowCoachContext,
  type Routine,
} from "./flow-types.js";
import type { RoutineLookup } from "./patch-validation.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = join(__dirname, "..", "fixtures");

/** Lean routine summary — id, name, phase, hashes, exercise counts. No exercise bodies. */
export interface RoutineSummary {
  id: string;
  name: string;
  currentPhase: string;
  sectionCount: number;
  exerciseCount: number;
  contentHash: string;
  stateHash: string;
}

/** The payload `get_flow_coach_context` returns. Deliberately lean: see README "payload size" note. */
export interface LeanCoachContext {
  generatedAt: string;
  app: string;
  routines: RoutineSummary[];
  recentStrengthSummaryCount: number;
  recentCardioSummaryCount: number;
  /** Short digests, not full summaries — enough for the assistant to ask a follow-up via list_routines/get_routine. */
  recentStrengthDigest: string[];
  recentCardioDigest: string[];
  constraintsNotes: string | undefined;
}

function loadFixture(filename: string): FlowCoachContext {
  const path = join(FIXTURES_DIR, filename);
  const raw = readFileSync(path, "utf-8");
  const parsed = flowCoachContextSchema.parse(JSON.parse(raw));
  return parsed;
}

/**
 * Picks the local override fixture if present (a real export dropped in by
 * Alex for the phone smoke test — see fixtures/coach-context.local.json in
 * the README), otherwise falls back to the committed fixture built from
 * RoutineStore.swift's two seed routines.
 */
function loadInitialContext(): FlowCoachContext {
  const localPath = join(FIXTURES_DIR, "coach-context.local.json");
  if (existsSync(localPath)) {
    return loadFixture("coach-context.local.json");
  }
  return loadFixture("coach-context.json");
}

function summarizeRoutine(routine: Routine, context: FlowCoachContext): RoutineSummary {
  const exerciseCount = routine.sections.reduce((sum, section) => sum + section.exercises.length, 0);
  return {
    id: routine.id,
    name: routine.name,
    currentPhase: context.currentPhaseByRoutineId[routine.id] ?? routine.currentPhase,
    sectionCount: routine.sections.length,
    exerciseCount,
    contentHash: context.routineContentHashByRoutineId[routine.id] ?? "c1-unknown",
    stateHash: context.routineStateHashByRoutineId[routine.id] ?? "s1-unknown",
  };
}

function digestStrength(context: FlowCoachContext): string[] {
  return context.recentStrengthSummary
    .slice(0, 5)
    .map((entry) => `${entry.date}: ${entry.routineName} (${entry.phase}) - ${entry.ratings.good} good, ${entry.ratings.easy} easy, ${entry.ratings.failed} failed`);
}

function digestCardio(context: FlowCoachContext): string[] {
  return context.recentCardioSummary
    .slice(0, 5)
    .map((entry) => `${entry.date}: ${entry.activity} ${(entry.distanceMetres / 1000).toFixed(2)}km in ${Math.round(entry.durationSeconds / 60)}min`);
}

export class ContextStore implements RoutineLookup {
  private context: FlowCoachContext;

  constructor(initial: FlowCoachContext = loadInitialContext()) {
    this.context = initial;
  }

  /** Replaces the stored context wholesale, as a future "Flow pushes latest context" call would. */
  replaceContext(context: FlowCoachContext): void {
    this.context = context;
  }

  getFullContext(): FlowCoachContext {
    return this.context;
  }

  getLeanContext(): LeanCoachContext {
    return {
      generatedAt: this.context.generatedAt,
      app: this.context.app,
      routines: this.context.routines.map((routine) => summarizeRoutine(routine, this.context)),
      recentStrengthSummaryCount: this.context.recentStrengthSummary.length,
      recentCardioSummaryCount: this.context.recentCardioSummary.length,
      recentStrengthDigest: digestStrength(this.context),
      recentCardioDigest: digestCardio(this.context),
      constraintsNotes: this.context.constraints?.notes,
    };
  }

  listRoutineSummaries(): RoutineSummary[] {
    return this.context.routines.map((routine) => summarizeRoutine(routine, this.context));
  }

  // --- RoutineLookup (used by patch validation) ---

  getRoutine(routineId: string): Routine | undefined {
    return this.context.routines.find((routine) => routine.id === routineId);
  }

  getContentHash(routineId: string): string | undefined {
    return this.context.routineContentHashByRoutineId[routineId];
  }
}
