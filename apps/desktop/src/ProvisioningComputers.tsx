import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import {
  PROVISIONING_STEPS,
  actionsForProvisioning,
  isAutomaticProvisioningCheckpoint,
  provisioningActionRequiresAuthenticationSecret,
  provisioningClient,
  ProvisioningClientError,
  type AllowedJobKind,
  type ProvisioningComputer,
  type ProvisioningActionInput,
  type ProvisioningOperationResult,
  type ProvisioningStep,
  type ProvisioningUiAction,
  type StartComputerInput,
  type SshAuthenticationMethod,
} from "./api/provisioning";

const stepLabels: Record<ProvisioningStep, string> = {
  draft: "Created",
  ssh_connecting: "SSH connection",
  host_key_pending: "Host key",
  authenticated: "Authenticated",
  discovering: "Discovery",
  credential_stored: "Credential policy",
  kit_staged: "Worker kit staged",
  worker_installed: "Worker installed",
  enrollment_issued: "Enrollment issued",
  paired: "Paired",
  service_enabled: "Service enabled",
  heartbeat_seen: "Heartbeat",
  smoke_check: "Smoke check",
  ready: "Ready",
};

const stateLabels: Record<ProvisioningComputer["state"], string> = {
  ...stepLabels,
  failed: "Failed",
};

const actionLabels: Record<ProvisioningUiAction, string> = {
  approve_host_key: "Approve host key",
  continue: "Continue",
  resume: "Resume",
  retry: "Retry",
  repair: "Repair",
  rollback: "Rollback",
  remove: "Remove",
  forget_ssh_password: "Forget SSH password",
};

const jobKindLabels: Record<AllowedJobKind, string> = {
  build: "Build",
  test: "Test",
  static_analysis: "Static analysis",
  compute: "Compute",
  gpu: "GPU",
  container: "Container",
  service: "Service",
  data_transform: "Data transform",
  media_transform: "Media transform",
  render: "Render",
};

const defaultJobKinds: AllowedJobKind[] = ["build", "test", "compute"];

const authenticationLabels: Record<SshAuthenticationMethod, string> = {
  password: "Password",
  agent: "Native SSH agent",
  private_key: "Private key",
};

export interface AddForm {
  displayName: string;
  host: string;
  port: string;
  username: string;
  authenticationMethod: SshAuthenticationMethod;
  privateKeyPath: string;
  password: string;
  passphrase: string;
  rememberPassword: boolean;
  serviceScope: "auto" | "user" | "system";
  workspace: string;
  priority: string;
  maximumParallelJobs: string;
  cpuLimitPercent: string;
  memoryLimitMiB: string;
  allowedJobKinds: AllowedJobKind[];
  allowOnBattery: boolean;
}

function initialForm(): AddForm {
  return {
    displayName: "",
    host: "",
    port: "22",
    username: "",
    authenticationMethod: "password",
    privateKeyPath: "",
    password: "",
    passphrase: "",
    rememberPassword: true,
    serviceScope: "auto",
    workspace: "",
    priority: "0",
    maximumParallelJobs: "",
    cpuLimitPercent: "",
    memoryLimitMiB: "",
    allowedJobKinds: [...defaultJobKinds],
    allowOnBattery: false,
  };
}

export interface ProvisioningModalReset {
  form: AddForm;
  recordId: string;
  intendedNodeId: string;
  actionSecret: "";
  hostKeyConfirmed: false;
}

function secureUuid(): string {
  if (!globalThis.crypto?.randomUUID) {
    throw new Error("A cryptographically secure UUID generator is required");
  }
  return globalThis.crypto.randomUUID();
}

/** One modal attempt keeps these identities stable across an ambiguous retry.
 * Closing or completing the modal calls this again, which also proves every
 * React-owned secret/trust bit is cleared. */
