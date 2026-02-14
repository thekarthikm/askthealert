/**
 * Console authentication middleware.
 *
 * Validates the Authorization header against the shared secret.
 * Even for hackathon demo, endpoints are protected so nobody can
 * spam pushes or read telemetry without the secret.
 *
 * Usage: router.use(requireConsoleAuth) on protected route groups.
 */

import type { Request, Response, NextFunction } from "express";
import { env } from "../config/env.js";

export function requireConsoleAuth(
  req: Request,
  res: Response,
  next: NextFunction
): void {
  const authHeader = req.headers.authorization;

  if (!authHeader) {
    res.status(401).json({ error: "Missing Authorization header" });
    return;
  }

  // Accept "Bearer <secret>" format
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice(7)
    : authHeader;

  if (token !== env.CONSOLE_AUTH_SECRET) {
    res.status(403).json({ error: "Invalid credentials" });
    return;
  }

  next();
}
