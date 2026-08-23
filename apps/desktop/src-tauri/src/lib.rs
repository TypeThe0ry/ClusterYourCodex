use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use reqwest::header::{HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_TYPE};
use reqwest::{Client, Method};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{State, WebviewUrl, WebviewWindowBuilder};
use thiserror::Error;
use zeroize::Zeroizing;

mod full_run;
mod integration;
mod provisioning;

use full_run::{FullRunCheckManager, FullRunCheckResult, PublicFullRunCheckError};

use integration::{
    IntegrationActionResult, IntegrationManager, IntegrationSelfTestResult, IntegrationStatus,
    PublicIntegrationError,
};
use provisioning::{
    ApproveHostKeyRequest, ComputerIdRequest, ProvisioningComputerView,
    ProvisioningInitializationError, ProvisioningManager, ProvisioningOperationResult,
    PublicProvisioningError, RevisionRequest, SecretActionRequest, StartComputerRequest,
};

#[derive(Clone)]
struct ManagedProvisioning {
    manager: Option<ProvisioningManager>,
    unavailable_code: &'static str,
}

impl ManagedProvisioning {
    fn from_result(result: Result<ProvisioningManager, ProvisioningInitializationError>) -> Self {
        match result {
            Ok(manager) => Self {
                manager: Some(manager),
                unavailable_code: "provisioning_unavailable",
            },
            Err(error) => Self {
                manager: None,
                unavailable_code: error.public_code(),
            },
        }
    }

    fn manager(&self) -> Result<ProvisioningManager, PublicProvisioningError> {
        self.manager.clone().ok_or_else(|| {
            PublicProvisioningError::initialization_unavailable(self.unavailable_code)
        })
    }
}

const CONTROLLER_ORIGIN: &str = "http://127.0.0.1:47831";
const MAX_REQUEST_BYTES: usize = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const MAX_RENDERER_TIMEOUT: Duration = Duration::from_secs(8);
// Even when almost the entire renderer budget remains, the native HTTP
// attempt ends first. The per-request timeout is also reduced to the absolute
// renderer deadline after any Tauri queue delay.
const NATIVE_PROXY_TIMEOUT: Duration = Duration::from_secs(7);

// The renderer gets exactly one narrow bridge. It never receives a base URL,
// token path, bearer token, or header injection primitive.
const BRIDGE_INITIALIZATION_SCRIPT: &str = r#"
(() => {
  const noCredentials = location.username === "" && location.password === "";
  const trusted = noCredentials && ((location.protocol === "tauri:" &&
      location.hostname === "localhost" && location.port === "") ||
    ((location.protocol === "http:" || location.protocol === "https:") &&
      location.hostname === "tauri.localhost" && location.port === "") ||
    (location.protocol === "http:" && location.hostname === "127.0.0.1" &&
      location.port === "1420"));
  if (!trusted) return;
  const bridge = Object.freeze({
    controllerRequest(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("controller_request", { request });
    },
    integrationStatus() {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("integration_status");
    },
    installOrRepairIntegration() {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("install_or_repair_integration");
    },
    integrationSelfTest() {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("integration_self_test");
    },
    fullRunCheck() {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("full_run_check");
    },
    fullRunCheckStatus() {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("full_run_check_status");
    },
    provisioningStart(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_start", { request });
    },
    provisioningList() {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_list");
    },
    provisioningGet(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_get", { request });
    },
    provisioningApproveHostKey(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_approve_host_key", { request });
    },
    provisioningContinue(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_continue", { request });
    },
    provisioningResume(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_resume", { request });
    },
    provisioningRetry(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_retry", { request });
    },
    provisioningRepair(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_repair", { request });
    },
    provisioningRollback(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_rollback", { request });
    },
    provisioningRemove(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_remove", { request });
    },
    provisioningForgetSshPassword(request) {
      const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
      if (typeof invoke !== "function") {
        return Promise.reject(new Error("native bridge unavailable"));
      }
      return invoke("provisioning_forget_ssh_password", { request });
    }
  });
  Object.defineProperty(window, "__CLUSTER_YOUR_CODEX__", {
    value: bridge,
    configurable: false,
    enumerable: false,
    writable: false
  });
})();
"#;

