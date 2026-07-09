/**
 * In-memory store for the latest Flow coach context, plus the lean
 * projection `get_flow_coach_context` returns.
 *
 * Prototype-only: a real bridge (#37/#38) replaces this with whatever the
 * managed/serverless storage decision lands on. The shape of what is stored
 * and returned — full FlowCoachContext in, lean summary out — should carry
 * forward.
 */
import { randomUUID } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  flowCoachContextSchema,
  type FlowCoachContext,
  type FlowCoachCardioSummary,
  type FlowCoachStrengthSummary,
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
  /** Opaque identity for the snapshot the assistant is reading. */
  contextId: string;
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

type StrengthSummaryWithoutHealthMetrics = Omit<FlowCoachStrengthSummary, "appleWatchMetrics">;
type CardioSummaryWithoutHealthMetrics = Omit<FlowCoachCardioSummary, "averageHeartRate" | "maxHeartRate">;

export interface RecentTrainingSummary {
  contextId: string;
  generatedAt: string;
  includesHealthMetrics: boolean;
  strength: Array<FlowCoachStrengthSummary | StrengthSummaryWithoutHealthMetrics>;
  cardio: Array<FlowCoachCardioSummary | CardioSummaryWithoutHealthMetrics>;
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
  private contextId: string;

  constructor(initial: FlowCoachContext = loadInitialContext(), contextId: string = randomUUID()) {
    this.context = initial;
    this.contextId = contextId;
  }

  /** Replaces the stored context wholesale, as a future "Flow pushes latest context" call would. */
  replaceContext(context: FlowCoachContext, contextId: string = randomUUID()): string {
    this.context = context;
    this.contextId = contextId;
    return this.contextId;
  }

  getFullContext(): FlowCoachContext {
    return this.context;
  }

  getContextId(): string {
    return this.contextId;
  }

  isCurrentContextId(contextId: string): boolean {
    return this.contextId === contextId;
  }

  getLeanContext(): LeanCoachContext {
    return {
      contextId: this.contextId,
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

  getRecentTrainingSummary(options: {
    strengthLimit?: number;
    cardioLimit?: number;
    includeHealthMetrics?: boolean;
  } = {}): RecentTrainingSummary {
    const strengthLimit = Math.min(Math.max(options.strengthLimit ?? 5, 1), 10);
    const cardioLimit = Math.min(Math.max(options.cardioLimit ?? 5, 1), 12);
    const includeHealthMetrics = options.includeHealthMetrics === true;

    const strength = this.context.recentStrengthSummary.slice(0, strengthLimit).map((entry) => {
      if (includeHealthMetrics) return entry;
      const { appleWatchMetrics: _healthMetrics, ...summary } = entry;
      return summary;
    });
    const cardio = this.context.recentCardioSummary.slice(0, cardioLimit).map((entry) => {
      if (includeHealthMetrics) return entry;
      const { averageHeartRate: _averageHeartRate, maxHeartRate: _maxHeartRate, ...summary } = entry;
      return summary;
    });

    return {
      contextId: this.contextId,
      generatedAt: this.context.generatedAt,
      includesHealthMetrics: includeHealthMetrics,
      strength,
      cardio,
    };
  }

  // --- RoutineLookup (used by patch validation) ---

  getRoutine(routineId: string): Routine | undefined {
    return this.context.routines.find((routine) => routine.id === routineId);
  }

  getContentHash(routineId: string): string | undefined {
    return this.context.routineContentHashByRoutineId[routineId];
  }
}
