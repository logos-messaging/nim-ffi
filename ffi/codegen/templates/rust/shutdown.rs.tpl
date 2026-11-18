{{DOC}}    /// This wrapper reports that as true.
    pub fn shutdown() -> bool {
        unsafe { ffi::{{LIB}}_shutdown() == 0 }
    }
