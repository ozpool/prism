import {createServer, type Server} from "node:http";
import type {Logger} from "pino";

import type {Metrics} from "./metrics.js";

export interface HealthDeps {
  port: number;
  logger: Logger;
  metrics: Metrics;
}

/// Start the lifecycle HTTP server: GET /health and GET /metrics.
///
/// /health returns 200 OK with a tiny JSON body once the keeper has
/// completed at least one cycle (so a freshly-started container that
/// can't reach the RPC fails the first health probe and gets restarted
/// rather than masquerading as healthy). The cycle-count check is
/// computed off the live Metrics snapshot.
///
/// /metrics returns the same Metrics snapshot in JSON. A Prometheus
/// text exporter is a follow-up — the JSON shape is sufficient for
/// the Fly.io health check + ad-hoc curl debugging that #60 targets.
///
/// Returns the Server so the caller can shut it down on SIGTERM.
export function startHealthServer(deps: HealthDeps): Server {
  const {port, logger, metrics} = deps;

  const server = createServer((req, res) => {
    if (req.method !== "GET") {
      res.writeHead(405, {"content-type": "text/plain"}).end("method not allowed");
      return;
    }

    if (req.url === "/health") {
      const snapshot = metrics.snapshot();
      const healthy = snapshot.cycleCount > 0;
      const body = JSON.stringify({
        status: healthy ? "ok" : "starting",
        uptimeMs: snapshot.uptimeMs,
        cycleCount: snapshot.cycleCount,
        cycleErrors: snapshot.cycleErrors,
      });
      res.writeHead(healthy ? 200 : 503, {"content-type": "application/json"}).end(body);
      return;
    }

    if (req.url === "/metrics") {
      res.writeHead(200, {"content-type": "application/json"}).end(JSON.stringify(metrics.snapshot()));
      return;
    }

    res.writeHead(404, {"content-type": "text/plain"}).end("not found");
  });

  server.listen(port, () => {
    logger.info({port}, "health server listening");
  });

  return server;
}

/// Wraps server.close in a Promise so the lifecycle code can await
/// graceful shutdown alongside the poll-loop drain.
export function stopHealthServer(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((err) => (err ? reject(err) : resolve()));
  });
}
