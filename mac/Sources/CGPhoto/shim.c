#include "include/shim.h"
#include <stdio.h>
#include <stdlib.h>

const char *tethr_filepath_name(const CameraFilePath *p)   { return p ? p->name   : 0; }
const char *tethr_filepath_folder(const CameraFilePath *p) { return p ? p->folder : 0; }

int tethr_widget_get_string(CameraWidget *w, const char **out) {
    return gp_widget_get_value(w, out);
}

int tethr_widget_set_string(CameraWidget *w, const char *val) {
    return gp_widget_set_value(w, val);
}

int tethr_widget_choice_count(CameraWidget *w) {
    return gp_widget_count_choices(w);
}

const char *tethr_widget_choice_at(CameraWidget *w, int index) {
    const char *c = 0;
    if (gp_widget_get_choice(w, index, &c) < GP_OK) return 0;
    return c;
}

int tethr_widget_type(CameraWidget *w) {
    CameraWidgetType t;
    if (gp_widget_get_type(w, &t) < GP_OK) return -1;
    return (int)t;
}

const char *tethr_event_string(void *data) { return (const char *)data; }

int tethr_widget_value_string(CameraWidget *w, char *buf, int buflen) {
    CameraWidgetType t;
    int r = gp_widget_get_type(w, &t);
    if (r < GP_OK) return r;

    switch (t) {
    case GP_WIDGET_TEXT:
    case GP_WIDGET_RADIO:
    case GP_WIDGET_MENU: {
        const char *s = 0;
        r = gp_widget_get_value(w, &s);
        if (r < GP_OK) return r;
        if (!s) return GP_ERROR;
        snprintf(buf, buflen, "%s", s);
        return GP_OK;
    }
    case GP_WIDGET_RANGE: {
        float f = 0.0f;
        r = gp_widget_get_value(w, &f);
        if (r < GP_OK) return r;
        snprintf(buf, buflen, "%g", (double)f);
        return GP_OK;
    }
    case GP_WIDGET_TOGGLE:
    case GP_WIDGET_DATE: {
        int i = 0;
        r = gp_widget_get_value(w, &i);
        if (r < GP_OK) return r;
        snprintf(buf, buflen, "%d", i);
        return GP_OK;
    }
    default:
        return GP_ERROR_NOT_SUPPORTED;
    }
}

int tethr_widget_set_from_string(CameraWidget *w, const char *val) {
    CameraWidgetType t;
    int r = gp_widget_get_type(w, &t);
    if (r < GP_OK) return r;

    switch (t) {
    case GP_WIDGET_TEXT:
    case GP_WIDGET_RADIO:
    case GP_WIDGET_MENU:
        return gp_widget_set_value(w, val);
    case GP_WIDGET_RANGE: {
        float f = (float)atof(val);
        return gp_widget_set_value(w, &f);
    }
    case GP_WIDGET_TOGGLE:
    case GP_WIDGET_DATE: {
        int i = atoi(val);
        return gp_widget_set_value(w, &i);
    }
    default:
        return GP_ERROR_NOT_SUPPORTED;
    }
}

int tethr_widget_readonly(CameraWidget *w) {
    int ro = 0;
    int r = gp_widget_get_readonly(w, &ro);
    if (r < GP_OK) return r;
    return ro;
}
