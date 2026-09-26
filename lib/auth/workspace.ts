import { cache } from "react";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export const ACTIVE_ORG_COOKIE = "pomelo_active_org";

export const getWorkspaceMembership = cache(async () => {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(50);

  if (!memberships?.length) redirect("/organization/create");

  const ids = memberships.map((m) => m.organization_id);
  // Honor an explicit workspace switch when it still belongs to the user.
  const cookieStore = await cookies();
  const preferred = cookieStore.get(ACTIVE_ORG_COOKIE)?.value;
  const organizationId = preferred && ids.includes(preferred) ? preferred : ids[0];

  return {
    supabase,
    user,
    organizationId,
    organizationIds: ids,
  };
});

export const getWorkspaceContext = cache(async () => {
  const { supabase, user, organizationId } = await getWorkspaceMembership();

  const [{ data: organization }, { data: profile }] = await Promise.all([
    supabase
      .from("organizations")
      .select("id, organization_number, organization_name, email, phone_number, address, tin, bin, status, created_at")
      .eq("id", organizationId)
      .single(),
    supabase.from("profiles").select("full_name").eq("id", user.id).single(),
  ]);

  return { supabase, user, organizationId, organization, profile };
});
