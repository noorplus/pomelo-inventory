import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCachedWorkspaceReferenceData } from "@/lib/cache/reference-data";

export const getWorkspaceContext = cache(async () => {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) redirect("/auth/login");

  const { data: sessionData } = await supabase.auth.getSession();
  const accessToken = sessionData.session?.access_token;
  if (!accessToken) redirect("/auth/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const { organization, profile } = await getCachedWorkspaceReferenceData(
    organizationId,
    user.id,
    accessToken,
  );

  return { supabase, user, organizationId, organization, profile, accessToken };
});
