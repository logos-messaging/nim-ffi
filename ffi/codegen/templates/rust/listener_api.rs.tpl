{{DOC}}    /// Register a typed listener for `{{WIRE}}`. The returned handle can be
    /// passed to `remove_event_listener` to unregister.
    pub fn add_{{EVENT_SNAKE}}_listener<F>(&self, handler: F) -> ListenerHandle
    where F: Fn(&{{PAYLOAD}}) + Send + Sync + 'static,
    {
        let owned: Box<{{EVENT}}Handler> = Box::new({{EVENT}}Handler { f: Box::new(handler) });
        let raw = &*owned as *const {{EVENT}}Handler as *mut c_void;
        self.add_listener_inner(b"{{WIRE}}\0".as_ptr() as *const c_char, {{EVENT_SNAKE}}_trampoline, raw, owned)
    }
