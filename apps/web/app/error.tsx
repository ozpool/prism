"use client";

import {useEffect} from "react";

// Route-level error boundary. Caught errors render this page inside the
// app shell (Header + Footer remain mounted). Uncaught errors during the
// initial render bubble up to global-error.tsx instead.
export default function RouteError({
  error,
  reset,
}: {
  error: Error & {digest?: string};
  reset: () => void;
}) {
  useEffect(() => {
    // Surface during dev; replace with a real telemetry sink (Sentry, etc.)
    // when telemetry lands.
    console.error("[prism] route error", error);
  }, [error]);

  return (
    <div className="flex flex-col items-start gap-4 py-12">
      <span className="inline-flex items-center gap-2 rounded-pill border border-danger/40 bg-danger/10 px-3 py-1 text-xs text-danger">
        <span className="h-1.5 w-1.5 rounded-pill bg-danger" />
        Something went wrong
      </span>
      <h1 className="text-2xl font-semibold tracking-tight text-text">
        We couldn&apos;t load this page
      </h1>
      <p className="max-w-prose text-sm text-text-muted">
        {error.message || "An unexpected error occurred while rendering."}
        {error.digest ? <span className="ml-2 font-mono text-xs text-text-faint">[{error.digest}]</span> : null}
      </p>
      <button
        type="button"
        onClick={reset}
        className="mt-2 rounded-md border border-border-strong bg-surface px-4 py-2 text-sm text-text transition-colors duration-fast ease-standard hover:bg-surface-raised"
      >
        Try again
      </button>
    </div>
  );
}