export function resetProvisioningModal(
  uuid: () => string = secureUuid,
): ProvisioningModalReset {
  return {
    form: initialForm(),
    recordId: uuid(),
    intendedNodeId: uuid(),
    actionSecret: "",
    hostKeyConfirmed: false,
  };
}

function optionalPositive(value: string): number | undefined {
  if (!value.trim()) return undefined;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
}

export function buildStartComputerInput(
  form: AddForm,
  recordId: string,
  intendedNodeId: string,
): StartComputerInput {
  return {
    recordId,
    intendedNodeId,
    displayName: form.displayName.trim() || form.host.trim(),
    host: form.host.trim(),
    port: Number(form.port),
    username: form.username.trim(),
    authenticationMethod: form.authenticationMethod,
    privateKeyPath: form.authenticationMethod === "private_key"
      ? form.privateKeyPath.trim()
      : undefined,
    password: form.authenticationMethod === "password" ? form.password : "",
    passphrase: form.authenticationMethod === "private_key" ? form.passphrase : "",
    rememberPassword: form.authenticationMethod === "password" && form.rememberPassword,
    advanced: {
      serviceScope: form.serviceScope,
      workspace: form.workspace.trim() || undefined,
      priority: Number(form.priority),
      maximumParallelJobs: optionalPositive(form.maximumParallelJobs),
      cpuLimitPercent: optionalPositive(form.cpuLimitPercent),
      memoryLimitMiB: optionalPositive(form.memoryLimitMiB),
      allowedJobKinds: [...form.allowedJobKinds],
      allowOnBattery: form.allowOnBattery,
    },
  };
}

function safeError(caught: unknown): ProvisioningClientError {
  return caught instanceof ProvisioningClientError
    ? caught
    : new ProvisioningClientError("operation_unavailable");
}

function hasActiveWork(computers: ProvisioningComputer[]): boolean {
  return computers.some((computer) =>
    computer.state !== "ready"
      && computer.state !== "failed"
      && computer.attention !== "host_key"
      && computer.attention !== "credential",
  );
}

function Timeline({ computer }: { computer: ProvisioningComputer }) {
  const activeIndex = PROVISIONING_STEPS.indexOf(computer.step);
  return (
    <ol className="provisioning-timeline" aria-label="Provisioning timeline">
      {PROVISIONING_STEPS.map((step, index) => {
        const failed = computer.state === "failed" && step === computer.step;
        const done = computer.state === "ready" || index < activeIndex;
        const active = !done && index === activeIndex;
        return (
          <li className={failed ? "failed" : done ? "done" : active ? "active" : "pending"} key={step}>
            <i>{failed ? "!" : done ? "✓" : index + 1}</i>
            <span>{stepLabels[step]}</span>
          </li>
        );
      })}
    </ol>
  );
}

function sortComputers(items: ProvisioningComputer[]): ProvisioningComputer[] {
  return [...items].sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
}

/** CAS revisions are monotonic. Equal or older documents must never replace
 * renderer state, even if an older list request finishes late. */
export function upsertComputer(
  items: ProvisioningComputer[],
  next: ProvisioningComputer,
): ProvisioningComputer[] {
  const previous = items.find((item) => item.id === next.id);
  if (previous && previous.revision >= next.revision) return items;
  return sortComputers([next, ...items.filter((item) => item.id !== next.id)]);
}

/** Reconcile an authoritative, request-ordered list while retaining any local
 * document whose revision is newer than the matching list document. */
export function reconcileComputerList(
  current: ProvisioningComputer[],
  incoming: ProvisioningComputer[],
): ProvisioningComputer[] {
  const currentById = new Map(current.map((item) => [item.id, item]));
  return sortComputers(incoming.map((item) => {
    const previous = currentById.get(item.id);
    return previous && previous.revision >= item.revision ? previous : item;
  }));
}

