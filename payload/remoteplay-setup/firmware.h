/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RP_FIRMWARE_H
#define RP_FIRMWARE_H
#include <stdint.h>
/* SDK v0.43 crt/kernel.c selects firmware offsets with
 * switch(kernel_get_fw_version() & 0xffff0000), including case 0x13600000.
 * The low 16 build bits remain visible in diagnostics but are not a version family.
 * https://github.com/ps5-payload-dev/sdk/blob/v0.43/crt/kernel.c */
static inline int rp_supported_firmware(uint32_t raw) {
    return (raw & 0xffff0000u)==0x13600000u;
}
#endif
