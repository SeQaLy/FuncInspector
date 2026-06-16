/* switches.c - コンパイルスイッチ ON/OFF と一覧のテスト
 * always は常に検出。他は -D 次第。
 *   既定(全OFF): notA, leg, always
 *   -D CFG_A   : a,    leg, always
 *   -D VER=2   : notA, v2,  always
 *   -D CFG_B   : notA, b,   always
 * スイッチ一覧: CFG_A x2, CFG_B x1, VER x1
 */
#ifdef CFG_A
void a(void){ fa(); }
#endif

#ifndef CFG_A
void notA(void){ fn(); }
#endif

#if VER >= 2
void v2(void){ fv(); }
#elif defined(CFG_B)
void b(void){ fb(); }
#else
void leg(void){ fl(); }
#endif

void always(void){ fk(); }