export function provisioningActionLabel(
  action: ProvisioningUiAction,
  computer: ProvisioningComputer,
): string {
  if (action === "retry" && computer.attention === "credential") {
    return computer.credential.authenticationMethod === "private_key"
      ? "Retry private key / passphrase"
      : "Retry with corrected password";
  }
  if (action !== "continue") return actionLabels[action];
  if (computer.attention === "credential") {
    const secret = computer.credential.authenticationMethod === "private_key"
      ? "passphrase"
      : "password";
    if (computer.intent === "rollback") return `Continue rollback with ${secret}`;
    if (computer.intent === "remove") return `Continue removal with ${secret}`;
    return `Continue setup with ${secret}`;
  }
  if (computer.attention === "external") return "Check now";
  return actionLabels[action];
}

export function ProvisioningComputers({ addRequest = 0 }: { addRequest?: number }) {
  const initialModal = useMemo(resetProvisioningModal, []);
  const [computers, setComputers] = useState<ProvisioningComputer[]>([]);
  const [selectedId, setSelectedId] = useState<string>();
  const [showWizard, setShowWizard] = useState(false);
  const [form, setForm] = useState<AddForm>(initialModal.form);
  const [recordId, setRecordId] = useState(initialModal.recordId);
  const [intendedNodeId, setIntendedNodeId] = useState(initialModal.intendedNodeId);
  const [loadingCount, setLoadingCount] = useState(0);
  const [hasLoaded, setHasLoaded] = useState(false);
  const [operation, setOperation] = useState<string>();
  const [error, setError] = useState<ProvisioningClientError>();
  const [hostKeyConfirmed, setHostKeyConfirmed] = useState(false);
  const [actionSecret, setActionSecret] = useState("");
  const [autoTick, setAutoTick] = useState(0);
  const listSequence = useRef(0);
  const lastAppliedList = useRef(0);
  const mutationEpoch = useRef(0);
  const autoTimers = useRef(new Map<string, number>());
  const autoInFlight = useRef(new Set<string>());
  const autoAdvance = useRef(new Map<string, { revision: number; delayMs: number; startedAt: number }>());
  const loading = loadingCount > 0 || !hasLoaded;

  const selected = useMemo(
    () => computers.find((computer) => computer.id === selectedId),
    [computers, selectedId],
  );

  const refresh = useCallback(async (quiet = false) => {
    const sequence = ++listSequence.current;
    const startedMutationEpoch = mutationEpoch.current;
    setLoadingCount((current) => current + 1);
    try {
      const recovered = await provisioningClient.list();
      if (sequence !== listSequence.current || sequence < lastAppliedList.current || startedMutationEpoch !== mutationEpoch.current) return;
      lastAppliedList.current = sequence;
      setComputers((current) => reconcileComputerList(current, recovered));
      if (!quiet) setError(undefined);
    } catch (caught) {
      if (!quiet && sequence === listSequence.current && sequence >= lastAppliedList.current && startedMutationEpoch === mutationEpoch.current) {
        setError(safeError(caught));
      }
    } finally {
      setHasLoaded(true);
      setLoadingCount((current) => Math.max(0, current - 1));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    if (addRequest > 0) setShowWizard(true);
  }, [addRequest]);

  useEffect(() => {
    if (!hasActiveWork(computers)) return undefined;
    const interval = window.setInterval(() => void refresh(true), 3_000);
    return () => window.clearInterval(interval);
  }, [computers, refresh]);

  useEffect(() => {
    setSelectedId((current) => current && computers.some((item) => item.id === current)
      ? current
      : computers[0]?.id);
  }, [computers]);

  useEffect(() => {
    setHostKeyConfirmed(false);
    setActionSecret("");
  }, [selected?.id, selected?.hostKey?.fingerprint, selected?.revision]);

  const applyResult = useCallback((result: ProvisioningOperationResult) => {
    mutationEpoch.current += 1;
    if (result.removedId) {
      setComputers((current) => current.filter((item) => item.id !== result.removedId));
      setSelectedId((current) => current === result.removedId ? undefined : current);
    } else if (result.computer) {
      setComputers((current) => upsertComputer(current, result.computer!));
      setSelectedId(result.computer.id);
    }
  }, []);

  useEffect(() => {
    if (operation) {
      for (const timer of autoTimers.current.values()) window.clearTimeout(timer);
      autoTimers.current.clear();
      return;
    }
    const candidates = new Map(computers.filter(isAutomaticProvisioningCheckpoint).map((item) => [item.id, item]));
    for (const [id, timer] of autoTimers.current) {
      const candidate = candidates.get(id);
      const progress = autoAdvance.current.get(id);
      if (!candidate || progress?.revision !== candidate.revision) {
        window.clearTimeout(timer);
        autoTimers.current.delete(id);
      }
    }
    for (const id of autoAdvance.current.keys()) {
      if (!candidates.has(id)) autoAdvance.current.delete(id);
    }

    const MAX_AUTO_CONCURRENCY = 2;
    let available = Math.max(0, MAX_AUTO_CONCURRENCY - autoInFlight.current.size - autoTimers.current.size);
    for (const candidate of candidates.values()) {
      if (available === 0) break;
      if (autoInFlight.current.has(candidate.id) || autoTimers.current.has(candidate.id)) continue;
      const previous = autoAdvance.current.get(candidate.id);
      const progress = previous?.revision === candidate.revision
        ? previous
        : { revision: candidate.revision, delayMs: 500, startedAt: previous?.startedAt ?? Date.now() };
      autoAdvance.current.set(candidate.id, progress);
      if (Date.now() - progress.startedAt > 10 * 60_000) {
        setError(new ProvisioningClientError("automatic_advance_deadline", true));
        continue;
      }
      available -= 1;
      const timer = window.setTimeout(() => {
        autoTimers.current.delete(candidate.id);
        if (autoInFlight.current.size >= MAX_AUTO_CONCURRENCY) {
          setAutoTick((current) => current + 1);
          return;
        }
        autoInFlight.current.add(candidate.id);
        mutationEpoch.current += 1;
        setAutoTick((current) => current + 1);
        void provisioningClient.continue({ id: candidate.id, revision: candidate.revision })
          .then((result) => {
            applyResult(result);
            if (result.computer && isAutomaticProvisioningCheckpoint(result.computer)) {
              autoAdvance.current.set(result.computer.id, {
                revision: result.computer.revision,
                delayMs: Math.min(progress.delayMs * 2, 8_000),
                startedAt: progress.startedAt,
              });
            } else {
              autoAdvance.current.delete(candidate.id);
            }
            setError(undefined);
          })
          .catch((caught: unknown) => {
            setError(safeError(caught));
            void refresh(true);
          })
          .finally(() => {
            autoInFlight.current.delete(candidate.id);
            mutationEpoch.current += 1;
            setAutoTick((current) => current + 1);
            void refresh(true);
          });
      }, progress.delayMs);
      autoTimers.current.set(candidate.id, timer);
    }
  }, [applyResult, autoTick, computers, operation, refresh]);

  useEffect(() => () => {
    for (const timer of autoTimers.current.values()) window.clearTimeout(timer);
    autoTimers.current.clear();
  }, []);

  const resetAndCloseWizard = useCallback(() => {
    const reset = resetProvisioningModal();
    setShowWizard(false);
    setForm(reset.form);
    setRecordId(reset.recordId);
    setIntendedNodeId(reset.intendedNodeId);
    setActionSecret(reset.actionSecret);
    setHostKeyConfirmed(reset.hostKeyConfirmed);
  }, []);

  const start = useCallback(async (event: FormEvent) => {
    event.preventDefault();
    const port = Number(form.port);
    const priority = Number(form.priority);
    if (
      !Number.isSafeInteger(port) ||
      port < 1 ||
      port > 65535 ||
      !Number.isSafeInteger(priority) ||
      form.allowedJobKinds.length === 0 ||
      (form.authenticationMethod === "password" && !form.password) ||
      (form.authenticationMethod === "private_key" && !form.privateKeyPath.trim())
    ) {
      setError(new ProvisioningClientError("invalid_request"));
      return;
    }
    const input = buildStartComputerInput(form, recordId, intendedNodeId);
    mutationEpoch.current += 1;
    setOperation("start");
    setError(undefined);
    // Clear the React-owned copy before the native promise resolves. The API
    // client also clears its request object in a finally block.
    setForm((current) => ({ ...current, password: "", passphrase: "" }));
    try {
      applyResult(await provisioningClient.start(input));
      resetAndCloseWizard();
    } catch (caught) {
      setError(safeError(caught));
    } finally {
      input.password = "";
      input.passphrase = "";
      mutationEpoch.current += 1;
      setOperation(undefined);
      void refresh(true);
    }
  }, [applyResult, form, intendedNodeId, recordId, refresh, resetAndCloseWizard]);

  const runAction = useCallback(async (action: Exclude<ProvisioningUiAction, "approve_host_key" | "forget_ssh_password">) => {
    if (!selected) return;
    if (action === "remove" && !window.confirm(`Remove ${selected.displayName} and its managed worker?`)) return;
    const pendingAuto = autoTimers.current.get(selected.id);
    if (pendingAuto !== undefined) {
      window.clearTimeout(pendingAuto);
      autoTimers.current.delete(selected.id);
    }
    autoAdvance.current.delete(selected.id);
    mutationEpoch.current += 1;
    setOperation(action);
    setError(undefined);
    const input: ProvisioningActionInput = {
      id: selected.id,
      revision: selected.revision,
      ...(actionSecret
        ? selected.credential.authenticationMethod === "private_key"
          ? { passphrase: actionSecret }
          : { password: actionSecret }
        : {}),
    };
    setActionSecret("");
    try {
      applyResult(await provisioningClient[action](input));
    } catch (caught) {
      setError(safeError(caught));
    } finally {
      input.password = "";
      input.passphrase = "";
      mutationEpoch.current += 1;
      setOperation(undefined);
      void refresh(true);
    }
  }, [actionSecret, applyResult, refresh, selected]);

  const approveHostKey = useCallback(async () => {
    if (!selected || !hostKeyConfirmed) return;
    mutationEpoch.current += 1;
    setOperation("approve_host_key");
    setError(undefined);
    try {
      applyResult(await provisioningClient.approveHostKey(selected));
    } catch (caught) {
      setError(safeError(caught));
    } finally {
      mutationEpoch.current += 1;
      setOperation(undefined);
      void refresh(true);
    }
  }, [applyResult, hostKeyConfirmed, refresh, selected]);

  const forgetPassword = useCallback(async () => {
    if (!selected) return;
    mutationEpoch.current += 1;
    setOperation("forget_ssh_password");
    setError(undefined);
    try {
      applyResult(await provisioningClient.forgetSshPassword(selected));
    } catch (caught) {
      setError(safeError(caught));
    } finally {
      mutationEpoch.current += 1;
      setOperation(undefined);
      void refresh(true);
    }
  }, [applyResult, refresh, selected]);

  const actions = selected ? actionsForProvisioning(selected) : [];
  const selectedAutoBusy = selected ? autoInFlight.current.has(selected.id) : false;
  return (
    <section className="panel page-panel provisioning-panel">
      <header className="panel-header with-actions">
        <div><h3>Add Computer setup</h3><p>Durable SSH setup records resume after a desktop restart.</p></div>
        <div className="provisioning-header-actions">
          <button className="button button-secondary" disabled={loading || Boolean(operation)} onClick={() => void refresh()}>{loading ? "Loading…" : "Refresh"}</button>
          <button className="button button-primary" disabled={Boolean(operation)} onClick={() => setShowWizard(true)}>＋ Add computer</button>
        </div>
      </header>

      {error ? (
        <div className="provisioning-error" role="alert">
          <strong>{error.code}</strong><span>{error.message}</span>{error.retryable ? <small>Retryable</small> : null}
        </div>
      ) : null}

      {computers.length ? (
        <div className="provisioning-workspace">
          <div className="provisioning-record-list" aria-label="Provisioning records">
            {computers.map((computer) => (
              <button className={computer.id === selectedId ? "selected" : ""} key={computer.id} onClick={() => setSelectedId(computer.id)}>
                <span className={`provisioning-state state-${computer.state}`} />
                <span><strong>{computer.displayName}</strong><small>{computer.endpoint.username}@{computer.endpoint.host}:{computer.endpoint.port}</small></span>
                <em>{stateLabels[computer.state]}</em>
              </button>
            ))}
          </div>

          {selected ? (
            <article className="provisioning-detail">
              <header>
                <div><span className="eyebrow">MANAGED SETUP</span><h3>{selected.displayName}</h3><p>{selected.endpoint.username}@{selected.endpoint.host}:{selected.endpoint.port} · {authenticationLabels[selected.credential.authenticationMethod]}</p></div>
                <span className={`status-pill provision-${selected.state}`}>{stateLabels[selected.state]}</span>
              </header>

              <Timeline computer={selected} />

              {selected.attention === "host_key" && selected.hostKey && !selected.hostKey.approved ? (
                <section className="host-key-confirmation">
                  <strong>Verify this SSH host key</strong>
                  <p>Compare the full fingerprint with the computer itself. Approval is bound to this exact key.</p>
                  <dl><dt>Algorithm</dt><dd>{selected.hostKey.algorithm}</dd><dt>SHA256 fingerprint</dt><dd className="fingerprint">{selected.hostKey.fingerprint}</dd></dl>
                  <label className="confirmation-check"><input checked={hostKeyConfirmed} onChange={(event) => setHostKeyConfirmed(event.target.checked)} type="checkbox" /> I verified this exact fingerprint.</label>
                  <button className="button button-primary" disabled={!hostKeyConfirmed || Boolean(operation) || selectedAutoBusy} onClick={() => void approveHostKey()}>{operation === "approve_host_key" ? "Approving…" : "Approve once and continue"}</button>
                </section>
              ) : null}

              {selected.attention === "credential" ? (
                <section className="credential-resume">
                  <strong>{selected.credential.authenticationMethod === "private_key"
                    ? selected.failure?.code === "SSH_PRIVATE_KEY_REJECTED"
                      ? "Private key or passphrase rejected"
                      : "Private-key passphrase required"
                    : selected.failure?.code === "SSH_AUTH_REJECTED"
                      ? "SSH password rejected"
                      : "SSH password required"}</strong>
                  <p>{selected.credential.authenticationMethod === "private_key"
                    ? "Enter the optional private-key passphrase for this retry. After submission, the renderer drops its request reference and the native copy is cleared when the operation settles."
                    : selected.failure?.code === "SSH_AUTH_REJECTED"
                      ? "SSH rejected the attempted or stored credential. Enter the corrected password to retry this same setup record."
                      : "The session-only secret is no longer available. Enter it again; it is passed directly to the native secret boundary."}</p>
                  <label>{selected.credential.authenticationMethod === "private_key" ? "Private-key passphrase" : "Password"}<input autoComplete="new-password" onChange={(event) => setActionSecret(event.target.value)} type="password" value={actionSecret} /></label>
                  <small>{selected.credential.authenticationMethod === "private_key"
                    ? "The key path remains durable, but this passphrase is never stored in the provisioning journal or credential vault."
                    : "The original remember-password policy is durable. A remembered replacement is saved only after SSH accepts it."}</small>
                </section>
              ) : null}

              {selected.state === "failed" && selected.failure ? (
                <section className="provisioning-failure">
                  <strong>{selected.failure.code}</strong>
                  <p>Failed at {stepLabels[selected.step]}. {selected.failure.retryable ? "Retry this exact checkpoint, or roll it back." : "Roll back or remove this incomplete setup record."}</p>
                </section>
              ) : null}

              {selected.attention === "external" ? <div className="provisioning-wait"><span className="spinner" />Automatically waiting for pairing, a post-enable daemon heartbeat, the real smoke job, and its cleanup receipt.</div> : null}

              {selected.inventory ? (
                <section className="inventory-summary">
                  <div><span>Operating system</span><strong>{selected.inventory.operatingSystem} · {selected.inventory.architecture}</strong></div>
                  <div><span>CPU</span><strong>{selected.inventory.cpuModel} · {selected.inventory.logicalCpuCount} threads</strong></div>
                  <div><span>Memory</span><strong>{Math.round(selected.inventory.memoryBytes / 1024 / 1024 / 1024)} GiB</strong></div>
                  <div><span>GPU</span><strong>{selected.inventory.gpuDevices.map((gpu) => gpu.name).join(", ") || "None detected"}</strong></div>
                </section>
              ) : null}

              <footer className="provisioning-actions">
                {actions.filter((action) => action !== "approve_host_key").map((action) => (
                  <button
                    className={action === "remove" ? "button button-danger" : action === "retry" || action === "continue" ? "button button-primary" : "button button-secondary"}
                    disabled={Boolean(operation) || selectedAutoBusy || (provisioningActionRequiresAuthenticationSecret(action, selected) && !actionSecret)}
                    key={action}
                    onClick={() => action === "forget_ssh_password" ? void forgetPassword() : void runAction(action)}
                  >
                    {operation === action ? "Working…" : provisioningActionLabel(action, selected)}
                  </button>
                ))}
              </footer>
              <small className="record-meta">Revision {selected.revision} · cycle {selected.cycle} · updated {new Date(selected.updatedAt).toLocaleString()}</small>
            </article>
          ) : null}
        </div>
      ) : !loading ? (
        <div className="provisioning-empty"><strong>No setup records yet</strong><p>Add a computer to start real SSH discovery and managed worker installation.</p><button className="button button-primary" onClick={() => setShowWizard(true)}>Add your first computer</button></div>
      ) : null}

      {showWizard ? (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !operation) resetAndCloseWizard(); }}>
          <form className="computer-wizard" onSubmit={(event) => void start(event)}>
            <header><div><span className="eyebrow">ADD COMPUTER</span><h2>Connect over SSH</h2><p>Choose password, native SSH agent, or a validated local private key. Authentication secrets are passed only to the native host.</p></div><button aria-label="Close Add Computer" className="modal-close" disabled={Boolean(operation)} onClick={resetAndCloseWizard} type="button">×</button></header>
            <div className="form-grid">
              <label className="wide">Display name (optional)<input maxLength={128} onChange={(event) => setForm({ ...form, displayName: event.target.value })} placeholder="Defaults to host until discovery" value={form.displayName} /></label>
              <label className="wide">Host or IP<input autoFocus maxLength={1024} onChange={(event) => setForm({ ...form, host: event.target.value })} required value={form.host} /></label>
              <label>Port<input max={65535} min={1} onChange={(event) => setForm({ ...form, port: event.target.value })} required type="number" value={form.port} /></label>
              <label>SSH user<input maxLength={256} onChange={(event) => setForm({ ...form, username: event.target.value })} required value={form.username} /></label>
              <label className="wide">Authentication<select onChange={(event) => {
                const authenticationMethod = event.target.value as SshAuthenticationMethod;
                setForm({
                  ...form,
                  authenticationMethod,
                  password: "",
                  passphrase: "",
                  privateKeyPath: "",
                  rememberPassword: authenticationMethod === "password" && form.rememberPassword,
                });
              }} value={form.authenticationMethod}><option value="password">Password</option><option value="agent">Native SSH agent</option><option value="private_key">Private key file</option></select></label>
              {form.authenticationMethod === "password" ? <label className="wide">SSH password<input autoComplete="new-password" onChange={(event) => setForm({ ...form, password: event.target.value })} required type="password" value={form.password} /></label> : null}
              {form.authenticationMethod === "private_key" ? <>
                <label className="wide">Private-key path<input autoComplete="off" onChange={(event) => setForm({ ...form, privateKeyPath: event.target.value })} placeholder="C:\\Users\\you\\.ssh\\id_ed25519" required value={form.privateKeyPath} /></label>
                <label className="wide">Passphrase (optional)<input autoComplete="new-password" onChange={(event) => setForm({ ...form, passphrase: event.target.value })} type="password" value={form.passphrase} /></label>
              </> : null}
              {form.authenticationMethod === "agent" ? <small className="wide auth-method-note">ClusterYourCodex will use identities already exposed by the native SSH agent. No secret is requested or stored.</small> : null}
            </div>
            {form.authenticationMethod === "password" ? <label className="check-row"><input checked={form.rememberPassword} onChange={(event) => setForm({ ...form, rememberPassword: event.target.checked })} type="checkbox" /> Remember securely in Windows Credential Manager</label> : null}

            <details className="advanced-options">
              <summary>Advanced options</summary>
              <div className="form-grid">
                <label>Service scope<select onChange={(event) => setForm({ ...form, serviceScope: event.target.value as AddForm["serviceScope"] })} value={form.serviceScope}><option value="auto">Automatic</option><option value="user">Current user</option><option value="system">System</option></select></label>
                <label>Routing priority<input max={10000} min={-10000} onChange={(event) => setForm({ ...form, priority: event.target.value })} type="number" value={form.priority} /></label>
                <label className="wide">Worker workspace (absolute)<input onChange={(event) => setForm({ ...form, workspace: event.target.value })} placeholder="Auto-select by OS" value={form.workspace} /></label>
                <label>Max parallel jobs<input min={1} onChange={(event) => setForm({ ...form, maximumParallelJobs: event.target.value })} type="number" value={form.maximumParallelJobs} /></label>
                <label>CPU limit %<input max={100} min={1} onChange={(event) => setForm({ ...form, cpuLimitPercent: event.target.value })} type="number" value={form.cpuLimitPercent} /></label>
                <label>Memory limit MiB<input min={1} onChange={(event) => setForm({ ...form, memoryLimitMiB: event.target.value })} type="number" value={form.memoryLimitMiB} /></label>
              </div>
              <fieldset><legend>Allowed job kinds</legend><div className="job-kind-grid">{(Object.keys(jobKindLabels) as AllowedJobKind[]).map((kind) => <label key={kind}><input checked={form.allowedJobKinds.includes(kind)} onChange={(event) => setForm({ ...form, allowedJobKinds: event.target.checked ? [...form.allowedJobKinds, kind] : form.allowedJobKinds.filter((item) => item !== kind) })} type="checkbox" />{jobKindLabels[kind]}</label>)}</div>{form.allowedJobKinds.length === 0 ? <small role="alert">Select at least one job kind.</small> : null}</fieldset>
              <label className="check-row"><input checked={form.allowOnBattery} onChange={(event) => setForm({ ...form, allowOnBattery: event.target.checked })} type="checkbox" /> Allow jobs while this computer is on battery</label>
              <small>Routing priority and typed capacity policy are synchronized after pairing and enforced atomically during placement. The current worker containment advertises one safe execution slot.</small>
            </details>

            <footer><button className="button button-secondary" disabled={Boolean(operation)} onClick={resetAndCloseWizard} type="button">Cancel</button><button className="button button-primary" disabled={Boolean(operation) || form.allowedJobKinds.length === 0 || (form.authenticationMethod === "password" && !form.password) || (form.authenticationMethod === "private_key" && !form.privateKeyPath.trim())} type="submit">{operation === "start" ? "Connecting…" : "Connect and inspect"}</button></footer>
          </form>
        </div>
      ) : null}
    </section>
  );
}
