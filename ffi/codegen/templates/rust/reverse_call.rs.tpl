/// Answer token for one `{{WIRE}}` call (`Copy`). Reply once, from any thread;
/// a late or second reply is dropped, and one after destroy returns an error.
#[derive(Debug, Clone, Copy)]
pub struct {{CALL}} { ctx: usize, id: u64 }

impl {{CALL}} {
{{REPLY}}
    pub fn fail(&self, msg: &str) -> Result<(), String> {
        let rc = unsafe { ffi::{{LIB}}_reverse_reply(self.ctx as *mut c_void, self.id, 1, msg.as_ptr(), msg.len()) };
        if rc == NIMFFI_RET_OK { Ok(()) } else { Err(format!("fail {{WIRE}}: {}", ret_name(rc))) }
    }
}

struct {{BOX}} {
    f: Box<dyn {{BOUND}}>,
}

/// The library calls it once no invocation runs the box any more.
unsafe extern "C" fn {{SNAKE}}_impl_release(ud: *mut c_void) {
    if !ud.is_null() { drop(Box::from_raw(ud as *mut {{BOX}})); }
}

unsafe extern "C" fn {{SNAKE}}_impl_trampoline(
    ctx: *mut c_void, call_id: u64, args: *const u8, len: usize, ud: *mut c_void,
) {
    if ud.is_null() { return; }
    let b = &*(ud as *const {{BOX}});
    let call = {{CALL}} { ctx: ctx as usize, id: call_id };
    // A panic must not unwind into the library's worker thread: it would abort.
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
{{INVOKE}}
    }));
    if r.is_err() {
        let _ = call.fail("host impl panicked"); // dropped if it already replied
    }
}
