    pub fn reply(&self) -> Result<(), String> {
        let rc = unsafe { ffi::{{LIB}}_reverse_reply(self.ctx as *mut c_void, self.id, 0, std::ptr::null(), 0) };
        if rc == NIMFFI_RET_OK { Ok(()) } else { Err(format!("reply {{WIRE}}: {}", ret_name(rc))) }
    }
