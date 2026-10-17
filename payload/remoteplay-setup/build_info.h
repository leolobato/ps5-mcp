/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RP_BUILD_INFO_H
#define RP_BUILD_INFO_H
/* The production builder supplies a deterministic source/template fingerprint.
 * Host fixtures are deliberately labeled and never represent a deployable ELF. */
#ifndef RP_BUILD_ID
#define RP_BUILD_ID "unversioned-host-fixture"
#endif
#endif
