{{DOC}}    pub fn emit_{{NAME}}({{PARAMS}}) -> Result<(), String> {
        let payload = {{REQ}};
        let b = encode_cbor(&payload).map_err(|e| format!("emit {{WIRE}}: {e}"))?;
        let rc = unsafe { ffi::{{LIB}}_emit_{{WIRE}}(self.ptr, b.as_ptr(), b.len()) };
        if rc == NIMFFI_RET_OK { Ok(()) } else { Err(format!("emit {{WIRE}}: {}", ret_name(rc))) }
    }
