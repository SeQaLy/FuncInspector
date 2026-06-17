#ifndef PLATFORM_H
#define PLATFORM_H

/* フラグ: 既定OFF。-D PLATFORM_ARM で有効 */
#define PLATFORM_ARM

#ifdef PLATFORM_ARM
#define WORD_SIZE 32      /* 条件付きの値マクロ → 反映(カスケード) */
#else
#define WORD_SIZE 16
#endif

#endif /* PLATFORM_H */
