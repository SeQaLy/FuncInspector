<#
.SYNOPSIS
    FuncInspector (関数定義版 / コア実装) - プロファイル埋め込み用。

.DESCRIPTION
    このファイルは「関数を定義するだけ」で、読み込んだ時点では何も実行しません。
    起動プロファイル ($PROFILE) にドットソースしておくと、使いたいときに
    Invoke-FuncInspector コマンドで呼び出せます。

    出力フォーマット:  file.c,line,funcname,steps

    機能:
      - WINAMS などのマクロが関数名の前に付いていても対応
      - コメント / 文字列リテラルを除去してから解析
      - プロトタイプ宣言 (末尾 ;) や関数呼び出しは除外
      - コンパイルスイッチ (#ifdef/#ifndef/#if/#elif) の一覧表示 (-ListSwitches)
      - スイッチを -D/-U で ON/OFF し条件コンパイルを評価 (未指定は OFF=未定義)
      - 各関数のステップ数 (本体の実行行数。空行・コメント・波括弧のみの行は除く)
      - CUI / GUI(Windows Forms) 両対応

.NOTES
    ◆ プロファイルへの埋め込み
        . "Z:\develop\FuncInspector\powershell\FuncInspector.Functions.ps1"
    ◆ 使い方
        Invoke-FuncInspector -Path .\src
        Invoke-FuncInspector -Path .\src -ListSwitches
        Invoke-FuncInspector -Path .\src -D CFG_A,VER=2
        Invoke-FuncInspector -Path .\src -IgnoreSwitches
        Invoke-FuncInspector -Gui
        funcinspect .\src                       # 別名
#>

# --- #if 式の評価器 (再帰下降) --------------------------------------------
class FiExpr {
    [System.Collections.Generic.List[object]]$Toks
    [int]$Idx
    [hashtable]$Defs
    FiExpr($tokens, $defines) { $this.Toks = $tokens; $this.Idx = 0; $this.Defs = $defines }
    [object] Peek() { if ($this.Idx -lt $this.Toks.Count) { return $this.Toks[$this.Idx] } return $null }
    [object] Adv() { $x = $this.Toks[$this.Idx]; $this.Idx++; return $x }

    [int] MacroInt([string]$name, [System.Collections.Generic.HashSet[string]]$seen) {
        if (-not $this.Defs.ContainsKey($name)) { return 0 }
        if ($seen.Contains($name)) { return 0 }
        $v = [string]$this.Defs[$name]
        if ([string]::IsNullOrEmpty($v)) { return 1 }
        $v = $v.Trim()
        $num = [int64]0
        if ([int64]::TryParse($v, [ref]$num)) { return [int]$num }
        if ($v -match '^0[xX][0-9a-fA-F]+$') { return [int][Convert]::ToInt64($v, 16) }
        if ($v -match '^[A-Za-z_]\w*$') { [void]$seen.Add($name); return $this.MacroInt($v, $seen) }
        return 0
    }
    [int] ApplyOp([string]$op, [int]$a, [int]$b) {
        switch ($op) {
            '*' { return $a * $b }
            '/' { if ($b) { return [int]($a / $b) } else { return 0 } }
            '%' { if ($b) { return $a % $b } else { return 0 } }
            '+' { return $a + $b }
            '-' { return $a - $b }
            '<' { if ($a -lt $b) { return 1 } else { return 0 } }
            '>' { if ($a -gt $b) { return 1 } else { return 0 } }
            '<=' { if ($a -le $b) { return 1 } else { return 0 } }
            '>=' { if ($a -ge $b) { return 1 } else { return 0 } }
            '==' { if ($a -eq $b) { return 1 } else { return 0 } }
            '!=' { if ($a -ne $b) { return 1 } else { return 0 } }
            '&&' { if ($a -and $b) { return 1 } else { return 0 } }
            '||' { if ($a -or $b) { return 1 } else { return 0 } }
        }
        return 0
    }
    [int] Primary() {
        $t = $this.Peek()
        if ($null -eq $t) { return 0 }
        if ($t.K -eq 'op' -and $t.V -eq '(') {
            $this.Adv(); $v = $this.Or(); $p = $this.Peek()
            if ($p -and $p.K -eq 'op' -and $p.V -eq ')') { $this.Adv() }
            return $v
        }
        if ($t.K -eq 'id' -and $t.V -eq 'defined') {
            $this.Adv(); $nm = $null; $p = $this.Peek()
            if ($p -and $p.K -eq 'op' -and $p.V -eq '(') {
                $this.Adv(); $q = $this.Peek()
                if ($q -and $q.K -eq 'id') { $nm = $this.Adv().V }
                $r = $this.Peek(); if ($r -and $r.K -eq 'op' -and $r.V -eq ')') { $this.Adv() }
            }
            elseif ($p -and $p.K -eq 'id') { $nm = $this.Adv().V }
            if ($null -ne $nm -and $this.Defs.ContainsKey($nm)) { return 1 } else { return 0 }
        }
        if ($t.K -eq 'id') { $this.Adv(); return $this.MacroInt($t.V, (New-Object 'System.Collections.Generic.HashSet[string]')) }
        if ($t.K -eq 'num') { $this.Adv(); return [int]$t.V }
        $this.Adv(); return 0
    }
    [int] Unary() {
        $t = $this.Peek()
        if ($t -and $t.K -eq 'op' -and @('!', '-', '+') -contains $t.V) {
            $this.Adv(); $v = $this.Unary()
            if ($t.V -eq '!') { if ($v) { return 0 } else { return 1 } }
            if ($t.V -eq '-') { return - $v }
            return $v
        }
        return $this.Primary()
    }
    [int] Mul() {
        $v = $this.Unary()
        while ($true) { $t = $this.Peek(); if ($t -and $t.K -eq 'op' -and @('*', '/', '%') -contains $t.V) { $this.Adv(); $v = $this.ApplyOp($t.V, $v, $this.Unary()) } else { break } }
        return $v
    }
    [int] Add() {
        $v = $this.Mul()
        while ($true) { $t = $this.Peek(); if ($t -and $t.K -eq 'op' -and @('+', '-') -contains $t.V) { $this.Adv(); $v = $this.ApplyOp($t.V, $v, $this.Mul()) } else { break } }
        return $v
    }
    [int] Rel() {
        $v = $this.Add()
        while ($true) { $t = $this.Peek(); if ($t -and $t.K -eq 'op' -and @('<', '>', '<=', '>=') -contains $t.V) { $this.Adv(); $v = $this.ApplyOp($t.V, $v, $this.Add()) } else { break } }
        return $v
    }
    [int] Eq() {
        $v = $this.Rel()
        while ($true) { $t = $this.Peek(); if ($t -and $t.K -eq 'op' -and @('==', '!=') -contains $t.V) { $this.Adv(); $v = $this.ApplyOp($t.V, $v, $this.Rel()) } else { break } }
        return $v
    }
    [int] And() {
        $v = $this.Eq()
        while ($true) { $t = $this.Peek(); if ($t -and $t.K -eq 'op' -and $t.V -eq '&&') { $this.Adv(); $v = $this.ApplyOp('&&', $v, $this.Eq()) } else { break } }
        return $v
    }
    [int] Or() {
        $v = $this.And()
        while ($true) { $t = $this.Peek(); if ($t -and $t.K -eq 'op' -and $t.V -eq '||') { $this.Adv(); $v = $this.ApplyOp('||', $v, $this.And()) } else { break } }
        return $v
    }
}

# --- 除外キーワード (1回だけ構築) -----------------------------------------
if (-not (Get-Variable -Name FuncInspectorKeywords -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FuncInspectorKeywords = @{}
    foreach ($k in @(
            'if', 'for', 'while', 'switch', 'return', 'sizeof', 'do', 'else',
            'goto', 'case', 'default', 'typedef', 'struct', 'union', 'enum',
            'static', 'extern', 'const', 'volatile', 'register', 'auto',
            'signed', 'unsigned', 'void', 'char', 'short', 'int', 'long',
            'float', 'double', '_Bool', 'inline', '__inline', '__attribute__',
            '_Static_assert', '_Generic', '_Alignas', 'defined', 'asm', '__asm'
        )) { $script:FuncInspectorKeywords[$k] = $true }
}
$script:FiRxDir = [regex]'^\s*#\s*(ifdef|ifndef|if|elif|else|endif|define|undef)\b(.*)$'
$script:FiRxId = [regex]'[A-Za-z_]\w*'

function Remove-FICommentsStrings {
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

function ConvertTo-FiTokens {
    param([string]$s)
    $toks = New-Object System.Collections.Generic.List[object]
    $i = 0; $n = $s.Length
    while ($i -lt $n) {
        $c = $s[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ([char]::IsDigit($c)) {
            if ($c -eq '0' -and ($i + 1) -lt $n -and ($s[$i + 1] -eq 'x' -or $s[$i + 1] -eq 'X')) {
                $j = $i + 2
                while ($j -lt $n -and (($s[$j] -ge '0' -and $s[$j] -le '9') -or ($s[$j] -ge 'a' -and $s[$j] -le 'f') -or ($s[$j] -ge 'A' -and $s[$j] -le 'F'))) { $j++ }
                $toks.Add([pscustomobject]@{ K = 'num'; V = [int][Convert]::ToInt64($s.Substring($i, $j - $i), 16) }); $i = $j
            }
            else {
                $j = $i
                while ($j -lt $n -and [char]::IsDigit($s[$j])) { $j++ }
                $val = [int]$s.Substring($i, $j - $i)
                while ($j -lt $n -and 'uUlL'.IndexOf($s[$j]) -ge 0) { $j++ }
                $toks.Add([pscustomobject]@{ K = 'num'; V = $val }); $i = $j
            }
            continue
        }
        if ($c -eq '_' -or [char]::IsLetter($c)) {
            $j = $i
            while ($j -lt $n -and ([char]::IsLetterOrDigit($s[$j]) -or $s[$j] -eq '_')) { $j++ }
            $toks.Add([pscustomobject]@{ K = 'id'; V = $s.Substring($i, $j - $i) }); $i = $j; continue
        }
        $two = if (($i + 1) -lt $n) { $s.Substring($i, 2) } else { '' }
        if (@('&&', '||', '==', '!=', '<=', '>=') -contains $two) { $toks.Add([pscustomobject]@{ K = 'op'; V = $two }); $i += 2; continue }
        if ('!()<>+-*/%'.IndexOf($c) -ge 0) { $toks.Add([pscustomobject]@{ K = 'op'; V = [string]$c }); $i++; continue }
        $i++
    }
    return $toks
}

function Get-FiIfValue {
    param([string]$Expr, [hashtable]$Defines)
    $toks = ConvertTo-FiTokens $Expr
    $p = [FiExpr]::new($toks, $Defines)
    try { $v = $p.Or() } catch { $v = 0 }
    return [bool]$v
}

function Test-FiEmitting {
    param($Stack)
    foreach ($f in $Stack) { if (-not $f.active) { return $false } }
    return $true
}

function Invoke-FiPreprocess {
    param([string]$Clean, [hashtable]$Defines)
    $out = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($Clean -split "`n")) {
        $m = $script:FiRxDir.Match($line)
        if ($m.Success) {
            $kind = $m.Groups[1].Value
            $rest = $m.Groups[2].Value.Trim()
            switch ($kind) {
                'ifdef' {
                    $parent = Test-FiEmitting $stack
                    $idm = $script:FiRxId.Match($rest)
                    $cond = $idm.Success -and $Defines.ContainsKey($idm.Value)
                    $stack.Add(@{ parent = $parent; taken = ($parent -and $cond); active = ($parent -and $cond) })
                }
                'ifndef' {
                    $parent = Test-FiEmitting $stack
                    $idm = $script:FiRxId.Match($rest)
                    $cond = (-not $idm.Success) -or (-not $Defines.ContainsKey($idm.Value))
                    $stack.Add(@{ parent = $parent; taken = ($parent -and $cond); active = ($parent -and $cond) })
                }
                'if' {
                    $parent = Test-FiEmitting $stack
                    $cond = if ($parent) { Get-FiIfValue $rest $Defines } else { $false }
                    $stack.Add(@{ parent = $parent; taken = ($parent -and $cond); active = ($parent -and $cond) })
                }
                'elif' {
                    if ($stack.Count) {
                        $f = $stack[$stack.Count - 1]
                        if ($f.parent -and -not $f.taken) {
                            $cond = Get-FiIfValue $rest $Defines
                            $f.active = $cond; $f.taken = ($f.taken -or $cond)
                        }
                        else { $f.active = $false }
                    }
                }
                'else' {
                    if ($stack.Count) {
                        $f = $stack[$stack.Count - 1]
                        if ($f.parent -and -not $f.taken) { $f.active = $true; $f.taken = $true } else { $f.active = $false }
                    }
                }
                'endif' { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) } }
                'define' {
                    if (Test-FiEmitting $stack) {
                        $idm = $script:FiRxId.Match($rest)
                        if ($idm.Success) {
                            $after = $rest.Substring($idm.Index + $idm.Length).Trim()
                            if ($after -eq '') { $after = '1' }
                            $Defines[$idm.Value] = $after
                        }
                    }
                }
                'undef' {
                    if (Test-FiEmitting $stack) {
                        $idm = $script:FiRxId.Match($rest)
                        if ($idm.Success -and $Defines.ContainsKey($idm.Value)) { $Defines.Remove($idm.Value) }
                    }
                }
            }
            $out.Add('')
        }
        else {
            if (Test-FiEmitting $stack) { $out.Add($line) } else { $out.Add('') }
        }
    }
    return ($out -join "`n")
}

function Get-CSwitch {
    <# 指定パスのコンパイルスイッチ名 -> 出現回数 を返す。 #>
    param([string[]]$Path, [string[]]$Extensions = @('.c', '.h'))
    $counts = @{}
    foreach ($f in (Get-FITargetFiles -Paths $Path -Exts $Extensions)) {
        try { $src = [System.IO.File]::ReadAllText($f) } catch { continue }
        $clean = Remove-FICommentsStrings $src
        foreach ($line in ($clean -split "`n")) {
            $m = $script:FiRxDir.Match($line)
            if (-not $m.Success) { continue }
            $kind = $m.Groups[1].Value; $rest = $m.Groups[2].Value
            if ($kind -eq 'ifdef' -or $kind -eq 'ifndef') {
                $idm = $script:FiRxId.Match($rest)
                if ($idm.Success) { $counts[$idm.Value] = ([int]$counts[$idm.Value]) + 1 }
            }
            elseif ($kind -eq 'if' -or $kind -eq 'elif') {
                foreach ($im in $script:FiRxId.Matches($rest)) {
                    if ($im.Value -eq 'defined') { continue }
                    $counts[$im.Value] = ([int]$counts[$im.Value]) + 1
                }
            }
        }
    }
    return $counts
}

function Test-FIIdentStart([char]$c) { return ([char]::IsLetter($c) -or $c -eq '_') }
function Test-FIIdentChar([char]$c) { return ([char]::IsLetterOrDigit($c) -or $c -eq '_') }

function Test-FIMemberAccess {
    param([string]$s, [int]$idx)
    $j = $idx - 1
    while ($j -ge 0 -and ($s[$j] -eq ' ' -or $s[$j] -eq "`t" -or $s[$j] -eq "`r" -or $s[$j] -eq "`n")) { $j-- }
    if ($j -lt 0) { return $false }
    if ($s[$j] -eq '.') { return $true }
    if ($s[$j] -eq '>' -and ($j - 1) -ge 0 -and $s[$j - 1] -eq '-') { return $true }
    return $false
}

function Get-FiScan {
    param([string]$FilePath, [string]$Clean)
    $n = $Clean.Length

    $starts = New-Object System.Collections.Generic.List[int]
    $starts.Add(0)
    for ($x = 0; $x -lt $n; $x++) { if ($Clean[$x] -eq "`n") { $starts.Add($x + 1) } }
    $startsArr = $starts.ToArray()
    $lines = $Clean -split "`n"

    function LineOf([int]$idx) {
        $r = [array]::BinarySearch($startsArr, $idx)
        if ($r -ge 0) { return $r + 1 } else { return (-$r - 1) }
    }
    function CountSteps([int]$l1, [int]$l2) {
        $cnt = 0
        for ($k = $l1; $k -le $l2; $k++) {
            if ($k - 1 -lt 0 -or $k - 1 -ge $lines.Count) { continue }
            $t = ($lines[$k - 1] -replace '\s', '')
            if ($t.Length -eq 0) { continue }
            if ($t -match '^[{}]+$') { continue }
            $cnt++
        }
        return $cnt
    }

    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $n) {
        $c = $Clean[$i]
        if (Test-FIIdentStart $c) {
            $j = $i
            while ($j -lt $n -and (Test-FIIdentChar $Clean[$j])) { $j++ }
            $name = $Clean.Substring($i, $j - $i)
            $k = $j
            while ($k -lt $n -and ($Clean[$k] -eq ' ' -or $Clean[$k] -eq "`t" -or $Clean[$k] -eq "`r" -or $Clean[$k] -eq "`n")) { $k++ }
            if ($k -lt $n -and $Clean[$k] -eq '(' -and -not $script:FuncInspectorKeywords.ContainsKey($name)) {
                $depth = 0; $p = $k
                while ($p -lt $n) {
                    if ($Clean[$p] -eq '(') { $depth++ }
                    elseif ($Clean[$p] -eq ')') { $depth--; if ($depth -eq 0) { $p++; break } }
                    $p++
                }
                $qq = $p
                while ($qq -lt $n -and ($Clean[$qq] -eq ' ' -or $Clean[$qq] -eq "`t" -or $Clean[$qq] -eq "`r" -or $Clean[$qq] -eq "`n")) { $qq++ }
                if ($qq -lt $n -and $Clean[$qq] -eq '{' -and -not (Test-FIMemberAccess $Clean $i)) {
                    $d2 = 0; $r = $qq; $close = $n - 1
                    while ($r -lt $n) {
                        if ($Clean[$r] -eq '{') { $d2++ }
                        elseif ($Clean[$r] -eq '}') { $d2--; if ($d2 -eq 0) { $close = $r; break } }
                        $r++
                    }
                    $l1 = LineOf $qq
                    $l2 = LineOf $close
                    $steps = CountSteps $l1 $l2
                    $results.Add([pscustomobject]@{ File = $FilePath; Line = (LineOf $i); Function = $name; Steps = $steps })
                    $i = $qq + 1
                    continue
                }
                $i = $p; continue
            }
            else { $i = $j; continue }
        }
        else { $i++ }
    }
    return $results
}

