    /// Remove a previously-registered listener by handle. Returns true
    /// if the listener existed and was removed; false otherwise.
    pub fn remove_event_listener(&self, handle: ListenerHandle) -> bool {
        if handle.id == 0 { return false; }
        let rc = unsafe {
            ffi::{{LIB}}_remove_event_listener(self.ptr, handle.id)
        };
        self.listeners.lock().unwrap().remove(&handle.id);
        rc == 0
    }
