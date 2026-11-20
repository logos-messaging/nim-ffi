{{DOC}}    pub async fn {{NAME}}_async({{PARAMS}}) -> Result<{{RET}}, String> {
        let req = {{REQ}};
        let req_bytes = encode_cbor(&req)?;
{{PTR_COPY}}        let raw_bytes = ffi_call_async({{TIMEOUT}}, {{PROGRESS}}, move |cb, ud| unsafe {
            ffi::{{PROC}}({{CTX_ARG}}cb, ud, req_bytes.as_ptr(), req_bytes.len())
        }).await?;
        decode_cbor::<{{RET}}>(&raw_bytes)
    }
