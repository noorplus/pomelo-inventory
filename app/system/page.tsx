import { redirect } from "next/navigation";

export default function LegacySystemRoute() {
  redirect("/settings");
}
