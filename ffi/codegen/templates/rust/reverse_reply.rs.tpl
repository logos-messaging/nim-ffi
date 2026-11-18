    /// A reply that does not encode still answers the call, with the reason
    /// as the error, so the library does not wait out its timeout.
    pub fn reply(&self, r: &{{REPLY_TYPE}}) -> Result<(), String> {
        let b = match encode_cbor(r) {
            Ok(b) => b,
            Err(e) => {
                let _ = self.fail(&e);
                return Err(format!("reply {{WIRE}}: {e}"));
            }
        };
        let rc = unsafe { ffi::{{LIB}}_reverse_reply(self.ctx as *mut c_void, self.id, 0, b.as_ptr(), b.len()) };
        if rc == NIMFFI_RET_OK { Ok(()) } else { Err(format!("reply {{WIRE}}: {}", ret_name(rc))) }
    }