#[derive(Clone)]
struct ControllerProxy {
    client: Client,
    token_file: PathBuf,
}

impl ControllerProxy {
    fn new(token_file: PathBuf) -> Result<Self, InternalProxyError> {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(2))
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .map_err(|_| InternalProxyError::ClientSetup)?;
        Ok(Self { client, token_file })
    }

    async fn execute(
        &self,
        request: ControllerRequest,
    ) -> Result<ControllerResponse, InternalProxyError> {
        // Validate before any token or body work. A queued Tauri command whose
        // renderer deadline elapsed must never become an upstream request.
        request.validate_at(unix_epoch_millis()?)?;
        let method = match request.method {
            ControllerMethod::Get => Method::GET,
            ControllerMethod::Post => Method::POST,
        };
        let endpoint = format!("{CONTROLLER_ORIGIN}{}", request.path);
        let mut upstream = self
            .client
            .request(method, endpoint)
            .header(ACCEPT, "application/json");

        // Health is intentionally public on the controller. Every other route
        // is authenticated here, inside the native host.
        let token = if request.path == "/v1/health" {
            None
        } else {
            Some(load_token(&self.token_file)?)
        };
        if let Some(token) = token.as_ref() {
            let encoded = Zeroizing::new(format!("Bearer {}", token.as_str()));
            let mut header = HeaderValue::from_str(encoded.as_str())
                .map_err(|_| InternalProxyError::TokenInvalid)?;
            header.set_sensitive(true);
            upstream = upstream.header(AUTHORIZATION, header);
        }

        if request.method == ControllerMethod::Post {
            let default_body = Value::Object(Default::default());
            let body = request.body.as_ref().unwrap_or(&default_body);
            let encoded = serde_json::to_vec(body).map_err(|_| InternalProxyError::InvalidBody)?;
            if encoded.len() > MAX_REQUEST_BYTES {
                return Err(InternalProxyError::RequestTooLarge);
            }
            upstream = upstream
                .header(CONTENT_TYPE, "application/json")
                .body(encoded);
        }

        // Re-check immediately before send so local token/body work cannot
        // extend a mutation beyond the renderer's absolute deadline.
        let request_timeout = request.validate_at(unix_epoch_millis()?)?;
        let response = upstream
            .timeout(request_timeout)
            .send()
            .await
            .map_err(|_| InternalProxyError::ControllerUnavailable)?;
        let status = response.status();
        let response_headers = copy_public_headers(response.headers());
        let body = read_bounded_response(response).await?;

        Ok(ControllerResponse {
            status: status.as_u16(),
            status_text: status.canonical_reason().map(ToOwned::to_owned),
            headers: response_headers,
            body,
        })
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "UPPERCASE")]
enum ControllerMethod {
    Get,
    Post,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ControllerRequest {
    method: ControllerMethod,
    path: String,
    deadline_ms: u64,
    #[serde(default)]
    body: Option<Value>,
}

impl ControllerRequest {
    fn validate_at(&self, now_ms: u64) -> Result<Duration, InternalProxyError> {
        if self.path.len() > 256 || !is_allowed_controller_route(self.method, &self.path) {
            return Err(InternalProxyError::RouteNotAllowed);
        }
        match self.method {
            ControllerMethod::Get if self.body.is_some() => {
                return Err(InternalProxyError::InvalidBody)
            }
            ControllerMethod::Get | ControllerMethod::Post => {}
        }
        let remaining_ms = self
            .deadline_ms
            .checked_sub(now_ms)
            .filter(|remaining| *remaining > 0)
            .ok_or(InternalProxyError::RequestExpired)?;
        let remaining = Duration::from_millis(remaining_ms);
        if remaining > MAX_RENDERER_TIMEOUT {
            return Err(InternalProxyError::InvalidDeadline);
        }
        Ok(remaining.min(NATIVE_PROXY_TIMEOUT))
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ControllerResponse {
    status: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    status_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    headers: Option<std::collections::BTreeMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    body: Option<Value>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicProxyError {
    code: &'static str,
}

#[derive(Debug, Error)]
enum InternalProxyError {
    #[error("native HTTP client setup failed")]
    ClientSetup,
    #[error("controller route is not allowed")]
    RouteNotAllowed,
    #[error("request body is invalid")]
    InvalidBody,
    #[error("request body is too large")]
    RequestTooLarge,
    #[error("request deadline is invalid")]
    InvalidDeadline,
    #[error("request deadline expired")]
    RequestExpired,
    #[error("controller token is unavailable")]
    TokenUnavailable,
    #[error("controller token is invalid")]
    TokenInvalid,
    #[error("controller is unavailable")]
    ControllerUnavailable,
    #[error("controller response is too large")]
    ResponseTooLarge,
    #[error("controller returned a non-JSON response")]
    InvalidResponse,
}

impl From<InternalProxyError> for PublicProxyError {
    fn from(value: InternalProxyError) -> Self {
        let code = match value {
            InternalProxyError::RouteNotAllowed => "route_not_allowed",
            InternalProxyError::InvalidBody => "invalid_body",
            InternalProxyError::RequestTooLarge => "request_too_large",
            InternalProxyError::InvalidDeadline => "invalid_deadline",
            InternalProxyError::RequestExpired => "request_expired",
            InternalProxyError::ResponseTooLarge => "response_too_large",
            InternalProxyError::TokenUnavailable | InternalProxyError::TokenInvalid => {
                "controller_auth_unavailable"
            }
            InternalProxyError::ClientSetup
            | InternalProxyError::ControllerUnavailable
            | InternalProxyError::InvalidResponse => "controller_unavailable",
        };
        Self { code }
    }
}

fn unix_epoch_millis() -> Result<u64, InternalProxyError> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| InternalProxyError::InvalidDeadline)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| InternalProxyError::InvalidDeadline)
}

#[tauri::command]
async fn controller_request(
    request: ControllerRequest,
    proxy: State<'_, ControllerProxy>,
) -> Result<ControllerResponse, PublicProxyError> {
    proxy.execute(request).await.map_err(Into::into)
}

#[tauri::command]
async fn integration_status(
    manager: State<'_, IntegrationManager>,
) -> Result<IntegrationStatus, PublicIntegrationError> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.status())
        .await
        .map_err(|_| {
            PublicIntegrationError::from(integration::IntegrationError::OperationUnavailable)
        })?
        .map_err(Into::into)
}

