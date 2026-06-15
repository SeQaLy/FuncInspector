<#
.SYNOPSIS
    FuncInspector (PowerShell) - C ソースから関数定義の関数名を抽出する。

.DESCRIPTION
    出力フォーマット:  file.c,line,funcname

    WINAMS などの呼び出し規約マクロが関数名の前に付いていても対応
    (関数名は「( の直前の識別子」として検出)。
    コメント / 文字列リテラルを除去してから解析するため誤検出が少ない。
    プロトタイプ宣言 (末尾 ;) や関数呼び出しは除外。

.PARAMETER Path
    解析するフォルダ または ファイル。複数指定可。

.PARAMETER Out
    CSV 出力先。省略時は標準出力。

.PARAMETER Extensions
    対象拡張子 (既定: .c,.h)。

.PARAMETER Header
    ヘッダ行 file,line,function を付ける。

.PARAMETER Gui
    GUI を起動する。Path 省略時も GUI が起動する。

.EXAMPLE
    .\FuncInspector.ps1 -Path .\src
    .\FuncInspector.ps1 -Path .\src -Out result.csv -Header
    .\FuncInspector.ps1 -Gui
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$Out,
    [string[]]$Extensions = @('.c', '.h'),
    [switch]$Header,
    [switch]$Gui
)

# 関数名になり得ない（除外）キーワード
$script:Keywords = @{}
foreach ($k in @(
        'if', 'for', 'while', 'switch', 'return', 'sizeof', 'do', 'else',
        'goto', 'case', 'default', 'typedef', 'struct', 'union', 'enum',
        'static', 'extern', 'const', 'volatile', 'register', 'auto',
        'signed', 'unsigned', 'void', 'char', 'short', 'int', 'long',
        'float', 'double', '_Bool', 'inline', '__inline', '__attribute__',
        '_Static_assert', '_Generic', '_Alignas', 'defined', 'asm', '__asm'
    )) { $script:Keywords[$k] = $true }

function Remove-CommentsStrings {
    param([string]$Src)
    $n = $Src.Length
    $sb = New-Object System.Text.StringBuilder $n
    $i = 0
    while ($i -lt $n) {
        $c = $Src[$i]
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Src[$i + 1] -eq '/') {
            while ($i -lt $n -and $Src[$i] -ne "`n") { [void]$sb.Append(' '); $i++ }
        }
        elseif ($c -eq '/' -and ($i + 1) -lt $n -and $Src[$i + 1] -eq '*') {
            [void]$sb.Append('  '); $i += 2
            while ($i -lt $n -and -not ($Src[$i] -eq '*' -and ($i + 1) -lt $n -and $Src[$i + 1] -eq '/')) {
                if ($Src[$i] -eq "`n") { [void]$sb.Append("`n") } else { [void]$sb.Append(' ') }
                $i++
            }
            if ($i -lt $n) { [void]$sb.Append('  '); $i += 2 }
        }
        elseif ($c -eq '"' -or $c -eq "'") {
            $q = $c; [void]$sb.Append(' '); $i++
            while ($i -lt $n -and $Src[$i] -ne $q) {
                if ($Src[$i] -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append('  '); $i += 2 }
                elseif ($Src[$i] -eq "`n") { [void]$sb.Append("`n"); $i++ }
                else { [void]$sb.Append(' '); $i++ }
            }
            if ($i -lt $n) { [void]$sb.Append(' '); $i++ }
        }
        else { [void]$sb.Append($c); $i++ }
    }
    return $sb.ToString()
}

function Test-IdentStart([char]$c) { return ([char]::IsLetter($c) -or $c -eq '_') }
function Test-IdentChar([char]$c) { return ([char]::IsLetterOrDigit($c) -or $c -eq '_') }

function Test-MemberAccess {
    param([string]$s, [int]$idx)
    $j = $idx - 1
    while ($j -ge 0 -and ($s[$j] -eq ' ' -or $s[$j] -eq "`t" -or $s[$j] -eq "`r" -or $s[$j] -eq "`n")) { $j-- }
    if ($j -lt 0) { return $false }
    if ($s[$j] -eq '.') { return $true }
    if ($s[$j] -eq '>' -and ($j - 1) -ge 0 -and $s[$j - 1] -eq '-') { return $true }
    return $false
}

