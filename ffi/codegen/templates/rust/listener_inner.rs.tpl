    fn add_listener_inner(
        &self,
        event_name: *const c_char,
        callback: ffi::FFICallback,
        raw: *mut c_void,
        owned: Box<dyn std::any::Any + Send>,
    ) -> ListenerHandle {
        let id = unsafe {
            ffi::{{LIB}}_add_event_listener(self.ptr, event_name, callback, raw)
        };
        if id != 0 {
            self.listeners.lock().unwrap().insert(id, owned);
        }
        ListenerHandle { id }
    }
