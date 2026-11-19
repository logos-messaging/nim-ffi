{{DOC}}    /// Returns true if the listener existed and was removed; false otherwise.
    pub fn remove_event_listener(&self, handle: ListenerHandle) -> bool {
        if handle.id == 0 { return false; }
        let rc = unsafe {
            ffi::{{LIB}}_remove_event_listener(self.ptr, handle.id)
        };
        let removed = self.listeners.lock().unwrap().remove(&handle.id);
        if let Some(owned) = removed {
            if DISPATCH_DEPTH.with(|d| d.get()) > 0 {
                DEFERRED_LISTENERS.with(|l| l.borrow_mut().push(owned));
            }
        }
        rc == 0
    }
