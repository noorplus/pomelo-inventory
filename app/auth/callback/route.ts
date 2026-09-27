import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = url.searchParams.get("next");

  let safeNext = "/";
  if (next) {
    try {
      const candidate = new URL(next, url.origin);
      if (candidate.origin === url.origin) {
        safeNext = candidate.pathname + candidate.search + candidate.hash;
      }
    } catch {
      // Invalid redirect targets fall back to the application root.
    }
  }

  if (!code) {
    return NextResponse.redirect(new URL("/login?error=missing_code", url.origin));
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    return NextResponse.redirect(new URL("/login?error=confirmation_failed", url.origin));
  }

  return NextResponse.redirect(new URL(safeNext, url.origin));
}
