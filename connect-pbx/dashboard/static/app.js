const state = {
  environment: "dev",
  availableEnvironments: [],
  modules: [],
  enabledModulePaths: [],
  actionMode: "apply",
  loadingState: false,
  resolutionLoading: false,
  selected: new Set(),
  resolution: null,
  resolutionInfo: "",
  validationTimer: null,
  validationRequestSeq: 0,
  runStartupPending: false,
  runRequestPending: false,
  activeTaskId: null,
  lastTaskSnapshot: null,
  runRestoredFromReload: false,
  pendingRunApproval: null,
  runApprovalInput: "",
  pollHandle: null,
  loadingReason: "",
  accountScopeTooltipMessage: "",
};

const els = {
  environmentSelect: document.getElementById("environmentSelect"),
  refreshButton: document.getElementById("refreshButton"),
  manifestProfile: document.getElementById("manifestProfile"),
  awsProfile: document.getElementById("awsProfile"),
  awsAccountId: document.getElementById("awsAccountId"),
  githubRepoSlug: document.getElementById("githubRepoSlug"),
  githubEnvironment: document.getElementById("githubEnvironment"),
  backendScope: document.getElementById("backendScope"),
  packSummary: document.getElementById("packSummary"),
  enabledCount: document.getElementById("enabledCount"),
  deployedCount: document.getElementById("deployedCount"),
  envStateSummary: document.getElementById("envStateSummary"),
  accountScopeInfoButton: document.getElementById("accountScopeInfoButton"),
  floatingInfoTooltip: document.getElementById("floatingInfoTooltip"),
  moduleSearch: document.getElementById("moduleSearch"),
  moduleList: document.getElementById("moduleList"),
  runnerStatus: document.getElementById("runnerStatus"),
  runnerStatusDetail: document.getElementById("runnerStatusDetail"),
  requestedCount: document.getElementById("requestedCount"),
  autoAddedCount: document.getElementById("autoAddedCount"),
  executionCount: document.getElementById("executionCount"),
  requestedSummaryLabel: document.getElementById("requestedSummaryLabel"),
  autoAddedSummaryLabel: document.getElementById("autoAddedSummaryLabel"),
  executionSummaryLabel: document.getElementById("executionSummaryLabel"),
  requestedHeading: document.getElementById("requestedHeading"),
  autoAddedHeading: document.getElementById("autoAddedHeading"),
  executionHeading: document.getElementById("executionHeading"),
  requestedList: document.getElementById("requestedList"),
  dependencyList: document.getElementById("dependencyList"),
  executionList: document.getElementById("executionList"),
  resolutionError: document.getElementById("resolutionError"),
  resolutionInfo: document.getElementById("resolutionInfo"),
  resolutionWarnings: document.getElementById("resolutionWarnings"),
  deployModeButton: document.getElementById("deployModeButton"),
  destroyModeButton: document.getElementById("destroyModeButton"),
  selectAllButton: document.getElementById("selectAllButton"),
  clearButton: document.getElementById("clearButton"),
  planButton: document.getElementById("planButton"),
  applyButton: document.getElementById("applyButton"),
  destroyButton: document.getElementById("destroyButton"),
  actionAvailability: document.getElementById("actionAvailability"),
  runMeta: document.getElementById("runMeta"),
  runMetaContent: document.getElementById("runMetaContent"),
  runApprovalOverlay: document.getElementById("runApprovalOverlay"),
  runApprovalCopy: document.getElementById("runApprovalCopy"),
  runApprovalPhrase: document.getElementById("runApprovalPhrase"),
  runApprovalInput: document.getElementById("runApprovalInput"),
  runApprovalConfirmButton: document.getElementById("runApprovalConfirmButton"),
  runApprovalCancelButton: document.getElementById("runApprovalCancelButton"),
  runLog: document.getElementById("runLog"),
};

const DASHBOARD_ROLLUPS = [
  {
    id: "pack:platform-foundation",
    title: "Platform Foundation Pack",
    capabilityPackName: "Platform Foundation",
    primaryPaths: ["modules/l0-account-baseline"],
    optionalPaths: ["modules/l0-audit-pipeline"],
    operatorManagedPaths: ["modules/bootstrap"],
    memberPaths: ["modules/bootstrap", "modules/l0-account-baseline", "modules/l0-audit-pipeline"],
    destroyPaths: ["modules/l0-account-baseline", "modules/l0-audit-pipeline"],
    searchTerms: [
      "platform foundation",
      "platform-foundation",
      "bootstrap",
      "account baseline",
      "audit pipeline",
      "prd-00",
      "prd-02",
      "prd-03",
    ],
    applyDescription: "PRD-00 bootstrap, PRD-02 account baseline, optional PRD-03 audit pipeline",
    destroyDescription: "Destroy PRD-02 and PRD-03 here. <strong>Bootstrap backend teardown remains a separate manual step outside dashboard destroy mode.</strong>",
    addonToggleLabel: "Include PRD-03 audit add-on",
    addonLockedDetail: "Available after PRD-02 account baseline is deployed.",
    addonAvailableDetail: "Optional within the rollup.",
    addonUnavailableDetail: "Not enabled by the current manifest.",
    pathLabels: {
      "modules/bootstrap": "PRD-00 bootstrap backend",
      "modules/l0-account-baseline": "PRD-02 account baseline",
      "modules/l0-audit-pipeline": "PRD-03 audit add-on",
    },
    pathFallbacks: {
      "modules/bootstrap": "Operator-managed prerequisite.",
      "modules/l0-account-baseline": "Baseline module missing from dashboard state.",
      "modules/l0-audit-pipeline": "Audit add-on is not present in the catalog.",
    },
    destroyDetails: {
      "modules/bootstrap": "The backend cannot destroy itself through tf-run.sh. Manual destroy required.",
      "modules/l0-account-baseline": "Destroys the account foundation after deployed higher-layer dependents have already been removed.",
      "modules/l0-audit-pipeline": "Destroys AWS Config, CloudTrail, Security Hub, and the audit bucket for this environment.",
    },
  },
  {
    id: "pack:core-telephony",
    title: "Core Telephony Pack",
    capabilityPackName: "Core Telephony",
    primaryPaths: [
      "modules/l1-connect-instance",
      "modules/l1-phone-numbers",
      "modules/l1-hours-of-operation",
      "modules/l1-queue-architecture",
      "modules/l1-contact-flow-framework",
    ],
    optionalPaths: [],
    operatorManagedPaths: [],
    memberPaths: [
      "modules/l1-connect-instance",
      "modules/l1-phone-numbers",
      "modules/l1-hours-of-operation",
      "modules/l1-queue-architecture",
      "modules/l1-contact-flow-framework",
    ],
    destroyPaths: [
      "modules/l1-hours-of-operation",
      "modules/l1-queue-architecture",
      "modules/l1-contact-flow-framework",
    ],
    searchTerms: [
      "core telephony",
      "core-telephony",
      "connect instance",
      "phone numbers",
      "hours of operation",
      "queue architecture",
      "contact flow framework",
      "prd-10",
      "prd-11",
      "prd-12",
      "prd-13",
      "prd-14",
    ],
    applyDescription: "PRD-10 through PRD-14 telephony baseline: Connect instance, numbers, hours, queues, and base contact flows.",
    destroyDescription: "Destroy the deployed telephony layers around the retained Connect instance and claimed numbers. Core Telephony pack destroy preserves PRD-10 and PRD-11 by default, but the dashboard can promote them into an explicitly approved teardown.",
    pathLabels: {
      "modules/l1-connect-instance": "PRD-10 Connect instance",
      "modules/l1-phone-numbers": "PRD-11 phone numbers",
      "modules/l1-hours-of-operation": "PRD-12 hours of operation",
      "modules/l1-queue-architecture": "PRD-13 queues and routing",
      "modules/l1-contact-flow-framework": "PRD-14 contact flows",
    },
    destroyDetails: {
      "modules/l1-connect-instance": "Retained by default. The Connect instance stays outside pack destroy unless you explicitly select the PRD-10 row and approve an operator destroy run.",
      "modules/l1-phone-numbers": "Retained by default. Claimed numbers stay outside pack destroy unless you explicitly select the PRD-11 row and approve an operator destroy run.",
      "modules/l1-hours-of-operation": "Destroys hours and holiday schedules after higher telephony layers are removed.",
      "modules/l1-queue-architecture": "Destroys queues and routing profiles after dependent contact flows are removed.",
      "modules/l1-contact-flow-framework": "Destroys base contact flows and disassociates phone numbers from flows during teardown.",
    },
  },
];

const BOOTSTRAP_MODULE_PATH = "modules/bootstrap";
const AUDIT_PIPELINE_MODULE_PATH = "modules/l0-audit-pipeline";
const AUDIT_DESTROY_APPROVAL_PHRASE = "EMPTY AUDIT BUCKETS";
const CORE_TELEPHONY_INSTANCE_MODULE_PATH = "modules/l1-connect-instance";
const CORE_TELEPHONY_PHONE_NUMBERS_MODULE_PATH = "modules/l1-phone-numbers";
const CORE_TELEPHONY_DESTROY_APPROVAL_PHRASE = "DESTROY CORE TELEPHONY";
const DASHBOARD_UI_STATE_KEY = "connectPbxDashboardUiStateV1";

function moduleSupportsDestroyInDashboard(module) {
  return Boolean(module && (module.supports_destroy === true || module.supports_operator_destroy === true));
}

