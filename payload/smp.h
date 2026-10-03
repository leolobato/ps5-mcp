/* ShadowMountPlus titles: uninstall them with their source, so SMP's next scan does not install them again. */
#ifndef PS5MCP_SMP_H
#define PS5MCP_SMP_H

#define SMP_PORT 10101

/* True when SMP manages the title (it has <app_dir>/<id>/mount.lnk). */
int smp_managed(const char *app_dir, const char *title_id);

/* Deletes the title's source through SMP, waits for the job, then uninstalls. Returns 0, an errno, or the
 * system_uninstall result: ECONNREFUSED (SMP not running), EBUSY (SMP busy or a game is running; retry),
 * EINPROGRESS (the source is still being deleted; ask again) or EIO (SMP refused the delete). */
int smp_uninstall(int port, const char *title_id);

#endif
