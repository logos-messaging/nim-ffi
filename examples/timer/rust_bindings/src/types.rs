use serde::{Deserialize, Serialize};

pub const MAX_DELAY_MS: i64 = 5000;
pub const DEFAULT_BACKOFF_MS: u32 = 250;
pub const TIMER_VERSION: &str = "nim-timer v0.1.0";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum JobPriority {
    #[serde(rename = "low")]
    JpLow,
    #[serde(rename = "normal")]
    JpNormal,
    #[serde(rename = "high")]
    JpHigh,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimerConfig {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EchoRequest {
    pub message: String,
    #[serde(rename = "delayMs")]
    pub delay_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EchoResponse {
    pub echoed: String,
    #[serde(rename = "timerName")]
    pub timer_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComplexRequest {
    pub messages: Vec<EchoRequest>,
    pub tags: Vec<String>,
    pub note: Option<String>,
    pub retries: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComplexResponse {
    pub summary: String,
    #[serde(rename = "itemCount")]
    pub item_count: i64,
    #[serde(rename = "hasNote")]
    pub has_note: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EchoEvent {
    pub message: String,
    #[serde(rename = "echoCount")]
    pub echo_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobSpec {
    pub name: String,
    pub payload: Vec<String>,
    pub priority: JobPriority,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetryPolicy {
    #[serde(rename = "maxAttempts")]
    pub max_attempts: i64,
    #[serde(rename = "backoffMs")]
    pub backoff_ms: i64,
    #[serde(rename = "retryOn")]
    pub retry_on: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduleConfig {
    #[serde(rename = "startAtMs")]
    pub start_at_ms: i64,
    #[serde(rename = "intervalMs")]
    pub interval_ms: i64,
    pub jitter: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduleResult {
    #[serde(rename = "jobId")]
    pub job_id: String,
    #[serde(rename = "willRunCount")]
    pub will_run_count: i64,
    #[serde(rename = "firstRunAtMs")]
    pub first_run_at_ms: i64,
    #[serde(rename = "effectiveBackoffMs")]
    pub effective_backoff_ms: i64,
    pub priority: JobPriority,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MyTimerCreateCtorReq {
    pub config: TimerConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MyTimerEchoReq {
    pub req: EchoRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MyTimerVersionReq {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MyTimerComplexReq {
    pub req: ComplexRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MyTimerScheduleReq {
    pub job: JobSpec,
    pub retry: RetryPolicy,
    pub schedule: ScheduleConfig,
}
