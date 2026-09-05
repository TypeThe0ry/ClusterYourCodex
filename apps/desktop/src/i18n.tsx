import {
  createContext,
  type PropsWithChildren,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";

export const SUPPORTED_LOCALES = ["en", "zh-CN"] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];

export const DEFAULT_LOCALE: Locale = "en";
export const LOCALE_STORAGE_KEY = "clusteryourcodex.locale";

const en = {
  "language.label": "Language",
  "language.english": "English",
  "language.simplifiedChinese": "Simplified Chinese",
  "common.add": "Add",
  "common.back": "Back",
  "common.cancel": "Cancel",
  "common.close": "Close",
  "common.continue": "Continue",
  "common.copy": "Copy",
  "common.done": "Done",
  "common.loading": "Loading…",
  "common.next": "Next",
  "common.refresh": "Refresh",
  "common.retry": "Retry",
  "common.save": "Save",
  "common.search": "Search",
  "nav.home": "Home",
  "nav.computers": "Computers",
  "nav.tasks": "Tasks",
  "nav.integration": "Codex integration",
  "nav.settings": "Settings",
  "nav.routingRules": "Routing rules",
  "nav.workspace": "Workspace",
  "nav.integrationGroup": "Integration",
  "status.available": "Available",
  "status.busy": "Busy",
  "status.connected": "Connected",
  "status.connecting": "Connecting",
  "status.degraded": "Degraded",
  "status.disconnected": "Disconnected",
  "status.failed": "Failed",
  "status.offline": "Offline",
  "status.online": "Online",
  "status.pending": "Pending",
  "status.ready": "Ready",
  "status.running": "Running",
  "status.unknown": "Unknown",
  "app.tagline": "Your computers. One Codex.",
  "home.title": "Run Codex work on every computer you own.",
  "home.description":
    "Add Windows, Linux, and GPU machines. ClusterYourCodex chooses the right one, runs the work, and brings the result back.",
  "home.addComputer": "Add a computer",
  "home.openComputers": "View computers",
  "home.computersTitle": "Your computers",
  "home.recentTasksTitle": "Recent tasks",
  "home.pageTitle": "Your Codex fleet",
  "home.pageSubtitle": "One place to see where Codex is working and why.",
  "home.eyebrow": "CODEX COMPUTE POOL",
  "home.quickStart": "QUICK START",
  "home.quickStartTitle": "Ready in three steps",
  "home.quickStartDescription": "Add one computer, connect the Codex plugin, then run one verified check.",
  "home.stepAdd": "Add a computer",
  "home.stepConnect": "Connect Codex",
  "home.stepCheck": "Run the check",
  "home.stepStart": "Start",
  "home.stepOpen": "Open",
  "home.stepPending": "Enabled after setup",
  "computers.title": "Computers",
  "computers.description": "Connect a computer and make it available to Codex.",
  "computers.add": "Add computer",
  "computers.emptyTitle": "No computers yet",
  "computers.emptyDescription": "Add your first computer to start distributing Codex work.",
  "computers.pageSubtitle": "Connect the machines Codex can use for builds, tests, and compute.",
  "computers.connectedTitle": "Connected computers",
  "computers.connectedDescription": "Only workers that completed pairing, heartbeat, and smoke check appear here.",
  "computers.noReadyTitle": "No ready workers yet",
  "computers.noReadyDescription": "A computer moves here only after the controller reports a healthy worker.",
  "tasks.title": "Tasks",
  "tasks.pageSubtitle": "Track every delegated run from queue to verified artifact.",
  "tasks.emptyTitle": "Your task history is empty",
  "tasks.emptyDescription":
    "Ask Codex to run a meaningful build, test, container, or GPU workload. ClusterYourCodex will record it here.",
  "tasks.column.task": "Task",
  "tasks.column.computer": "Computer",
  "tasks.column.status": "Status",
  "tasks.column.duration": "Duration",
  "rules.pageSubtitle": "Decide which computer Codex should prefer for each kind of work.",
  "integration.title": "Connect Codex",
  "integration.description": "Connect ClusterYourCodex to Codex in a few steps.",
  "integration.pageSubtitle": "Keep the desktop controller and Codex plugin connected.",
  "integration.connectedTitle": "Codex is connected.",
  "integration.connectTitle": "Connect Codex to your fleet.",
  "integration.checklistTitle": "Setup checklist",
  "integration.checklistDescription": "Three steps, no manual JSON editing.",
  "integration.stepController": "Install the controller",
  "integration.stepPlugin": "Install the Codex plugin",
  "integration.stepCheck": "Run the plugin check",
  "integration.advanced": "Advanced verification",
  "integration.advancedDescription": "Run and inspect the full controller-to-worker proof",
  "integration.pluginDescription": "The plugin connects Codex to your computers while credentials stay in the local controller.",
  "integration.desktopController": "Desktop controller",
  "integration.codexPlugin": "Codex plugin",
  "integration.checking": "Checking…",
  "integration.unknown": "Unknown",
  "integration.statusNotVerified": "Status not verified",
  "integration.statusNeedsRefresh": "A fresh local status check is required before the full run is enabled.",
  "integration.checkAgain": "Check again",
  "integration.controllerReady": "The authenticated local controller is responding.",
  "integration.controllerStart": "Start or repair the local controller first.",
  "integration.pluginDescriptionShort": "Add or repair the bundled Skill and MCP bridge.",
  "integration.pluginCheckDescription": "Verify the installed plugin, then confirm the active Codex connection.",
  "integration.install": "Install plugin",
  "integration.update": "Update plugin",
  "integration.repair": "Repair plugin",
  "integration.working": "Working…",
  "integration.operationFailed": "Integration operation failed",
  "integration.refreshStatus": "Refresh status",
  "integration.state.notFound": "Codex not found",
  "integration.state.notInstalled": "Not installed",
  "integration.state.installed": "Installed",
  "integration.state.restartRequired": "Restart required",
  "integration.state.connected": "Connected",
  "integration.state.stale": "Check stale",
  "integration.state.broken": "Needs repair",
  "integration.state.versionMismatch": "Update required",
  "settings.title": "Settings",
  "controller.offlineTitle": "The local controller is not responding.",
  "controller.offlineDescription": "Start ClusterYourCodex Controller on port {port}, then refresh.",
  "controller.openSetup": "Open setup",
  "controller.online": "Controller online",
  "controller.offline": "Controller offline",
  "controller.integrationUnavailable": "Integration unavailable",
  "controller.waiting": "Waiting on port 47831",
  "controller.checking": "Checking controller…",
  "controller.proxyUnavailable": "Secure proxy unavailable",
  "controller.availableCount": "{count} computers available",
  "workspace.local": "Local workspace",
  "workspace.personalFleet": "Personal fleet",
  "provision.title": "Add a computer",
  "provision.subtitle": "Choose a simple setup method. You can review every command before running it.",
  "provision.chooseMethod": "How do you want to connect it?",
  "provision.recommended": "Recommended",
  "provision.local": "This computer",
  "provision.remote": "Another computer",
  "provision.copyCommand": "Copy setup command",
  "provision.commandCopied": "Command copied",
  "provision.waiting": "Waiting for the computer…",
  "provision.successTitle": "Computer connected",
  "provision.successDescription": "{name} is ready for Codex work.",
  "provision.errorTitle": "Connection failed",
  "provision.showDetails": "Show technical details",
  "provision.hideDetails": "Hide technical details",
  "provision.connectSsh": "Connect over SSH",
  "provision.host": "Host or IP",
  "provision.user": "SSH user",
  "provision.authentication": "Authentication",
  "provision.password": "Password",
  "provision.advanced": "Advanced options",
  "provision.displayName": "Display name (optional)",
  "provision.sshPort": "SSH port",
  "provision.rememberPassword": "Remember securely in Windows Credential Manager",
} as const;

