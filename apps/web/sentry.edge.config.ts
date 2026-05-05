// Sentry — Next.js edge runtime. Captures errors thrown inside
// middleware running on the edge runtime. Subset of the Node SDK.

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
