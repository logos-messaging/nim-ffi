    // `{.ffiStatic.}` replies arrive on the library's static context, which has
    // one dispatch thread per process, started by the first static call.
    static Result<std::shared_ptr<NimFfiDispatcher>> staticDispatcher_() {
        return staticDispatcherHolder_().acquire(&{{LIB}}_static_ctx, &{{LIB}}_poll, &{{LIB}}_last_error);
    }
    // Never destroyed: no static destructor may race the dispatch thread at exit.
    static NimFfiStaticDispatcher& staticDispatcherHolder_() {
        static NimFfiStaticDispatcher* holder = new NimFfiStaticDispatcher();
        return *holder;
    }
