/*
 * mwm_ctl.h — the window manager's channel to MonadHost: one stream, lines
 * of text each way. MonadHost dials it (a vsock port in the VM); nothing
 * in the VM is meant to.
 *
 * To MonadHost, whenever a window comes, goes, moves or is renamed:
 *
 *   monad-wm 1 <sheet width> <sheet height>      once, first
 *   windows <generation> <count>
 *   window <id> <x> <y> <width> <height> <scale> <inner x> <inner y>
 *          <inner width> <inner height> <parent> <offset x> <offset y>
 *          <bar> <app id> <title>                            count times
 *   gl <window> <stream> <surface>                    after its window's line,
 *                                                     for a window whose picture
 *                                                     the Mac's GPU draws
 *                                                     (mwm_gl_wire.h): no pixels
 *                                                     of it are sent
 *   end
 *   cursor <shape>                    how the pointer is to look where it
 *                                     is, when that changes: 0 hidden, 1 the
 *                                     arrow (which goes without saying), or
 *                                     another of wp_cursor_shape_device_v1's
 *                                     shapes, up to MWM_CURSOR_LAST
 *   pixels <window> <x> <y> <width> <height> <bytes>
 *                                     then that many bytes: what the window
 *                                     shows there. width × height × 4 of
 *                                     them are the pixels as they are, row
 *                                     by row from the top, a pixel as four
 *                                     bytes (blue, green, red, how much of
 *                                     the pixel is there; the colours with
 *                                     that share taken already); fewer are
 *                                     those pixels packed (mwm_pack.h).
 *                                     (x, y) is from the window's top left,
 *                                     in its pixels. Only of a window in the
 *                                     list last told, and inside it; all of
 *                                     a window first, then what its program
 *                                     drew again, MWM_CTL_PIXELS at most in
 *                                     one piece
 *   move <window>                     the program asks for its window to be
 *                                     moved: the user drags the bar it drew
 *   zoom <window> <0|1>               ... to be as large as it gets, or back
 *   minimize <window>                 ... to be put away
 *
 * `bar` is "-" when the window's frame is all the Mac's, and otherwise the
 * colour (rrggbb) the program's own title bar has at its top, for the
 * Mac's title bar to continue. The wishes (move, zoom, minimize) come only
 * from the window the pointer is over or the one in front, the last one
 * when MonadHost was slow to read; MonadHost does them or not.
 *
 * A window's place is in the sheet's pixels; `scale` is how many of them
 * the program draws to one of its units (the Mac's window is that many
 * times smaller in points); `inner` is the part that is the window proper,
 * when the program draws a shadow around it. A popup (a menu, a tooltip)
 * names the window it is on as `parent`, and where its inner part stands
 * from that window's inner top left, in that window's pixels; a window of
 * its own says 0 0 0. Text is the program's: every byte but plain
 * printable ASCII is written %XX, and an empty text is "-", so a line is
 * always as many words as its kind has. MonadHost reads all of it as
 * hostile.
 *
 * From MonadHost, what the Mac's pointer and keyboard do and what happens
 * to the Mac's windows (windows are named by id; 0 is no window):
 *
 *   scale <n>                         the Mac's screen: 1, or 2 on a Retina screen
 *   screen <width> <height>           and its size in units, which programs are
 *                                     told as the screen they are on
 *   pointer <window> <x> <y>          in the window, in 1/256 of a unit
 *   button <code> <0|1>
 *   scroll <dx> <dy>                  in 1/256 of a unit
 *   focus <window>
 *   key <code> <0|1>
 *   mods <held down> <locked>
 *   keys <count>                      then count times:
 *   k <code> <caps 0|1> <plain> <shift> <third> <shift third>
 *   size <window> <width> <height>    in units
 *   close <window>
 *   dismiss <window>                  the user clicked away from its popups
 *   paste <bytes>                     then that many bytes, as they are: the
 *                                     Mac's text (UTF-8), which a paste in the
 *                                     VM gives from now on; 0: nothing of the
 *                                     Mac's does. The user pressed ⌘V.
 *   copy                              the user pressed ⌘C (or ⌘X): what the
 *                                     program in front copies next is for the Mac
 *
 * To MonadHost, after `copy`, at most once for each:
 *
 *   copied <bytes>                    then that many bytes (UTF-8, at most
 *                                     MWM_MAX_COPY): the text the program
 *                                     copied; 0 when it copied something the
 *                                     Mac cannot have (no text, or too much)
 *
 * A line it does not know is skipped (a newer Monad may say more); one
 * longer than MWM_CTL_LINE ends the connection, as does a paste of more
 * than MWM_MAX_CLIPBOARD bytes.
 */
#ifndef MWM_CTL_H
#define MWM_CTL_H

#include "mwm_server.h"

enum {
    MWM_CTL_VERSION = 1,
    /* The longest line either way, its newline included. */
    MWM_CTL_LINE = 1024,
    /* Bytes of lines waiting for a MonadHost that does not read: beyond, it is dropped. */
    MWM_CTL_OUT = 256 << 10,
    /* The most pixels of a window sent in one piece (32 MiB of them): a
     * larger window's come in several, from its top down. */
    MWM_CTL_PIXELS = 8 << 20,
};

typedef struct mwm_ctl mwm_ctl;

mwm_ctl *mwm_ctl_new(mwm_server *server);
void mwm_ctl_free(mwm_ctl *c);

/* MonadHost connected: its stream, taken and made non-blocking. The one
 * before, if any, is closed: there is one MonadHost. */
void mwm_ctl_attach(mwm_ctl *c, int fd);
/* The stream, for poll; -1 when nobody is connected. */
int mwm_ctl_fd(const mwm_ctl *c);
bool mwm_ctl_wants_write(const mwm_ctl *c);

/* The stream has something to read, or room to write. `time_ms` stamps
 * what the pointer and the keys did. */
void mwm_ctl_service(mwm_ctl *c, bool readable, bool writable, uint32_t time_ms);

/* The windows may have changed: MonadHost is told when they have. */
void mwm_ctl_update(mwm_ctl *c);

#endif
