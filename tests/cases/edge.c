/* edge.c - 既知の限界を「現在の挙動」として固定するテスト
 * 期待 (既定):
 *   - DEFINE_HANDLER が関数として検出される (誤検出: 本当の名前は h)
 *   - trail  は検出されない () と { の間に属性があるため (見逃し)
 *   - getfp  は検出されない 関数ポインタを返す関数 (見逃し)
 *   - knr    は検出されない K&R 旧式定義 (見逃し)
 * => 既定では DEFINE_HANDLER のみ検出
 */
DEFINE_HANDLER(h)
{
    go();
}

int trail(void) __attribute__((noreturn))
{
    return 0;
}

void (*getfp(void))(int)
{
    return 0;
}

int knr(a, b)
int a;
int b;
{
    return a + b;
}
