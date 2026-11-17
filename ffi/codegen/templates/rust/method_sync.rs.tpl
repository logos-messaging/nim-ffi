{{DOC}}    pub fn {{NAME}}({{PARAMS}}) -> Result<{{RET}}, String> {
        let req = {{REQ}};
        let req_bytes = encode_cbor(&req)?;
        let raw_bytes = ffi_call_sync({{TIMEOUT}}, |cb, ud| unsafe {
            ffi::{{PROC}}({{CTX_ARG}}cb, ud, req_bytes.as_ptr(), req_bytes.len())
        })?;
        decode_cbor::<{{RET}}>(&raw_bytes)
    }
