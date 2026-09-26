import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export const getWorkspaceContext = cache(async () => {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;

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
