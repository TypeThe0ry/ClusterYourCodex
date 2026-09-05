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
import { useI18n, type TranslationKey, type TranslationValues } from "./i18n";

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

const stepLabelKeys: Record<ProvisioningStep, TranslationKey> = {
  draft: "provision.step.created",
  ssh_connecting: "provision.step.sshConnecting",
  host_key_pending: "provision.step.hostKey",
  authenticated: "provision.step.authenticated",
  discovering: "provision.step.discovery",
  credential_stored: "provision.step.credentialPolicy",
  kit_staged: "provision.step.kitStaged",
  worker_installed: "provision.step.workerInstalled",
  enrollment_issued: "provision.step.enrollmentIssued",
  paired: "provision.step.paired",
  service_enabled: "provision.step.serviceEnabled",
  heartbeat_seen: "provision.step.heartbeat",
  smoke_check: "provision.step.smokeCheck",
  ready: "provision.step.ready",
};

const stateLabelKeys: Record<ProvisioningComputer["state"], TranslationKey> = {
  ...stepLabelKeys,
  failed: "provision.state.failed",
};

const actionLabelKeys: Record<ProvisioningUiAction, TranslationKey> = {
  approve_host_key: "provision.action.approveHostKey",
  continue: "provision.action.continue",
  resume: "provision.action.resume",
  retry: "provision.action.retry",
  repair: "provision.action.repair",
  rollback: "provision.action.rollback",
  remove: "provision.action.remove",
  forget_ssh_password: "provision.action.forgetPassword",
};

const jobKindLabelKeys: Record<AllowedJobKind, TranslationKey> = {
  build: "provision.jobKind.build",
  test: "provision.jobKind.test",
  static_analysis: "provision.jobKind.staticAnalysis",
  compute: "provision.jobKind.compute",
  gpu: "provision.jobKind.gpu",
  container: "provision.jobKind.container",
  service: "provision.jobKind.service",
  data_transform: "provision.jobKind.dataTransform",
  media_transform: "provision.jobKind.mediaTransform",
  render: "provision.jobKind.render",
};

const authenticationLabelKeys: Record<SshAuthenticationMethod, TranslationKey> = {
  password: "provision.password",
  agent: "provision.nativeAgent",
  private_key: "provision.privateKey",
};

const provisioningErrorKeys: Readonly<Record<string, TranslationKey>> = {
  bridge_unavailable: "error.provisionBridgeUnavailable",
  invalid_request: "error.provisionInvalidRequest",
  invalid_id: "error.provisionInvalidId",
  not_found: "error.provisionNotFound",
  revision_conflict: "error.provisionRevisionConflict",
  host_key_mismatch: "error.provisionHostKeyMismatch",
  credential_required: "error.provisionCredentialRequired",
  credential_store_unavailable: "error.provisionCredentialStoreUnavailable",
  private_key_invalid: "error.provisionPrivateKeyInvalid",
  SSH_PRIVATE_KEY_INVALID: "error.provisionPrivateKeyInvalid",
  SSH_PRIVATE_KEY_UNAVAILABLE: "error.provisionPrivateKeyUnavailable",
  SSH_PRIVATE_KEY_REJECTED: "error.provisionPrivateKeyRejected",
  SSH_AGENT_UNAVAILABLE: "error.provisionAgentUnavailable",
  SSH_AGENT_REJECTED: "error.provisionAgentRejected",
  SSH_AUTH_METHOD_UNSUPPORTED: "error.provisionAuthMethodUnsupported",
  worker_kit_catalog_unavailable: "error.provisionWorkerKitUnavailable",
  controller_unavailable: "error.provisionControllerUnavailable",
  provisioning_store_unavailable: "error.provisionStoreUnavailable",
  driver_unavailable: "error.provisionDriverUnavailable",
  operation_unavailable: "error.provisionOperationUnavailable",
  drive_limit_reached: "error.provisionDriveLimit",
  automatic_advance_deadline: "error.provisionAutomaticDeadline",
  PAIRING_PROVISIONING_FAILED: "error.provisionPairingFailed",
  PAIRING_WORKER_INSTALL_FAILED: "error.provisionWorkerInstallFailed",
  PAIRING_WORKER_PAIRING_FAILED: "error.provisionWorkerPairingFailed",
  PAIRING_WORKER_HEALTH_CHECK_FAILED: "error.provisionWorkerHealthFailed",
  PAIRING_EXPIRED: "error.provisionExpired",
};

type Translator = (key: TranslationKey, values?: TranslationValues) => string;

function localizedProvisioningError(
  error: Pick<ProvisioningClientError, "code" | "message"> | { code: string; message: string } | undefined,
  t: Translator,
): string | undefined {
  if (!error) return undefined;
  const key = provisioningErrorKeys[error.code];
  return key ? t(key) : error.message;
}

