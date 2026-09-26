type UnitOfMeasure = {
  id: string;
  name: string;
  status: string;
  created_at?: string;
};

type CacheEntry = {
  expiresAt: number;
  units: UnitOfMeasure[];
};

const UOM_TTL_MS = 60_000;
const uomCache = new Map<string, CacheEntry>();

function cacheKey(organizationId: string, accessToken: string) {
  return `${organizationId}:${accessToken}`;
}

export async function getCachedUnitsOfMeasure(
  organizationId: string,
  accessToken: string,
) {
  const key = cacheKey(organizationId, accessToken);
  const now = Date.now();
  const cached = uomCache.get(key);

  if (cached && cached.expiresAt > now) {
    return cached.units;
  }

  if (cached) uomCache.delete(key);

  const { createClient: createSupabaseClient } = await import("@supabase/supabase-js");
  const supabase = createSupabaseClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    },
  );

  const { data, error } = await supabase
    .from("units_of_measure")
    .select("id, name, status, created_at")
    .eq("organization_id", organizationId)
    .order("name");

  if (error) throw new Error(error.message);

  const units = data ?? [];
  uomCache.set(key, { units, expiresAt: now + UOM_TTL_MS });

  return units;
}

export function invalidateCachedUnitsOfMeasure(
  organizationId: string,
  accessToken: string,
) {
  uomCache.delete(cacheKey(organizationId, accessToken));
}
