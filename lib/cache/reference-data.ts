import { unstable_cache } from "next/cache";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";

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
