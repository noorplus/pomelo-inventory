import { getCache } from "@vercel/functions";
import type { SupabaseClient } from "@supabase/supabase-js";

type UnitOfMeasure = {
  id: string;
  name: string;
  status: string;
  created_at?: string;
};

function cacheKey(organizationId: string, userId: string) {
  return `pomelo:uom:${organizationId}:${userId}`;
}

function cacheTag(organizationId: string, userId: string) {
  return `pomelo-uom-${organizationId}-${userId}`;
}

export async function getCachedUnitsOfMeasure(
  supabase: SupabaseClient,
  organizationId: string,
  userId: string,
) {
  const cache = getCache();
  const key = cacheKey(organizationId, userId);
  const cached = await cache.get(key) as UnitOfMeasure[] | undefined;

  if (cached) return cached;

  const { data, error } = await supabase
    .from("units_of_measure")
    .select("id, name, status, created_at")
    .eq("organization_id", organizationId)
    .order("name");

  if (error) throw new Error(error.message);

  const units = data ?? [];
  await cache.set(key, units, {
    ttl: 60,
    tags: [cacheTag(organizationId, userId)],
    name: "organization-uom",
  });

  return units;
}

export async function invalidateCachedUnitsOfMeasure(
  organizationId: string,
  userId: string,
) {
  await getCache().expireTag(cacheTag(organizationId, userId));
}
