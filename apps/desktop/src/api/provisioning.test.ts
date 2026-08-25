import { afterEach, describe, expect, it, vi } from "vitest";
import {
  actionsForProvisioning,
  isAutomaticProvisioningCheckpoint,
  provisioningActionRequiresAuthenticationSecret,
  provisioningClient,
  ProvisioningClientError,
  type ProvisioningComputer,
  type StartComputerInput,
} from "./provisioning";
import { buildStartComputerInput, reconcileComputerList, resetProvisioningModal, upsertComputer } from "../ProvisioningComputers";

const PASSWORD = "super-secret-ssh-password";
const PASSPHRASE = "private-key-passphrase-must-not-leak";

function record(overrides: Record<string, unknown> = {}) {
  return {
    id: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
    displayName: "Build worker",
    endpoint: { host: "192.0.2.10", port: 22, username: "builder" },
    state: "host_key_pending",
    step: "host_key_pending",
    attention: "host_key",
    intent: "continue",
    revision: 3,
    cycle: 0,
    intendedNodeId: "3873d272-3786-46b9-9813-1ad2674fc7cb",
    hostKey: {
      algorithm: "ssh-ed25519",
      fingerprint: "SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDE",
      approved: false,
    },
    credential: { authenticationMethod: "password", rememberRequested: true, state: "pending" },
    configuration: {
      serviceScope: "auto",
      priority: 10,
      allowedJobKinds: ["build", "test", "compute"],
      allowOnBattery: false,
    },
    createdAt: "2026-08-23T00:00:00Z",
    updatedAt: "2026-08-23T00:00:01Z",
    ...overrides,
  };
}

function startInput(): StartComputerInput {
  return {
    recordId: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
    intendedNodeId: "3873d272-3786-46b9-9813-1ad2674fc7cb",
    displayName: "Build worker",
    host: "192.0.2.10",
    port: 22,
    username: "builder",
    authenticationMethod: "password",
    password: PASSWORD,
    passphrase: "",
    rememberPassword: true,
    advanced: {
      serviceScope: "auto",
      workspace: "C:/CodexWorker",
      priority: 10,
      allowedJobKinds: ["build", "test", "compute"],
      allowOnBattery: false,
    },
  };
}

afterEach(() => vi.unstubAllGlobals());

