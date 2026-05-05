// Sentry — Next.js server runtime (Node). Captures errors thrown
// inside route handlers, server components, and middleware that runs
// in the Node runtime.

import * as Sentry from "@sentry/nextjs";

const dsn = process.env.SENTRY_DSN;

if (dsn) {
  Sentry.init({
    dsn,
    tracesSampleRate: 0,
    environment: process.env.SENTRY_ENV ?? process.env.NODE_ENV,
    release: process.env.SENTRY_RELEASE,
  });
}
