#ifndef FEATURES_H
#define FEATURES_H

#include "config.h"

/* USE_FEATURE_X(フラグ)の選択に応じて派生する値マクロ */
#ifdef USE_FEATURE_X
#define FEATURE_X_LEVEL 3
#else
#define FEATURE_X_LEVEL 0
#endif

/* 値マクロ BUILD_LEVEL から派生 */
#if BUILD_LEVEL >= 2
#define DEBUG_BUILD 1
#else
#define DEBUG_BUILD 0
#endif

#endif /* FEATURES_H */
