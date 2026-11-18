{{DOC}}    pub fn set_{{SNAKE}}_impl<F>(&self, f: F) -> Result<(), String>
    where F: {{BOUND}} + 'static,
    {
        let raw = Box::into_raw(Box::new({{BOX}} { f: Box::new(f) })) as *mut c_void;
        // The library owns the box now: it releases it once no invocation runs it.
        let rc = unsafe {
            ffi::{{LIB}}_set_{{WIRE}}_impl(self.ptr, Some({{SNAKE}}_impl_trampoline), raw, Some({{SNAKE}}_impl_release))
        };
        if rc != NIMFFI_RET_OK {
            drop(unsafe { Box::from_raw(raw as *mut {{BOX}}) }); // refused: still ours
            return Err(format!("set {{WIRE}} impl: {}", ret_name(rc)));
        }
        Ok(())
    }

    pub fn clear_{{SNAKE}}_impl(&self) -> Result<(), String> {
        let rc = unsafe { ffi::{{LIB}}_set_{{WIRE}}_impl(self.ptr, None, std::ptr::null_mut(), None) };
        if rc == NIMFFI_RET_OK { Ok(()) } else { Err(format!("clear {{WIRE}} impl: {}", ret_name(rc))) }
    }
