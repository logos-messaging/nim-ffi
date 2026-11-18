impl Drop for {{CTX}} {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { ffi::{{DTOR}}(self.ptr); }
            self.ptr = std::ptr::null_mut();
        }
    }
}