#[tauri::command]
async fn install_or_repair_integration(
    manager: State<'_, IntegrationManager>,
) -> Result<IntegrationActionResult, PublicIntegrationError> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.install_or_repair())
        .await
        .map_err(|_| {
            PublicIntegrationError::from(integration::IntegrationError::OperationUnavailable)
        })?
        .map_err(Into::into)
}

#[tauri::command]
async fn integration_self_test(
    manager: State<'_, IntegrationManager>,
) -> Result<IntegrationSelfTestResult, PublicIntegrationError> {
    let manager = manager.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.self_test())
        .await
        .map_err(|_| {
            PublicIntegrationError::from(integration::IntegrationError::OperationUnavailable)
        })?
        .map_err(Into::into)
}

#[tauri::command]
async fn full_run_check(
    manager: State<'_, FullRunCheckManager>,
    integration: State<'_, IntegrationManager>,
) -> Result<FullRunCheckResult, PublicFullRunCheckError> {
    let manager = manager.inner().clone();
    let integration = integration.inner().clone();
    tauri::async_runtime::spawn_blocking(move || manager.run(&integration))
        .await
        .map_err(|_| PublicFullRunCheckError::operation_unavailable())?
}

#[tauri::command]
fn full_run_check_status(manager: State<'_, FullRunCheckManager>) -> Option<FullRunCheckResult> {
    manager.progress()
}

