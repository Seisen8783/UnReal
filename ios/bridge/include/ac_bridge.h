#ifndef AC_BRIDGE_H
#define AC_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ac_session ac_session;

typedef enum {
    AC_OK = 0,
    AC_ERR_UNREACHABLE = 1,
    AC_ERR_PAIRING = 2,
    AC_ERR_DEV_MODE = 3,
    AC_ERR_DDI = 4,
    AC_ERR_TUNNEL = 5,
    AC_ERR_DVT = 6,
    AC_ERR_TIMEOUT = 7,
    AC_ERR_INVALID_ARG = 8,
} ac_status;

typedef struct {
    char product_version[16];
    char device_name[64];
    bool developer_mode;
    bool ddi_mounted;
} ac_device_info;

ac_status ac_session_open(const char *host_ip, uint16_t port,
                          const uint8_t *pairing_plist, size_t pairing_len,
                          uint32_t timeout_ms, ac_session **out);

ac_status ac_session_open_usb(const char *udid, uint32_t timeout_ms, ac_session **out);

ac_status ac_device_info_get(ac_session *s, ac_device_info *out);

ac_status ac_ddi_mount(ac_session *s, const char *restore_dir, uint32_t timeout_ms);

ac_status ac_location_open(ac_session *s);

ac_status ac_location_set(ac_session *s, double lat, double lon);

ac_status ac_location_clear(ac_session *s);

ac_status ac_session_ping(ac_session *s);

void ac_session_close(ac_session *s);

const char *ac_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
