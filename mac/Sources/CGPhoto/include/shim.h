#ifndef TETHR_SHIM_H
#define TETHR_SHIM_H

#include <gphoto2/gphoto2.h>

// CameraFilePath は char name[128] / char folder[1024] の固定長配列を持つ。
// Swift はこれを巨大なタプルとして取り込むため、C 側で char* に落とす。
const char *tethr_filepath_name(const CameraFilePath *p);
const char *tethr_filepath_folder(const CameraFilePath *p);

// gp_widget_get_value / set_value が void* に書き込む中身はウィジェットの型で変わる。
//   TEXT / RADIO / MENU  -> const char *
//   RANGE                -> float
//   TOGGLE / DATE        -> int
// 型を取り違えると float のビット列をポインタとして読むことになり即クラッシュする。
// 型の判定は C 側に閉じ込め、Swift へは常に文字列で渡す。
int tethr_widget_value_string(CameraWidget *w, char *buf, int buflen);
int tethr_widget_set_from_string(CameraWidget *w, const char *val);

// 書き込み可否。1=読み取り専用, 0=書き込み可, 負値=取得失敗。
// 露出モードによって可否が変わる項目がある（A なら shutterspeed は読み取り専用）。
int tethr_widget_readonly(CameraWidget *w);

// 文字列ウィジェット専用（選択肢の読み出しなど型が確定している場面のみ）
int tethr_widget_get_string(CameraWidget *w, const char **out);
int tethr_widget_set_string(CameraWidget *w, const char *val);

// 選択肢の列挙。count 個の C 文字列を順に取り出す。
int tethr_widget_choice_count(CameraWidget *w);
const char *tethr_widget_choice_at(CameraWidget *w, int index);

// ウィジェット種別（GP_WIDGET_RADIO などの生の値）
int tethr_widget_type(CameraWidget *w);

// gp_camera_wait_for_event の data は型がイベント依存。
// GP_EVENT_UNKNOWN のときは malloc された C 文字列が来る。
const char *tethr_event_string(void *data);

#endif