export type TranslationKey = keyof typeof en;
export type TranslationValues = Readonly<Record<string, string | number>>;

const zhCN = {
  "language.label": "语言",
  "language.english": "English",
  "language.simplifiedChinese": "简体中文",
  "common.add": "添加",
  "common.back": "返回",
  "common.cancel": "取消",
  "common.close": "关闭",
  "common.continue": "继续",
  "common.copy": "复制",
  "common.done": "完成",
  "common.loading": "正在加载…",
  "common.next": "下一步",
  "common.refresh": "刷新",
  "common.retry": "重试",
  "common.save": "保存",
  "common.search": "搜索",
  "nav.home": "首页",
  "nav.computers": "电脑",
  "nav.tasks": "任务",
  "nav.integration": "Codex 集成",
  "nav.settings": "设置",
  "nav.routingRules": "路由规则",
  "nav.workspace": "工作区",
  "nav.integrationGroup": "集成",
  "status.available": "可用",
  "status.busy": "忙碌",
  "status.connected": "已连接",
  "status.connecting": "正在连接",
  "status.degraded": "性能受限",
  "status.disconnected": "未连接",
  "status.failed": "失败",
  "status.offline": "离线",
  "status.online": "在线",
  "status.pending": "等待中",
  "status.ready": "就绪",
  "status.running": "运行中",
  "status.unknown": "未知",
  "app.tagline": "多台电脑，一个 Codex。",
  "home.title": "让 Codex 使用你的每一台电脑。",
  "home.description": "添加 Windows、Linux 和 GPU 电脑。ClusterYourCodex 会选择合适的电脑执行工作，并将结果带回来。",
  "home.addComputer": "添加电脑",
  "home.openComputers": "查看电脑",
  "home.computersTitle": "你的电脑",
  "home.recentTasksTitle": "最近任务",
  "home.pageTitle": "你的 Codex 电脑集群",
  "home.pageSubtitle": "在一个界面查看 Codex 在哪里工作，以及为什么选择它。",
  "home.eyebrow": "CODEX 算力池",
  "home.quickStart": "快速开始",
  "home.quickStartTitle": "三步即可开始",
  "home.quickStartDescription": "添加一台电脑、连接 Codex 插件，然后运行一次验证检查。",
  "home.stepAdd": "添加电脑",
  "home.stepConnect": "连接 Codex",
  "home.stepCheck": "运行检查",
  "home.stepStart": "开始",
  "home.stepOpen": "打开",
  "home.stepPending": "完成设置后启用",
  "computers.title": "电脑",
  "computers.description": "连接一台电脑，让 Codex 可以使用它。",
  "computers.add": "添加电脑",
  "computers.emptyTitle": "还没有电脑",
  "computers.emptyDescription": "添加第一台电脑，即可开始分配 Codex 工作。",
  "computers.pageSubtitle": "连接可供 Codex 执行构建、测试和计算的电脑。",
  "computers.connectedTitle": "已连接的电脑",
  "computers.connectedDescription": "完成配对、心跳和冒烟检查的工作机才会显示在这里。",
  "computers.noReadyTitle": "还没有就绪的工作机",
  "computers.noReadyDescription": "控制器确认工作机健康后，电脑才会移到这里。",
  "tasks.title": "任务",
  "tasks.pageSubtitle": "跟踪每次分配任务，从排队到验证产物。",
  "tasks.emptyTitle": "任务记录为空",
  "tasks.emptyDescription": "让 Codex 执行构建、测试、容器或 GPU 工作，ClusterYourCodex 会在这里记录结果。",
  "tasks.column.task": "任务",
  "tasks.column.computer": "电脑",
  "tasks.column.status": "状态",
  "tasks.column.duration": "用时",
  "rules.pageSubtitle": "决定 Codex 对每类工作应优先选择哪台电脑。",
  "integration.title": "连接 Codex",
  "integration.description": "只需几步，即可将 ClusterYourCodex 连接到 Codex。",
  "integration.pageSubtitle": "保持桌面控制器与 Codex 插件连接。",
  "integration.connectedTitle": "Codex 已连接。",
  "integration.connectTitle": "将 Codex 连接到你的电脑集群。",
  "integration.checklistTitle": "设置清单",
  "integration.checklistDescription": "只需三步，无需手动编辑 JSON。",
  "integration.stepController": "安装控制器",
  "integration.stepPlugin": "安装 Codex 插件",
  "integration.stepCheck": "运行插件检查",
  "integration.advanced": "高级验证",
  "integration.advancedDescription": "运行并检查从控制器到工作机的完整证明",
  "integration.pluginDescription": "插件会把 Codex 连接到你的电脑，凭据始终保留在本地控制器中。",
  "integration.desktopController": "桌面控制器",
  "integration.codexPlugin": "Codex 插件",
  "integration.checking": "正在检查…",
  "integration.unknown": "未知",
  "integration.statusNotVerified": "状态尚未验证",
  "integration.statusNeedsRefresh": "启用完整运行前，需要一次最新的本地状态检查。",
  "integration.checkAgain": "重新检查",
  "integration.controllerReady": "已通过认证的本地控制器正在响应。",
  "integration.controllerStart": "请先启动或修复本地控制器。",
  "integration.pluginDescriptionShort": "添加或修复内置的 Skill 与 MCP 桥接器。",
  "integration.pluginCheckDescription": "验证已安装的插件，然后确认 Codex 当前连接。",
  "integration.install": "安装插件",
  "integration.update": "更新插件",
  "integration.repair": "修复插件",
  "integration.working": "正在处理…",
  "integration.operationFailed": "集成操作失败",
  "integration.refreshStatus": "刷新状态",
  "integration.state.notFound": "未找到 Codex",
  "integration.state.notInstalled": "尚未安装",
  "integration.state.installed": "已安装",
  "integration.state.restartRequired": "需要重启",
  "integration.state.connected": "已连接",
  "integration.state.stale": "检查已过期",
  "integration.state.broken": "需要修复",
  "integration.state.versionMismatch": "需要更新",
  "settings.title": "设置",
  "controller.offlineTitle": "本地控制器没有响应。",
  "controller.offlineDescription": "请启动端口 {port} 上的 ClusterYourCodex Controller，然后刷新。",
  "controller.openSetup": "打开设置",
  "controller.online": "控制器在线",
  "controller.offline": "控制器离线",
  "controller.integrationUnavailable": "集成不可用",
  "controller.waiting": "正在等待端口 47831",
  "controller.checking": "正在检查控制器…",
  "controller.proxyUnavailable": "安全代理不可用",
  "controller.availableCount": "{count} 台电脑可用",
  "workspace.local": "本地工作区",
  "workspace.personalFleet": "个人电脑集群",
  "provision.title": "添加电脑",
  "provision.subtitle": "选择一种简单的设置方式。运行前，你可以检查每一条命令。",
  "provision.chooseMethod": "你想如何连接？",
  "provision.recommended": "推荐",
  "provision.local": "这台电脑",
  "provision.remote": "另一台电脑",
  "provision.copyCommand": "复制设置命令",
  "provision.commandCopied": "命令已复制",
  "provision.waiting": "正在等待电脑…",
  "provision.successTitle": "电脑已连接",
  "provision.successDescription": "{name} 已可用于 Codex 工作。",
  "provision.errorTitle": "连接失败",
  "provision.showDetails": "显示技术详情",
  "provision.hideDetails": "隐藏技术详情",
  "provision.connectSsh": "通过 SSH 连接",
  "provision.host": "主机名或 IP",
  "provision.user": "SSH 用户",
  "provision.authentication": "认证方式",
  "provision.password": "密码",
  "provision.advanced": "高级选项",
  "provision.displayName": "显示名称（可选）",
  "provision.sshPort": "SSH 端口",
  "provision.rememberPassword": "安全保存到 Windows 凭据管理器",
} as const satisfies Record<TranslationKey, string>;

