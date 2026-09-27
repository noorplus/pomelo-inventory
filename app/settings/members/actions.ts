"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { getWorkspaceMembership } from "@/lib/auth/workspace";

function go(message?: string): never {
  redirect(message ? `/settings/members?error=${encodeURIComponent(message)}` : "/settings/members");
}

export async function addMember(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const email = String(formData.get("email") || "").trim();
  if (!email) go("email-required");
  const { error } = await supabase.rpc("add_organization_member", { p_organization_id: organizationId, p_email: email });
  if (error) go(error.message.includes("No registered user") ? "user-not-found" : error.message.includes("already a member") ? "already-member" : "member-action-failed");
  revalidatePath("/settings/members");
  go();
}

export async function changeMemberRole(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const userId = String(formData.get("user_id") || "");
  const role = String(formData.get("role") || "");
  if (!userId || !["owner", "member"].includes(role)) go("invalid-role");
  const { error } = await supabase.rpc("set_organization_member_role", { p_organization_id: organizationId, p_user_id: userId, p_role: role });
  if (error) go(error.message.includes("Transfer ownership") ? "transfer-ownership-first" : "member-action-failed");
  revalidatePath("/settings/members");
  go();
}

export async function removeMember(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const userId = String(formData.get("user_id") || "");
  if (!userId) go("invalid-member");
  const { error } = await supabase.rpc("remove_organization_member", { p_organization_id: organizationId, p_user_id: userId });
  if (error) go(error.message.includes("owner") ? "owner-protected" : "member-action-failed");
  revalidatePath("/settings/members");
  go();
}
