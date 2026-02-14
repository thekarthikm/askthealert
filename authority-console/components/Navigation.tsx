/**
 * Navigation — top bar for the Authority Console.
 *
 * Shows navigation links, backend status indicator, and logout button.
 */

"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { checkHealth } from "../lib/api";

interface NavigationProps {
  onLogout: () => void;
}

export function Navigation({ onLogout }: NavigationProps) {
  const pathname = usePathname();
  const [backendOnline, setBackendOnline] = useState<boolean | null>(null);

  useEffect(() => {
    let mounted = true;
    const check = async () => {
      try {
        await checkHealth();
        if (mounted) setBackendOnline(true);
      } catch {
        if (mounted) setBackendOnline(false);
      }
    };
    check();
    const interval = setInterval(check, 30_000);
    return () => {
      mounted = false;
      clearInterval(interval);
    };
  }, []);

  const links = [
    { href: "/", label: "Dashboard" },
    { href: "/incidents", label: "Incidents" },
    { href: "/alerts/new", label: "Send Alert" },
    { href: "/updates", label: "Publish Update" },
  ];

  return (
    <nav className="bg-white border-b border-gray-200 px-6 py-3 flex items-center justify-between">
      <div className="flex items-center gap-6">
        <Link href="/" className="flex items-center gap-2">
          <span className="text-xl font-bold text-red-600">⚠️ Ask the Alert</span>
          <span className="text-sm text-gray-500">Authority Console</span>
        </Link>

        <div className="flex items-center gap-1 ml-4">
          {links.map((link) => {
            const active =
              link.href === "/"
                ? pathname === "/"
                : pathname.startsWith(link.href);
            return (
              <Link
                key={link.href}
                href={link.href}
                className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                  active
                    ? "bg-red-50 text-red-700"
                    : "text-gray-600 hover:text-gray-900 hover:bg-gray-50"
                }`}
              >
                {link.label}
              </Link>
            );
          })}
        </div>
      </div>

      <div className="flex items-center gap-4">
        {/* Backend status */}
        <div className="flex items-center gap-2 text-xs">
          <span
            className={`w-2 h-2 rounded-full ${
              backendOnline === null
                ? "bg-gray-300"
                : backendOnline
                ? "bg-green-500"
                : "bg-red-500"
            }`}
          />
          <span className="text-gray-500">
            Backend {backendOnline === null ? "" : backendOnline ? "Online" : "Offline"}
          </span>
        </div>

        <button
          onClick={onLogout}
          className="text-sm text-gray-500 hover:text-gray-700 transition-colors"
        >
          Sign Out
        </button>
      </div>
    </nav>
  );
}
