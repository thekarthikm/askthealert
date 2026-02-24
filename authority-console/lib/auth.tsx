/**
 * Authentication context for the Authority Console.
 *
 * Uses a shared secret (demo-friendly) stored in session storage.
 * The login gate validates the secret against the backend before granting access.
 * Even for demo, every endpoint is protected — no open access to push or telemetry.
 *
 * ⚠️ SECURITY LIMITATION (HACKATHON ONLY):
 * Storing auth secrets in sessionStorage is vulnerable to XSS attacks.
 * SessionStorage is accessible via JavaScript and visible in browser dev tools.
 *
 * For production, migrate to:
 * - httpOnly cookies (not accessible via JS, safer from XSS)
 * - Short-lived JWT tokens with refresh mechanism
 * - OAuth2/OIDC with proper token rotation
 * - Or reverse proxy authentication (e.g., Cloudflare Access)
 *
 * This implementation is acceptable for local development/demo where:
 * - Console runs on localhost (not exposed to internet)
 * - Shared secret is rotated after demo
 * - No user PII or critical operations depend on this auth
 */

"use client";

import {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
  type ReactNode,
} from "react";

interface AuthState {
  /** Whether the user is authenticated. */
  isAuthenticated: boolean;
  /** Whether auth state is still loading (checking session). */
  isLoading: boolean;
  /** Log in with the shared secret. Returns true on success. */
  login: (secret: string) => Promise<boolean>;
  /** Log out and clear session. */
  logout: () => void;
}

const AuthContext = createContext<AuthState>({
  isAuthenticated: false,
  isLoading: true,
  login: async () => false,
  logout: () => {},
});

const SESSION_KEY = "askthealert_console_auth";
const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:3001";

export function AuthProvider({ children }: { children: ReactNode }) {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isLoading, setIsLoading] = useState(true);

  // Check session on mount
  useEffect(() => {
    const stored = sessionStorage.getItem(SESSION_KEY);
    if (stored) {
      // Verify the stored secret is still valid
      verifySecret(stored).then((valid) => {
        setIsAuthenticated(valid);
        if (!valid) sessionStorage.removeItem(SESSION_KEY);
        setIsLoading(false);
      });
    } else {
      setIsLoading(false);
    }
  }, []);

  const login = useCallback(async (secret: string): Promise<boolean> => {
    const valid = await verifySecret(secret);
    if (valid) {
      // SECURITY NOTE: sessionStorage is vulnerable to XSS (see file header for production alternatives)
      // For hackathon demo on localhost, this is acceptable with understanding of limitations
      sessionStorage.setItem(SESSION_KEY, secret);
      // Also set it for the API client env
      (window as unknown as Record<string, unknown>).__AUTH_SECRET = secret;
      setIsAuthenticated(true);
    }
    return valid;
  }, []);

  const logout = useCallback(() => {
    sessionStorage.removeItem(SESSION_KEY);
    setIsAuthenticated(false);
  }, []);

  return (
    <AuthContext.Provider value={{ isAuthenticated, isLoading, login, logout }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthState {
  return useContext(AuthContext);
}

/** Get the stored auth secret (for API calls). */
export function getStoredSecret(): string {
  if (typeof window === "undefined") return "";
  return sessionStorage.getItem(SESSION_KEY) ?? process.env.NEXT_PUBLIC_AUTH_SECRET ?? "";
}

/** Verify a secret against the backend. */
async function verifySecret(secret: string): Promise<boolean> {
  try {
    const res = await fetch(`${API_URL}/incidents?limit=1`, {
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${secret}`,
      },
    });
    return res.ok;
  } catch {
    // If backend is unreachable, accept if env var matches (offline dev)
    return secret === process.env.NEXT_PUBLIC_AUTH_SECRET && secret.length > 0;
  }
}
