struct {{EVENT}}Handler {
    f: Box<dyn Fn(&{{PAYLOAD}}) + Send + Sync>,
}

unsafe extern "C" fn {{EVENT_SNAKE}}_trampoline(
    ret: c_int, msg: *const c_char, len: usize, ud: *mut c_void,
) {
    if ud.is_null() || ret != 0 || msg.is_null() || len == 0 {
        return;
    }
    let h = &*(ud as *const {{EVENT}}Handler);
    let bytes = slice::from_raw_parts(msg as *const u8, len);
    #[derive(serde::Deserialize)]
    struct Envelope { payload: {{PAYLOAD}} }
    if let Ok(env) = ciborium::de::from_reader::<Envelope, _>(bytes) {
        (h.f)(&env.payload);
    }
}
