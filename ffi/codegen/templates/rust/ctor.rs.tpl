{{DOC}}    pub fn create({{PARAMS}}) -> Result<Self, String> {
        let req = {{REQ}};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync(Some(timeout), |cb, ud| unsafe {
            let _ = ffi::{{PROC}}(req_bytes.as_ptr(), req_bytes.len(), cb, ud);
            0
        })?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
{{SELF_INIT}}
    }

{{DOC}}    pub async fn new_async({{PARAMS}}) -> Result<Self, String> {
        let req = {{REQ}};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_async(Some(timeout), move |cb, ud| unsafe {
            let _ = ffi::{{PROC}}(req_bytes.as_ptr(), req_bytes.len(), cb, ud);
            0
        }).await?;
        let addr_str: String = decode_cbor(&raw_bytes)?;
        let addr: usize = addr_str.parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
{{SELF_INIT}}
    }
