import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ControllerApiError, controllerClient, preferNewerFleetSnapshot } from "./api/client";
import { ProvisioningComputers } from "./ProvisioningComputers";
import {
  INTEGRATION_STATUS_MAX_AGE_MS,
  integrationClient,
  fullRunLayerIds,
  fullRunStaleReason,
  integrationStatusIdentity,
  type FullRunCheckResult,
  type FullRunEvidenceBaseline,
  type IntegrationActionResult,
  type IntegrationSelfTestResult,
  type IntegrationState,
  type IntegrationStatus,
} from "./api/integration";
import type { FleetInfo, JobStatus, NodeStatus, NodeSummary } from "./api/types";
import { localeOptions, type TranslationKey, useI18n } from "./i18n";

type Page = "home" | "computers" | "tasks" | "rules" | "integration";
type IconName =
  | "home"
  | "computer"
  | "tasks"
  | "rules"
  | "codex"
  | "spark"
  | "plus"
  | "refresh"
  | "cpu"
  | "clock"
  | "check"
  | "arrow"
  | "terminal"
  | "shield"
  | "gpu"
  | "more";

const navigation: Array<{ id: Page; labelKey: TranslationKey; icon: IconName }> = [
  { id: "home", labelKey: "nav.home", icon: "home" },
  { id: "computers", labelKey: "nav.computers", icon: "computer" },
  { id: "tasks", labelKey: "nav.tasks", icon: "tasks" },
  { id: "rules", labelKey: "nav.routingRules", icon: "rules" },
  { id: "integration", labelKey: "nav.integration", icon: "codex" },
];

const pageTitles: Record<Page, { titleKey: TranslationKey; subtitleKey: TranslationKey }> = {
  home: {
    titleKey: "home.pageTitle",
    subtitleKey: "home.pageSubtitle",
  },
  computers: {
    titleKey: "computers.title",
    subtitleKey: "computers.pageSubtitle",
  },
  tasks: {
    titleKey: "tasks.title",
    subtitleKey: "tasks.pageSubtitle",
  },
  rules: {
    titleKey: "nav.routingRules",
    subtitleKey: "rules.pageSubtitle",
  },
  integration: {
    titleKey: "nav.integration",
    subtitleKey: "integration.pageSubtitle",
  },
};

function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
  const paths: Record<IconName, ReactNode> = {
    home: <><path d="m3 10 9-7 9 7" /><path d="M5 9v11h14V9" /><path d="M9 20v-6h6v6" /></>,
    computer: <><rect x="3" y="4" width="18" height="13" rx="2" /><path d="M8 21h8M12 17v4" /></>,
    tasks: <><path d="M9 5h11M9 12h11M9 19h11" /><path d="m3.5 5 1 1 2-2M3.5 12l1 1 2-2M3.5 19l1 1 2-2" /></>,
    rules: <><path d="M4 6h16M7 12h10M10 18h4" /><circle cx="15" cy="6" r="2" /><circle cx="9" cy="12" r="2" /><circle cx="15" cy="18" r="2" /></>,
    codex: <><path d="M12 3 4.2 7.5v9L12 21l7.8-4.5v-9L12 3Z" /><path d="m7.8 9.6 4.2-2.4 4.2 2.4v4.8L12 16.8l-4.2-2.4V9.6Z" /></>,
    spark: <><path d="m12 2 1.4 5.1L18 10l-4.6 2.9L12 18l-1.4-5.1L6 10l4.6-2.9L12 2Z" /><path d="m19 16 .6 2.1L22 19.5l-2.4 1.4L19 23l-.6-2.1-2.4-1.4 2.4-1.4L19 16Z" /></>,
    plus: <path d="M12 5v14M5 12h14" />,
    refresh: <><path d="M20 6v5h-5" /><path d="M4 18v-5h5" /><path d="M18.5 9A7 7 0 0 0 6 6.5L4 9M5.5 15A7 7 0 0 0 18 17.5l2-2.5" /></>,
    cpu: <><rect x="7" y="7" width="10" height="10" rx="1" /><path d="M9 2v3M15 2v3M9 19v3M15 19v3M19 9h3M19 15h3M2 9h3M2 15h3" /></>,
    clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
    check: <path d="m5 12 4 4L19 6" />,
    arrow: <><path d="M5 12h14" /><path d="m14 7 5 5-5 5" /></>,
    terminal: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="m7 9 3 3-3 3M13 15h4" /></>,
    shield: <><path d="M12 3 5 6v5c0 4.6 2.8 8 7 10 4.2-2 7-5.4 7-10V6l-7-3Z" /><path d="m9 12 2 2 4-4" /></>,
    gpu: <><rect x="3" y="6" width="18" height="12" rx="2" /><circle cx="13" cy="12" r="3" /><path d="M6 9v6M21 10h2M21 14h2" /></>,
    more: <><circle cx="5" cy="12" r="1" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="1" fill="currentColor" stroke="none" /><circle cx="19" cy="12" r="1" fill="currentColor" stroke="none" /></>,
  };

  return (
    <svg
      aria-hidden="true"
      className="icon"
      fill="none"
      height={size}
      viewBox="0 0 24 24"
      width={size}
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="1.8"
    >
      {paths[name]}
    </svg>
  );
}

function Logo() {
  return (
    <div className="logo" aria-label="ClusterYourCodex">
      <span className="logo-mark"><span /><span /><span /></span>
      <span>Cluster<span>Your</span>Codex</span>
    </div>
  );
}

function StatusDot({ status }: { status: NodeStatus | "connected" | "disconnected" }) {
  const normalized = status === "connected" ? "online" : status === "disconnected" ? "offline" : status;
  return <span className={`status-dot status-${normalized}`} aria-label={status} />;
}

