import { describe, expect, it } from "vitest";
import type { JobStatus } from "./api/types";
import { matchesTaskFilter } from "./taskFilters";

const statuses: JobStatus[] = ["queued", "preparing", "running", "verifying", "succeeded", "failed", "cancelled"];

describe("task filters", () => {
  it("shows every state under all", () => {
    expect(statuses.filter((status) => matchesTaskFilter(status, "all"))).toEqual(statuses);
  });
  it("shows active execution stages, not queued or terminal jobs", () => {
    expect(statuses.filter((status) => matchesTaskFilter(status, "running"))).toEqual(["preparing", "running", "verifying"]);
  });
  it("keeps failures separate from cancellations and successes", () => {
    expect(statuses.filter((status) => matchesTaskFilter(status, "failed"))).toEqual(["failed"]);
  });
});
