use serde::{Deserialize, Serialize};

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