async fn run_provisioning<T, F>(operation: F) -> Result<T, PublicProvisioningError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, PublicProvisioningError> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(operation)
        .await
        .map_err(|_| PublicProvisioningError::operation_unavailable())?
}

#[tauri::command]
async fn provisioning_start(
    request: StartComputerRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.start(request)).await
}

#[tauri::command]
async fn provisioning_list(
    manager: State<'_, ManagedProvisioning>,
) -> Result<Vec<ProvisioningComputerView>, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.list()).await
}

#[tauri::command]
async fn provisioning_get(
    request: ComputerIdRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningComputerView, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.get(request)).await
}

#[tauri::command]
async fn provisioning_approve_host_key(
    request: ApproveHostKeyRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.approve_host_key(request)).await
}

#[tauri::command]
async fn provisioning_continue(
    request: SecretActionRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.continue_provisioning(request)).await
}

#[tauri::command]
async fn provisioning_resume(
    request: SecretActionRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || {
        manager.request_intent(cyc_provision::ProvisioningIntent::Resume, request)
    })
    .await
}

#[tauri::command]
async fn provisioning_retry(
    request: SecretActionRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || {
        manager.request_intent(cyc_provision::ProvisioningIntent::Retry, request)
    })
    .await
}

#[tauri::command]
async fn provisioning_repair(
    request: SecretActionRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.repair(request)).await
}

#[tauri::command]
async fn provisioning_rollback(
    request: SecretActionRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.rollback(request)).await
}

#[tauri::command]
async fn provisioning_remove(
    request: SecretActionRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.remove(request)).await
}

#[tauri::command]
async fn provisioning_forget_ssh_password(
    request: RevisionRequest,
    manager: State<'_, ManagedProvisioning>,
) -> Result<ProvisioningOperationResult, PublicProvisioningError> {
    let manager = manager.inner().manager()?;
    run_provisioning(move || manager.forget_ssh_password(request)).await
}

fn is_allowed_controller_route(method: ControllerMethod, path: &str) -> bool {
    match (method, path) {
        (ControllerMethod::Get, "/v1/health" | "/v1/fleet") => true,
        (ControllerMethod::Post, "/v1/plans" | "/v1/jobs") => true,
        (ControllerMethod::Get, path) => route_identifier(path, "/v1/jobs/", ""),
        (ControllerMethod::Post, path) => route_identifier(path, "/v1/jobs/", "/cancel"),
    }
}

fn route_identifier(path: &str, prefix: &str, suffix: &str) -> bool {
    let Some(value) = path
        .strip_prefix(prefix)
        .and_then(|value| value.strip_suffix(suffix))
    else {
        return false;
    };
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn load_token(path: &Path) -> Result<Zeroizing<String>, InternalProxyError> {
    let metadata = std::fs::metadata(path).map_err(|_| InternalProxyError::TokenUnavailable)?;
    if !metadata.is_file() || metadata.len() > 1024 {
        return Err(InternalProxyError::TokenInvalid);
    }
    let raw = std::fs::read(path).map_err(|_| InternalProxyError::TokenUnavailable)?;
    let raw = Zeroizing::new(raw);
    let text = std::str::from_utf8(raw.as_slice()).map_err(|_| InternalProxyError::TokenInvalid)?;
    let token = text.trim_end_matches(['\r', '\n']);
    if token.len() < 32
        || token.len() > 256
        || token.bytes().any(|byte| !(0x21..=0x7e).contains(&byte))
    {
        return Err(InternalProxyError::TokenInvalid);
    }
    Ok(Zeroizing::new(token.to_owned()))
}

fn copy_public_headers(
    headers: &reqwest::header::HeaderMap,
) -> Option<std::collections::BTreeMap<String, String>> {
    let mut result = std::collections::BTreeMap::new();
    for name in ["content-type", "x-request-id", "etag"] {
        if let Some(value) = headers.get(name).and_then(|value| value.to_str().ok()) {
            if value.len() <= 512 && !value.contains(['\r', '\n']) {
                result.insert(name.to_owned(), value.to_owned());
            }
        }
    }
    (!result.is_empty()).then_some(result)
}

async fn read_bounded_response(
    mut response: reqwest::Response,
) -> Result<Option<Value>, InternalProxyError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(InternalProxyError::ResponseTooLarge);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| InternalProxyError::ControllerUnavailable)?
    {
        if bytes.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err(InternalProxyError::ResponseTooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Ok(None);
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| InternalProxyError::InvalidResponse)
}

