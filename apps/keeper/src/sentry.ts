// Sentry wiring for the keeper. Init is a no-op when SENTRY_DSN is
// unset so local dev / tests don't need a project. Production sets
// the DSN via fly secrets (`fly secrets set SENTRY_DSN=...`).
//
// What we capture:
//   - Unhandled exceptions and rejections (at the process level —
//     these end up in `index.ts` main().catch and would otherwise
//     just log via pino).
//   - Explicit `captureException` calls in poll/sim/submit error
//     handlers for non-fatal but surprising conditions.
//
// What we deliberately don't capture:
//   - Reverts on simulation (those are expected — the gate exists to
//     filter them out before broadcast).
//   - 4xx-class RPC errors during normal polling (e.g. node throttling).

import * as Sentry from "@sentry/node";

let initialized = false;

export function initSentry(opts: {release?: string; environment?: string}): void {
  const dsn = process.env.SENTRY_DSN;
  if (!dsn) return;
  Sentry.init({
    dsn,
    release: opts.release,
    environment: opts.environment ?? process.env.NODE_ENV ?? "development",
    tracesSampleRate: 0,
    integrations: [Sentry.httpIntegration()],
  });
  initialized = true;
}

export function captureException(err: unknown, context?: Record<string, unknown>): void {
  if (!initialized) return;
  Sentry.captureException(err, context ? {extra: context} : undefined);
}

export function captureMessage(msg: string, context?: Record<string, unknown>): void {
  if (!initialized) return;
  Sentry.captureMessage(msg, context ? {extra: context} : undefined);
}

export async function flushSentry(timeoutMs = 2_000): Promise<void> {
  if (!initialized) return;
  await Sentry.flush(timeoutMs);
}
