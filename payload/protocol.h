/* ps5-mcp wire protocol, version 1. Existing layouts are frozen; incompatible changes bump PMCP_VERSION.
 * Optional new messages must be gated by a capability flag.
 *
 * Every message is an 8-byte little-endian header followed by `length` bytes:
 *   magic "PMCP" | u8 version | u8 type | u16 length
 * Python mirror: src/ps5mcp/protocol.py. Spec: docs/protocol.md.
 */
#ifndef PS5MCP_PROTOCOL_H
#define PS5MCP_PROTOCOL_H

#include <stdint.h>

#define PMCP_MAGIC   "PMCP"
#define PMCP_VERSION 1
#define PMCP_PORT    9305
#define PMCP_HEADER_BYTES 8
#define PMCP_MAX_PAYLOAD  256

enum pmcp_type {
    PMCP_HELLO = 1,     /* server -> client on connect: struct pmcp_hello */
    PMCP_STATE = 2,     /* client -> server: struct pmcp_state; server -> client in reply to GET_STATE */
    PMCP_PING = 3,      /* client -> server: u32 token; server -> client: struct pmcp_pong */
    PMCP_ACK = 4,       /* server -> client: struct pmcp_ack */
    PMCP_ERROR = 5,     /* server -> client: u32 code + UTF-8 message */
    PMCP_SHUTDOWN = 6,  /* client -> server: no payload; ACK, then the payload removes the pad and exits */
    PMCP_GET_STATE = 7, /* client -> server: no payload */
    PMCP_COMMAND = 8,   /* client -> server: struct pmcp_command; answered with ACK */
    PMCP_GET_USER = 9,  /* no request payload; reply: struct pmcp_user (requires PMCP_FLAG_USER_NAME) */
};

#define PMCP_TOUCH_POINTS 2

#pragma pack(push, 1)
struct pmcp_touch {
    uint8_t active;
    uint8_t id;
    uint16_t x;     /* 0..1919 */
    uint16_t y;     /* 0..1079 */
};

struct pmcp_state {             /* 28 bytes: the complete pad state, never a delta */
    uint32_t seq;
    uint32_t buttons;           /* bits as in docs/vpad-abi.md */
    uint8_t lx, ly, rx, ry;     /* 0x80 = centre */
    uint8_t l2, r2;             /* analogue triggers */
    uint8_t reserved[2];
    struct pmcp_touch touch[PMCP_TOUCH_POINTS];
};

struct pmcp_hello {             /* 20 bytes */
    uint16_t protocol;
    uint16_t payload_version;   /* major << 8 | minor */
    int32_t pad_handle;         /* -1 when no pad could be added */
    int32_t user_id;
    uint32_t flags;             /* PMCP_FLAG_* */
    uint32_t add_errno;
};

struct pmcp_user {              /* 72 bytes */
    int32_t status;             /* 0 ok; >0 errno; <0 SCE error */
    int32_t user_id;            /* the user assigned to this pad */
    char name[64];              /* NUL-terminated UTF-8 local profile name; empty on failure */
};

struct pmcp_pong {              /* 40 bytes */
    uint32_t token;
    uint16_t protocol;
    uint16_t payload_version;
    uint64_t uptime_ms;
    int32_t pad_handle;
    uint32_t flags;
    uint64_t reports_sent;
    uint32_t report_failures;
    uint32_t neutral_events;    /* times the watchdog or a disconnect forced neutral */
};

struct pmcp_ack {               /* 8 bytes */
    uint32_t seq;               /* STATE seq, or COMMAND seq */
    int32_t status;             /* 0 ok; >0 errno; <0 SCE error code */
};

struct pmcp_command {           /* 4 + 4 + 32 bytes */
    uint32_t seq;
    uint32_t op;                /* PMCP_CMD_* */
    char arg[32];               /* NUL-terminated, e.g. a title id */
};
#pragma pack(pop)

#define PMCP_FLAG_PAD_READY       0x1
#define PMCP_FLAG_TOUCH_UNMAPPED  0x2   /* touch coordinates are accepted but not delivered */
#define PMCP_FLAG_USER_NAME       0x4   /* GET_USER supported (padd 1.2+) */
#define PMCP_FLAG_UNINSTALL       0x8   /* COMMAND op UNINSTALL supported (padd 1.3+) */

enum pmcp_command_op {
    PMCP_CMD_HOME = 1,          /* return to the home screen; arg = method ("" = default) */
    PMCP_CMD_LAUNCH = 2,        /* launch arg (title id) for the foreground user */
    PMCP_CMD_CLOSE = 3,         /* close the running game or app */
    PMCP_CMD_UNINSTALL = 4,     /* uninstall arg (title id, 4 letters + 5 digits); the removal finishes later */
};

enum pmcp_error {
    PMCP_ERR_BAD_MAGIC = 1,
    PMCP_ERR_BAD_VERSION = 2,
    PMCP_ERR_BAD_LENGTH = 3,
    PMCP_ERR_UNKNOWN_TYPE = 4,
    PMCP_ERR_BUSY = 5,
    PMCP_ERR_NO_PAD = 6,
};

_Static_assert(sizeof(struct pmcp_state) == 28, "state is 28 bytes");
_Static_assert(sizeof(struct pmcp_hello) == 20, "hello is 20 bytes");
_Static_assert(sizeof(struct pmcp_user) == 72, "user is 72 bytes");
_Static_assert(sizeof(struct pmcp_pong) == 40, "pong is 40 bytes");
_Static_assert(sizeof(struct pmcp_ack) == 8, "ack is 8 bytes");
_Static_assert(sizeof(struct pmcp_command) == 40, "command is 40 bytes");

#endif
