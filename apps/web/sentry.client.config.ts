// Sentry — browser. Loads on every page. No-op when DSN unset so
// local dev / preview builds don't fail open with an obvious sample
// project. DSN is exposed via NEXT_PUBLIC_SENTRY_DSN because Next.js
// only inlines NEXT_PUBLIC_* into the client bundle.

import * as Sentry from "@sentry/nextjs";

const dsn = process.env.NEXT_PUBLIC_SENTRY_DSN;

if (dsn) {
  Sentry.init({
    dsn,
    tracesSampleRate: 0,
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 0,
    environment: process.env.NEXT_PUBLIC_SENTRY_ENV ?? process.env.NODE_ENV,
    release: process.env.NEXT_PUBLIC_SENTRY_RELEASE,
  });
}
