/*
 * mwm_data.c — the clipboard's interface (wl_data_device_manager and its
 * wl_data_source and wl_data_device), as far as programs need it to
 * start: they may bind it and say what they would offer, and nothing is
 * carried anywhere yet. Nothing a program copied reaches another program
 * or the Mac, and nothing of the Mac's reaches a program.
 */
#include "mwm_internal.h"

void mwm_data_request(mwm_server *s, client *c, object *o, mwm_msg *m) {
    (void)s;
    switch ((obj_type)o->type) {
    case T_DATA_MANAGER:
        if (m->opcode == 0 || m->opcode == 1) { /* create_data_source; get_data_device, for a seat */
            uint32_t id = mwm_get_uint(m), seat = m->opcode == 1 ? mwm_get_uint(m) : 0;
            if (m->bad) return;
            if (m->opcode == 1 && !mwm_is(c, seat, T_SEAT)) {
                mwm_fail(c, m->object, E_INVALID_OBJECT, "not a seat");
                return;
            }
            (void)mwm_add(c, id, m->opcode == 0 ? T_DATA_SOURCE : T_DATA_DEVICE, NULL);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_data_device_manager has no such request");
        }
        break;
    case T_DATA_SOURCE:
        if (m->opcode == 1) mwm_del(c, m->object); /* destroy */
        else if (m->opcode == 0 || m->opcode == 2) mwm_skip_arguments(m); /* offer, set_actions: nobody is offered anything */
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_data_source has no such request");
        break;
    case T_DATA_DEVICE:
        if (m->opcode == 2) mwm_del(c, m->object); /* release */
        else if (m->opcode <= 1) mwm_skip_arguments(m); /* start_drag, set_selection: it goes nowhere */
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_data_device has no such request");
        break;
    default:
        break;
    }
}
