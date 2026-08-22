import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { controllerClient } from "./api/client";
import type { FleetInfo, JobStatus, NodeStatus, NodeSummary } from "./api/types";

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

const navigation: Array<{ id: Page; label: string; icon: IconName }> = [
  { id: "home", label: "Home", icon: "home" },
  { id: "computers", label: "Computers", icon: "computer" },
  { id: "tasks", label: "Tasks", icon: "tasks" },
  { id: "rules", label: "Routing rules", icon: "rules" },
  { id: "integration", label: "Codex integration", icon: "codex" },
];

const pageTitles: Record<Page, { title: string; subtitle: string }> = {
  home: {
    title: "Your Codex fleet",
    subtitle: "One place to see where Codex is working and why.",
  },
  computers: {
    title: "Computers",
    subtitle: "Connect the machines Codex can use for builds, tests, and compute.",
  },
  tasks: {
    title: "Tasks",
    subtitle: "Track every delegated run from queue to verified artifact.",
  },
  rules: {
    title: "Routing rules",
    subtitle: "Decide which computer Codex should prefer for each kind of work.",
  },
  integration: {
    title: "Codex integration",
    subtitle: "Keep the desktop controller and Codex plugin connected.",
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

function HomePage({ fleet, online, openPage }: { fleet?: FleetInfo; online: boolean; openPage: (page: Page) => void }) {
  const nodes = fleet?.nodes ?? [];
  const onlineNodes = nodes.filter((node) => node.status === "online" || node.status === "busy").length;
  const recentJobs = fleet?.recentJobs ?? [];

  return (
    <>
      <section className="hero-card">
        <div className="hero-glow" />
        <div className="hero-copy">
          <span className="eyebrow"><Icon name="spark" size={15} /> CODEX COMPUTE POOL</span>
          <h2>Let Codex use every<br />computer you own.</h2>
          <p>Add Windows, Linux, and GPU machines. ClusterYourCodex chooses the right one, runs the work, and brings the result back.</p>
          <div className="hero-actions">
            <button className="button button-dark" onClick={() => openPage("computers")}><Icon name="plus" /> Add a computer</button>
            <button className="text-button" onClick={() => openPage("integration")}>Connect Codex <Icon name="arrow" /></button>
          </div>
        </div>
        <div className="hero-visual" aria-hidden="true">
          <div className="orbit orbit-large"><span className="orbit-node node-a"><Icon name="computer" /></span><span className="orbit-node node-b"><Icon name="gpu" /></span></div>
          <div className="orbit orbit-small"><span className="orbit-node node-c"><Icon name="terminal" /></span></div>
          <div className="codex-core"><Icon name="codex" size={34} /><small>CODEX</small></div>
        </div>
      </section>

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
              action={<button className="button button-primary" onClick={() => openPage("computers")}><Icon name="plus" /> Add computer</button>}
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
    </>
  );
}

function ComputersPage({ fleet }: { fleet?: FleetInfo }) {
  const nodes = fleet?.nodes ?? [];
  return (
    <section className="panel page-panel">
      <header className="panel-header with-actions">
        <div><h3>Connected computers</h3><p>Each machine is probed before Codex schedules work.</p></div>
        <button className="button button-primary"><Icon name="plus" /> Add computer</button>
      </header>
      {nodes.length ? (
        <div className="node-list full">{nodes.map((node) => <NodeRow key={node.id} node={node} />)}</div>
      ) : (
        <EmptyState
          icon="computer"
          title="Build your first Codex fleet"
          copy="Connect over SSH, verify the host key, and let the setup wizard discover the machine's tools and capacity."
          action={<button className="button button-primary"><Icon name="plus" /> Add your first computer</button>}
        />
      )}
    </section>
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
              <div><strong>{job.title ?? `${job.kind} task`}</strong><span>{job.id}</span></div>
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

function IntegrationPage({ online, fleet }: { online: boolean; fleet?: FleetInfo }) {
  const pluginConnected = fleet?.codex.connected ?? false;
  return (
    <div className="integration-layout">
      <section className="integration-hero panel">
        <div className="integration-mark"><Icon name="codex" size={40} /><span><i /><i /><i /></span></div>
        <span className="eyebrow">CODEX + YOUR COMPUTERS</span>
        <h2>{pluginConnected ? "Codex is connected." : "Connect Codex to your fleet."}</h2>
        <p>The plugin gives Codex five focused tools to inspect, plan, submit, monitor, and cancel delegated work. Machine credentials stay inside the local controller.</p>
        <div className="connection-statuses">
          <div><StatusDot status={online ? "connected" : "disconnected"} /><span>Desktop controller</span><strong>{online ? "Online" : "Offline"}</strong></div>
          <div><StatusDot status={pluginConnected ? "connected" : "disconnected"} /><span>Codex plugin</span><strong>{pluginConnected ? "Connected" : "Not detected"}</strong></div>
        </div>
      </section>
      <section className="panel setup-panel">
        <header className="panel-header"><div><h3>Setup checklist</h3><p>Three steps, no manual JSON editing.</p></div></header>
        <div className="setup-step done"><span><Icon name="check" /></span><div><strong>Install the controller</strong><p>Local API is available only on loopback.</p></div></div>
        <div className={`setup-step ${pluginConnected ? "done" : "current"}`}><span>{pluginConnected ? <Icon name="check" /> : "2"}</span><div><strong>Install the Codex plugin</strong><p>Add the Skill and local MCP bridge to Codex.</p></div><button className="button button-secondary">Install plugin</button></div>
        <div className="setup-step"><span>3</span><div><strong>Run connection check</strong><p>Verify Codex can see eligible computers without seeing credentials.</p></div><button className="text-button small">Run check <Icon name="arrow" size={14} /></button></div>
      </section>
    </div>
  );
}

export function App() {
  const [page, setPage] = useState<Page>("home");
  const [fleet, setFleet] = useState<FleetInfo>();
  const [online, setOnline] = useState(false);
  const [loading, setLoading] = useState(true);
  const [lastCheckedAt, setLastCheckedAt] = useState<Date>();

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const [health, fleetInfo] = await Promise.all([controllerClient.health(), controllerClient.fleet()]);
      setOnline(health.status === "ready" || health.status === "degraded");
      setFleet(fleetInfo);
    } catch {
      setOnline(false);
    } finally {
      setLastCheckedAt(new Date());
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const interval = window.setInterval(() => void refresh(), 15_000);
    return () => window.clearInterval(interval);
  }, [refresh]);

  const heading = pageTitles[page];
  const statusCopy = useMemo(() => {
    if (loading && !lastCheckedAt) return "Checking controller…";
    if (!online) return "Controller offline";
    return `${fleet?.nodes.filter((node) => node.status !== "offline").length ?? 0} computers available`;
  }, [fleet, lastCheckedAt, loading, online]);

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <Logo />
        <nav aria-label="Primary navigation">
          <span className="nav-label">WORKSPACE</span>
          {navigation.slice(0, 4).map((item) => (
            <button className={page === item.id ? "active" : ""} key={item.id} onClick={() => setPage(item.id)}>
              <Icon name={item.icon} /><span>{item.label}</span>
              {item.id === "tasks" && (fleet?.controller.activeJobs ?? 0) > 0 ? <em>{fleet?.controller.activeJobs}</em> : null}
            </button>
          ))}
          <span className="nav-label integration-label">INTEGRATION</span>
          {navigation.slice(4).map((item) => (
            <button className={page === item.id ? "active" : ""} key={item.id} onClick={() => setPage(item.id)}><Icon name={item.icon} /><span>{item.label}</span></button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="controller-card">
            <div><StatusDot status={online ? "connected" : "disconnected"} /><strong>{online ? "Controller online" : "Controller offline"}</strong></div>
            <span>{online ? `v${fleet?.controller.version ?? "0.1"} · localhost` : "Waiting on port 47831"}</span>
          </div>
          <div className="profile"><span className="avatar">CY</span><div><strong>Local workspace</strong><span>Personal fleet</span></div><Icon name="more" /></div>
        </div>
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div><h1>{heading.title}</h1><p>{heading.subtitle}</p></div>
          <div className="topbar-actions">
            <span className={`live-status ${online ? "is-online" : ""}`}><StatusDot status={online ? "connected" : "disconnected"} />{statusCopy}</span>
            <button className={`icon-button refresh-button ${loading ? "spinning" : ""}`} onClick={() => void refresh()} aria-label="Refresh controller status"><Icon name="refresh" /></button>
            <button className="button button-primary" onClick={() => setPage("computers")}><Icon name="plus" /> Add computer</button>
          </div>
        </header>

        {!online && !loading ? (
          <div className="offline-banner"><Icon name="terminal" /><div><strong>The local controller is not responding.</strong><span>Start ClusterYourCodex Controller on port 47831, then refresh.</span></div><button className="text-button small" onClick={() => setPage("integration")}>Open setup <Icon name="arrow" size={14} /></button></div>
        ) : null}

        <div className="page-content">
          {page === "home" ? <HomePage fleet={fleet} online={online} openPage={setPage} /> : null}
          {page === "computers" ? <ComputersPage fleet={fleet} /> : null}
          {page === "tasks" ? <TasksPage fleet={fleet} /> : null}
          {page === "rules" ? <RulesPage /> : null}
          {page === "integration" ? <IntegrationPage fleet={fleet} online={online} /> : null}
        </div>
      </main>
    </div>
  );
}