export const translations: Readonly<Record<Locale, Readonly<Record<TranslationKey, string>>>> = {
  en,
  "zh-CN": zhCN,
};

export const localeOptions: readonly { locale: Locale; labelKey: TranslationKey }[] = [
  { locale: "en", labelKey: "language.english" },
  { locale: "zh-CN", labelKey: "language.simplifiedChinese" },
];

type StorageLike = Pick<Storage, "getItem" | "setItem">;

export function normalizeLocale(value: string | null | undefined): Locale | undefined {
  if (!value) return undefined;
  const normalized = value.trim().replaceAll("_", "-").toLowerCase();
  if (normalized === "en" || normalized.startsWith("en-")) return "en";
  if (normalized === "zh" || normalized === "zh-cn" || normalized === "zh-sg" || normalized.startsWith("zh-hans")) {
    return "zh-CN";
  }
  return undefined;
}

function browserStorage(): StorageLike | undefined {
  if (typeof window === "undefined") return undefined;
  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

function browserLanguage(): string | undefined {
  return typeof navigator === "undefined" ? undefined : navigator.language;
}

export interface LocaleEnvironment {
  storage?: StorageLike;
  navigatorLanguage?: string;
  storageKey?: string;
}

export function resolveInitialLocale(environment: LocaleEnvironment = {}): Locale {
  const storage = environment.storage ?? browserStorage();
  const storageKey = environment.storageKey ?? LOCALE_STORAGE_KEY;
  try {
    const stored = normalizeLocale(storage?.getItem(storageKey));
    if (stored) return stored;
  } catch {
    // Storage can be unavailable in locked-down webviews; navigator remains a safe fallback.
  }
  return normalizeLocale(environment.navigatorLanguage ?? browserLanguage()) ?? DEFAULT_LOCALE;
}

export function persistLocale(locale: Locale, storage: StorageLike | undefined = browserStorage(), storageKey = LOCALE_STORAGE_KEY): boolean {
  try {
    storage?.setItem(storageKey, locale);
    return storage !== undefined;
  } catch {
    return false;
  }
}

export function translate(locale: Locale, key: TranslationKey, values?: TranslationValues): string {
  const template = translations[locale]?.[key] ?? translations[DEFAULT_LOCALE][key];
  if (!values) return template;
  return template.replace(/\{([A-Za-z0-9_]+)\}/g, (placeholder, name: string) => {
    const value = values[name];
    return value === undefined ? placeholder : String(value);
  });
}

export interface I18nContextValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: TranslationKey, values?: TranslationValues) => string;
  supportedLocales: typeof SUPPORTED_LOCALES;
}

const I18nContext = createContext<I18nContextValue | undefined>(undefined);

export interface I18nProviderProps extends PropsWithChildren {
  initialLocale?: Locale;
  storage?: StorageLike;
  storageKey?: string;
  navigatorLanguage?: string;
}

export function I18nProvider({
  children,
  initialLocale,
  storage,
  storageKey = LOCALE_STORAGE_KEY,
  navigatorLanguage,
}: I18nProviderProps) {
  const [locale, setLocale] = useState<Locale>(() =>
    initialLocale ?? resolveInitialLocale({ storage, storageKey, navigatorLanguage }),
  );

  useEffect(() => {
    persistLocale(locale, storage ?? browserStorage(), storageKey);
    if (typeof document !== "undefined") document.documentElement.lang = locale;
  }, [locale, storage, storageKey]);

  const t = useCallback((key: TranslationKey, values?: TranslationValues) => translate(locale, key, values), [locale]);
  const value = useMemo<I18nContextValue>(
    () => ({ locale, setLocale, t, supportedLocales: SUPPORTED_LOCALES }),
    [locale, t],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nContextValue {
  const context = useContext(I18nContext);
  if (!context) throw new Error("useI18n must be used within an I18nProvider");
  return context;
}