function loadDashboardUiState() {
  try {
    const raw = window.localStorage.getItem(DASHBOARD_UI_STATE_KEY);
    if (!raw) {
      return null;
    }
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function saveDashboardUiState() {
  try {
    const existing = loadDashboardUiState() || {};
    const selectionsByEnvironment = existing.selectionsByEnvironment || {};
    const environmentSelections = selectionsByEnvironment[state.environment] || {};
    environmentSelections[state.actionMode] = [...state.selected].slice().sort();
    selectionsByEnvironment[state.environment] = environmentSelections;

    window.localStorage.setItem(
      DASHBOARD_UI_STATE_KEY,
      JSON.stringify({
        environment: state.environment,
        actionMode: state.actionMode,
        selectionsByEnvironment,
      }),
    );
  } catch {
    // Best-effort UI persistence only.
  }
}

function hydrateDashboardUiState() {
  const persisted = loadDashboardUiState();
  if (!persisted) {
    return;
  }

  if (typeof persisted.environment === "string" && persisted.environment) {
    state.environment = persisted.environment;
  }
  if (persisted.actionMode === "apply" || persisted.actionMode === "destroy") {
    state.actionMode = persisted.actionMode;
  }

  const persistedSelections = persisted.selectionsByEnvironment?.[state.environment]?.[state.actionMode];
  if (Array.isArray(persistedSelections)) {
    state.selected = new Set(persistedSelections);
  }
}

function restoreSelectionsForCurrentContext(restorablePaths) {
  const persisted = loadDashboardUiState();
  const persistedSelections = persisted?.selectionsByEnvironment?.[state.environment]?.[state.actionMode];
  if (!Array.isArray(persistedSelections)) {
    state.selected = new Set();
    return;
  }

  state.selected = new Set(persistedSelections.filter((path) => restorablePaths.has(path)));
}

async function requestJson(url, options = {}) {
  const response = await fetch(url, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await response.json();
  if (!response.ok) {
    const error = new Error(data.error || "Request failed.");
    error.payload = data;
    throw error;
  }
  return data;
}

function setRunnerStatus(message, loading = false, detail = "") {
  els.runnerStatus.textContent = message;
  els.runnerStatus.classList.toggle("loading", loading);
  if (detail) {
    els.runnerStatusDetail.textContent = detail;
    els.runnerStatusDetail.classList.remove("hidden");
  } else {
    els.runnerStatusDetail.textContent = "";
    els.runnerStatusDetail.classList.add("hidden");
  }
}

function formatGithubStatusDetail(githubStatus) {
  if (!githubStatus) {
    return "";
  }

  const lines = [
    `GitHub env: ${githubStatus.environment_status || "unknown"}`,
    `Bootstrap secrets: ${githubStatus.bootstrap_secrets_status || "unknown"}`,
    `PRD-02 secret: ${githubStatus.prd02_secret_status || "unknown"}`,
    `CI/CD readiness: ${githubStatus.cicd_readiness || "unknown"}`,
  ];

  if (githubStatus.detail) {
    lines.push(`GitHub status detail: ${githubStatus.detail}`);
  }

  return lines.join("\n");
}

function hideFloatingInfoTooltip() {
  els.floatingInfoTooltip.textContent = "";
  els.floatingInfoTooltip.classList.add("hidden");
}

function positionFloatingInfoTooltip(x, y) {
  const offset = 14;
  const tooltipWidth = els.floatingInfoTooltip.offsetWidth || 0;
  const tooltipHeight = els.floatingInfoTooltip.offsetHeight || 0;
  const maxLeft = Math.max(12, window.innerWidth - tooltipWidth - 12);
  const maxTop = Math.max(12, window.innerHeight - tooltipHeight - 12);
  const nextLeft = Math.min(x + offset, maxLeft);
  const nextTop = Math.min(y + offset, maxTop);

  els.floatingInfoTooltip.style.left = `${nextLeft}px`;
  els.floatingInfoTooltip.style.top = `${nextTop}px`;
}

function showFloatingInfoTooltip(message, x, y) {
  if (!message) {
    hideFloatingInfoTooltip();
    return;
  }

  els.floatingInfoTooltip.textContent = message;
  els.floatingInfoTooltip.classList.remove("hidden");
  positionFloatingInfoTooltip(x, y);
}

function renderAccountScopeNotice(message) {
  state.accountScopeTooltipMessage = message || "";

  if (!state.accountScopeTooltipMessage) {
    els.accountScopeInfoButton.classList.add("hidden");
    hideFloatingInfoTooltip();
    return;
  }

  els.accountScopeInfoButton.classList.remove("hidden");
}

function renderRunPlaceholder(status, detail, { hideMeta = false } = {}) {
  setRunMetaContent(hideMeta
    ? `
      <strong>RUN STATUS</strong>
      <br>
      Status: <strong>idle</strong>
    `
    : `
      <strong>RUN STATUS</strong>
      <br>
      Status: <strong>${status}</strong>
    `);
  els.runLog.textContent = detail;
}

function rememberTask(task) {
  state.lastTaskSnapshot = {
    ...task,
    requested_modules: [...(task.requested_modules || [])],
    execution_order: [...(task.execution_order || [])],
    auto_added_dependencies: [...(task.auto_added_dependencies || [])],
    logs: [...(task.logs || [])],
  };
}

function setRunMetaContent(html) {
  els.runMetaContent.innerHTML = html;
  els.runMetaContent.title = els.runMetaContent.textContent.replace(/\s+/g, " ").trim();
}

function renderActionAvailability() {
  let message = "";
  let loading = false;

  if (state.pendingRunApproval) {
    message = state.pendingRunApproval.availabilityMessage || "Explicit approval required before this destroy run can continue.";
  } else if (state.runStartupPending) {
    message = "Preparing the requested run and locking actions until preflight checks finish...";
    loading = true;
  } else if (state.runRequestPending) {
    message = "Submitting run request and locking actions until the dashboard receives the task id...";
    loading = true;
  } else if (state.activeTaskId) {
    message = "Run in progress. Action buttons will refresh after the current task completes.";
    loading = true;
  } else if (state.loadingState) {
    if (state.loadingReason === "post-run-sync") {
      message = "Updating deployment state after the last run. Action availability will return once badges and dependency preview are current.";
    } else if (state.loadingReason === "environment-switch") {
      message = "Loading the selected environment and recalculating available actions...";
    } else if (state.loadingReason === "manual-refresh") {
      message = "Refreshing live state and recalculating action availability...";
    } else {
      message = "Syncing dashboard state and recalculating available actions...";
    }
    loading = true;
  } else if (state.actionMode === "destroy" && state.resolutionLoading) {
    message = "Checking server-side destroy safety before enabling the next action...";
    loading = true;
  }

  if (!message) {
    els.actionAvailability.textContent = "";
    els.actionAvailability.classList.remove("loading");
    els.actionAvailability.classList.add("hidden");
    return;
  }

  els.actionAvailability.textContent = message;
  els.actionAvailability.classList.toggle("loading", loading);
  els.actionAvailability.classList.remove("hidden");
}

function hasDestroySelectionFor(paths) {
  if (state.actionMode !== "destroy") {
    return false;
  }

  const selectedPaths = new Set([
    ...state.selected,
    ...((state.resolution?.requested_modules) || []),
    ...((state.resolution?.execution_order) || []),
  ]);

  return paths.some((path) => selectedPaths.has(path));
}

function requiredDestroyApproval(action) {
  if (action !== "destroy" || !state.resolution || state.resolution.error) {
    return null;
  }

  if (hasDestroySelectionFor([CORE_TELEPHONY_INSTANCE_MODULE_PATH, CORE_TELEPHONY_PHONE_NUMBERS_MODULE_PATH])) {
    return {
      approvalId: "core-telephony-destroy",
      action,
      requiredPhrase: CORE_TELEPHONY_DESTROY_APPROVAL_PHRASE,
      availabilityMessage: "Explicit approval required. This destroy run includes protected core-telephony resources.",
      message: "This destroy run includes protected core-telephony resources. Destroying the Connect instance or managed phone-number boundary is a nuclear action and may permanently remove routing for this environment. If PRD-10 is actually destroyed, AWS may release claimed Connect numbers and they may not be recoverable.",
    };
  }

  if ((state.resolution.execution_order || []).includes(AUDIT_PIPELINE_MODULE_PATH)) {
    return {
      approvalId: "audit-bucket-destroy",
      action,
      requiredPhrase: AUDIT_DESTROY_APPROVAL_PHRASE,
      availabilityMessage: "Explicit approval required. This destroy run will empty protected audit buckets before teardown.",
      message: "This destroy run will first empty every object version and delete marker in the audit buckets before teardown. That cleanup is irreversible.",
    };
  }

  return null;
}

function renderRunApproval() {
  const approval = state.pendingRunApproval;
  if (!approval) {
    els.runApprovalOverlay.classList.add("hidden");
    els.runApprovalCopy.textContent = "";
    els.runApprovalPhrase.textContent = AUDIT_DESTROY_APPROVAL_PHRASE;
    els.runApprovalInput.value = "";
    els.runApprovalConfirmButton.disabled = true;
    return;
  }

  els.runApprovalCopy.textContent = approval.message;
  els.runApprovalPhrase.textContent = approval.requiredPhrase;
  els.runApprovalOverlay.classList.remove("hidden");
  els.runApprovalInput.value = state.runApprovalInput;
  els.runApprovalConfirmButton.disabled = state.runApprovalInput.trim() !== approval.requiredPhrase;
}

function clearRunApproval() {
  if (!state.pendingRunApproval && !state.runApprovalInput) {
    return;
  }
  state.pendingRunApproval = null;
  state.runApprovalInput = "";
  renderRunApproval();
  renderActionAvailability();
}

function syncRunApprovalState() {
  if (!state.pendingRunApproval) {
    renderRunApproval();
    return;
  }

  const requiredApproval = requiredDestroyApproval(state.pendingRunApproval.action);
  if (!requiredApproval) {
    clearRunApproval();
    return;
  }

  if (
    state.pendingRunApproval.approvalId !== requiredApproval.approvalId
    || state.pendingRunApproval.requiredPhrase !== requiredApproval.requiredPhrase
    || state.pendingRunApproval.message !== requiredApproval.message
  ) {
    state.pendingRunApproval = requiredApproval;
  }

  renderRunApproval();
}

function requestDestroyApproval(action) {
  const approval = requiredDestroyApproval(action);
  if (!approval) {
    return;
  }

  state.pendingRunApproval = approval;
  state.runApprovalInput = "";
  renderRunApproval();
  syncActionButtons(Boolean(state.resolution && !state.resolution.error));
  window.requestAnimationFrame(() => {
    els.runApprovalInput.focus();
    els.runApprovalInput.select();
  });
}

function moduleMapByPath() {
  return new Map(state.modules.map((module) => [module.path, module]));
}

function statusLabelForModule(module) {
  if (module.deployment_status === "deployed") {
    return "Deployed";
  }
  if (module.deployment_status === "partial") {
    return "Partial";
  }
  if (module.deployment_status === "no-state") {
    return "No State";
  }
  return "Unknown";
}

function statusTagClass(module) {
  return `status-${module.deployment_status}`;
}

function isActiveDeploymentStatus(status) {
  return status === "deployed" || status === "partial";
}

function rolledUpModulePathSet() {
  return new Set(DASHBOARD_ROLLUPS.flatMap((definition) => definition.memberPaths));
}

function rollupDefinitionForPath(modulePath) {
  return DASHBOARD_ROLLUPS.find((definition) => definition.memberPaths.includes(modulePath)) || null;
}

function destroyPathsForRollup(definition) {
  if (Array.isArray(definition.destroyPaths) && definition.destroyPaths.length > 0) {
    return definition.destroyPaths;
  }

  return [...definition.primaryPaths, ...definition.optionalPaths]
    .filter((path, index, paths) => paths.indexOf(path) === index)
    .filter((path) => !definition.operatorManagedPaths.includes(path));
}

function retainedPathsForRollup(definition) {
  const destroyPaths = new Set(destroyPathsForRollup(definition));
  return definition.memberPaths.filter((path) => !destroyPaths.has(path));
}

function isModuleSelectableInCurrentMode(module) {
  if (!module?.enabled_in_manifest) {
    return false;
  }
  if (state.actionMode === "destroy") {
    return moduleSupportsDestroyInDashboard(module) && isActiveDeploymentStatus(module.deployment_status);
  }
  return module.dashboard_selectable !== false;
}

function selectableRollupPaths(paths) {
  const modulesByPath = moduleMapByPath();
  return paths.filter((path) => {
    const module = modulesByPath.get(path);
    return isModuleSelectableInCurrentMode(module);
  });
}

function rollupContext(definition, autoAddedDependencies = new Set()) {
  const modulesByPath = moduleMapByPath();
  const memberModules = definition.memberPaths
    .map((path) => modulesByPath.get(path))
    .filter(Boolean);
  const primarySelectablePaths = selectableRollupPaths(definition.primaryPaths);
  const optionalSelectablePaths = selectableRollupPaths(definition.optionalPaths);
  const destroySelectablePaths = selectableRollupPaths(destroyPathsForRollup(definition));
  const operatorManagedModules = definition.operatorManagedPaths
    .map((path) => modulesByPath.get(path))
    .filter(Boolean);

  const primaryExplicitlySelected = primarySelectablePaths.length > 0
    && primarySelectablePaths.every((path) => state.selected.has(path));
  const primaryAutoAdded = primarySelectablePaths.length > 0
    && primarySelectablePaths.every((path) => autoAddedDependencies.has(path))
    && !primaryExplicitlySelected;
  const optionalSelected = optionalSelectablePaths.some((path) => state.selected.has(path));
  const optionalAutoAdded = optionalSelectablePaths.some((path) => autoAddedDependencies.has(path)) && !optionalSelected;
  const destroyExplicitlySelected = destroySelectablePaths.length > 0
    && destroySelectablePaths.every((path) => state.selected.has(path));
  const destroyAutoAdded = destroySelectablePaths.length > 0
    && destroySelectablePaths.every((path) => autoAddedDependencies.has(path))
    && !destroyExplicitlySelected;

  const searchHaystack = [
    definition.title,
    definition.capabilityPackName,
    ...definition.searchTerms,
    ...memberModules.flatMap((module) => [
      module.path,
      module.prd,
      module.classification,
      ...(module.capability_pack_names || []),
    ]),
  ]
    .join(" ")
    .toLowerCase();

  return {
    definition,
    memberModules,
    operatorManagedModules,
    primarySelectablePaths,
    optionalSelectablePaths,
    destroySelectablePaths,
    primaryExplicitlySelected,
    primaryAutoAdded,
    optionalSelected,
    optionalAutoAdded,
    destroyExplicitlySelected,
    destroyAutoAdded,
    searchHaystack,
  };
}

function isRollupAddonUnlocked(definition) {
  const modulesByPath = moduleMapByPath();
  const primaryModules = definition.primaryPaths
    .map((path) => modulesByPath.get(path))
    .filter(Boolean);

  if (primaryModules.length === 0) {
    return false;
  }

  return primaryModules.every((module) => module.deployment_status === "deployed");
}

function syncRollupSelectionConstraints() {
  if (state.actionMode === "destroy") {
    const modulesByPath = moduleMapByPath();
    [...state.selected].forEach((path) => {
      if (!isModuleSelectableInCurrentMode(modulesByPath.get(path))) {
        state.selected.delete(path);
      }
    });
  }

  DASHBOARD_ROLLUPS.forEach((definition) => {
    if (isRollupAddonUnlocked(definition)) {
      return;
    }

    definition.optionalPaths.forEach((path) => {
      state.selected.delete(path);
    });
  });
}

function rollupAddonStatusText(optionalAvailable, addonUnlocked) {
  if (!optionalAvailable) {
    return "Not enabled by the current manifest.";
  }
  if (!addonUnlocked) {
    return "Available after the pack baseline is deployed.";
  }
  return "Optional within the rollup.";
}

function rollupMemberLabel(definition, path, module = null) {
  return definition.pathLabels?.[path] || module?.prd || path;
}

function rollupMemberFallback(definition, path) {
  return definition.pathFallbacks?.[path] || "Module missing from dashboard state.";
}

function rollupAddonStatusTextForDefinition(definition, optionalAvailable, addonUnlocked) {
  if (!optionalAvailable) {
    return definition.addonUnavailableDetail || rollupAddonStatusText(optionalAvailable, addonUnlocked);
  }
  if (!addonUnlocked) {
    return definition.addonLockedDetail || rollupAddonStatusText(optionalAvailable, addonUnlocked);
  }
  return definition.addonAvailableDetail || rollupAddonStatusText(optionalAvailable, addonUnlocked);
}

function renderRollupStatusLines(definition, context) {
  const orderedPaths = [
    ...definition.operatorManagedPaths,
    ...definition.primaryPaths,
    ...definition.optionalPaths,
  ];
  const modulesByPath = new Map(context.memberModules.map((module) => [module.path, module]));

  return orderedPaths
    .map((path) => {
      const module = modulesByPath.get(path) || null;
      return renderRollupStatusLine(
        rollupMemberLabel(definition, path, module),
        module,
        rollupMemberFallback(definition, path),
      );
    })
    .join("");
}

function renderRollupStatusLine(label, module, fallback) {
  if (!module) {
    return `
      <div class="rollup-status-line">
        <div class="rollup-status-header">
          <strong>${label}:</strong>
        </div>
        <div class="rollup-status-detail">
          <span class="inline-detail">${fallback}</span>
        </div>
      </div>
    `;
  }
  return `
    <div class="rollup-status-line">
      <div class="rollup-status-header">
        <strong>${label}:</strong>
        <span class="tag ${statusTagClass(module)}">${statusLabelForModule(module)}</span>
      </div>
      <div class="rollup-status-detail">
        <span class="inline-detail">${module.deployment_detail || ""}</span>
      </div>
    </div>
  `;
}

function rollupDisplayLabel(definition, includedPaths) {
  const normalizedIncluded = definition.memberPaths.filter((path) => includedPaths.includes(path));
  const includesAllPrimary = definition.primaryPaths.length > 0
    && definition.primaryPaths.every((path) => normalizedIncluded.includes(path));
  const includesAllOptional = definition.optionalPaths.every((path) => normalizedIncluded.includes(path));
  const includesAllOperatorManaged = definition.operatorManagedPaths.every((path) => normalizedIncluded.includes(path));
  const destroyPaths = destroyPathsForRollup(definition);
  const includesAllDestroyPaths = destroyPaths.length > 0
    && destroyPaths.every((path) => normalizedIncluded.includes(path));

  if (includesAllPrimary && includesAllOptional && includesAllOperatorManaged) {
    return definition.title;
  }
  if (state.actionMode === "destroy" && includesAllDestroyPaths) {
    return definition.title;
  }

  const parts = normalizedIncluded.map((path) => rollupMemberLabel(definition, path));
  return parts.length > 0 ? `${definition.title} (${parts.join(" + ")})` : definition.title;
}

function collapsePathsForDisplay(paths) {
  const collapsed = [];
  const processedRollups = new Set();

  paths.forEach((path) => {
    const definition = rollupDefinitionForPath(path);
    if (!definition) {
      collapsed.push(path);
      return;
    }
    if (processedRollups.has(definition.id)) {
      return;
    }

    const includedPaths = paths.filter((candidate) => definition.memberPaths.includes(candidate));
    collapsed.push(rollupDisplayLabel(definition, includedPaths));
    processedRollups.add(definition.id);
  });

  return collapsed;
}

function executionDisplayEntries(executionPaths) {
  return collapsePathsForDisplay(executionPaths);
}

function destroyComponentLabel(module) {
  if (module.path === "modules/l0-audit-pipeline") {
    return "PRD-03 audit add-on";
  }
  if (module.path === "modules/l0-account-baseline") {
    return "PRD-02 account baseline";
  }
  if (module.path === BOOTSTRAP_MODULE_PATH) {
    return "PRD-00 bootstrap backend";
  }
  return module.prd;
}

function destroyComponentDetail(module) {
  if (module.path === "modules/l0-audit-pipeline") {
    return "Destroys AWS Config, CloudTrail, Security Hub, and the audit bucket for this environment.";
  }
  if (module.path === "modules/l0-account-baseline") {
    return "Destroys the account foundation after deployed higher-layer dependents have already been removed.";
  }
  if (module.path === BOOTSTRAP_MODULE_PATH) {
    return "The backend cannot destroy itself through tf-run.sh. Manual destroy required.";
  }
  return module.deployment_detail || "";
}

function destroyComponentDetailForRollup(definition, module) {
  return definition.destroyDetails?.[module.path] || destroyComponentDetail(module);
}

function bulkSelectablePaths() {
  if (state.actionMode === "destroy") {
    return state.modules
      .filter((module) => module.enabled_in_manifest && module.supports_destroy === true && isActiveDeploymentStatus(module.deployment_status))
      .map((module) => module.path);
  }

  return state.modules
    .filter((module) => module.enabled_in_manifest && module.dashboard_selectable !== false)
    .map((module) => module.path);
}

function liveEnvironmentSummary(modules) {
  const enabledModules = modules.filter((module) => module.enabled_in_manifest);
  const deployedModules = enabledModules.filter((module) => module.deployment_status === "deployed");
  const partialModules = enabledModules.filter((module) => module.deployment_status === "partial");
  const noStateModules = enabledModules.filter((module) => module.deployment_status === "no-state");
  const unknownModules = enabledModules.filter((module) => module.deployment_status === "unknown");
  const bootstrapDeployed = deployedModules.some((module) => module.path === BOOTSTRAP_MODULE_PATH);
  const nonBootstrapDeployed = deployedModules.filter((module) => module.path !== BOOTSTRAP_MODULE_PATH);

  if (enabledModules.length === 0) {
    return "No manifest-enabled modules";
  }
  if (unknownModules.length > 0 && deployedModules.length === 0 && noStateModules.length === 0) {
    return "State detection unavailable";
  }
  if (partialModules.length > 0) {
    return `Partial deployment detected (${partialModules.length} partial)`;
  }
  if (unknownModules.length > 0) {
    return `Mixed (${deployedModules.length} deployed, ${unknownModules.length} unknown)`;
  }
  if (deployedModules.length === 0) {
    return "Not deployed";
  }
  if (bootstrapDeployed && nonBootstrapDeployed.length === 0) {
    return "Bootstrap only";
  }
  if (deployedModules.length === enabledModules.length) {
    return "Fully deployed";
  }
  return `Partially deployed (${deployedModules.length}/${enabledModules.length})`;
}

function syncUiInteractivity() {
  const busy = state.loadingState;
  els.environmentSelect.disabled = busy;
  els.refreshButton.disabled = busy;
  els.moduleSearch.disabled = busy;
  els.deployModeButton.disabled = busy;
  els.destroyModeButton.disabled = busy;
  els.selectAllButton.disabled = busy;
  els.clearButton.disabled = busy;
}

async function loadState(environment) {
  let loadReason = "refresh";
  if (typeof environment === "object" && environment !== null) {
    loadReason = environment.reason || "refresh";
    environment = environment.environment || state.environment;
  }
  const quietSync = loadReason === "post-run-sync";

  state.loadingState = true;
  state.loadingReason = loadReason;
  state.resolutionLoading = false;
  clearRunApproval();
  if (!quietSync && !state.activeTaskId && !state.lastTaskSnapshot) {
    renderRunPlaceholder(
      "syncing",
      "Checking for an active dashboard run and refreshing server state...",
    );
  }
  syncUiInteractivity();
  syncActionButtons(Boolean(state.resolution && !state.resolution.error));
  renderActionAvailability();
  if (!quietSync) {
    setRunnerStatus("Checking runner...", true, "Requesting environment state from the dashboard backend...");
  }

  try {
    const data = await requestJson(`/api/state?env=${encodeURIComponent(environment)}`);
    if (!quietSync) {
      setRunnerStatus("Checking runner...", true, "Applying environment metadata and deployment badges...");
    }
    state.environment = data.environment;
    state.availableEnvironments = data.available_environments;
    state.modules = data.modules;
    state.enabledModulePaths = data.enabled_module_paths;
    state.resolution = null;
    state.resolutionInfo = "";
    clearPendingValidation();
    restoreSelectionsForCurrentContext(new Set([...state.enabledModulePaths, BOOTSTRAP_MODULE_PATH]));
    saveDashboardUiState();

    els.environmentSelect.innerHTML = "";
    data.available_environments.forEach((env) => {
      const option = document.createElement("option");
      option.value = env;
      option.textContent = env;
      option.selected = env === data.environment;
      els.environmentSelect.appendChild(option);
    });

    els.manifestProfile.textContent = data.manifest.deployment_profile_name || "-";
    els.awsProfile.textContent = data.aws_profile || "default";
    els.awsAccountId.textContent = data.aws_account_id || "unknown";
    els.githubRepoSlug.textContent = data.github_repo_slug || "-";
    els.githubEnvironment.textContent = data.github_environment || data.environment;
    els.backendScope.textContent = data.backend_scope || "-";
    els.packSummary.textContent = (data.manifest.enabled_capability_packs || []).join(", ") || "-";
    els.enabledCount.textContent = String(data.enabled_module_paths.length);
    const deployedCount = data.modules.filter((module) => module.deployment_status === "deployed").length;
    els.deployedCount.textContent = String(deployedCount);
    els.envStateSummary.textContent = liveEnvironmentSummary(data.modules);
    renderAccountScopeNotice(data.account_scope_notice || "");
    if (!quietSync) {
      setRunnerStatus(
        data.bash_available
        ? `Runner ready. Git Bash detected. Backend config: ${data.backend_config_present ? "present" : "missing"}.`
        : "Git Bash not detected. Runs will fail until Bash is available.",
        true,
        `Finalizing module preview...\n${formatGithubStatusDetail(data.github_status)}`,
      );
    }

    renderModules();
    await resolveSelection();
    let restoredRun = false;
    if (!state.activeTaskId) {
      restoredRun = await restoreRunPanelFromServer();
    }
    if (!state.activeTaskId && !restoredRun) {
      if (state.lastTaskSnapshot) {
        renderTask(state.lastTaskSnapshot);
      } else {
        renderRunPlaceholder("idle", "No run started yet.", { hideMeta: true });
      }
    }
    setRunnerStatus(
      data.bash_available
      ? `Runner ready. Git Bash detected. Backend config: ${data.backend_config_present ? "present" : "missing"}.`
      : "Git Bash not detected. Runs will fail until Bash is available.",
      false,
      formatGithubStatusDetail(data.github_status),
    );
  } finally {
    state.loadingState = false;
    state.loadingReason = "";
    syncUiInteractivity();
    renderModules();
    syncActionButtons(Boolean(state.resolution && !state.resolution.error));
    renderActionAvailability();
  }
}

function resolutionAction() {
  return state.actionMode === "destroy" ? "destroy" : "apply";
}

function resolutionLabels() {
  const destroyMode = state.actionMode === "destroy";
  return {
    requestedSummary: destroyMode ? "Requested destroy targets" : "Requested",
    autoAddedSummary: destroyMode ? "Auto-added reverse dependents" : "Auto-added dependencies",
    executionSummary: destroyMode ? "Destroy order" : "Execution order",
    requestedHeading: destroyMode ? "Requested destroy targets" : "Requested selections",
    autoAddedHeading: destroyMode ? "Auto-added reverse dependents" : "Auto-added dependencies",
    executionHeading: destroyMode ? "Destroy order" : "Execution order",
    emptyAutoAdded: destroyMode ? "No deployed reverse dependents need teardown." : "No extra dependencies needed.",
    emptyPreviewAutoAdded: destroyMode ? "No reverse-dependent expansion yet." : "No dependency expansion yet.",
    emptyExecution: destroyMode ? "No destroy order yet." : "No execution order yet.",
    autoAddedTag: destroyMode ? "Included as reverse dependent" : "Included as dependency",
    autoAddedTitle: destroyMode
      ? "Included as reverse dependent. Click to explicitly select this module."
      : "Included as dependency. Click to explicitly select this module.",
  };
}

function syncModeControls() {
  const destroyMode = state.actionMode === "destroy";
  els.deployModeButton.classList.toggle("active", !destroyMode);
  els.destroyModeButton.classList.toggle("active", destroyMode);

  const labels = resolutionLabels();
  els.requestedSummaryLabel.textContent = labels.requestedSummary;
  els.autoAddedSummaryLabel.textContent = labels.autoAddedSummary;
  els.executionSummaryLabel.textContent = labels.executionSummary;
  els.requestedHeading.textContent = labels.requestedHeading;
  els.autoAddedHeading.textContent = labels.autoAddedHeading;
  els.executionHeading.textContent = labels.executionHeading;
}

async function setActionMode(mode) {
  if (state.actionMode === mode) {
    return;
  }
  clearRunApproval();
  state.actionMode = mode;
  restoreSelectionsForCurrentContext(new Set([...state.enabledModulePaths, BOOTSTRAP_MODULE_PATH]));
  state.resolutionInfo = "";
  state.resolutionLoading = false;
  clearPendingValidation();
  saveDashboardUiState();
  syncModeControls();
  await resolveSelection();
}

function autoIncludedModuleSet() {
  return new Set(
    (state.resolution?.auto_added_dependencies || []).filter((modulePath) => !state.selected.has(modulePath)),
  );
}

function resolveApplySelectionLocally(selectedModules) {
  const enabledOrder = state.enabledModulePaths;
  const enabledSet = new Set(enabledOrder);
  const modulesByPath = new Map(state.modules.map((module) => [module.path, module]));
  const resolved = new Set();

  function include(path) {
    if (resolved.has(path)) {
      return;
    }

    const module = modulesByPath.get(path);
    if (!module) {
      throw new Error(`Unknown module in dashboard state: ${path}`);
    }

    (module.dependencies || []).forEach((dependency) => {
      if (!enabledSet.has(dependency)) {
        throw new Error(`${path} requires dependency ${dependency}, which is disabled in the manifest.`);
      }
      if (dependency === "modules/bootstrap") {
        return;
      }
      include(dependency);
    });

    resolved.add(path);
  }

  selectedModules.forEach((path) => include(path));

  const executionOrder = enabledOrder.filter((path) => resolved.has(path));
  const autoAddedDependencies = executionOrder.filter((path) => !state.selected.has(path));
  const warnings = [];

  if (executionOrder.includes(AUDIT_PIPELINE_MODULE_PATH)) {
    warnings.push("PRD-03 is included. Applying it will manage AWS Config, CloudTrail, Security Hub, and the audit bucket.");
  }

  if (executionOrder.includes("modules/l1-phone-numbers")) {
    warnings.push("PRD-11 is stateful. Phone numbers are retained infrastructure and should be changed deliberately.");
  }

  return {
    action: "apply",
    environment: state.environment,
    requested_modules: selectedModules,
    auto_added_dependencies: autoAddedDependencies,
    execution_order: executionOrder,
    warnings,
  };
}

function clearPendingValidation() {
  if (state.validationTimer) {
    clearTimeout(state.validationTimer);
    state.validationTimer = null;
  }
}

function markModulesOptimistically(task) {
  const status = task.action === "destroy" ? "no-state" : "deployed";
  const detail = task.action === "destroy"
    ? "Dashboard marked this module as not deployed after successful destroy. Refreshing backend state..."
    : "Dashboard marked this module as deployed after successful apply. Refreshing backend state...";
  const targets = new Set(task.execution_order || []);

  state.modules = state.modules.map((module) => {
    if (!targets.has(module.path)) {
      return module;
    }
    return {
      ...module,
      deployment_status: status,
      deployment_detail: detail,
    };
  });
}

function currentSelectionSnapshot() {
  return [...state.selected].slice().sort();
}

function selectionsMatch(left, right) {
  if (left.length !== right.length) {
    return false;
  }
  return left.every((value, index) => value === right[index]);
}

function normalizeResolutionForCompare(resolution) {
  if (!resolution) {
    return null;
  }
  if (resolution.error) {
    return { error: resolution.error };
  }
  return {
    action: resolution.action,
    requested_modules: [...(resolution.requested_modules || [])],
    auto_added_dependencies: [...(resolution.auto_added_dependencies || [])],
    execution_order: [...(resolution.execution_order || [])],
    warnings: [...(resolution.warnings || [])],
    deferred_modules: [...(resolution.deferred_modules || [])],
  };
}

function queueBackendValidation(selectedModules) {
  clearPendingValidation();
  const requestSeq = ++state.validationRequestSeq;
  const expectedEnvironment = state.environment;
  const expectedSelection = [...selectedModules].slice().sort();
  state.resolutionInfo = "Validating preview with server...";
  renderResolution();

  state.validationTimer = setTimeout(async () => {
    try {
      const backendResolution = await requestJson("/api/resolve", {
        method: "POST",
        body: JSON.stringify({
          action: "apply",
          environment: expectedEnvironment,
          selected_modules: selectedModules,
        }),
      });

      if (requestSeq !== state.validationRequestSeq) {
        return;
      }
      if (state.actionMode !== "apply" || state.environment !== expectedEnvironment) {
        return;
      }
      if (!selectionsMatch(currentSelectionSnapshot(), expectedSelection)) {
        return;
      }

      const previous = JSON.stringify(normalizeResolutionForCompare(state.resolution));
      const next = JSON.stringify(normalizeResolutionForCompare(backendResolution));
      state.resolution = backendResolution;
      state.resolutionInfo = previous === next ? "" : "Preview updated after server validation.";
      renderModules();
      renderResolution();
    } catch (error) {
      if (requestSeq !== state.validationRequestSeq) {
        return;
      }
      if (state.actionMode !== "apply" || state.environment !== expectedEnvironment) {
        return;
      }
      if (!selectionsMatch(currentSelectionSnapshot(), expectedSelection)) {
        return;
      }

      state.resolutionInfo = `Showing local preview. Server validation failed: ${error.message}`;
      renderResolution();
    } finally {
      if (requestSeq === state.validationRequestSeq) {
        state.validationTimer = null;
      }
    }
  }, 250);
}

function renderModulesLegacy() {
  const search = els.moduleSearch.value.trim().toLowerCase();
  els.moduleList.innerHTML = "";
  const autoAddedDependencies = autoIncludedModuleSet();
  const labels = resolutionLabels();
  const rolledUpPaths = rolledUpModulePathSet();

  DASHBOARD_ROLLUPS.forEach((definition) => {
    const context = rollupContext(definition, autoAddedDependencies);
    if (context.memberModules.length === 0 || !context.searchHaystack.includes(search)) {
      return;
    }

    const bootstrapModule = context.operatorManagedModules[0] || null;
    const baselineModule = context.memberModules.find((module) => definition.primaryPaths.includes(module.path)) || null;
    const auditModule = context.memberModules.find((module) => definition.optionalPaths.includes(module.path)) || null;
    const selectable = context.primarySelectablePaths.length > 0;
    const selectorControl = !selectable
      ? '<span class="selection-indicator placeholder" aria-hidden="true"></span>'
      : context.primaryAutoAdded
        ? `<button type="button" class="selection-indicator auto-added" data-promote-rollup="${definition.id}" title="${labels.autoAddedTitle}" aria-label="${labels.autoAddedTitle}" ${state.loadingState ? "disabled" : ""}>*</button>`
        : `<input type="checkbox" ${context.primaryExplicitlySelected ? "checked" : ""} data-rollup="${definition.id}" ${state.loadingState ? "disabled" : ""}>`;
    const optionalAvailable = context.optionalSelectablePaths.length > 0;
    const addonUnlocked = isRollupAddonUnlocked(definition);
    const optionalSelectable = optionalAvailable && addonUnlocked;
    const optionalChecked = optionalSelectable && (context.optionalSelected || context.optionalAutoAdded);
    const auditAddonImplemented = auditModule?.deployment_status === "deployed";

    const card = document.createElement("div");
    card.className = "module-card rollup-card";
    card.innerHTML = `
      <div class="module-topline">
        ${selectorControl}
        <div class="module-body">
          <div class="module-title">
            <strong>${definition.title}</strong>
          </div>
          <div class="module-subtitle">PRD-00 bootstrap, PRD-02 account baseline, optional PRD-03 audit pipeline</div>
          <div class="tag-row">
            <span class="tag">${definition.capabilityPackName}</span>
            ${context.primaryAutoAdded ? `<span class="tag dependency">${labels.autoAddedTag}</span>` : ""}
            ${bootstrapModule ? `<span class="tag ${statusTagClass(bootstrapModule)}">${statusLabelForModule(bootstrapModule)}</span>` : ""}
            ${baselineModule ? `<span class="tag ${statusTagClass(baselineModule)}">${statusLabelForModule(baselineModule)}</span>` : ""}
            ${auditModule ? `<span class="tag ${statusTagClass(auditModule)}">${statusLabelForModule(auditModule)}</span>` : ""}
          </div>
          <div class="module-meta rollup-meta">
            ${renderRollupStatusLine("Bootstrap", bootstrapModule, "Operator-managed prerequisite.")}
            ${renderRollupStatusLine("Account baseline", baselineModule, "Baseline module missing from dashboard state.")}
            ${renderRollupStatusLine("Audit add-on", auditModule, "Audit add-on is not present in the catalog.")}
          </div>
          ${auditAddonImplemented
            ? ""
            : `
              <div class="rollup-addon-row">
                <label class="addon-toggle${optionalSelectable ? "" : " disabled"}" for="addon-${definition.id}">
                  <input
                    id="addon-${definition.id}"
                    type="checkbox"
                    data-rollup-addon="${definition.id}"
                    ${optionalChecked ? "checked" : ""}
                    ${!optionalSelectable || state.loadingState ? "disabled" : ""}
                  >
                  <span>Include PRD-03 audit add-on | ${rollupAddonStatusText(optionalAvailable, addonUnlocked)}</span>
                </label>
              </div>
            `}
        </div>
      </div>
    `;

    const rollupCheckbox = card.querySelector("[data-rollup]");
    if (rollupCheckbox) {
      rollupCheckbox.addEventListener("change", async (event) => {
        if (event.target.checked) {
          context.primarySelectablePaths.forEach((path) => state.selected.add(path));
        } else {
          [...context.primarySelectablePaths, ...context.optionalSelectablePaths].forEach((path) => state.selected.delete(path));
        }
        await resolveSelection();
      });
    }

    const promoteButton = card.querySelector("[data-promote-rollup]");
    if (promoteButton) {
      promoteButton.addEventListener("click", async (event) => {
        event.preventDefault();
        context.primarySelectablePaths.forEach((path) => state.selected.add(path));
        await resolveSelection();
      });
    }

    const addonToggle = card.querySelector("[data-rollup-addon]");
    if (addonToggle) {
      addonToggle.addEventListener("change", async (event) => {
        if (event.target.checked) {
          context.primarySelectablePaths.forEach((path) => state.selected.add(path));
          context.optionalSelectablePaths.forEach((path) => state.selected.add(path));
        } else {
          context.optionalSelectablePaths.forEach((path) => state.selected.delete(path));
        }
        await resolveSelection();
      });
    }

    els.moduleList.appendChild(card);
  });

  const visibleModules = state.modules.filter((module) => {
    if (rolledUpPaths.has(module.path)) {
      return false;
    }
    const haystack = [
      module.path,
      module.prd,
      module.classification,
      ...(module.capability_pack_names || []),
    ]
      .join(" ")
      .toLowerCase();
    return haystack.includes(search);
  });

  visibleModules.forEach((module) => {
    const card = document.createElement("label");
    card.className = `module-card${module.enabled_in_manifest ? "" : " disabled"}`;

    const checked = state.selected.has(module.path);
    const autoAdded = autoAddedDependencies.has(module.path);
    const selectable = module.enabled_in_manifest && module.dashboard_selectable !== false;
    const dependencySummary = module.dependencies.length
      ? `Depends on: ${module.dependencies.join(", ")}`
      : "No module dependencies.";
    const statusLabel =
      module.deployment_status === "deployed"
        ? "Deployed"
        : module.deployment_status === "no-state"
          ? "No State"
          : "Unknown";
    const selectorControl = !selectable
      ? '<span class="selection-indicator placeholder" aria-hidden="true"></span>'
      : autoAdded
        ? `<button type="button" class="selection-indicator auto-added" data-promote-module="${module.path}" title="${labels.autoAddedTitle}" aria-label="${labels.autoAddedTitle}" ${state.loadingState ? "disabled" : ""}>★</button>`
        : `<input type="checkbox" ${checked ? "checked" : ""} data-module="${module.path}" ${state.loadingState ? "disabled" : ""}>`;

    card.innerHTML = `
      <div class="module-topline">
        ${selectorControl}
        <div class="module-body">
          <div class="module-title">
            <strong>${module.prd}</strong>
            <span class="tag muted">Layer ${module.layer}</span>
          </div>
          <div class="module-subtitle">${module.path}</div>
          <div class="tag-row">
            ${(module.capability_pack_names || []).map((name) => `<span class="tag">${name}</span>`).join("")}
            <span class="tag muted">${module.classification}</span>
            <span class="tag status-${module.deployment_status}">${statusLabel}</span>
            ${autoAdded ? `<span class="tag dependency">${labels.autoAddedTag}</span>` : ""}
            ${module.dashboard_selectable === false ? '<span class="tag muted">Operator managed</span>' : ""}
            ${module.domain_tfvars ? `<span class="tag muted">${module.domain_tfvars}</span>` : ""}
          </div>
          <div class="module-meta">
            <div>${dependencySummary}</div>
            <div>${
              !module.enabled_in_manifest
                ? "Disabled by current manifest."
                : module.dashboard_selectable === false
                  ? "Enabled in current manifest, but managed outside the dashboard."
                  : "Enabled in current manifest."
            }</div>
            <div>${module.deployment_detail || ""}</div>
          </div>
        </div>
      </div>
    `;

    const checkbox = card.querySelector("input");
    if (checkbox) {
      checkbox.addEventListener("change", async (event) => {
        if (event.target.checked) {
          state.selected.add(module.path);
        } else {
          state.selected.delete(module.path);
        }
        await resolveSelection();
      });
    }

    const promoteButton = card.querySelector("[data-promote-module]");
    if (promoteButton) {
      promoteButton.addEventListener("click", async (event) => {
        event.preventDefault();
        state.selected.add(module.path);
        await resolveSelection();
      });
    }

    els.moduleList.appendChild(card);
  });
}

function renderModules() {
  const search = els.moduleSearch.value.trim().toLowerCase();
  els.moduleList.innerHTML = "";
  const autoAddedDependencies = autoIncludedModuleSet();
  const labels = resolutionLabels();
  const rolledUpPaths = rolledUpModulePathSet();
  const destroyMode = state.actionMode === "destroy";
  const modulesByPath = moduleMapByPath();

  DASHBOARD_ROLLUPS.forEach((definition) => {
    const context = rollupContext(definition, autoAddedDependencies);
    if (context.memberModules.length === 0 || !context.searchHaystack.includes(search)) {
      return;
    }

    const selectable = destroyMode
      ? context.destroySelectablePaths.length > 0
      : context.primarySelectablePaths.length > 0;
    const rollupExplicitlySelected = destroyMode
      ? context.destroyExplicitlySelected
      : context.primaryExplicitlySelected;
    const rollupAutoAdded = destroyMode
      ? context.destroyAutoAdded
      : context.primaryAutoAdded;
    const selectorControl = destroyMode
      ? !selectable
        ? '<span class="selection-indicator placeholder" aria-hidden="true"></span>'
        : rollupAutoAdded
          ? `<button type="button" class="selection-indicator auto-added" data-promote-rollup="${definition.id}" title="${labels.autoAddedTitle}" aria-label="${labels.autoAddedTitle}" ${state.loadingState ? "disabled" : ""}>*</button>`
          : `<input type="checkbox" ${rollupExplicitlySelected ? "checked" : ""} data-rollup="${definition.id}" ${state.loadingState ? "disabled" : ""}>`
      : !selectable
        ? '<span class="selection-indicator placeholder" aria-hidden="true"></span>'
        : rollupAutoAdded
          ? `<button type="button" class="selection-indicator auto-added" data-promote-rollup="${definition.id}" title="${labels.autoAddedTitle}" aria-label="${labels.autoAddedTitle}" ${state.loadingState ? "disabled" : ""}>*</button>`
          : `<input type="checkbox" ${rollupExplicitlySelected ? "checked" : ""} data-rollup="${definition.id}" ${state.loadingState ? "disabled" : ""}>`;
    const optionalAvailable = context.optionalSelectablePaths.length > 0;
    const addonUnlocked = isRollupAddonUnlocked(definition);
    const optionalSelectable = optionalAvailable && addonUnlocked;
    const optionalChecked = optionalSelectable && (context.optionalSelected || context.optionalAutoAdded);
    const optionalModulesDeployed = definition.optionalPaths.length > 0
      && definition.optionalPaths.every((path) => modulesByPath.get(path)?.deployment_status === "deployed");
    const destroyComponents = destroyMode
      ? definition.memberPaths
        .map((path) => modulesByPath.get(path))
        .filter(Boolean)
      : [];

    const card = document.createElement("div");
    card.className = "module-card rollup-card";
    card.innerHTML = `
      <div class="module-topline">
        ${selectorControl}
        <div class="module-body">
          <div class="module-title">
            <strong>${definition.title}</strong>
          </div>
          <div class="module-subtitle">${
            destroyMode
              ? definition.destroyDescription
              : definition.applyDescription
          }</div>
          <div class="tag-row">
            <span class="tag">${definition.capabilityPackName}</span>
            ${rollupAutoAdded ? `<span class="tag dependency">${labels.autoAddedTag}</span>` : ""}
            ${destroyMode && retainedPathsForRollup(definition).length > 0 ? '<span class="tag muted">Retains protected base</span>' : ""}
            ${!selectable ? `<span class="tag muted">${destroyMode ? "No safe destroy targets" : "Disabled by manifest"}</span>` : ""}
          </div>
          <div class="module-meta rollup-meta">
            ${renderRollupStatusLines(definition, context)}
          </div>
          ${destroyMode
            ? `
              <div class="rollup-destroy-list">
                ${destroyComponents.map((module) => {
                  const explicitSelected = state.selected.has(module.path);
                  const autoAdded = autoAddedDependencies.has(module.path);
                  const selectableInDestroy = module.path !== BOOTSTRAP_MODULE_PATH
                    && Boolean(module.enabled_in_manifest && moduleSupportsDestroyInDashboard(module) && isActiveDeploymentStatus(module.deployment_status));
                  const control = !selectableInDestroy
                    ? '<span class="selection-indicator placeholder" aria-hidden="true"></span>'
                    : autoAdded
                      ? `<button type="button" class="selection-indicator auto-added" data-promote-module="${module.path}" title="${labels.autoAddedTitle}" aria-label="${labels.autoAddedTitle}" ${state.loadingState ? "disabled" : ""}>*</button>`
                      : `<input type="checkbox" ${explicitSelected ? "checked" : ""} data-module="${module.path}" ${state.loadingState ? "disabled" : ""}>`;
                  const detail = module.enabled_in_manifest
                    ? destroyComponentDetailForRollup(definition, module)
                    : "Not enabled by the current manifest.";
                  return `
                    <div class="destroy-component-row">
                      <div class="destroy-component-toggle">
                        ${control}
                        <div class="destroy-component-copy">
                          <strong>${rollupMemberLabel(definition, module.path, module)}</strong>
                          <span>${detail}</span>
                        </div>
                      </div>
                      <div class="destroy-component-tags">
                        <span class="tag ${statusTagClass(module)}">${statusLabelForModule(module)}</span>
                        ${autoAdded ? `<span class="tag dependency">${labels.autoAddedTag}</span>` : ""}
                        ${retainedPathsForRollup(definition).includes(module.path) ? '<span class="tag muted">Retained by default</span>' : ""}
                        ${module.path === BOOTSTRAP_MODULE_PATH ? '<span class="tag muted">Manual destroy only</span>' : ""}
                        ${!module.enabled_in_manifest ? '<span class="tag muted">Disabled</span>' : ""}
                        ${module.enabled_in_manifest && !isActiveDeploymentStatus(module.deployment_status) ? '<span class="tag muted">Not currently deployed</span>' : ""}
                        ${module.enabled_in_manifest && module.path !== BOOTSTRAP_MODULE_PATH && !moduleSupportsDestroyInDashboard(module) ? '<span class="tag muted">Not destroyable</span>' : ""}
                      </div>
                    </div>
                  `;
                }).join("")}
              </div>
            `
            : `
              ${definition.optionalPaths.length === 0 || optionalModulesDeployed
                ? ""
                : `
                  <div class="rollup-addon-row">
                    <label class="addon-toggle${optionalSelectable ? "" : " disabled"}" for="addon-${definition.id}">
                      <input
                        id="addon-${definition.id}"
                        type="checkbox"
                        data-rollup-addon="${definition.id}"
                        ${optionalChecked ? "checked" : ""}
                        ${!optionalSelectable || state.loadingState ? "disabled" : ""}
                      >
                      <span>${definition.addonToggleLabel} | ${rollupAddonStatusTextForDefinition(definition, optionalAvailable, addonUnlocked)}</span>
                    </label>
                  </div>
                `}
            `}
        </div>
      </div>
    `;

    const rollupCheckbox = card.querySelector("[data-rollup]");
    if (rollupCheckbox) {
      rollupCheckbox.addEventListener("change", async (event) => {
        const rollupPaths = destroyMode
          ? context.destroySelectablePaths
          : context.primarySelectablePaths;
        if (event.target.checked) {
          rollupPaths.forEach((path) => state.selected.add(path));
        } else {
          rollupPaths.forEach((path) => state.selected.delete(path));
          if (!destroyMode) {
            context.optionalSelectablePaths.forEach((path) => state.selected.delete(path));
          }
        }
        await resolveSelection();
      });
    }

    const promoteButton = card.querySelector("[data-promote-rollup]");
    if (promoteButton) {
      promoteButton.addEventListener("click", async (event) => {
        event.preventDefault();
        const rollupPaths = destroyMode
          ? context.destroySelectablePaths
          : context.primarySelectablePaths;
        rollupPaths.forEach((path) => state.selected.add(path));
        await resolveSelection();
      });
    }

    if (!destroyMode) {
      const addonToggle = card.querySelector("[data-rollup-addon]");
      if (addonToggle) {
        addonToggle.addEventListener("change", async (event) => {
          if (event.target.checked) {
            context.primarySelectablePaths.forEach((path) => state.selected.add(path));
            context.optionalSelectablePaths.forEach((path) => state.selected.add(path));
          } else {
            context.optionalSelectablePaths.forEach((path) => state.selected.delete(path));
          }
          await resolveSelection();
        });
      }
    } else {
      const destroyCheckboxes = card.querySelectorAll("[data-module]");
      destroyCheckboxes.forEach((checkbox) => {
        checkbox.addEventListener("change", async (event) => {
          const modulePath = event.target.getAttribute("data-module");
          if (!modulePath) {
            return;
          }
          if (event.target.checked) {
            state.selected.add(modulePath);
          } else {
            state.selected.delete(modulePath);
          }
          await resolveSelection();
        });
      });

      const destroyPromoteButtons = card.querySelectorAll("[data-promote-module]");
      destroyPromoteButtons.forEach((button) => {
        button.addEventListener("click", async (event) => {
          event.preventDefault();
          const modulePath = event.currentTarget.getAttribute("data-promote-module");
          if (!modulePath) {
            return;
          }
          state.selected.add(modulePath);
          await resolveSelection();
        });
      });
    }

    els.moduleList.appendChild(card);
  });

  const visibleModules = state.modules.filter((module) => {
    if (rolledUpPaths.has(module.path)) {
      return false;
    }
    const haystack = [
      module.path,
      module.prd,
      module.classification,
      ...(module.capability_pack_names || []),
    ]
      .join(" ")
      .toLowerCase();
    return haystack.includes(search);
  });

  visibleModules.forEach((module) => {
    const card = document.createElement("label");
    card.className = `module-card${module.enabled_in_manifest ? "" : " disabled"}`;

    const checked = state.selected.has(module.path);
    const autoAdded = autoAddedDependencies.has(module.path);
    const selectable = isModuleSelectableInCurrentMode(module);
    const dependencySummary = module.dependencies.length
      ? `Depends on: ${module.dependencies.join(", ")}`
      : "No module dependencies.";
    const statusLabel = statusLabelForModule(module);
    const selectorControl = !selectable
      ? '<span class="selection-indicator placeholder" aria-hidden="true"></span>'
      : autoAdded
        ? `<button type="button" class="selection-indicator auto-added" data-promote-module="${module.path}" title="${labels.autoAddedTitle}" aria-label="${labels.autoAddedTitle}" ${state.loadingState ? "disabled" : ""}>*</button>`
        : `<input type="checkbox" ${checked ? "checked" : ""} data-module="${module.path}" ${state.loadingState ? "disabled" : ""}>`;

    card.innerHTML = `
      <div class="module-topline">
        ${selectorControl}
        <div class="module-body">
          <div class="module-title">
            <strong>${module.prd}</strong>
            <span class="tag muted">Layer ${module.layer}</span>
          </div>
          <div class="module-subtitle">${module.path}</div>
          <div class="tag-row">
            ${(module.capability_pack_names || []).map((name) => `<span class="tag">${name}</span>`).join("")}
            <span class="tag muted">${module.classification}</span>
            <span class="tag status-${module.deployment_status}">${statusLabel}</span>
            ${autoAdded ? `<span class="tag dependency">${labels.autoAddedTag}</span>` : ""}
            ${module.dashboard_selectable === false ? '<span class="tag muted">Operator managed</span>' : ""}
            ${module.domain_tfvars ? `<span class="tag muted">${module.domain_tfvars}</span>` : ""}
          </div>
          <div class="module-meta">
            <div>${dependencySummary}</div>
            <div>${
              !module.enabled_in_manifest
                ? "Disabled by current manifest."
                : !selectable && destroyMode
                  ? "Enabled in current manifest, but not marked destroyable for dashboard teardown."
                  : module.dashboard_selectable === false
                    ? "Enabled in current manifest, but managed outside the dashboard."
                    : "Enabled in current manifest."
            }</div>
            <div>${module.deployment_detail || ""}</div>
          </div>
        </div>
      </div>
    `;

    const checkbox = card.querySelector("input");
    if (checkbox) {
      checkbox.addEventListener("change", async (event) => {
        if (event.target.checked) {
          state.selected.add(module.path);
        } else {
          state.selected.delete(module.path);
        }
        await resolveSelection();
      });
    }

    const promoteButton = card.querySelector("[data-promote-module]");
    if (promoteButton) {
      promoteButton.addEventListener("click", async (event) => {
        event.preventDefault();
        state.selected.add(module.path);
        await resolveSelection();
      });
    }

    els.moduleList.appendChild(card);
  });
}

async function resolveSelection() {
  syncRollupSelectionConstraints();
  saveDashboardUiState();
  const selectedModules = [...state.selected];
  state.resolutionInfo = "";
  state.resolutionLoading = false;
  if (selectedModules.length === 0) {
    state.resolution = null;
    clearPendingValidation();
    renderModules();
    renderResolution();
    return;
  }

  if (resolutionAction() === "apply") {
    try {
      state.resolution = resolveApplySelectionLocally(selectedModules);
      queueBackendValidation(selectedModules);
    } catch (error) {
      state.resolution = { error: error.message };
      clearPendingValidation();
    }

    renderModules();
    renderResolution();
    return;
  }

  try {
    clearPendingValidation();
    state.resolutionInfo = "Preparing destroy preview with server checks...";
    state.resolutionLoading = true;
    renderResolution();
    state.resolution = await requestJson("/api/resolve", {
      method: "POST",
      body: JSON.stringify({
        action: resolutionAction(),
        environment: state.environment,
        selected_modules: selectedModules,
      }),
    });
    state.resolutionInfo = "";
  } catch (error) {
    state.resolution = { error: error.message };
    state.resolutionInfo = "";
  } finally {
    state.resolutionLoading = false;
  }

  renderModules();
  renderResolution();
}

function renderResolutionLegacy() {
  const requestedModules = [...state.selected];
  const requestedDisplay = collapsePathsForDisplay(requestedModules);
  const labels = resolutionLabels();
  syncModeControls();
  els.requestedCount.textContent = String(requestedDisplay.length);

  if (!state.resolution || state.resolution.error) {
    els.autoAddedCount.textContent = "0";
    els.executionCount.textContent = "0";
    els.requestedList.innerHTML = requestedDisplay.length
      ? requestedDisplay.map((module) => `<li>${module}</li>`).join("")
      : "<li>No modules selected.</li>";
    els.dependencyList.innerHTML = `<li>${labels.emptyPreviewAutoAdded}</li>`;
    els.executionList.innerHTML = `<li>${labels.emptyExecution}</li>`;
    if (state.resolution?.error) {
      els.resolutionError.textContent = state.resolution.error;
      els.resolutionError.classList.remove("hidden");
    } else {
      els.resolutionError.classList.add("hidden");
    }
    if (state.resolutionInfo) {
      els.resolutionInfo.textContent = state.resolutionInfo;
      els.resolutionInfo.classList.toggle("loading", state.resolutionLoading);
      els.resolutionInfo.classList.remove("hidden");
    } else {
      els.resolutionInfo.classList.remove("loading");
      els.resolutionInfo.classList.add("hidden");
    }
    els.resolutionWarnings.classList.add("hidden");
    syncActionButtons(false);
    syncRunApprovalState();
    return;
  }

  const autoAdded = state.resolution.auto_added_dependencies || [];
  const execution = state.resolution.execution_order || [];
  const autoAddedDisplay = collapsePathsForDisplay(autoAdded);
  const executionDisplay = collapsePathsForDisplay(execution);

  els.autoAddedCount.textContent = String(autoAddedDisplay.length);
  els.executionCount.textContent = String(executionDisplay.length);
  els.requestedList.innerHTML = requestedDisplay.map((module) => `<li>${module}</li>`).join("") || "<li>No modules selected.</li>";
  els.dependencyList.innerHTML = autoAddedDisplay.map((module) => `<li>${module}</li>`).join("") || `<li>${labels.emptyAutoAdded}</li>`;
  els.executionList.innerHTML = executionDisplay.map((module) => `<li>${module}</li>`).join("") || `<li>${labels.emptyExecution}</li>`;

  els.resolutionError.classList.add("hidden");
  if (state.resolutionInfo) {
    els.resolutionInfo.textContent = state.resolutionInfo;
    els.resolutionInfo.classList.toggle("loading", state.resolutionLoading);
    els.resolutionInfo.classList.remove("hidden");
  } else {
    els.resolutionInfo.classList.remove("loading");
    els.resolutionInfo.classList.add("hidden");
  }
  if ((state.resolution.warnings || []).length > 0) {
    els.resolutionWarnings.innerHTML = (state.resolution.warnings || [])
      .map((warning) => `<div>${warning}</div>`)
      .join("");
    els.resolutionWarnings.classList.remove("hidden");
  } else {
    els.resolutionWarnings.classList.add("hidden");
  }

  syncActionButtons(true);
  syncRunApprovalState();
}

function renderResolution() {
  const requestedModules = [...state.selected];
  const requestedDisplay = collapsePathsForDisplay(requestedModules);
  const labels = resolutionLabels();
  syncModeControls();
  els.requestedCount.textContent = String(requestedDisplay.length);

  if (!state.resolution || state.resolution.error) {
    els.autoAddedCount.textContent = "0";
    els.executionCount.textContent = "0";
    els.requestedList.innerHTML = requestedDisplay.length
      ? requestedDisplay.map((module) => `<li>${module}</li>`).join("")
      : "<li>No modules selected.</li>";
    els.dependencyList.innerHTML = `<li>${labels.emptyPreviewAutoAdded}</li>`;
    els.executionList.innerHTML = `<li>${labels.emptyExecution}</li>`;
    if (state.resolution?.error) {
      els.resolutionError.textContent = state.resolution.error;
      els.resolutionError.classList.remove("hidden");
    } else {
      els.resolutionError.classList.add("hidden");
    }
    if (state.resolutionInfo) {
      els.resolutionInfo.textContent = state.resolutionInfo;
      els.resolutionInfo.classList.toggle("loading", state.resolutionLoading);
      els.resolutionInfo.classList.remove("hidden");
    } else {
      els.resolutionInfo.classList.remove("loading");
      els.resolutionInfo.classList.add("hidden");
    }
    els.resolutionWarnings.classList.add("hidden");
    syncActionButtons(false);
    syncRunApprovalState();
    return;
  }

  const autoAdded = state.resolution.auto_added_dependencies || [];
  const execution = state.resolution.execution_order || [];
  const autoAddedDisplay = collapsePathsForDisplay(autoAdded);
  const executionDisplay = executionDisplayEntries(execution);

  els.autoAddedCount.textContent = String(autoAddedDisplay.length);
  els.executionCount.textContent = String(executionDisplay.length);
  els.requestedList.innerHTML = requestedDisplay.map((module) => `<li>${module}</li>`).join("") || "<li>No modules selected.</li>";
  els.dependencyList.innerHTML = autoAddedDisplay.map((module) => `<li>${module}</li>`).join("") || `<li>${labels.emptyAutoAdded}</li>`;
  els.executionList.innerHTML = executionDisplay.map((module) => `<li>${module}</li>`).join("") || `<li>${labels.emptyExecution}</li>`;

  els.resolutionError.classList.add("hidden");
  if (state.resolutionInfo) {
    els.resolutionInfo.textContent = state.resolutionInfo;
    els.resolutionInfo.classList.toggle("loading", state.resolutionLoading);
    els.resolutionInfo.classList.remove("hidden");
  } else {
    els.resolutionInfo.classList.remove("loading");
    els.resolutionInfo.classList.add("hidden");
  }
  if ((state.resolution.warnings || []).length > 0) {
    els.resolutionWarnings.innerHTML = (state.resolution.warnings || [])
      .map((warning) => `<div>${warning}</div>`)
      .join("");
    els.resolutionWarnings.classList.remove("hidden");
  } else {
    els.resolutionWarnings.classList.add("hidden");
  }

  syncActionButtons(true);
  syncRunApprovalState();
}

function syncActionButtons(enabled) {
  const destroyMode = state.actionMode === "destroy";
  const blocked = !enabled || state.loadingState || state.runStartupPending || state.runRequestPending || Boolean(state.activeTaskId) || Boolean(state.pendingRunApproval) || (destroyMode && state.resolutionLoading);
  els.planButton.disabled = blocked || destroyMode;
  els.applyButton.disabled = blocked || destroyMode;
  els.destroyButton.disabled = blocked || !destroyMode;
  renderActionAvailability();
}

async function startRun(action, options = {}) {
  const skipApproval = Boolean(options.skipApproval);
  const allowOperatorDestroy = Boolean(options.allowOperatorDestroy);
  state.runRestoredFromReload = false;

  const desiredMode = action === "destroy" ? "destroy" : "apply";
  if (state.actionMode !== desiredMode) {
    state.actionMode = desiredMode;
    syncModeControls();
    await resolveSelection();
  }

  if (!state.resolution || state.resolution.error) {
    syncActionButtons(Boolean(state.resolution && !state.resolution.error));
    return;
  }

  if (!skipApproval && requiredDestroyApproval(action)) {
    requestDestroyApproval(action);
    return;
  }

  clearRunApproval();
  state.runStartupPending = true;
  syncActionButtons(Boolean(state.resolution && !state.resolution.error));
  state.resolutionInfo = "";
  clearPendingValidation();
  state.runStartupPending = false;
  state.runRequestPending = true;
  syncActionButtons(true);
  setRunMetaContent(`
    <strong>${action.toUpperCase()}</strong> in <strong>${state.environment}</strong>
    <br>
    Status: <strong>starting</strong>
  `);
  els.runLog.textContent = "Submitting run request...";

  try {
    const task = await requestJson("/api/run", {
      method: "POST",
      body: JSON.stringify({
        action,
        environment: state.environment,
        selected_modules: [...state.selected],
        allow_operator_destroy: allowOperatorDestroy,
      }),
    });

    state.activeTaskId = task.task_id;
    renderTask(task);
    await pollTaskOnce();
    beginPolling();
  } catch (error) {
    if (error.payload?.active_task) {
      state.activeTaskId = error.payload.active_task.task_id;
      renderTask(error.payload.active_task);
      els.runLog.textContent += "\n\nAnother dashboard run is already active. Reattached to that run instead of starting a second one.";
      await pollTaskOnce();
      if (state.activeTaskId) {
        beginPolling();
      }
      return;
    }
    setRunMetaContent(`
      <strong>${action.toUpperCase()}</strong> in <strong>${state.environment}</strong>
      <br>
      Status: <strong>failed to start</strong>
    `);
    els.runLog.textContent = `Run request failed: ${error.message}`;
  } finally {
    state.runStartupPending = false;
    state.runRequestPending = false;
    syncActionButtons(Boolean(state.resolution && !state.resolution.error));
  }
}

function renderTask(task) {
  rememberTask(task);
  setRunMetaContent(`
    <strong>${task.action.toUpperCase()}</strong> in <strong>${task.environment}</strong>
    <br>
    Status: <strong>${task.status}</strong>
    ${task.active_module ? `<br>Active module: <code>${task.active_module}</code>` : ""}
    ${state.runRestoredFromReload ? '<br><span class="run-meta-note">Recovered after reload</span>' : ""}
  `);
  els.runLog.textContent = (task.logs || []).join("\n") || "Run created. Waiting for output...";
  els.runLog.scrollTop = els.runLog.scrollHeight;
}

async function restoreRunPanelFromServer() {
  if (state.activeTaskId) {
    return false;
  }

  const data = await requestJson("/api/runs");
  const runs = data.runs || [];
  const activeTask = runs.find((task) => task.status === "queued" || task.status === "running");
  if (activeTask) {
    state.runRestoredFromReload = true;
    state.activeTaskId = activeTask.task_id;
    renderTask(activeTask);
    syncActionButtons(Boolean(state.resolution && !state.resolution.error));
    await pollTaskOnce();
    if (state.activeTaskId) {
      beginPolling();
    }
    return true;
  }

  const latestTask = runs[0];
  if (!latestTask) {
    return false;
  }

  state.runRestoredFromReload = true;
  state.activeTaskId = null;
  renderTask(latestTask);
  syncActionButtons(Boolean(state.resolution && !state.resolution.error));
  return true;
}

function beginPolling() {
  if (state.pollHandle) {
    clearInterval(state.pollHandle);
  }

  state.pollHandle = setInterval(async () => {
    await pollTaskOnce();
  }, 1500);
}

async function pollTaskOnce() {
  if (!state.activeTaskId) {
    if (state.pollHandle) {
      clearInterval(state.pollHandle);
      state.pollHandle = null;
    }
    syncActionButtons(Boolean(state.resolution && !state.resolution.error));
    return;
  }

  try {
    const task = await requestJson(`/api/runs/${encodeURIComponent(state.activeTaskId)}`);
    renderTask(task);
    if (task.status === "failed" || task.status === "succeeded") {
      rememberTask(task);
      const completedEnvironment = task.environment;
      const successfulApplyOrDestroy = task.status === "succeeded" && (task.action === "apply" || task.action === "destroy");

      if (successfulApplyOrDestroy) {
        markModulesOptimistically(task);
        state.selected.clear();
        saveDashboardUiState();
        state.resolution = null;
        state.resolutionInfo = "";
        renderModules();
        renderResolution();
      }

      state.activeTaskId = null;
      clearRunApproval();
      if (state.pollHandle) {
        clearInterval(state.pollHandle);
        state.pollHandle = null;
      }
      syncActionButtons(Boolean(state.resolution && !state.resolution.error));
      await loadState({ environment: completedEnvironment, reason: "post-run-sync" });
    }
  } catch (error) {
    if (state.pollHandle) {
      clearInterval(state.pollHandle);
      state.pollHandle = null;
    }
    state.activeTaskId = null;
    els.runLog.textContent += `\n\nPolling stopped: ${error.message}`;
    syncActionButtons(Boolean(state.resolution && !state.resolution.error));
  }
}

els.environmentSelect.addEventListener("change", async (event) => {
  await loadState({ environment: event.target.value, reason: "environment-switch" });
});

els.refreshButton.addEventListener("click", async () => {
  await loadState({ environment: state.environment, reason: "manual-refresh" });
});

els.accountScopeInfoButton.addEventListener("mouseenter", (event) => {
  showFloatingInfoTooltip(state.accountScopeTooltipMessage, event.clientX, event.clientY);
});

els.accountScopeInfoButton.addEventListener("mousemove", (event) => {
  if (els.floatingInfoTooltip.classList.contains("hidden")) {
    return;
  }
  positionFloatingInfoTooltip(event.clientX, event.clientY);
});

els.accountScopeInfoButton.addEventListener("mouseleave", () => {
  hideFloatingInfoTooltip();
});

els.accountScopeInfoButton.addEventListener("focus", () => {
  const rect = els.accountScopeInfoButton.getBoundingClientRect();
  showFloatingInfoTooltip(state.accountScopeTooltipMessage, rect.right, rect.bottom);
});

els.accountScopeInfoButton.addEventListener("blur", () => {
  hideFloatingInfoTooltip();
});

els.deployModeButton.addEventListener("click", async () => {
  await setActionMode("apply");
});

els.destroyModeButton.addEventListener("click", async () => {
  await setActionMode("destroy");
});

els.moduleSearch.addEventListener("input", () => {
  renderModules();
});

els.selectAllButton.addEventListener("click", async () => {
  state.selected = new Set(bulkSelectablePaths());
  renderModules();
  await resolveSelection();
});

els.clearButton.addEventListener("click", async () => {
  state.selected.clear();
  renderModules();
  await resolveSelection();
});

els.planButton.addEventListener("click", async () => {
  await startRun("plan");
});

els.applyButton.addEventListener("click", async () => {
  await startRun("apply");
});

els.destroyButton.addEventListener("click", async () => {
  await startRun("destroy");
});

els.runApprovalInput.addEventListener("input", (event) => {
  state.runApprovalInput = event.target.value;
  renderRunApproval();
});

els.runApprovalInput.addEventListener("keydown", async (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    clearRunApproval();
    syncActionButtons(Boolean(state.resolution && !state.resolution.error));
    return;
  }

  if (event.key === "Enter" && !els.runApprovalConfirmButton.disabled && state.pendingRunApproval) {
    event.preventDefault();
    const action = state.pendingRunApproval.action;
    clearRunApproval();
    await startRun(action, { skipApproval: true, allowOperatorDestroy: true });
  }
});

els.runApprovalCancelButton.addEventListener("click", () => {
  clearRunApproval();
  syncActionButtons(Boolean(state.resolution && !state.resolution.error));
});

els.runApprovalConfirmButton.addEventListener("click", async () => {
  if (!state.pendingRunApproval || state.runApprovalInput.trim() !== state.pendingRunApproval.requiredPhrase) {
    return;
  }

  const action = state.pendingRunApproval.action;
  clearRunApproval();
  await startRun(action, { skipApproval: true, allowOperatorDestroy: true });
});

hydrateDashboardUiState();
syncModeControls();
renderActionAvailability();
renderRunApproval();
loadState({ environment: state.environment, reason: "initial-load" }).catch((error) => {
  setRunnerStatus(`Failed to load dashboard state: ${error.message}`, false, "");
});
