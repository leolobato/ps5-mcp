/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RP_FILES_H
#define RP_FILES_H
#include <stddef.h>
int rp_file_read(const char *,unsigned char *,size_t *);
int rp_file_write(const char *,const unsigned char *,size_t);
int rp_file_remove(const char *);
int rp_mkdir(const char *, unsigned);
#endif
