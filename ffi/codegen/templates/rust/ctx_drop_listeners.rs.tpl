impl Drop for {{CTX}} {
    fn drop(&mut self) {
        if self.ptr.is_null() {
            return;
        }
        let rc = unsafe { ffi::{{DTOR}}(self.ptr) };
        self.ptr = std::ptr::null_mut();
        if rc != NIMFFI_RET_OK {
            let boxes = self.listeners.get_mut().unwrap_or_else(|e| e.into_inner());
            boxes.drain().for_each(|(_, owned)| { Box::leak(owned); });
        }
    }
}
