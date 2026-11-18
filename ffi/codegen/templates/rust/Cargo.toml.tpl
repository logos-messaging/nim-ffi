[package]
name = "{{LIB}}"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1", features = ["derive"] }{{SERDE_BYTES_DEP}}
ciborium = "0.2"
flume = { version = "0.11", default-features = false, features = ["async"] }
tokio = { version = "1", features = ["sync", "time"] }

[dev-dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros", "sync", "time"] }
