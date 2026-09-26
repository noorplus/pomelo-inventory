import { unstable_cache } from "next/cache";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";

type WorkspaceReferenceData = {
  organization: {
    id: string;
    organization_number: number;
    organization_name: string;
    email: string | null;
    phone_number: string;
    address: string;
    tin: string | null;
    bin: string | null;
    status: string;
    created_at: string;
  } | null;
  profile: { full_name: string | null } | null;
};

type UnitOfMeasure = {
  id: string;
  name: string;
  status: string;
  created_at?: string;
};

function createTokenClient(accessToken: string) {
  return createSupabaseClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    },
  );
}

export async function getCachedWorkspaceReferenceData(
  organizationId: string,
  userId: string,
  accessToken: string,
) {
  const getCached = unstable_cache(
    async (): Promise<WorkspaceReferenceData> => {
      const supabase = createTokenClient(accessToken);

      const [{ data: organization }, { data: profile }] = await Promise.all([
        supabase
          .from("organizations")
          .select("id, organization_number, organization_name, email, phone_number, address, tin, bin, status, created_at")
          .eq("id", organizationId)
          .single(),
        supabase.from("profiles").select("full_name").eq("id", userId).single(),
      ]);

      return { organization, profile };
    },
    ["workspace-reference", organizationId, userId, accessToken],
    {
      revalidate: 300,
      tags: [`workspace-reference:${organizationId}:${userId}`],
    },
  );

  return getCached();
}

export async function getCachedUnitsOfMeasure(
  organizationId: string,
  accessToken: string,
) {
  const getCached = unstable_cache(
    async (): Promise<UnitOfMeasure[]> => {
      const supabase = createTokenClient(accessToken);

      const { data, error } = await supabase
        .from("units_of_measure")
        .select("id, name, status, created_at")
        .eq("organization_id", organizationId)
        .order("name");

      if (error) throw new Error(error.message);
      return data ?? [];
    },
    ["organization-uom", organizationId, accessToken],
    {
      revalidate: 60,
      tags: [`uom:${organizationId}`],
    },
  );

  return getCached();
}