function localizedProvisioningActionLabel(
  action: ProvisioningUiAction,
  computer: ProvisioningComputer,
  t: Translator,
): string {
  if (action === "retry" && computer.attention === "credential") {
    return computer.credential.authenticationMethod === "private_key"
      ? t("provision.action.retryPrivateKey")
      : t("provision.action.retryPassword");
  }
  if (action !== "continue") return t(actionLabelKeys[action]);
  if (computer.attention === "credential") {
    const secret = computer.credential.authenticationMethod === "private_key"
      ? t("provision.privateKeyPassphrase")
      : t("provision.password");
    if (computer.intent === "rollback") return t("provision.action.continueRollback", { secret });
    if (computer.intent === "remove") return t("provision.action.continueRemoval", { secret });
    return t("provision.action.continueSetup", { secret });
  }
  if (computer.attention === "external") return t("provision.action.checkNow");
  return t(actionLabelKeys[action]);
}

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
  const { t } = useI18n();
  const activeIndex = PROVISIONING_STEPS.indexOf(computer.step);
  return (
    <ol className="provisioning-timeline" aria-label={t("provision.timeline")}>
      {PROVISIONING_STEPS.map((step, index) => {
        const failed = computer.state === "failed" && step === computer.step;
        const done = computer.state === "ready" || index < activeIndex;
        const active = !done && index === activeIndex;
        return (
          <li className={failed ? "failed" : done ? "done" : active ? "active" : "pending"} key={step}>
            <i>{failed ? "!" : done ? "✓" : index + 1}</i>
            <span>{t(stepLabelKeys[step])}</span>
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
  const { t } = useI18n();
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
    if (action === "remove" && !window.confirm(t("provision.confirmRemove", { name: selected.displayName }))) return;
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
  }, [actionSecret, applyResult, refresh, selected, t]);

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
        <div><h3>{t("provision.title")}</h3><p>{t("provision.subtitle")}</p></div>
        <div className="provisioning-header-actions">
          <button className="button button-secondary" disabled={loading || Boolean(operation)} onClick={() => void refresh()}>{loading ? t("common.loading") : t("common.refresh")}</button>
          <button className="button button-primary" disabled={Boolean(operation)} onClick={() => setShowWizard(true)}>＋ {t("computers.add")}</button>
        </div>
      </header>

      {error ? (
        <div className="provisioning-error" role="alert">
          <span className="provisioning-error-icon"><span aria-hidden="true">!</span></span>
          <span className="provisioning-error-copy">
            <strong>{localizedProvisioningError(error, t)}</strong>
            {error.retryable ? <small>{t("common.retryable")}</small> : null}
          </span>
          <details className="provisioning-error-details">
            <summary>{t("provision.showDetails")}</summary>
            <code>{error.code}</code>
          </details>
        </div>
      ) : null}

      {computers.length ? (
        <div className="provisioning-workspace">
          <div className="provisioning-record-list" aria-label={t("provision.records")}>
            {computers.map((computer) => (
              <button className={computer.id === selectedId ? "selected" : ""} key={computer.id} onClick={() => setSelectedId(computer.id)}>
                <span className={`provisioning-state state-${computer.state}`} />
                <span><strong>{computer.displayName}</strong><small>{computer.endpoint.username}@{computer.endpoint.host}:{computer.endpoint.port}</small></span>
                <em>{t(stateLabelKeys[computer.state])}</em>
              </button>
            ))}
          </div>

          {selected ? (
            <article className="provisioning-detail">
              <header>
                <div><span className="eyebrow">{t("provision.managedSetup")}</span><h3>{selected.displayName}</h3><p>{selected.endpoint.username}@{selected.endpoint.host}:{selected.endpoint.port} · {t(authenticationLabelKeys[selected.credential.authenticationMethod])}</p></div>
                <span className={`status-pill provision-${selected.state}`}>{t(stateLabelKeys[selected.state])}</span>
              </header>

              <Timeline computer={selected} />

              {selected.attention === "host_key" && selected.hostKey && !selected.hostKey.approved ? (
                <section className="host-key-confirmation">
                  <strong>{t("provision.verifyHostKey")}</strong>
                  <p>{t("provision.hostKeyDescription")}</p>
                  <dl><dt>{t("provision.algorithm")}</dt><dd>{selected.hostKey.algorithm}</dd><dt>{t("provision.fingerprint")}</dt><dd className="fingerprint">{selected.hostKey.fingerprint}</dd></dl>
                  <label className="confirmation-check"><input checked={hostKeyConfirmed} onChange={(event) => setHostKeyConfirmed(event.target.checked)} type="checkbox" /> {t("provision.fingerprintCheck")}</label>
                  <button className="button button-primary" disabled={!hostKeyConfirmed || Boolean(operation) || selectedAutoBusy} onClick={() => void approveHostKey()}>{operation === "approve_host_key" ? t("provision.approving") : t("provision.approveContinue")}</button>
                </section>
              ) : null}

              {selected.attention === "credential" ? (
                <section className="credential-resume">
                  <strong>{selected.credential.authenticationMethod === "private_key"
                    ? selected.failure?.code === "SSH_PRIVATE_KEY_REJECTED"
                       ? t("provision.privateKeyRejected")
                       : t("provision.passphraseRequired")
                    : selected.failure?.code === "SSH_AUTH_REJECTED"
                       ? t("provision.sshPasswordRejected")
                       : t("provision.passwordRequired")}</strong>
                  <p>{selected.credential.authenticationMethod === "private_key"
                     ? t("provision.retryPassphrase")
                    : selected.failure?.code === "SSH_AUTH_REJECTED"
                       ? t("provision.retryPassword")
                       : t("provision.sessionSecret")}</p>
                  <label>{selected.credential.authenticationMethod === "private_key" ? t("provision.privateKeyPassphrase") : t("provision.password")}<input autoComplete="new-password" onChange={(event) => setActionSecret(event.target.value)} type="password" value={actionSecret} /></label>
                  <small>{selected.credential.authenticationMethod === "private_key"
                     ? t("provision.privateKeyDurable")
                     : t("provision.rememberedReplacement")}</small>
                </section>
              ) : null}

              {selected.state === "failed" && selected.failure ? (
                <section className="provisioning-failure">
                  <strong>{localizedProvisioningError(selected.failure, t)}</strong>
                  <details className="provisioning-error-details">
                    <summary>{t("provision.showDetails")}</summary>
                    <code>{selected.failure.code}</code>
                  </details>
                  <p>{t("provision.failedAt", { step: t(stepLabelKeys[selected.step]) })} {selected.failure.retryable ? t("provision.retryCheckpoint") : t("provision.rollbackIncomplete")}</p>
                </section>
              ) : null}

              {selected.attention === "external" ? <div className="provisioning-wait"><span className="spinner" />{t("provision.waitingExternal")}</div> : null}

              {selected.inventory ? (
                <section className="inventory-summary">
                  <div><span>{t("provision.operatingSystem")}</span><strong>{selected.inventory.operatingSystem} · {selected.inventory.architecture}</strong></div>
                  <div><span>{t("provision.cpu")}</span><strong>{selected.inventory.cpuModel} · {selected.inventory.logicalCpuCount} {t("provision.threads")}</strong></div>
                  <div><span>{t("provision.memory")}</span><strong>{Math.round(selected.inventory.memoryBytes / 1024 / 1024 / 1024)} {t("provision.gib")}</strong></div>
                  <div><span>{t("provision.gpu")}</span><strong>{selected.inventory.gpuDevices.map((gpu) => gpu.name).join(", ") || t("provision.noneDetected")}</strong></div>
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
                    {operation === action ? t("integration.working") : localizedProvisioningActionLabel(action, selected, t)}
                  </button>
                ))}
              </footer>
              <small className="record-meta">{t("provision.revisionMeta", { revision: selected.revision, cycle: selected.cycle, time: new Date(selected.updatedAt).toLocaleString() })}</small>
            </article>
          ) : null}
        </div>
      ) : !loading ? (
        <div className="provisioning-empty"><strong>{t("computers.emptyTitle")}</strong><p>{t("computers.emptyDescription")}</p><button className="button button-primary" onClick={() => setShowWizard(true)}>{t("home.addComputer")}</button></div>
      ) : null}

      {showWizard ? (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !operation) resetAndCloseWizard(); }}>
          <form className="computer-wizard" onSubmit={(event) => void start(event)}>
            <header><div><span className="eyebrow">{t("provision.title").toUpperCase()}</span><h2>{t("provision.connectSsh")}</h2><p>{t("provision.subtitle")}</p></div><button aria-label={t("common.close")} className="modal-close" disabled={Boolean(operation)} onClick={resetAndCloseWizard} type="button">×</button></header>
            <div className="form-grid">
              <label className="wide">{t("provision.host")}<input autoFocus maxLength={1024} onChange={(event) => setForm({ ...form, host: event.target.value })} required value={form.host} /></label>
              <label className="wide">{t("provision.user")}<input maxLength={256} onChange={(event) => setForm({ ...form, username: event.target.value })} required value={form.username} /></label>
              <label className="wide">{t("provision.authentication")}<select onChange={(event) => {
                const authenticationMethod = event.target.value as SshAuthenticationMethod;
                setForm({
                  ...form,
                  authenticationMethod,
                  password: "",
                  passphrase: "",
                  privateKeyPath: "",
                  rememberPassword: authenticationMethod === "password" && form.rememberPassword,
                });
              }} value={form.authenticationMethod}><option value="password">{t("provision.password")}</option><option value="agent">{t("provision.nativeAgent")}</option><option value="private_key">{t("provision.privateKey")}</option></select></label>
              {form.authenticationMethod === "password" ? <label className="wide">{t("provision.password")}<input autoComplete="new-password" onChange={(event) => setForm({ ...form, password: event.target.value })} required type="password" value={form.password} /></label> : null}
              {form.authenticationMethod === "private_key" ? <>
                <label className="wide">{t("provision.privateKeyPath")}<input autoComplete="off" onChange={(event) => setForm({ ...form, privateKeyPath: event.target.value })} placeholder="C:\\Users\\you\\.ssh\\id_ed25519" required value={form.privateKeyPath} /></label>
                <label className="wide">{t("provision.passphraseOptional")}<input autoComplete="new-password" onChange={(event) => setForm({ ...form, passphrase: event.target.value })} type="password" value={form.passphrase} /></label>
              </> : null}
              {form.authenticationMethod === "agent" ? <small className="wide auth-method-note">{t("provision.agentNote")}</small> : null}
            </div>
            {form.authenticationMethod === "password" ? <label className="check-row"><input checked={form.rememberPassword} onChange={(event) => setForm({ ...form, rememberPassword: event.target.checked })} type="checkbox" /> {t("provision.rememberPassword")}</label> : null}

            <details className="advanced-options">
              <summary>{t("provision.advanced")}</summary>
              <div className="form-grid">
                <label className="wide">{t("provision.displayName")}<input maxLength={128} onChange={(event) => setForm({ ...form, displayName: event.target.value })} placeholder={t("provision.displayNamePlaceholder")} value={form.displayName} /></label>
                <label>{t("provision.sshPort")}<input max={65535} min={1} onChange={(event) => setForm({ ...form, port: event.target.value })} required type="number" value={form.port} /></label>
                <label>{t("provision.serviceScope")}<select onChange={(event) => setForm({ ...form, serviceScope: event.target.value as AddForm["serviceScope"] })} value={form.serviceScope}><option value="auto">{t("provision.scope.auto")}</option><option value="user">{t("provision.scope.user")}</option><option value="system">{t("provision.scope.system")}</option></select></label>
                <label>{t("provision.routingPriority")}<input max={10000} min={-10000} onChange={(event) => setForm({ ...form, priority: event.target.value })} type="number" value={form.priority} /></label>
                <label className="wide">{t("provision.workerWorkspace")}<input onChange={(event) => setForm({ ...form, workspace: event.target.value })} placeholder={t("provision.workerWorkspacePlaceholder")} value={form.workspace} /></label>
                <label>{t("provision.maxParallelJobs")}<input min={1} onChange={(event) => setForm({ ...form, maximumParallelJobs: event.target.value })} type="number" value={form.maximumParallelJobs} /></label>
                <label>{t("provision.cpuLimit")}<input max={100} min={1} onChange={(event) => setForm({ ...form, cpuLimitPercent: event.target.value })} type="number" value={form.cpuLimitPercent} /></label>
                <label>{t("provision.memoryLimit")}<input min={1} onChange={(event) => setForm({ ...form, memoryLimitMiB: event.target.value })} type="number" value={form.memoryLimitMiB} /></label>
              </div>
              <fieldset><legend>{t("provision.allowedJobKinds")}</legend><div className="job-kind-grid">{(Object.keys(jobKindLabels) as AllowedJobKind[]).map((kind) => <label key={kind}><input checked={form.allowedJobKinds.includes(kind)} onChange={(event) => setForm({ ...form, allowedJobKinds: event.target.checked ? [...form.allowedJobKinds, kind] : form.allowedJobKinds.filter((item) => item !== kind) })} type="checkbox" />{t(jobKindLabelKeys[kind])}</label>)}</div>{form.allowedJobKinds.length === 0 ? <small role="alert">{t("provision.selectJobKind")}</small> : null}</fieldset>
              <label className="check-row"><input checked={form.allowOnBattery} onChange={(event) => setForm({ ...form, allowOnBattery: event.target.checked })} type="checkbox" /> {t("provision.allowOnBattery")}</label>
              <small>{t("provision.advancedDescription")}</small>
            </details>

            <footer><button className="button button-secondary" disabled={Boolean(operation)} onClick={resetAndCloseWizard} type="button">{t("common.cancel")}</button><button className="button button-primary" disabled={Boolean(operation) || form.allowedJobKinds.length === 0 || (form.authenticationMethod === "password" && !form.password) || (form.authenticationMethod === "private_key" && !form.privateKeyPath.trim())} type="submit">{operation === "start" ? t("status.connecting") : t("common.continue")}</button></footer>
          </form>
        </div>
      ) : null}
    </section>
  );
}
