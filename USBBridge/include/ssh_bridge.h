#ifndef SSH_BRIDGE_H
#define SSH_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include "usb_device.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to an SSH session over RNDIS
typedef struct ssh_session ssh_session_t;

/// Result of a command execution
typedef struct {
    char    *stdout_buf;
    uint32_t stdout_len;
    char    *stderr_buf;
    uint32_t stderr_len;
    int      exit_code;
} ssh_exec_result_t;

/// Open an SSH session: RNDIS init → TCP connect → SSH handshake → auth.
/// vid/pid: USB device to open (e.g., RNDIS_VID/RNDIS_PID)
/// host_ip: our IP (e.g., "169.254.13.38")
/// remote_ip: console IP (e.g., "169.254.13.37")
/// Returns NULL on failure.
ssh_session_t *ssh_session_open(uint16_t vid, uint16_t pid,
                                 const char *host_ip, const char *remote_ip);

/// SSH on the exact observed RNDIS attachment; never fall back to another device.
ssh_session_t *ssh_session_open_bound(const hakchi_usb_identity_t *expected,
                                      const char *host_ip, const char *remote_ip);

/// Execute a command and capture stdout/stderr.
/// Caller must call ssh_result_free() on the result.
/// Returns 0 on success, negative on error.
int ssh_exec(ssh_session_t *s, const char *command, ssh_exec_result_t *result,
             int timeout_ms);

/// Bounded capture; -7 means an output cap was reached. Partial buffers are
/// returned on read/timeout/close errors too; always call ssh_result_free().
int ssh_exec_bounded(ssh_session_t *s, const char *command, ssh_exec_result_t *result,
                     int timeout_ms, uint32_t stdout_limit, uint32_t stderr_limit);

/// Execute a command with stdin data piped in (e.g., "cat > /path" or "tar -xvC /dir").
/// Returns 0 on success, negative on error.
int ssh_exec_stdin(ssh_session_t *s, const char *command,
                    const uint8_t *stdin_data, uint32_t stdin_len,
                    ssh_exec_result_t *result, int timeout_ms);

/// Nonzero if an upload/read did not reach verified completion.
int ssh_transfer_completion(uint32_t expected, uint32_t written, bool eof, bool timed_out);

/// Free memory in an exec result.
void ssh_result_free(ssh_exec_result_t *result);

/// Close the SSH session, TCP connection, and RNDIS device.
void ssh_session_close(ssh_session_t *s);

/// Check if RNDIS device is present on USB.
bool ssh_device_exists(void);

#ifdef __cplusplus
}
#endif

#endif /* SSH_BRIDGE_H */