function EmptyState({
  icon,
  title,
  copy,
  action,
}: {
  icon: IconName;
  title: string;
  copy: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty-state">
      <div className="empty-icon"><Icon name={icon} size={24} /></div>
      <h3>{title}</h3>
      <p>{copy}</p>
      {action}
    </div>
  );
}

function formatElapsed(milliseconds?: number) {
  if (milliseconds === undefined) return "—";
  const seconds = Math.max(0, Math.round(milliseconds / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}

function statusLabel(status: JobStatus) {
  return status.charAt(0).toUpperCase() + status.slice(1);
}

function NodeRow({ node }: { node: NodeSummary }) {
  const memory = node.resources?.memoryTotalMiB
    ? Math.round(((node.resources.memoryUsedMiB ?? 0) / node.resources.memoryTotalMiB) * 100)
    : undefined;

  return (
    <div className="node-row">
      <div className={`device-icon device-${node.os}`}><Icon name="computer" size={21} /></div>
      <div className="node-main">
        <div className="node-title"><StatusDot status={node.status} /><strong>{node.name}</strong></div>
        <span>{node.os} · {node.arch} · {node.address}</span>
        <span>{node.availability ? `Availability: ${node.availability}` : `Status: ${node.status}`}</span>
        {node.slots && <span>{node.slots.available}/{node.slots.effective} execution slots available</span>}
        {node.availabilityReasons?.[0] && <span className="capacity-reason">{node.availabilityReasons[0]}</span>}
        {node.telemetry && <span className="capacity-reason">Telemetry seq {node.telemetry.sequence} · boot {node.telemetry.bootGeneration} · received {new Date(node.telemetry.receivedAt).toLocaleTimeString()}</span>}
      </div>
      <div className="node-capabilities">
        {node.capabilities.slice(0, 3).map((capability) => <span key={capability}>{capability}</span>)}
      </div>
      <div className="resource-cell">
        <span>CPU {node.resources?.cpuPercent === undefined ? "—" : `${Math.round(node.resources.cpuPercent)}%`}</span>
        <div className="meter"><i style={{ width: `${node.resources?.cpuPercent ?? 0}%` }} /></div>
      </div>
      <div className="resource-cell">
        <span>Memory {memory === undefined ? "—" : `${memory}%`}</span>
        <div className="meter"><i style={{ width: `${memory ?? 0}%` }} /></div>
      </div>
      <button className="icon-button" aria-label={`More options for ${node.name}`}><Icon name="more" /></button>
    </div>
  );
}

function HomePage({ fleet, online, openPage, openAddComputer }: { fleet?: FleetInfo; online: boolean; openPage: (page: Page) => void; openAddComputer: () => void }) {
  const { t } = useI18n();
  const nodes = fleet?.nodes ?? [];
  const onlineNodes = nodes.filter((node) => node.status === "online" || node.status === "busy").length;
  const recentJobs = fleet?.recentJobs ?? [];

  return (
    <>
      <section className="hero-card">
        <div className="hero-glow" />
        <div className="hero-copy">
          <span className="eyebrow"><Icon name="spark" size={15} /> {t("home.eyebrow")}</span>
          <h2>{t("home.title")}</h2>
          <p>{t("home.description")}</p>
          <div className="hero-actions">
            <button className="button button-dark" onClick={openAddComputer}><Icon name="plus" /> {t("home.addComputer")}</button>
            <button className="text-button" onClick={() => openPage("integration")}>{t("home.stepConnect")} <Icon name="arrow" /></button>
          </div>
        </div>
        <div className="hero-visual" aria-hidden="true">
          <div className="orbit orbit-large"><span className="orbit-node node-a"><Icon name="computer" /></span><span className="orbit-node node-b"><Icon name="gpu" /></span></div>
          <div className="orbit orbit-small"><span className="orbit-node node-c"><Icon name="terminal" /></span></div>
          <div className="codex-core"><Icon name="codex" size={34} /><small>CODEX</small></div>
        </div>
      </section>

      {nodes.length === 0 && recentJobs.length === 0 ? (
        <section className="panel first-run-panel" aria-labelledby="first-run-title">
          <div className="first-run-copy">
            <span className="eyebrow">{t("home.quickStart")}</span>
            <h3 id="first-run-title">{t("home.quickStartTitle")}</h3>
            <p>{t("home.quickStartDescription")}</p>
          </div>
          <ol className="first-run-steps">
            <li><span>1</span><strong>{t("home.stepAdd")}</strong><button className="text-button small" onClick={openAddComputer}>{t("home.stepStart")} <Icon name="arrow" size={14} /></button></li>
            <li><span>2</span><strong>{t("home.stepConnect")}</strong><button className="text-button small" onClick={() => openPage("integration")}>{t("home.stepOpen")} <Icon name="arrow" size={14} /></button></li>
            <li><span>3</span><strong>{t("home.stepCheck")}</strong><small>{t("home.stepPending")}</small></li>
          </ol>
        </section>
      ) : <>
      <section className="stat-grid">
        <article className="stat-card">
          <div className="stat-icon mint"><Icon name="computer" /></div>
          <div><span>Available computers</span><strong>{online ? `${onlineNodes} / ${nodes.length}` : "—"}</strong></div>
          <button className="stat-link" onClick={() => openPage("computers")}>View fleet <Icon name="arrow" size={14} /></button>
        </article>
        <article className="stat-card">
          <div className="stat-icon amber"><Icon name="tasks" /></div>
          <div><span>Running now</span><strong>{online ? fleet?.controller.activeJobs ?? 0 : "—"}</strong></div>
          <span className="stat-note">{online ? `${fleet?.controller.queuedJobs ?? 0} queued` : "Controller offline"}</span>
        </article>
        <article className="stat-card">
          <div className="stat-icon violet"><Icon name="check" /></div>
          <div><span>Completed today</span><strong>{online ? fleet?.controller.completedToday ?? 0 : "—"}</strong></div>
          <span className="stat-note">Verified runs</span>
        </article>
      </section>

      <section className="dashboard-grid">
        <article className="panel fleet-panel">
          <header className="panel-header">
            <div><h3>Fleet overview</h3><p>Live capacity Codex can use</p></div>
            <button className="text-button small" onClick={() => openPage("computers")}>Manage <Icon name="arrow" size={14} /></button>
          </header>
          {nodes.length > 0 ? <div className="node-list">{nodes.slice(0, 4).map((node) => <NodeRow key={node.id} node={node} />)}</div> : (
            <EmptyState
              icon="computer"
              title="No computers connected yet"
              copy="Add your first machine and Codex can start delegating heavy work."
              action={<button className="button button-primary" onClick={openAddComputer}><Icon name="plus" /> Add computer</button>}
            />
          )}
        </article>

        <article className="panel activity-panel">
          <header className="panel-header">
            <div><h3>Recent tasks</h3><p>Delegated by Codex</p></div>
            <button className="text-button small" onClick={() => openPage("tasks")}>View all <Icon name="arrow" size={14} /></button>
          </header>
          {recentJobs.length > 0 ? (
            <div className="task-list">
              {recentJobs.slice(0, 5).map((job) => (
                <div className="task-row" key={job.id}>
                  <span className={`task-state task-${job.status}`}><Icon name={job.status === "succeeded" ? "check" : "terminal"} size={15} /></span>
                  <div><strong>{job.title ?? `${job.kind} task`}</strong><span>{job.nodeName ?? "Waiting for placement"}</span></div>
                  <time>{formatElapsed(job.elapsedMs)}</time>
                </div>
              ))}
            </div>
          ) : (
            <EmptyState icon="tasks" title="No delegated tasks yet" copy="When Codex sends work to your fleet, each run will appear here." />
          )}
        </article>
      </section>
      </>}
    </>
  );
}

function ComputersPage({ fleet, addRequest }: { fleet?: FleetInfo; addRequest: number }) {
  const { t } = useI18n();
  const nodes = fleet?.nodes ?? [];
  return (
    <div className="computers-layout">
      <ProvisioningComputers addRequest={addRequest} />
      <section className="panel page-panel">
        <header className="panel-header">
          <div><h3>{t("computers.connectedTitle")}</h3><p>{t("computers.connectedDescription")}</p></div>
        </header>
        {nodes.length ? (
          <div className="node-list full">{nodes.map((node) => <NodeRow key={node.id} node={node} />)}</div>
        ) : (
          <EmptyState
            icon="computer"
            title={t("computers.noReadyTitle")}
            copy={t("computers.noReadyDescription")}
          />
        )}
      </section>
    </div>
  );
}

function TasksPage({ fleet }: { fleet?: FleetInfo }) {
  const jobs = fleet?.recentJobs ?? [];
  return (
    <section className="panel page-panel">
      <header className="panel-header">
        <div><h3>Task history</h3><p>Source identity, placement, native exit code, and artifacts stay attached to every run.</p></div>
        <div className="filter-group"><button className="chip active">All</button><button className="chip">Running</button><button className="chip">Failed</button></div>
      </header>
      {jobs.length ? (
        <div className="task-table">
          <div className="table-head"><span>Task</span><span>Computer</span><span>Status</span><span>Duration</span></div>
          {jobs.map((job) => (
            <div className="table-row" key={job.id}>
              <div>
                <strong>{job.title ?? `${job.kind} task`}</strong><span>{job.id}</span>
                {job.placement ? <PlacementDetails job={job} /> : null}
              </div>
              <span>{job.nodeName ?? "—"}</span>
              <span className={`status-pill job-${job.status}`}>{statusLabel(job.status)}</span>
              <span>{formatElapsed(job.elapsedMs)}</span>
            </div>
          ))}
        </div>
      ) : <EmptyState icon="tasks" title="Your task history is empty" copy="Ask Codex to run a meaningful build, test, container, or GPU workload. ClusterYourCodex will record it here." />}
    </section>
  );
}

function PlacementDetails({ job }: { job: NonNullable<FleetInfo["recentJobs"]>[number] }) {
  const selectedId = job.placement?.selectedNodeId ?? job.nodeId;
  const selected = job.placement?.candidates.find((candidate) => candidate.nodeId === selectedId);
  const excluded = job.placement?.candidates.filter((candidate) => !candidate.eligible) ?? [];
  if (!job.placement || (!selected && excluded.length === 0)) return null;
  return (
    <details className="placement-details">
      <summary>Why this computer</summary>
      {selected ? (
        <div>
          <strong>Selected: {selected.nodeName}</strong>
          {selected.scoreComponents.map((component) => (
            <span key={`${component.key}:${component.detail}`}>{component.value >= 0 ? "+" : "−"} {component.detail}</span>
          ))}
        </div>
      ) : null}
      {excluded.slice(0, 4).map((candidate) => (
        <div key={candidate.nodeId}>
          <strong>{candidate.nodeName} excluded</strong>
          {candidate.rejectionReasons.slice(0, 3).map((reason) => <span key={`${reason.code}:${reason.detail}`}>− {reason.detail}</span>)}
        </div>
      ))}
    </details>
  );
}

const builtInRules = [
  { icon: "gpu" as IconName, name: "GPU workloads", target: "Prefer NVIDIA-capable computers", tone: "violet" },
  { icon: "computer" as IconName, name: "Windows builds", target: "Require Windows and compatible toolchains", tone: "blue" },
  { icon: "terminal" as IconName, name: "Linux builds and containers", target: "Prefer the fastest eligible Linux computer", tone: "mint" },
  { icon: "clock" as IconName, name: "Light always-on tasks", target: "Prefer low-load, service-suitable computers", tone: "amber" },
];

function RulesPage() {
  return (
    <div className="rules-layout">
      <section className="panel page-panel">
        <header className="panel-header with-actions"><div><h3>Active routing rules</h3><p>Hard compatibility always wins before performance preference.</p></div><button className="button button-secondary"><Icon name="plus" /> New rule</button></header>
        <div className="rule-list">
          {builtInRules.map((rule, index) => (
            <div className="rule-row" key={rule.name}>
              <span className="drag-handle">⠿</span>
              <span className={`stat-icon ${rule.tone}`}><Icon name={rule.icon} /></span>
              <div><strong>{rule.name}</strong><span>{rule.target}</span></div>
              <span className="rule-order">Priority {index + 1}</span>
              <label className="switch"><input type="checkbox" defaultChecked /><span /></label>
              <button className="icon-button" aria-label={`More options for ${rule.name}`}><Icon name="more" /></button>
            </div>
          ))}
        </div>
      </section>
      <aside className="panel explanation-card">
        <div className="stat-icon mint"><Icon name="shield" /></div>
        <h3>Predictable by design</h3>
        <p>Codex sees the selected computer and the exact reasons before a task starts. State-changing jobs never jump to another machine after they begin.</p>
        <div className="decision-order"><span>1</span><p><strong>Compatibility</strong>OS, architecture, tools, GPU</p></div>
        <div className="decision-order"><span>2</span><p><strong>Availability</strong>Health, queue, free resources</p></div>
        <div className="decision-order"><span>3</span><p><strong>Preference</strong>Your rule priority</p></div>
      </aside>
    </div>
  );
}

const integrationLabelKeys: Record<IntegrationState, TranslationKey> = {
  not_found: "integration.state.notFound",
  not_installed: "integration.state.notInstalled",
  installed: "integration.state.installed",
  restart_required: "integration.state.restartRequired",
  connected: "integration.state.connected",
  stale: "integration.state.stale",
  broken: "integration.state.broken",
  version_mismatch: "integration.state.versionMismatch",
};

function IntegrationPage({
  online,
  fleet,
  fleetRevision,
  fleetObservedAt,
}: {
  online: boolean;
  fleet?: FleetInfo;
  fleetRevision?: number;
  fleetObservedAt?: string;
}) {
  const { t } = useI18n();
  const [status, setStatus] = useState<IntegrationStatus>();
  const [statusFresh, setStatusFresh] = useState(false);
  const [statusChecking, setStatusChecking] = useState(true);
  const [autoPollStatus, setAutoPollStatus] = useState(false);
  const [operation, setOperation] = useState<"install" | "check" | "full_check">();
  const [error, setError] = useState<string>();
  const [result, setResult] = useState<IntegrationActionResult | IntegrationSelfTestResult>();
  const [fullRunResult, setFullRunResult] = useState<FullRunCheckResult>();
  const [fullRunBaseline, setFullRunBaseline] = useState<FullRunEvidenceBaseline>();
  const [fullRunError, setFullRunError] = useState<string>();
  const [integrationGeneration, setIntegrationGeneration] = useState(0);
  const statusSequence = useRef(0);
  const fullRunOperationSequence = useRef(0);

  const refreshStatus = useCallback(async () => {
    const sequence = ++statusSequence.current;
    setStatusChecking(true);
    setStatusFresh(false);
    try {
      const next = await integrationClient.status();
      if (sequence !== statusSequence.current) return;
      setStatus(next);
      setStatusFresh(true);
      setAutoPollStatus(["restart_required", "installed", "stale"].includes(next.state));
      setError(undefined);
    } catch (caught) {
      if (sequence !== statusSequence.current) return;
      setStatus(undefined);
      setStatusFresh(false);
      setError(caught instanceof Error ? caught.message : "Could not read Codex integration status");
    } finally {
      if (sequence === statusSequence.current) setStatusChecking(false);
    }
  }, []);

  useEffect(() => {
    void refreshStatus();
  }, [refreshStatus]);

  useEffect(() => {
    if (!statusFresh || !status) return undefined;
    const remaining = Math.max(0, status.checkedAtMs + INTEGRATION_STATUS_MAX_AGE_MS - Date.now());
    const timer = window.setTimeout(() => setStatusFresh(false), remaining);
    return () => window.clearTimeout(timer);
  }, [status, statusFresh]);

  useEffect(() => () => {
    fullRunOperationSequence.current += 1;
  }, []);

  const busy = operation !== undefined;
  useEffect(() => {
    if (busy || statusChecking || !autoPollStatus) return undefined;
    const timer = window.setTimeout(() => void refreshStatus(), 3_000);
    return () => window.clearTimeout(timer);
  }, [autoPollStatus, busy, refreshStatus, statusChecking]);

  const install = useCallback(async () => {
    setIntegrationGeneration((current) => current + 1);
    setOperation("install");
    setStatusFresh(false);
    setError(undefined);
    setResult(undefined);
    try {
      const installResult = await integrationClient.installOrRepair();
      setStatus(installResult.status);
      setStatusFresh(true);
      setAutoPollStatus(["restart_required", "installed", "stale"].includes(installResult.status.state));
      setResult(installResult);
    } catch (caught) {
      setStatus(undefined);
      setStatusFresh(false);
      setError(caught instanceof Error ? caught.message : "Codex plugin installation failed");
    } finally {
      setOperation(undefined);
    }
  }, []);

  const runPluginCheck = useCallback(async () => {
    setOperation("check");
    setStatusFresh(false);
    setError(undefined);
    setResult(undefined);
    try {
      const checkResult = await integrationClient.selfTest();
      setStatus(checkResult.status);
      setStatusFresh(true);
      setAutoPollStatus(["restart_required", "installed", "stale"].includes(checkResult.status.state));
      setResult(checkResult);
    } catch (caught) {
      setStatus(undefined);
      setStatusFresh(false);
      setError(caught instanceof Error ? caught.message : "Codex plugin check failed");
    } finally {
      setOperation(undefined);
    }
  }, []);

  const runFullCheck = useCallback(async () => {
    if (!status || !statusFresh) return;
    const sequence = ++fullRunOperationSequence.current;
    setOperation("full_check");
    setFullRunError(undefined);
    setFullRunResult(undefined);
    setFullRunBaseline(undefined);
    try {
      const check = await integrationClient.fullRunCheckWithProgress((progress) => {
        if (sequence === fullRunOperationSequence.current) setFullRunResult(progress);
      });
      if (sequence !== fullRunOperationSequence.current) return;
      setFullRunResult(check);
      if (check.state === "passed" && check.finalFleet && check.selectedNode) {
        const provedStatus = check.integration
          ? {
              ...status,
              activeRuntime: {
                pid: check.integration.activeRuntime.pid,
                startedAt: check.integration.activeRuntime.startedAt,
                bridgeVersion: check.integration.activeRuntime.bridgeVersion,
              },
            }
          : status;
        setFullRunBaseline({
          integrationIdentity: integrationStatusIdentity(provedStatus),
          integrationGeneration,
          fleetRevision: check.finalFleet.fleetRevision,
          selectedNodeId: check.selectedNode.id,
          selectedNodeHeartbeatAt: check.selectedNode.heartbeatAt,
        });
      }
    } catch (caught) {
      if (sequence !== fullRunOperationSequence.current) return;
      setFullRunResult(undefined);
      setFullRunError(caught instanceof Error ? caught.message : "Full Run Check failed to start");
    } finally {
      if (sequence === fullRunOperationSequence.current) {
        setOperation(undefined);
        void refreshStatus();
      }
    }
  }, [integrationGeneration, refreshStatus, status, statusFresh]);

  const pluginConnected = statusFresh && status?.state === "connected" && status.agentsIntegrated;
  const pluginInstalled = statusFresh && status?.pluginEnabled && status.agentsIntegrated &&
    Boolean(status.payloadCatalogSha256) && Boolean(status.buildCatalogSha256) &&
    status.installedVersion === status.desiredVersion &&
    ["installed", "restart_required", "connected", "stale"].includes(status.state);
  const installLabel = status?.state === "not_installed" || status?.state === "not_found"
    ? t("integration.install")
    : status?.state === "version_mismatch"
      ? t("integration.update")
      : t("integration.repair");
  const resultSteps = result && "steps" in result ? result.steps : result?.checks;
  const standalonePassed = result && "passed" in result ? result.passed : undefined;
  const actionPassed = result && "steps" in result
    ? result.steps.every((step) => step.passed) && result.status.state !== "broken"
    : standalonePassed;
  const staleReason = fullRunResult?.state === "passed"
    ? fullRunStaleReason(fullRunBaseline, {
        controllerOnline: online,
        statusFresh,
        status,
        integrationGeneration,
        fleetRevision,
        selectedNode: fullRunResult?.selectedNode
          ? fleet?.nodes.find((node) => node.id === fullRunResult.selectedNode?.id)
          : undefined,
      })
    : undefined;
  const fullRunVisualState = operation === "full_check"
    ? "running"
    : staleReason
      ? "stale"
      : fullRunResult?.state ?? "ready";

  return (
    <div className="integration-layout">
      <section className="integration-hero panel">
        <div className="integration-mark"><Icon name="codex" size={40} /><span><i /><i /><i /></span></div>
        <span className="eyebrow">CODEX + YOUR COMPUTERS</span>
        <h2>{pluginConnected ? t("integration.connectedTitle") : t("integration.connectTitle")}</h2>
        <p>{t("integration.pluginDescription")}</p>
        <div className="connection-statuses">
          <div><StatusDot status={online ? "connected" : "disconnected"} /><span>{t("integration.desktopController")}</span><strong>{online ? t("status.online") : t("status.offline")}</strong></div>
          <div><StatusDot status={pluginConnected ? "connected" : "disconnected"} /><span>{t("integration.codexPlugin")}</span><strong>{statusFresh && status ? t(integrationLabelKeys[status.state]) : statusChecking ? t("integration.checking") : t("integration.unknown")}</strong></div>
        </div>
        {statusFresh && status ? (
          <div className={`integration-state state-${status.state}`}>
            <strong>{t(integrationLabelKeys[status.state])}</strong><span>{status.message}</span>
            {status.installedVersion ? <small>Plugin v{status.installedVersion}{status.cliVersion ? ` · ${status.cliVersion}` : ""}{status.agentsIntegrated ? " · global AGENTS verified" : " · global AGENTS missing or drifted"}</small> : null}
            {status.activeRuntime ? <small>Active Codex runtime online · PID {status.activeRuntime.pid} · started {new Date(status.activeRuntime.startedAt).toLocaleString()} · bridge {status.activeRuntime.bridgeVersion}</small> : null}
            <small>Status checked {new Date(status.checkedAtMs).toLocaleString()}</small>
            <button className="text-button small" disabled={busy || statusChecking} onClick={() => void refreshStatus()}>{statusChecking ? t("integration.checking") : t("integration.checkAgain")}</button>
          </div>
        ) : (
          <div className="integration-state state-stale"><strong>{t("integration.statusNotVerified")}</strong><span>{t("integration.statusNeedsRefresh")}</span><button className="text-button small" disabled={busy || statusChecking} onClick={() => void refreshStatus()}>{statusChecking ? t("integration.checking") : t("integration.checkAgain")}</button></div>
        )}
      </section>
      <section className="panel setup-panel">
        <header className="panel-header"><div><h3>{t("integration.checklistTitle")}</h3><p>{t("integration.checklistDescription")}</p></div></header>
        <div className={`setup-step ${online ? "done" : "current"}`}><span>{online ? <Icon name="check" /> : "1"}</span><div><strong>{t("integration.stepController")}</strong><p>{online ? t("integration.controllerReady") : t("integration.controllerStart")}</p></div></div>
        <div className={`setup-step ${pluginInstalled ? "done" : "current"}`}><span>{pluginInstalled ? <Icon name="check" /> : "2"}</span><div><strong>{t("integration.stepPlugin")}</strong><p>{t("integration.pluginDescriptionShort")}</p></div><button className="button button-secondary" disabled={busy || statusChecking || status?.state === "not_found"} onClick={() => void install()}>{operation === "install" ? t("integration.working") : installLabel}</button></div>
        <div className={`setup-step ${pluginConnected ? "done" : pluginInstalled ? "current" : ""}`}><span>{pluginConnected ? <Icon name="check" /> : "3"}</span><div><strong>{t("integration.stepCheck")}</strong><p>{t("integration.pluginCheckDescription")}</p></div><button className="text-button small" disabled={busy || statusChecking || !online || !pluginInstalled} onClick={() => void runPluginCheck()}>{operation === "check" ? t("integration.checking") : t("integration.stepCheck")} <Icon name="arrow" size={14} /></button></div>
        {error ? <div className="integration-result is-error" role="alert"><strong>{t("integration.operationFailed")}</strong><span>{error}</span><button className="text-button small" disabled={busy || statusChecking} onClick={() => void refreshStatus()}>{t("integration.refreshStatus")}</button></div> : null}
        {result && resultSteps ? (
          <div className={`integration-result ${actionPassed ? "is-success" : "is-error"}`} aria-live="polite">
            <strong>{"passed" in result
              ? result.passed
                ? result.status.state === "connected" ? "Standalone plugin self-test passed; live runtime is Connected" : `Standalone plugin self-test passed; live runtime is ${t(integrationLabelKeys[result.status.state])}`
                : "Standalone plugin self-test failed"
              : actionPassed
                ? result.restartRequired ? "Plugin installed — restart Codex" : "Plugin install/repair transaction completed"
                : "Plugin install/repair did not reach a healthy installed state"}</strong>
            {resultSteps.map((item) => <span key={item.id}><i>{item.passed ? "✓" : "!"}</i>{item.message}</span>)}
            {"durationMs" in result ? <small>Standalone check completed in {result.durationMs} ms{result.restartRecommended ? " · Codex restart is still recommended" : ""}</small> : null}
            {"durationMs" in result && result.selfTestExecutor ? <small>Isolated installed-MCP executor · PID {result.selfTestExecutor.pid} · session {result.selfTestExecutor.sessionId} · bridge {result.selfTestExecutor.bridgeVersion}</small> : null}
          </div>
        ) : null}
      </section>
      <details className="panel full-run-details">
        <summary><span><strong>{t("integration.advanced")}</strong><small>{t("integration.advancedDescription")}</small></span><span className={`status-pill check-${fullRunVisualState}`}>{fullRunVisualState === "running" ? "Running" : fullRunVisualState === "passed" ? "Passed" : fullRunVisualState === "failed" ? "Failed" : fullRunVisualState === "stale" ? "Stale" : "Ready"}</span></summary>
      <section className="full-run-check">
        <header><div><span className="eyebrow">END-TO-END VALIDATION</span><h3>Full Run Check</h3></div><span className={`status-pill check-${fullRunVisualState}`}>{fullRunVisualState === "running" ? "Running" : fullRunVisualState === "passed" ? "Passed" : fullRunVisualState === "failed" ? "Failed" : fullRunVisualState === "stale" ? "Stale" : "Ready"}</span></header>
        <p>This is a real bounded proof: require an active Codex runtime online, separately run an isolated installed-MCP end-to-end executor, require a fresh managed-worker heartbeat, execute over managed HTTPS, verify outputs, and require an authoritative removal receipt.</p>
        <ol>{(fullRunResult?.layers ?? fullRunLayerIds.map((id, index) => ({ id, state: operation === "full_check" && index === 0 ? "running" as const : "pending" as const, message: operation === "full_check" && index === 0 ? "Native end-to-end check is running." : "Waiting for the native check." }))).map((layer) => <li className={`layer-${layer.state}`} key={layer.id} title={layer.message}><i>{layer.state === "passed" ? "✓" : layer.state === "failed" ? "!" : layer.state === "running" ? "↻" : layer.state === "skipped" ? "×" : "—"}</i><span><strong>{layer.id.split("_").map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(" ")}</strong><small>{layer.message}</small></span></li>)}</ol>
        {fullRunError ? <div className="full-run-evidence is-error" role="alert"><strong>Full Run Check could not complete</strong><span>{fullRunError}</span></div> : null}
        {staleReason ? <div className="full-run-evidence is-stale" role="status"><strong>Historical PASS is stale</strong><span>{staleReason}</span><span>Run Full Check again before relying on this proof.</span></div> : null}
        {fullRunResult ? (
          <div className={`full-run-evidence ${fullRunResult.state === "running" ? "is-running" : fullRunResult.state === "passed" && !staleReason ? "is-success" : fullRunResult.state === "failed" ? "is-error" : "is-stale"}`} aria-live="polite">
            <strong>{fullRunResult.state === "running"
              ? `Full Run Check running${fullRunResult.failure ? ` · cleanup after ${fullRunResult.failure.code}` : ""}`
              : fullRunResult.state === "passed"
                ? staleReason ? "Previous end-to-end proof (stale)" : "End-to-end worker proof passed"
                : `Full Run Check failed${fullRunResult.failure ? ` · ${fullRunResult.failure.code}` : ""}`}</strong>
            <span>{fullRunResult.finishedAt
              ? `Check window ${new Date(fullRunResult.startedAt).toLocaleString()} → ${new Date(fullRunResult.finishedAt).toLocaleString()} · ${fullRunResult.durationMs} ms`
              : `Check started ${new Date(fullRunResult.startedAt).toLocaleString()} · ${fullRunResult.durationMs} ms elapsed`}</span>
            <span>{fullRunResult.integration ? `Active Codex runtime online · PID ${fullRunResult.integration.activeRuntime.pid} · started ${new Date(fullRunResult.integration.activeRuntime.startedAt).toLocaleString()} · bridge ${fullRunResult.integration.activeRuntime.bridgeVersion} · independently reverified ${fullRunResult.integration.activeRuntime.reverifiedAfterRun ? "yes" : "no"}` : "No active Codex runtime evidence was accepted."}</span>
            <span>{fullRunResult.integration?.selfTestExecutor ? `Isolated installed-MCP end-to-end executor · PID ${fullRunResult.integration.selfTestExecutor.pid} · session ${fullRunResult.integration.selfTestExecutor.sessionId} · MCP tools: ${fullRunResult.integration.selfTestExecutor.mcpToolsExercised.join(", ")} · controller round trip ${new Date(fullRunResult.integration.selfTestExecutor.controllerRoundTripAt).toLocaleString()}` : "No isolated installed-MCP executor evidence was accepted."}</span>
            <span>{fullRunResult.selectedNode ? `Worker ${fullRunResult.selectedNode.name} (${fullRunResult.selectedNode.id}) · heartbeat ${new Date(fullRunResult.selectedNode.heartbeatAt).toLocaleString()}` : "No worker evidence was accepted."}</span>
            <span>{fullRunResult.transport ? `${fullRunResult.transport.transport} · TLS ${fullRunResult.transport.tls ? "verified" : "missing"} · per-node credential reference ${fullRunResult.transport.credentialReferencePresent ? "present" : "missing"} · ${fullRunResult.transport.endpoint}` : "No managed transport evidence was accepted."}</span>
            <span>{fullRunResult.placement ? `Plan ${fullRunResult.placement.planId} · score ${fullRunResult.placement.score} · revisions ${fullRunResult.placement.fleetRevision}/${fullRunResult.placement.nodeRevision}/${fullRunResult.placement.policyRevision}${fleetObservedAt ? ` · current fleet observed ${new Date(fleetObservedAt).toLocaleString()}` : ""}` : "No controller placement evidence was accepted."}</span>
            <span>{fullRunResult.finalFleet ? `Post-run fleet revision ${fullRunResult.finalFleet.fleetRevision} · observed ${new Date(fullRunResult.finalFleet.observedAt).toLocaleString()}${fleetRevision !== undefined ? ` · current revision ${fleetRevision}` : ""}` : "No post-run fleet freshness evidence was accepted."}</span>
            <span>{fullRunResult.snapshot ? `${fullRunResult.snapshot.digest} · ${fullRunResult.snapshot.sizeBytes} bytes` : "No snapshot receipt was accepted."}</span>
            <span>{fullRunResult.job ? `Job ${fullRunResult.job.jobId} · run ${fullRunResult.job.runId} · ${fullRunResult.job.observedStates.join(" → ")} · exit ${fullRunResult.job.exitCode ?? "pending"}` : "No job receipt has been accepted yet."}</span>
            {fullRunResult.logs.map((log) => <span key={log.stream}>Log {log.stream} · {log.sizeBytes} bytes · {log.chunkCount} chunk(s) · SHA-256 {log.sha256}</span>)}
            {fullRunResult.artifacts.map((artifact) => <span key={artifact.id}>Artifact {artifact.name} · {artifact.sizeBytes} bytes · SHA-256 {artifact.sha256}</span>)}
            <span>{fullRunResult.cleanup ? `Cleanup ${fullRunResult.cleanup.status} · ${fullRunResult.cleanup.relativeRoot} deleted · terminal version ${fullRunResult.cleanup.terminalStateVersion} · reservation released by ${fullRunResult.cleanup.releaseReason} at ${new Date(fullRunResult.cleanup.reservationReleasedAt).toLocaleString()}` : "No authoritative cleanup receipt was accepted."}</span>
          </div>
        ) : null}
        <button className="button button-secondary" disabled={busy || statusChecking || !online || !pluginConnected} onClick={() => void runFullCheck()}>{operation === "full_check" ? "Running real worker proof…" : staleReason ? "Run Full Check again" : "Run Full Check"}</button>
      </section>
      </details>
    </div>
  );
}

export function App() {
  const { locale, setLocale, t } = useI18n();
  const [page, setPage] = useState<Page>("home");
  const [fleet, setFleet] = useState<FleetInfo>();
  const [online, setOnline] = useState(false);
  const [accessError, setAccessError] = useState<string>();
  const [loadingCount, setLoadingCount] = useState(0);
  const [lastCheckedAt, setLastCheckedAt] = useState<Date>();
  const [addComputerRequest, setAddComputerRequest] = useState(0);
  const refreshSequence = useRef(0);
  const lastAppliedRefresh = useRef(0);
  const loading = loadingCount > 0 || !lastCheckedAt;

  const openAddComputer = useCallback(() => {
    setPage("computers");
    setAddComputerRequest((current) => current + 1);
  }, []);

  const refresh = useCallback(async () => {
    const sequence = ++refreshSequence.current;
    setLoadingCount((current) => current + 1);
    try {
      const health = await controllerClient.health();
      const fleetInfo = await controllerClient.fleet();
      if (sequence !== refreshSequence.current || sequence < lastAppliedRefresh.current) return;
      lastAppliedRefresh.current = sequence;
      setOnline(health.status === "ready" || health.status === "degraded");
      setFleet((current) => preferNewerFleetSnapshot(current, fleetInfo));
      setAccessError(undefined);
    } catch (error) {
      if (sequence !== refreshSequence.current || sequence < lastAppliedRefresh.current) return;
      lastAppliedRefresh.current = sequence;
      setOnline(false);
      setFleet(undefined);
      setAccessError(
        error instanceof ControllerApiError && (error.code === "transport_unavailable" || error.status === 401 || error.status === 403)
          ? error.message
          : undefined,
      );
    } finally {
      if (sequence === refreshSequence.current && sequence >= lastAppliedRefresh.current) setLastCheckedAt(new Date());
      setLoadingCount((current) => Math.max(0, current - 1));
    }
  }, []);

  useEffect(() => {
    void refresh();
    const interval = window.setInterval(() => void refresh(), 5_000);
    return () => window.clearInterval(interval);
  }, [refresh]);

  const heading = pageTitles[page];
  const statusCopy = useMemo(() => {
    if (loading && !lastCheckedAt) return t("controller.checking");
    if (accessError) return t("controller.proxyUnavailable");
    if (!online) return t("controller.offline");
    return t("controller.availableCount", { count: fleet?.nodes.filter((node) => node.status === "online" || node.status === "busy").length ?? 0 });
  }, [accessError, fleet, lastCheckedAt, loading, online, t]);

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <Logo />
        <nav aria-label="Primary navigation">
          <span className="nav-label">{t("nav.workspace").toUpperCase()}</span>
          {navigation.slice(0, 4).map((item) => (
            <button className={page === item.id ? "active" : ""} key={item.id} onClick={() => setPage(item.id)}>
              <Icon name={item.icon} /><span>{t(item.labelKey)}</span>
              {item.id === "tasks" && (fleet?.controller.activeJobs ?? 0) > 0 ? <em>{fleet?.controller.activeJobs}</em> : null}
            </button>
          ))}
          <span className="nav-label integration-label">{t("nav.integrationGroup").toUpperCase()}</span>
          {navigation.slice(4).map((item) => (
            <button className={page === item.id ? "active" : ""} key={item.id} onClick={() => setPage(item.id)}><Icon name={item.icon} /><span>{t(item.labelKey)}</span></button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="controller-card">
            <div><StatusDot status={online ? "connected" : "disconnected"} /><strong>{online ? t("controller.online") : accessError ? t("controller.integrationUnavailable") : t("controller.offline")}</strong></div>
            <span>{online ? `v${fleet?.controller.version ?? "0.1"} · localhost` : accessError ? t("controller.proxyUnavailable") : t("controller.waiting")}</span>
          </div>
          <div className="profile"><span className="avatar">CY</span><div><strong>{t("workspace.local")}</strong><span>{t("workspace.personalFleet")}</span></div><Icon name="more" /></div>
        </div>
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div><h1>{t(heading.titleKey)}</h1><p>{t(heading.subtitleKey)}</p></div>
          <div className="topbar-actions">
            <label className="language-picker"><span>{t("language.label")}</span><select aria-label={t("language.label")} onChange={(event) => setLocale(event.target.value as typeof locale)} value={locale}>{localeOptions.map((option) => <option key={option.locale} value={option.locale}>{t(option.labelKey)}</option>)}</select></label>
            <span className={`live-status ${online ? "is-online" : ""}`}><StatusDot status={online ? "connected" : "disconnected"} />{statusCopy}</span>
            <button className={`icon-button refresh-button ${loading ? "spinning" : ""}`} onClick={() => void refresh()} aria-label="Refresh controller status"><Icon name="refresh" /></button>
            <button className="button button-primary" onClick={openAddComputer}><Icon name="plus" /> {t("computers.add")}</button>
          </div>
        </header>

        {!online && !accessError && !loading ? (
          <div className="offline-banner"><Icon name="terminal" /><div><strong>{t("controller.offlineTitle")}</strong><span>{t("controller.offlineDescription", { port: 47831 })}</span></div><button className="text-button small" onClick={() => setPage("integration")}>{t("controller.openSetup")} <Icon name="arrow" size={14} /></button></div>
        ) : null}
        {accessError && !loading ? (
          <div className="offline-banner auth-banner"><Icon name="shield" /><div><strong>The secure controller proxy is unavailable.</strong><span>{accessError}</span></div><button className="text-button small" onClick={() => setPage("integration")}>Repair integration <Icon name="arrow" size={14} /></button></div>
        ) : null}

        <div className="page-content">
          {page === "home" ? <HomePage fleet={fleet} online={online} openAddComputer={openAddComputer} openPage={setPage} /> : null}
          {page === "computers" ? <ComputersPage addRequest={addComputerRequest} fleet={fleet} /> : null}
          {page === "tasks" ? <TasksPage fleet={fleet} /> : null}
          {page === "rules" ? <RulesPage /> : null}
          {page === "integration" ? <IntegrationPage fleet={fleet} fleetObservedAt={fleet?.observedAt} fleetRevision={fleet?.fleetRevision} online={online} /> : null}
        </div>
      </main>
    </div>
  );
}