function Find-CFunctions {
    param([string]$FilePath)
    try {
        $src = [System.IO.File]::ReadAllText($FilePath)
    }
    catch {
        Write-Warning "読み込み失敗: $FilePath"
        return @()
    }
    $clean = Remove-CommentsStrings $src
    $n = $clean.Length
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $n) {
        $c = $clean[$i]
        if (Test-IdentStart $c) {
            $j = $i
            while ($j -lt $n -and (Test-IdentChar $clean[$j])) { $j++ }
            $name = $clean.Substring($i, $j - $i)

            $k = $j
            while ($k -lt $n -and ($clean[$k] -eq ' ' -or $clean[$k] -eq "`t" -or $clean[$k] -eq "`r" -or $clean[$k] -eq "`n")) { $k++ }

            if ($k -lt $n -and $clean[$k] -eq '(' -and -not $script:Keywords.ContainsKey($name)) {
                $depth = 0; $p = $k
                while ($p -lt $n) {
                    if ($clean[$p] -eq '(') { $depth++ }
                    elseif ($clean[$p] -eq ')') { $depth--; if ($depth -eq 0) { $p++; break } }
                    $p++
                }
                $qq = $p
                while ($qq -lt $n -and ($clean[$qq] -eq ' ' -or $clean[$qq] -eq "`t" -or $clean[$qq] -eq "`r" -or $clean[$qq] -eq "`n")) { $qq++ }
                if ($qq -lt $n -and $clean[$qq] -eq '{' -and -not (Test-MemberAccess $clean $i)) {
                    # 行番号 = 先頭から識別子位置までの改行数 + 1
                    $line = 1
                    for ($t = 0; $t -lt $i; $t++) { if ($clean[$t] -eq "`n") { $line++ } }
                    $results.Add([pscustomobject]@{ File = $FilePath; Line = $line; Function = $name })
                    $i = $qq + 1
                    continue
                }
                $i = $p
                continue
            }
            else { $i = $j; continue }
        }
        else { $i++ }
    }
    return $results
}

function Get-TargetFiles {
    param([string[]]$Paths, [string[]]$Exts)
    $norm = $Exts | ForEach-Object { if ($_.StartsWith('.')) { $_.ToLower() } else { ('.' + $_).ToLower() } }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Recurse -File | Where-Object {
                $norm -contains $_.Extension.ToLower()
            } | ForEach-Object { $files.Add($_.FullName) }
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $files.Add((Resolve-Path -LiteralPath $p).Path)
        }
        else {
            Write-Warning "見つかりません: $p"
        }
    }
    return $files
}

function Invoke-Analyze {
    param([string[]]$Paths, [string[]]$Exts)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-TargetFiles -Paths $Paths -Exts $Exts)) {
        foreach ($r in (Find-CFunctions -FilePath $f)) { $rows.Add($r) }
    }
    return $rows
}