function Find-CFunctions {
    <#
    .SYNOPSIS  1ファイルを解析し File/Line/Function/Steps オブジェクトを返す。
    .PARAMETER Defines  ON にするスイッチ (hashtable name->value)。
    .PARAMETER IgnoreSwitches  条件コンパイルを無視して全コードを対象。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [hashtable]$Defines,
        [switch]$IgnoreSwitches
    )
    try { $src = [System.IO.File]::ReadAllText($FilePath) }
    catch { Write-Warning "読み込み失敗: $FilePath"; return @() }

    $clean = Remove-FICommentsStrings $src
    if (-not $IgnoreSwitches) {
        $d = if ($Defines) { $Defines.Clone() } else { @{} }
        $clean = Invoke-FiPreprocess $clean $d
    }
    return Get-FiScan $FilePath $clean
}

function Get-FITargetFiles {
    param([string[]]$Paths, [string[]]$Exts)
    $norm = $Exts | ForEach-Object { if ($_.StartsWith('.')) { $_.ToLower() } else { ('.' + $_).ToLower() } }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Recurse -File | Where-Object { $norm -contains $_.Extension.ToLower() } |
                ForEach-Object { $files.Add($_.FullName) }
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) { $files.Add((Resolve-Path -LiteralPath $p).Path) }
        else { Write-Warning "見つかりません: $p" }
    }
    return $files
}