#[allow(unused_variables)]
fn fixed_data_root(
    local_app_data: Option<&OsStr>,
    xdg_data_home: Option<&OsStr>,
    home: Option<&OsStr>,
) -> Result<PathBuf, InternalProxyError> {
    #[cfg(target_os = "windows")]
    {
        return local_app_data
            .map(PathBuf::from)
            .map(|path| path.join("ClusterYourCodex"))
            .ok_or(InternalProxyError::TokenUnavailable);
    }
    #[cfg(target_os = "macos")]
    {
        return home
            .map(PathBuf::from)
            .map(|path| {
                path.join("Library")
                    .join("Application Support")
                    .join("ClusterYourCodex")
            })
            .ok_or(InternalProxyError::TokenUnavailable);
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(path) = xdg_data_home {
            return Ok(PathBuf::from(path).join("clusteryourcodex"));
        }
        return home
            .map(PathBuf::from)
            .map(|path| path.join(".local").join("share").join("clusteryourcodex"))
            .ok_or(InternalProxyError::TokenUnavailable);
    }
    #[allow(unreachable_code)]
    Err(InternalProxyError::TokenUnavailable)
}

fn default_token_file() -> Result<PathBuf, InternalProxyError> {
    fixed_data_root(
        std::env::var_os("LOCALAPPDATA").as_deref(),
        std::env::var_os("XDG_DATA_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
    .map(|path| path.join("controller.token"))
}

fn trusted_navigation(url: &tauri::Url) -> bool {
    let no_credentials = url.username().is_empty() && url.password().is_none();
    if no_credentials
        && url.scheme() == "tauri"
        && url.host_str() == Some("localhost")
        && url.port().is_none()
    {
        return true;
    }
    if no_credentials
        && matches!(url.scheme(), "http" | "https")
        && url.host_str() == Some("tauri.localhost")
        && url.port().is_none()
    {
        return true;
    }
    cfg!(debug_assertions)
        && no_credentials
        && url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
        && url.port() == Some(1420)
}

pub fn run() {
    let token_file = default_token_file().expect("platform data directory must be available");
    let data_root = token_file
        .parent()
        .expect("controller token must have a data directory")
        .to_path_buf();
    let proxy =
        ControllerProxy::new(token_file.clone()).expect("native controller proxy must initialize");
    let integration = IntegrationManager::new(token_file.clone())
        .expect("native Codex integration manager must initialize");
    let full_run = FullRunCheckManager::new(token_file.clone())
        .expect("native Full Run Check manager must initialize");
    // Missing or damaged worker kits disable only Add Computer. The controller,
    // plugin repair, diagnostics, and Full Run pages must still start so the
    // installation can be repaired in place.
    let provisioning =
        ManagedProvisioning::from_result(ProvisioningManager::new(&data_root, token_file));
    tauri::Builder::default()
        .manage(proxy)
        .manage(integration)
        .manage(full_run)
        .manage(provisioning)
        .invoke_handler(tauri::generate_handler![
            controller_request,
            integration_status,
            install_or_repair_integration,
            integration_self_test,
            full_run_check,
            full_run_check_status,
            provisioning_start,
            provisioning_list,
            provisioning_get,
            provisioning_approve_host_key,
            provisioning_continue,
            provisioning_resume,
            provisioning_retry,
            provisioning_repair,
            provisioning_rollback,
            provisioning_remove,
            provisioning_forget_ssh_password
        ])
        .setup(|app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("ClusterYourCodex")
                .inner_size(1240.0, 820.0)
                .min_inner_size(960.0, 640.0)
                .resizable(true)
                .initialization_script(BRIDGE_INITIALIZATION_SCRIPT)
                .on_navigation(trusted_navigation)
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("ClusterYourCodex desktop host failed");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn route_allowlist_has_no_generic_url_or_admin_surface() {
        for (method, path) in [
            (ControllerMethod::Get, "/v1/health"),
            (ControllerMethod::Get, "/v1/fleet"),
            (ControllerMethod::Post, "/v1/plans"),
            (ControllerMethod::Post, "/v1/jobs"),
            (
                ControllerMethod::Get,
                "/v1/jobs/7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
            ),
            (
                ControllerMethod::Post,
                "/v1/jobs/7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e/cancel",
            ),
        ] {
            assert!(
                is_allowed_controller_route(method, path),
                "{method:?} {path}"
            );
        }
        for (method, path) in [
            (ControllerMethod::Get, "https://attacker.invalid/v1/fleet"),
            (ControllerMethod::Get, "/v1/pairings"),
            (ControllerMethod::Post, "/v1/pairings"),
            (ControllerMethod::Get, "/v1/jobs/../pairings"),
            (ControllerMethod::Get, "/v1/jobs/%2e%2e"),
            (ControllerMethod::Get, "/v1/jobs/id/logs/stdout"),
        ] {
            assert!(
                !is_allowed_controller_route(method, path),
                "{method:?} {path}"
            );
        }
    }

    #[test]
    fn get_body_is_rejected_and_unknown_fields_fail_deserialization() {
        let request: ControllerRequest = serde_json::from_value(serde_json::json!({
            "method": "GET",
            "path": "/v1/health",
            "deadlineMs": 8_000,
            "body": {}
        }))
        .unwrap();
        assert!(request.validate_at(1).is_err());
        assert!(
            serde_json::from_value::<ControllerRequest>(serde_json::json!({
                "method": "GET",
                "path": "/v1/health",
                "deadlineMs": 8_000,
                "headers": {"authorization": "Bearer attacker-controlled"}
            }))
            .is_err()
        );
    }

    #[test]
    fn absolute_deadline_is_required_and_strongly_typed() {
        for value in [
            serde_json::json!({"method": "GET", "path": "/v1/health"}),
            serde_json::json!({
                "method": "GET",
                "path": "/v1/health",
                "deadlineMs": "8000"
            }),
            serde_json::json!({
                "method": "GET",
                "path": "/v1/health",
                "deadlineMs": 8000.5
            }),
        ] {
            assert!(serde_json::from_value::<ControllerRequest>(value).is_err());
        }
    }

    #[test]
    fn queued_request_uses_only_remaining_deadline_budget() {
        let request = ControllerRequest {
            method: ControllerMethod::Post,
            path: "/v1/jobs".to_owned(),
            deadline_ms: 18_000,
            body: Some(serde_json::json!({})),
        };

        assert_eq!(request.validate_at(10_000).unwrap(), Duration::from_secs(7));
        assert_eq!(
            request.validate_at(11_500).unwrap(),
            Duration::from_millis(6_500)
        );
        assert!(matches!(
            request.validate_at(18_000),
            Err(InternalProxyError::RequestExpired)
        ));
        assert!(matches!(
            request.validate_at(9_999),
            Err(InternalProxyError::InvalidDeadline)
        ));
    }

    #[test]
    fn token_validation_accepts_only_bounded_ascii_graphic_material() {
        let root = std::env::temp_dir().join(format!("cyc-desktop-token-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let token_file = root.join("controller.token");
        std::fs::write(&token_file, format!("{}\r\n", "A".repeat(48))).unwrap();
        assert_eq!(load_token(&token_file).unwrap().len(), 48);
        std::fs::write(&token_file, "short").unwrap();
        assert!(load_token(&token_file).is_err());
        std::fs::write(
            &token_file,
            format!("{} {}", "A".repeat(32), "B".repeat(32)),
        )
        .unwrap();
        assert!(load_token(&token_file).is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn response_header_copy_is_an_allowlist() {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert("content-type", "application/json".parse().unwrap());
        headers.insert("x-request-id", "request-1".parse().unwrap());
        headers.insert("set-cookie", "secret=value".parse().unwrap());
        let copied = copy_public_headers(&headers).unwrap();
        assert_eq!(copied.len(), 2);
        assert!(!copied.contains_key("set-cookie"));
    }

    #[test]
    fn bridge_script_exposes_only_narrow_fixed_commands() {
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("controllerRequest"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("controller_request"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("integrationStatus"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("integration_status"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("installOrRepairIntegration"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("install_or_repair_integration"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("integrationSelfTest"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("integration_self_test"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("fullRunCheck"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("full_run_check"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("fullRunCheckStatus"));
        assert!(BRIDGE_INITIALIZATION_SCRIPT.contains("full_run_check_status"));
        for (method, command) in [
            ("provisioningStart", "provisioning_start"),
            ("provisioningList", "provisioning_list"),
            ("provisioningGet", "provisioning_get"),
            (
                "provisioningApproveHostKey",
                "provisioning_approve_host_key",
            ),
            ("provisioningContinue", "provisioning_continue"),
            ("provisioningResume", "provisioning_resume"),
            ("provisioningRetry", "provisioning_retry"),
            ("provisioningRepair", "provisioning_repair"),
            ("provisioningRollback", "provisioning_rollback"),
            ("provisioningRemove", "provisioning_remove"),
            (
                "provisioningForgetSshPassword",
                "provisioning_forget_ssh_password",
            ),
        ] {
            assert!(BRIDGE_INITIALIZATION_SCRIPT.contains(method));
            assert!(BRIDGE_INITIALIZATION_SCRIPT.contains(command));
        }
        for forbidden in ["Authorization", "Bearer ", CONTROLLER_ORIGIN, "token_file"] {
            assert!(!BRIDGE_INITIALIZATION_SCRIPT.contains(forbidden));
        }
        for forbidden in [
            "pairing",
            "admin",
            "command",
            "executable",
            "marketplaceRoot",
        ] {
            assert!(!BRIDGE_INITIALIZATION_SCRIPT.contains(forbidden));
        }
    }

    #[test]
    fn missing_worker_kits_disable_only_provisioning_without_panicking() {
        let managed =
            ManagedProvisioning::from_result(Err(ProvisioningInitializationError::WorkerKit(
                cyc_provision::WorkerKitError::InvalidCatalogRoot,
            )));
        let error = match managed.manager() {
            Err(error) => error,
            Ok(_) => panic!("missing worker kits must not create a provisioning manager"),
        };
        let value = serde_json::to_value(error).unwrap();
        assert_eq!(value["code"], "worker_kit_catalog_unavailable");
        assert_eq!(value["retryable"], false);
    }

    #[test]
    fn navigation_accepts_only_exact_packaged_origins() {
        for raw in ["tauri://localhost/", "http://tauri.localhost/index.html"] {
            let url = tauri::Url::parse(raw).unwrap();
            assert!(trusted_navigation(&url), "{raw}");
        }
        for raw in [
            "tauri://attacker.invalid/",
            "tauri://user@localhost/",
            "http://tauri.localhost:4444/",
            "https://tauri.localhost.evil.invalid/",
            "file:///C:/tmp/index.html",
        ] {
            let url = tauri::Url::parse(raw).unwrap();
            assert!(!trusted_navigation(&url), "{raw}");
        }
    }

    #[test]
    fn native_deadline_precedes_renderer_deadline() {
        assert!(NATIVE_PROXY_TIMEOUT < MAX_RENDERER_TIMEOUT);
    }
}
