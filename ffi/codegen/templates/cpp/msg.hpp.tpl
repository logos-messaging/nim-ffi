// ============================================================
// Messages from the library
// ============================================================
// What `<lib>_poll` hands out (mirrors ffi/ffi_msg.nim and the C header).
// Guarded so a translation unit that pulls in a second nim-ffi header, or the
// C header, keeps a single definition.
#ifndef NIMFFI_MSG_EVENT
extern "C" {
{{MSG_DECL}}
} // extern "C"
#endif // NIMFFI_MSG_EVENT