# --------------------------------------------------------------------------
# GUI (Windows Forms)
# --------------------------------------------------------------------------
function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'FuncInspector - C 関数名抽出'
    $form.Size = New-Object System.Drawing.Size(820, 560)
    $form.StartPosition = 'CenterScreen'

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'フォルダ/ファイル:'; $lbl.Location = '10,15'; $lbl.AutoSize = $true
    $form.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = '120,12'; $tb.Size = '480,24'
    $tb.Anchor = 'Top,Left,Right'
    $form.Controls.Add($tb)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'フォルダ...'; $btnFolder.Location = '610,11'; $btnFolder.Size = '90,25'
    $btnFolder.Anchor = 'Top,Right'
    $btnFolder.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.SelectedPath }
        })
    $form.Controls.Add($btnFolder)

    $btnFile = New-Object System.Windows.Forms.Button
    $btnFile.Text = 'ファイル...'; $btnFile.Location = '705,11'; $btnFile.Size = '90,25'
    $btnFile.Anchor = 'Top,Right'
    $btnFile.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'C source|*.c;*.h|All|*.*'
            if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.FileName }
        })
    $form.Controls.Add($btnFile)

    $lblExt = New-Object System.Windows.Forms.Label
    $lblExt.Text = '拡張子:'; $lblExt.Location = '10,48'; $lblExt.AutoSize = $true
    $form.Controls.Add($lblExt)

    $tbExt = New-Object System.Windows.Forms.TextBox
    $tbExt.Location = '120,45'; $tbExt.Size = '120,24'; $tbExt.Text = '.c,.h'
    $form.Controls.Add($tbExt)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = '10,80'; $lv.Size = '785,390'
    $lv.Anchor = 'Top,Bottom,Left,Right'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
    [void]$lv.Columns.Add('File', 470)
    [void]$lv.Columns.Add('Line', 60)
    [void]$lv.Columns.Add('Function', 230)
    $form.Controls.Add($lv)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = '10,475'; $status.Size = '500,20'; $status.Text = '準備完了'
    $status.Anchor = 'Bottom,Left'
    $form.Controls.Add($status)

    $script:guiRows = @()

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = 'スキャン'; $btnScan.Location = '600,495'; $btnScan.Size = '90,28'
    $btnScan.Anchor = 'Bottom,Right'
    $btnScan.Add_Click({
            if (-not $tb.Text.Trim()) {
                [System.Windows.Forms.MessageBox]::Show('フォルダかファイルを指定してください。') | Out-Null
                return
            }
            $exts = $tbExt.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if (-not $exts) { $exts = @('.c', '.h') }
            $rows = Invoke-Analyze -Paths @($tb.Text.Trim()) -Exts $exts
            $script:guiRows = $rows
            $lv.Items.Clear()
            foreach ($r in $rows) {
                $it = New-Object System.Windows.Forms.ListViewItem($r.File)
                [void]$it.SubItems.Add([string]$r.Line)
                [void]$it.SubItems.Add($r.Function)
                [void]$lv.Items.Add($it)
            }
            $status.Text = ("{0} 件の関数を検出" -f $rows.Count)
        })
    $form.Controls.Add($btnScan)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'CSV 保存'; $btnSave.Location = '700,495'; $btnSave.Size = '95,28'
    $btnSave.Anchor = 'Bottom,Right'
    $btnSave.Add_Click({
            if (-not $script:guiRows -or $script:guiRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('先にスキャンしてください。') | Out-Null
                return
            }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'CSV|*.csv|All|*.*'; $dlg.DefaultExt = 'csv'
            if ($dlg.ShowDialog() -eq 'OK') {
                $sb = New-Object System.Text.StringBuilder
                foreach ($r in $script:guiRows) {
                    [void]$sb.AppendLine(("{0},{1},{2}" -f $r.File, $r.Line, $r.Function))
                }
                [System.IO.File]::WriteAllText($dlg.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
                $status.Text = ("保存しました: {0}" -f $dlg.FileName)
            }
        })
    $form.Controls.Add($btnSave)

    [void]$form.ShowDialog()
}

# --------------------------------------------------------------------------
# エントリポイント
# --------------------------------------------------------------------------
if ($Gui -or -not $Path -or $Path.Count -eq 0) {
    Show-Gui
    return
}

$rows = Invoke-Analyze -Paths $Path -Exts $Extensions
$lines = New-Object System.Collections.Generic.List[string]
if ($Header) { $lines.Add('file,line,function') }
foreach ($r in $rows) { $lines.Add(("{0},{1},{2}" -f $r.File, $r.Line, $r.Function)) }
$text = [string]::Join("`r`n", $lines)

if ($Out) {
    [System.IO.File]::WriteAllText($Out, $text + "`r`n", [System.Text.Encoding]::UTF8)
    Write-Host ("{0} 件を {1} に書き出しました" -f $rows.Count, $Out)
}
else {
    if ($text) { Write-Output $text }
    Write-Host ("{0} 件検出" -f $rows.Count)
}