function Show-FuncInspectorGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'FuncInspector - C 関数名抽出'
    $form.Size = New-Object System.Drawing.Size(900, 600)
    $form.StartPosition = 'CenterScreen'

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'フォルダ/ファイル:'; $lbl.Location = '10,15'; $lbl.AutoSize = $true
    $form.Controls.Add($lbl)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = '120,12'; $tb.Size = '550,24'; $tb.Anchor = 'Top,Left,Right'
    $form.Controls.Add($tb)
    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'フォルダ...'; $btnFolder.Location = '680,11'; $btnFolder.Size = '90,25'; $btnFolder.Anchor = 'Top,Right'
    $btnFolder.Add_Click({ $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.SelectedPath } })
    $form.Controls.Add($btnFolder)
    $btnFile = New-Object System.Windows.Forms.Button
    $btnFile.Text = 'ファイル...'; $btnFile.Location = '775,11'; $btnFile.Size = '90,25'; $btnFile.Anchor = 'Top,Right'
    $btnFile.Add_Click({ $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter = 'C source|*.c;*.h|All|*.*'; if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.FileName } })
    $form.Controls.Add($btnFile)

    $lblExt = New-Object System.Windows.Forms.Label
    $lblExt.Text = '拡張子:'; $lblExt.Location = '10,48'; $lblExt.AutoSize = $true
    $form.Controls.Add($lblExt)
    $tbExt = New-Object System.Windows.Forms.TextBox
    $tbExt.Location = '120,45'; $tbExt.Size = '120,24'; $tbExt.Text = '.c,.h'
    $form.Controls.Add($tbExt)
    $cbIgnore = New-Object System.Windows.Forms.CheckBox
    $cbIgnore.Text = 'スイッチ無視(全コード有効)'; $cbIgnore.Location = '260,46'; $cbIgnore.AutoSize = $true
    $form.Controls.Add($cbIgnore)

    $lblSw = New-Object System.Windows.Forms.Label
    $lblSw.Text = 'スイッチ (チェック=ON)'; $lblSw.Location = '10,80'; $lblSw.AutoSize = $true
    $form.Controls.Add($lblSw)
    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = '10,100'; $clb.Size = '220,400'; $clb.Anchor = 'Top,Bottom,Left'; $clb.CheckOnClick = $true
    $form.Controls.Add($clb)
    $btnDetect = New-Object System.Windows.Forms.Button
    $btnDetect.Text = 'スイッチ検出'; $btnDetect.Location = '10,505'; $btnDetect.Size = '220,26'; $btnDetect.Anchor = 'Bottom,Left'
    $form.Controls.Add($btnDetect)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = '245,100'; $lv.Size = '630,400'; $lv.Anchor = 'Top,Bottom,Left,Right'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
    [void]$lv.Columns.Add('File', 350)
    [void]$lv.Columns.Add('Line', 55)
    [void]$lv.Columns.Add('Function', 160)
    [void]$lv.Columns.Add('Steps', 55)
    $form.Controls.Add($lv)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = '245,505'; $status.Size = '420,20'; $status.Text = '準備完了'; $status.Anchor = 'Bottom,Left'
    $form.Controls.Add($status)

    $script:FIguiRows = @()

    $btnDetect.Add_Click({
            if (-not $tb.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('フォルダかファイルを指定してください。') | Out-Null; return }
            $exts = $tbExt.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if (-not $exts) { $exts = @('.c', '.h') }
            $counts = Get-CSwitch -Path @($tb.Text.Trim()) -Extensions $exts
            $clb.Items.Clear()
            foreach ($name in ($counts.Keys | Sort-Object)) { [void]$clb.Items.Add(("{0}  (x{1})" -f $name, $counts[$name])) }
            $status.Text = ("{0} 個のスイッチを検出" -f $counts.Count)
        })

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = 'スキャン'; $btnScan.Location = '680,505'; $btnScan.Size = '90,28'; $btnScan.Anchor = 'Bottom,Right'
    $btnScan.Add_Click({
            if (-not $tb.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('フォルダかファイルを指定してください。') | Out-Null; return }
            $exts = $tbExt.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if (-not $exts) { $exts = @('.c', '.h') }
            $defines = @{}
            foreach ($it in $clb.CheckedItems) { $defines[([string]$it).Split(' ')[0]] = '1' }
            $ignore = $cbIgnore.Checked
            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($f in (Get-FITargetFiles -Paths @($tb.Text.Trim()) -Exts $exts)) {
                foreach ($r in (Find-CFunctions -FilePath $f -Defines $defines -IgnoreSwitches:$ignore)) { $rows.Add($r) }
            }
            $script:FIguiRows = $rows
            $lv.Items.Clear()
            $tot = 0
            foreach ($r in $rows) {
                $it = New-Object System.Windows.Forms.ListViewItem($r.File)
                [void]$it.SubItems.Add([string]$r.Line)
                [void]$it.SubItems.Add($r.Function)
                [void]$it.SubItems.Add([string]$r.Steps)
                [void]$lv.Items.Add($it)
                $tot += $r.Steps
            }
            $status.Text = ("{0} 関数 / 合計 {1} ステップ" -f $rows.Count, $tot)
        })
    $form.Controls.Add($btnScan)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'CSV 保存'; $btnSave.Location = '780,505'; $btnSave.Size = '95,28'; $btnSave.Anchor = 'Bottom,Right'
    $btnSave.Add_Click({
            if (-not $script:FIguiRows -or $script:FIguiRows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('先にスキャンしてください。') | Out-Null; return }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'CSV|*.csv|All|*.*'; $dlg.DefaultExt = 'csv'
            if ($dlg.ShowDialog() -eq 'OK') {
                $sb = New-Object System.Text.StringBuilder
                foreach ($r in $script:FIguiRows) { [void]$sb.AppendLine(("{0},{1},{2},{3}" -f $r.File, $r.Line, $r.Function, $r.Steps)) }
                [System.IO.File]::WriteAllText($dlg.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
                $status.Text = ("保存しました: {0}" -f $dlg.FileName)
            }
        })
    $form.Controls.Add($btnSave)

    [void]$form.ShowDialog()
}

