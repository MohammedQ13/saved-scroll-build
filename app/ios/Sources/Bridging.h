// C API of the Rust engine (app/engine/src/ffi.rs, pairing.rs).
#include <stdint.h>

char *ss_engine_start(const char *pairing_path, uint16_t port, const char *token);
char *ss_engine_status(void);
void ss_engine_stop_dive(void);
void ss_engine_app_active(void);   // app came to the front: reopen the 3-minute pairing window
void ss_engine_app_background(void);
void ss_string_free(char *s);

// iOS 27 on-device pairing (the phone pairs with this app; no computer)
char *ss_pair_begin(const char *out_path);
char *ss_pair_status(void);

// Self-refresh: re-sign and reinstall this app with the user's free Apple ID (refresh.rs)
char *ss_refresh_start(const char *json);
void ss_refresh_submit_code(const char *code);
char *ss_refresh_status(void);
