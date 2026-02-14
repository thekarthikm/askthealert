/**
 * ClientShell — wraps the entire app in AuthProvider + LoginGate + Navigation.
 *
 * This is a client component boundary because AuthProvider requires context.
 * The root layout.tsx stays a server component.
 */

"use client";

import { AuthProvider, useAuth } from "../lib/auth";
import { LoginGate } from "./LoginGate";
import { Navigation } from "./Navigation";

export function ClientShell({ children }: { children: React.ReactNode }) {
  return (
    <AuthProvider>
      <LoginGate>
        <AuthenticatedShell>{children}</AuthenticatedShell>
      </LoginGate>
    </AuthProvider>
  );
}

function AuthenticatedShell({ children }: { children: React.ReactNode }) {
  const { logout } = useAuth();

  return (
    <>
      <Navigation onLogout={logout} />
      <main className="max-w-7xl mx-auto px-6 py-8">{children}</main>
    </>
  );
}