function Invoke-FuncInspector {
    <#
    .SYNOPSIS  C ソースから関数名を抽出 (出力: file,line,funcname,steps)。
    .EXAMPLE   Invoke-FuncInspector -Path .\src
    .EXAMPLE   Invoke-FuncInspector -Path .\src -ListSwitches
    .EXAMPLE   Invoke-FuncInspector -Path .\src -D CFG_A,VER=2
    .EXAMPLE   Invoke-FuncInspector -Gui
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)][string[]]$Path,
        [string]$Out,
        [string[]]$Extensions = @('.c', '.h'),
        [switch]$Header,
        [switch]$Gui,
        [switch]$ListSwitches,
        [Alias('D')][string[]]$Define,
        [Alias('U')][string[]]$Undef,
        [switch]$IgnoreSwitches,
        [switch]$AsObject
    )

    if ($Gui -or (-not $Path -or $Path.Count -eq 0)) { Show-FuncInspectorGui; return }

    # defines 構築
    $defines = @{}
    foreach ($d in ($Define | Where-Object { $_ })) {
        if ($d.Contains('=')) { $kv = $d.Split('=', 2); $defines[$kv[0].Trim()] = $kv[1] }
        else { $defines[$d.Trim()] = '1' }
    }
    foreach ($u in ($Undef | Where-Object { $_ })) { $defines.Remove($u.Trim()) }

    # スイッチ一覧モード
    if ($ListSwitches) {
        $counts = Get-CSwitch -Path $Path -Extensions $Extensions
        $rows = foreach ($name in ($counts.Keys | Sort-Object)) {
            $st = if ($defines.ContainsKey($name)) { 'ON' } else { 'OFF' }
            [pscustomobject]@{ Switch = $name; Occurrences = $counts[$name]; State = $st }
        }
        if ($AsObject) { return $rows }
        $lines = New-Object System.Collections.Generic.List[string]
        if ($Header) { $lines.Add('switch,occurrences,state') }
        foreach ($r in $rows) { $lines.Add(("{0},{1},{2}" -f $r.Switch, $r.Occurrences, $r.State)) }
        $text = [string]::Join("`r`n", $lines)
        if ($Out) { [System.IO.File]::WriteAllText($Out, $text + "`r`n", [System.Text.Encoding]::UTF8); Write-Host ("{0} に書き出しました" -f $Out) }
        elseif ($text) { Write-Output $text }
        Write-Host ("{0} 個のスイッチ" -f $counts.Count) -ForegroundColor DarkGray
        return
    }

    # 関数抽出モード
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-FITargetFiles -Paths $Path -Exts $Extensions)) {
        foreach ($r in (Find-CFunctions -FilePath $f -Defines $defines -IgnoreSwitches:$IgnoreSwitches)) { $rows.Add($r) }
    }
    if ($AsObject) { return $rows }

    $lines = New-Object System.Collections.Generic.List[string]
    if ($Header) { $lines.Add('file,line,function,steps') }
    foreach ($r in $rows) { $lines.Add(("{0},{1},{2},{3}" -f $r.File, $r.Line, $r.Function, $r.Steps)) }
    $text = [string]::Join("`r`n", $lines)
    $tot = ($rows | Measure-Object -Property Steps -Sum).Sum
    if ($Out) { [System.IO.File]::WriteAllText($Out, $text + "`r`n", [System.Text.Encoding]::UTF8); Write-Host ("{0} に書き出しました" -f $Out) }
    elseif ($text) { Write-Output $text }
    Write-Host ("{0} 関数 / 合計 {1} ステップ" -f $rows.Count, ([int]$tot)) -ForegroundColor DarkGray
}

Set-Alias -Name funcinspect -Value Invoke-FuncInspector -Scope Global -ErrorAction SilentlyContinue
