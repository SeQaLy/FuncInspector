<#
.SYNOPSIS
    FuncInspector (PowerShell / 単体実行版) - C ソースから関数定義を抽出する。

.DESCRIPTION
    出力フォーマット:  file.c,line,funcname,steps

    本体ロジックは同フォルダの FuncInspector.Functions.ps1 にあり、本スクリプトは
    それを読み込んで Invoke-FuncInspector を呼ぶ薄いラッパーです。
    (関数定義のみが欲しい / プロファイルに埋め込みたい場合は Functions 版を直接使用)

    機能:
      - WINAMS などのマクロが関数名の前に付いていても対応
      - コメント / 文字列リテラルを除去してから解析
      - プロトタイプ宣言 (末尾 ;) や関数呼び出しは除外
      - コンパイルスイッチ (#ifdef/#ifndef/#if/#elif) の一覧表示 (-ListSwitches)
      - スイッチを -D/-U で ON/OFF し条件コンパイルを評価 (未指定は OFF)
      - 各関数のステップ数 (本体の実行行数)
      - CUI / GUI(Windows Forms) 両対応

.PARAMETER Path           解析するフォルダ または ファイル (複数可)。省略時は GUI。
.PARAMETER Out            CSV 出力先。省略時は標準出力。
.PARAMETER Extensions     対象拡張子 (既定: .c,.h)。
.PARAMETER NoHeader       先頭のヘッダ行を付けない (既定は付ける)。
.PARAMETER Gui            GUI を起動。
.PARAMETER ListSwitches   コンパイルスイッチの一覧を出力。
.PARAMETER Define         ON にするスイッチ (-D)。NAME または NAME=VAL。複数可。
.PARAMETER Undef          OFF にするスイッチ (-U)。複数可。
.PARAMETER IgnoreSwitches 条件コンパイルを無視して全コードを対象にする。

.EXAMPLE
    .\FuncInspector.ps1 -Path .\src
.EXAMPLE
    .\FuncInspector.ps1 -Path .\src -ListSwitches
.EXAMPLE
    .\FuncInspector.ps1 -Path .\src -D CFG_A,VER=2 -Out result.csv
.EXAMPLE
    .\FuncInspector.ps1 -Gui
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$Out,
    [string[]]$Extensions = @('.c', '.h'),
    [switch]$NoHeader,
    [switch]$Gui,
    [switch]$ListSwitches,
    [Alias('D')][string[]]$Define,
    [Alias('U')][string[]]$Undef,
    [switch]$IgnoreSwitches
)

# 本体ロジックを読み込む
$core = Join-Path $PSScriptRoot 'FuncInspector.Functions.ps1'
if (-not (Test-Path -LiteralPath $core)) {
    Write-Error "コア実装が見つかりません: $core"
    exit 1
}
. $core

# パラメータをそのまま委譲
$fwd = @{}
foreach ($k in 'Path', 'Out', 'Extensions', 'NoHeader', 'Gui', 'ListSwitches', 'Define', 'Undef', 'IgnoreSwitches') {
    if ($PSBoundParameters.ContainsKey($k)) { $fwd[$k] = $PSBoundParameters[$k] }
}
Invoke-FuncInspector @fwd