describe("provisioning client secret boundary", () => {
  it("clears password objects after start and never returns the secret", async () => {
    const provisioningStart = vi.fn(async (_request: unknown) => ({
      outcome: "awaiting_host_key_approval",
      computer: record(),
    }));
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningStart } });
    const input = startInput();

    const result = await provisioningClient.start(input);

    expect(input.password).toBe("");
    expect(input.passphrase).toBe("");
    expect(provisioningStart.mock.calls[0]?.[0]).toMatchObject({
      recordId: input.recordId,
      intendedNodeId: input.intendedNodeId,
      password: "",
    });
    expect(JSON.stringify(result)).not.toContain(PASSWORD);
    expect(JSON.stringify(provisioningStart.mock.calls)).not.toContain(PASSWORD);
  });

  it("clears passwords even when native code rejects and redacts native details", async () => {
    const provisioningStart = vi.fn(async (_request: unknown) => {
      throw { code: "credential_required", retryable: true, detail: `password=${PASSWORD}` };
    });
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningStart } });
    const input = startInput();

    const error = await provisioningClient.start(input).catch((caught: unknown) => caught);

    expect(input.password).toBe("");
    expect(input.passphrase).toBe("");
    expect(error).toBeInstanceOf(ProvisioningClientError);
    expect(error).toMatchObject({ code: "credential_required", retryable: true });
    expect(String(error)).not.toContain(PASSWORD);
    expect(JSON.stringify(error)).not.toContain(PASSWORD);
  });

  it("clears a re-entered password after action invocation", async () => {
    const provisioningContinue = vi.fn(async (_request: unknown) => ({
      outcome: "awaiting_external",
      computer: record({ state: "paired", step: "paired", attention: "external", revision: 8 }),
    }));
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningContinue } });
    const input = {
      id: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
      revision: 7,
      password: PASSWORD,
    };

    await provisioningClient.continue(input);

    expect(input.password).toBe("");
    expect(provisioningContinue.mock.calls[0]?.[0]).toMatchObject({ password: "" });
  });

  it("clears a private-key passphrase on success and failure without copying it to errors", async () => {
    const provisioningRetry = vi.fn(async (_request: unknown) => {
      throw { code: "SSH_PRIVATE_KEY_REJECTED", retryable: true, detail: PASSPHRASE };
    });
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningRetry } });
    const input = {
      id: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
      revision: 7,
      passphrase: PASSPHRASE,
    };

    const error = await provisioningClient.retry(input).catch((caught: unknown) => caught);

    expect(input.passphrase).toBe("");
    expect(provisioningRetry.mock.calls[0]?.[0]).toMatchObject({ passphrase: "" });
    expect(error).toMatchObject({ code: "SSH_PRIVATE_KEY_REJECTED", retryable: true });
    expect(JSON.stringify(error)).not.toContain(PASSPHRASE);
    expect(JSON.stringify(provisioningRetry.mock.calls)).not.toContain(PASSPHRASE);
  });

  it("submits private-key and agent policies without retaining authentication secrets", async () => {
    const provisioningStart = vi.fn(async (_request: unknown) => ({
      outcome: "awaiting_host_key_approval",
      computer: record({
        credential: {
          authenticationMethod: "private_key",
          rememberRequested: false,
          state: "pending",
        },
      }),
    }));
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningStart } });
    const privateKey: StartComputerInput = {
      ...startInput(),
      authenticationMethod: "private_key",
      privateKeyPath: "C:/Users/example/.ssh/id_ed25519",
      password: "",
      passphrase: PASSPHRASE,
      rememberPassword: false,
    };

    const result = await provisioningClient.start(privateKey);

    expect(privateKey.passphrase).toBe("");
    expect(provisioningStart.mock.calls[0]?.[0]).toMatchObject({
      authenticationMethod: "private_key",
      privateKeyPath: "C:/Users/example/.ssh/id_ed25519",
      passphrase: "",
    });
    expect(JSON.stringify(result)).not.toContain(PASSPHRASE);
    expect(JSON.stringify(provisioningStart.mock.calls)).not.toContain(PASSPHRASE);

    const agent = {
      ...startInput(),
      authenticationMethod: "agent" as const,
      password: "",
      passphrase: "",
      rememberPassword: false,
    };
    await provisioningClient.start(agent);
    const second = provisioningStart.mock.calls[1]?.[0] as Record<string, unknown>;
    expect(second.authenticationMethod).toBe("agent");
    expect(second.password).toBe("");
    expect(second.passphrase).toBe("");
  });
});

