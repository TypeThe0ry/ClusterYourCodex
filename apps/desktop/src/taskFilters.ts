import type { JobStatus } from "./api/types";

export type TaskFilter = "all" | "running" | "failed";

export function matchesTaskFilter(status: JobStatus, filter: TaskFilter): boolean {
  if (filter === "all") return true;
  if (filter === "failed") return status === "failed";
  return status === "preparing" || status === "running" || status === "verifying";
}
