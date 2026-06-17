#ifndef CONFIG_H
#define CONFIG_H

/* 値マクロ(定数): include解決で「反映」される */
#define BUILD_LEVEL 2
#define MAX_UNITS   4

/* フラグ: 値なし → 既定OFF。-D で選択した時だけ有効 */
#define USE_FEATURE_X

#include "sub/platform.h"

#endif /* CONFIG_H */