describe("durable provisioning recovery and actions", () => {
  it("resets every modal-owned secret/trust bit and rotates retry identities only on reset", () => {
    const ids = [
      "11111111-1111-4111-8111-111111111111",
      "22222222-2222-4222-8222-222222222222",
      "33333333-3333-4333-8333-333333333333",
      "44444444-4444-4444-8444-444444444444",
    ];
    const uuid = () => ids.shift()!;
    const first = resetProvisioningModal(uuid);
    first.form.password = PASSWORD;
    first.form.passphrase = PASSPHRASE;
    const second = resetProvisioningModal(uuid);

    expect(first.recordId).toBe("11111111-1111-4111-8111-111111111111");
    expect(second).toMatchObject({
      recordId: "33333333-3333-4333-8333-333333333333",
      intendedNodeId: "44444444-4444-4444-8444-444444444444",
      actionSecret: "",
      hostKeyConfirmed: false,
    });
    expect(second.form.password).toBe("");
    expect(second.form.passphrase).toBe("");
  });

  it("reuses the exact Add identity and immutable request on an ambiguous retry", () => {
    const ids = [
      "11111111-1111-4111-8111-111111111111",
      "22222222-2222-4222-8222-222222222222",
    ];
    const session = resetProvisioningModal(() => ids.shift()!);
    session.form.host = "worker.example.test";
    session.form.username = "builder";
    session.form.password = PASSWORD;
    const first = buildStartComputerInput(session.form, session.recordId, session.intendedNodeId);
    const replay = buildStartComputerInput(session.form, session.recordId, session.intendedNodeId);

    expect(replay).toEqual(first);
    expect(replay.recordId).toBe(session.recordId);
    expect(replay.intendedNodeId).toBe(session.intendedNodeId);
    expect(buildStartComputerInput({ ...session.form, host: "different.example.test" }, session.recordId, session.intendedNodeId)).not.toEqual(first);
  });

  it("round-trips each Add authentication choice without crossing secret fields", () => {
    const ids = [
      "11111111-1111-4111-8111-111111111111",
      "22222222-2222-4222-8222-222222222222",
    ];
    const session = resetProvisioningModal(() => ids.shift()!);
    const common = {
      ...session.form,
      host: "worker.example.test",
      username: "builder",
      password: PASSWORD,
      passphrase: PASSPHRASE,
      privateKeyPath: " C:/Users/example/.ssh/id_ed25519 ",
      rememberPassword: true,
    };

    const password = buildStartComputerInput(
      { ...common, authenticationMethod: "password" },
      session.recordId,
      session.intendedNodeId,
    );
    expect(password).toMatchObject({
      authenticationMethod: "password",
      privateKeyPath: undefined,
      password: PASSWORD,
      passphrase: "",
      rememberPassword: true,
    });

    const agent = buildStartComputerInput(
      { ...common, authenticationMethod: "agent" },
      session.recordId,
      session.intendedNodeId,
    );
    expect(agent).toMatchObject({
      authenticationMethod: "agent",
      privateKeyPath: undefined,
      password: "",
      passphrase: "",
      rememberPassword: false,
    });

    const privateKey = buildStartComputerInput(
      { ...common, authenticationMethod: "private_key" },
      session.recordId,
      session.intendedNodeId,
    );
    expect(privateKey).toMatchObject({
      authenticationMethod: "private_key",
      privateKeyPath: "C:/Users/example/.ssh/id_ed25519",
      password: "",
      passphrase: PASSPHRASE,
      rememberPassword: false,
    });
  });

  it("never lets an equal or older record revision replace renderer state", () => {
    const current = record({ revision: 8, updatedAt: "2026-08-23T00:00:08Z" }) as unknown as ProvisioningComputer;
    const older = record({ revision: 7, updatedAt: "2026-08-23T00:00:09Z", displayName: "stale" }) as unknown as ProvisioningComputer;
    const newer = record({ revision: 9, updatedAt: "2026-08-23T00:00:10Z", displayName: "fresh" }) as unknown as ProvisioningComputer;

    expect(upsertComputer([current], older)[0]).toBe(current);
    expect(reconcileComputerList([current], [older])[0]).toBe(current);
    expect(upsertComputer([current], newer)[0]?.displayName).toBe("fresh");
  });

  it("lists durable records on restart without a credential field", async () => {
    const provisioningList = vi.fn(async () => [record({
      state: "authenticated",
      step: "authenticated",
      attention: "credential",
      credential: { authenticationMethod: "password", rememberRequested: false, state: "session_only" },
      hostKey: { ...record().hostKey, approved: true },
    })]);
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningList } });

    const recovered = await provisioningClient.list();

    expect(provisioningList).toHaveBeenCalledWith();
    expect(recovered).toHaveLength(1);
    expect(recovered[0]?.attention).toBe("credential");
    expect(JSON.stringify(recovered)).not.toMatch(/"password":|credentialReference/i);
  });

  it("approves the full observed SHA256 fingerprint exactly once", async () => {
    const pending = record();
    const provisioningList = vi.fn(async () => [pending]);
    const provisioningApproveHostKey = vi.fn(async () => ({
      outcome: "awaiting_credential",
      computer: record({
        state: "authenticated",
        step: "authenticated",
        attention: "credential",
        revision: 4,
        hostKey: { ...pending.hostKey, approved: true },
      }),
    }));
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: { provisioningList, provisioningApproveHostKey },
    });
    const [computer] = await provisioningClient.list();
    expect(computer).toBeDefined();

    await provisioningClient.approveHostKey(computer!);

    expect(provisioningApproveHostKey).toHaveBeenCalledTimes(1);
    expect(provisioningApproveHostKey).toHaveBeenCalledWith({
      id: computer!.id,
      revision: computer!.revision,
      fingerprint: computer!.hostKey?.fingerprint,
    });
  });

  it("maps failure and ready states to the correct buttons", () => {
    const failed = record({
      state: "failed",
      step: "worker_installed",
      attention: "intent",
      failure: { code: "PAIRING_TIMEOUT", retryable: true },
    }) as unknown as ProvisioningComputer;
    const ready = record({
      state: "ready",
      step: "ready",
      attention: null,
      credential: { authenticationMethod: "password", rememberRequested: true, state: "stored" },
      hostKey: { ...record().hostKey, approved: true },
    }) as unknown as ProvisioningComputer;

    expect(actionsForProvisioning(failed)).toEqual(["retry", "rollback", "remove"]);
    expect(actionsForProvisioning(ready)).toEqual(["forget_ssh_password", "repair", "remove"]);
  });

  it("keeps agent and private-key policies non-secret and disables password-vault actions", async () => {
    const provisioningList = vi.fn(async () => [
      record({
        state: "ready",
        step: "ready",
        attention: null,
        credential: { authenticationMethod: "agent", rememberRequested: false, state: "session_only" },
        hostKey: { ...record().hostKey, approved: true },
      }),
      record({
        state: "failed",
        step: "authenticated",
        attention: "credential",
        credential: { authenticationMethod: "private_key", rememberRequested: false, state: "pending" },
        failure: { code: "SSH_PRIVATE_KEY_REJECTED", retryable: true },
        hostKey: { ...record().hostKey, approved: true },
      }),
    ]);
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningList } });

    const [agent, privateKey] = await provisioningClient.list();

    expect(actionsForProvisioning(agent!)).toEqual(["repair", "remove"]);
    expect(actionsForProvisioning(privateKey!)).toEqual(["retry", "rollback", "remove"]);
    expect(JSON.stringify([agent, privateKey])).not.toMatch(/privateKeyPath|passphrase/i);
    expect(provisioningActionRequiresAuthenticationSecret("retry", privateKey!)).toBe(false);
    expect(provisioningActionRequiresAuthenticationSecret("retry", {
      ...privateKey!,
      credential: { authenticationMethod: "password", rememberRequested: false, state: "pending" },
    })).toBe(true);
  });

  it("uses one credential continuation action with intent-specific alternatives", () => {
    const credential = record({
      state: "authenticated",
      step: "authenticated",
      attention: "credential",
      intent: "continue",
    }) as unknown as ProvisioningComputer;
    const rollback = { ...credential, intent: "rollback" as const };

    expect(actionsForProvisioning(credential)).toEqual(["continue", "rollback", "remove"]);
    expect(actionsForProvisioning(rollback)).toEqual(["continue", "remove"]);
  });

  it("automatically advances pairing through heartbeat and smoke but stops at human boundaries", () => {
    const sequence = [
      record({ state: "paired", step: "paired", attention: "external", revision: 8 }),
      record({ state: "service_enabled", step: "service_enabled", attention: "external", revision: 10 }),
      record({ state: "heartbeat_seen", step: "heartbeat_seen", attention: "external", revision: 12 }),
      record({ state: "smoke_check", step: "smoke_check", attention: "external", revision: 13 }),
      record({ state: "ready", step: "ready", attention: null, revision: 14 }),
    ] as unknown as ProvisioningComputer[];
    let index = 0;
    let calls = 0;
    while (isAutomaticProvisioningCheckpoint(sequence[index]!)) {
      calls += 1;
      index += 1;
    }
    expect(sequence[index]?.state).toBe("ready");
    expect(calls).toBe(4);
    expect(isAutomaticProvisioningCheckpoint(record() as unknown as ProvisioningComputer)).toBe(false);
    expect(isAutomaticProvisioningCheckpoint(record({
      state: "authenticated",
      step: "authenticated",
      attention: "credential",
    }) as unknown as ProvisioningComputer)).toBe(false);
  });

  it("rejects a failed snapshot that omits its stable failure code", async () => {
    const provisioningList = vi.fn(async () => [record({ state: "failed", step: "discovering", attention: "intent" })]);
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { provisioningList } });

    await expect(provisioningClient.list()).rejects.toMatchObject({ code: "invalid_response" });
  });
});
