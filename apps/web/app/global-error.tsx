"use client";

// Root-level error boundary. Renders only when the root layout itself
// fails (i.e. something below <Providers> threw before the AppShell could
// mount). Must define its own <html>/<body> because Next replaces the root.
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & {digest?: string};
  reset: () => void;
}) {
  return (
    <html lang="en" className="dark">
      <body
        style={{
          background: "#0c0a14",
          color: "#ebe5d5",
          minHeight: "100vh",
          margin: 0,
          fontFamily:
            "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          padding: "2rem",
        }}
      >
        <div style={{maxWidth: 480}}>
          <h1 style={{fontSize: 24, fontWeight: 600, marginBottom: 12}}>
            PRISM failed to start
          </h1>
          <p style={{color: "#9890b0", fontSize: 14, marginBottom: 16}}>
            {error.message || "An unexpected error occurred."}
            {error.digest ? <span style={{marginLeft: 8, fontFamily: "ui-monospace, monospace", fontSize: 12, color: "#696382"}}>[{error.digest}]</span> : null}
          </p>
          <button
            type="button"
            onClick={reset}
            style={{
              background: "#15121f",
              color: "#ebe5d5",
              border: "1px solid #352d4e",
              padding: "8px 16px",
              borderRadius: 10,
              fontSize: 14,
              cursor: "pointer",
            }}
          >
            Reload
          </button>
        </div>
      </body>
    </html>
  );
}
