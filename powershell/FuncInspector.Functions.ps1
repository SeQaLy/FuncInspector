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
$script:FiRxInc = [regex]'^\s*#\s*include\s*"([^"]+)"'
# このファイル自身のパス (GUI のバックグラウンド runspace から再読込するため)
$script:FiScriptPath = $PSCommandPath

# --- 高速化: ホットパス(コメント除去/プリプロセス/関数走査/スイッチ収集)を ---
# --- C# にコンパイルして実行する。失敗時は純 PowerShell 実装にフォールバック。 ---
$script:FiNativeType = $null
$script:FiNativeTried = $false
function Initialize-FiNative {
    if ($script:FiNativeType) { return $true }
    if ($script:FiNativeTried) { return $false }
    $script:FiNativeTried = $true
    # 名前空間にバージョンを付与: C# のシグネチャを変えたら必ず番号を上げること。
    # こうすると、同一プロセスに残った旧版の型と衝突せず、更新後の型を必ずコンパイルできる。
    try { $script:FiNativeType = [FuncInspectorNativeV10.Engine]; return $true } catch {}
    $code = @'
using System;
using System.Collections.Generic;
namespace FuncInspectorNativeV10 {
  public class Row { public string File; public int Line; public string Function; public int Steps; }
  public class Sw  { public string Name; public int Count; public int Line; public List<string> Vals = new List<string>(); }
  public static class Engine {
    static bool IdStart(char c){ return char.IsLetter(c) || c=='_'; }
    static bool IdChar(char c){ return char.IsLetterOrDigit(c) || c=='_'; }
    static readonly HashSet<string> KW = new HashSet<string>(new string[]{
      "if","for","while","switch","return","sizeof","do","else","goto","case","default",
      "typedef","struct","union","enum","static","extern","const","volatile","register",
      "auto","signed","unsigned","void","char","short","int","long","float","double",
      "_Bool","inline","__inline","__attribute__","_Static_assert","_Generic","_Alignas",
      "defined","asm","__asm" });

    public static string Strip(string src){
      int n=src.Length; char[] o=new char[n]; int i=0;
      while(i<n){
        char c=src[i];
        if(c=='/' && i+1<n && src[i+1]=='/'){ while(i<n && src[i]!='\n'){o[i]=' ';i++;} }
        else if(c=='/' && i+1<n && src[i+1]=='*'){ o[i]=' '; o[i+1]=' '; i+=2;
          while(i<n && !(src[i]=='*' && i+1<n && src[i+1]=='/')){ o[i]= src[i]=='\n'?'\n':' '; i++; }
          if(i<n){ o[i]=' '; if(i+1<n)o[i+1]=' '; i+=2; } }
        else if(c=='"' || c=='\''){ char q=c; o[i]=' '; i++;
          while(i<n && src[i]!=q){ if(src[i]=='\\' && i+1<n){o[i]=' ';o[i+1]=' ';i+=2;} else {o[i]= src[i]=='\n'?'\n':' ';i++;} }
          if(i<n){o[i]=' ';i++;} }
        else { o[i]=c; i++; }
      }
      return new string(o);
    }

    static int ParseDirective(char[] b,int ls,int le,out int rest){
      int p=ls; rest=ls;
      while(p<le && (b[p]==' '||b[p]=='\t')) p++;
      if(p>=le || b[p]!='#') return 0;
      p++; while(p<le && (b[p]==' '||b[p]=='\t')) p++;
      int k=p; while(p<le && char.IsLetter(b[p])) p++;
      rest=p; string kw=new string(b,k,p-k);
      switch(kw){ case "ifdef":return 1; case "ifndef":return 2; case "if":return 3;
        case "elif":return 4; case "else":return 5; case "endif":return 6;
        case "define":return 7; case "undef":return 8; default:return 0; }
    }
    static string FirstIdent(char[] b,int s,int e){
      int p=s; while(p<e && !IdStart(b[p])) p++; if(p>=e) return null;
      int st=p; while(p<e && IdChar(b[p])) p++; return new string(b,st,p-st);
    }
    static string FirstIdentAfter(char[] b,int s,int e,out int after){
      int p=s; while(p<e && !IdStart(b[p])) p++; if(p>=e){ after=e; return null; }
      int st=p; while(p<e && IdChar(b[p])) p++; after=p; return new string(b,st,p-st);
    }

    static bool IsHex(char c){ return (c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F'); }
    class Tok { public int Kind; public long Num; public string Id; }
    static List<Tok> Tokenize(char[] b,int s,int e){
      var t=new List<Tok>(); int i=s;
      while(i<e){ char c=b[i];
        if(char.IsWhiteSpace(c)){i++;continue;}
        if(char.IsDigit(c)){ long val;
          if(c=='0' && i+1<e && (b[i+1]=='x'||b[i+1]=='X')){ int j=i+2; while(j<e && IsHex(b[j])) j++; val=Convert.ToInt64(new string(b,i,j-i),16); i=j; }
          else { int j=i; while(j<e && char.IsDigit(b[j])) j++; val=long.Parse(new string(b,i,j-i)); while(j<e && (b[j]=='u'||b[j]=='U'||b[j]=='l'||b[j]=='L')) j++; i=j; }
          t.Add(new Tok{Kind=0,Num=val}); continue; }
        if(IdStart(c)){ int j=i; while(j<e && IdChar(b[j])) j++; t.Add(new Tok{Kind=1,Id=new string(b,i,j-i)}); i=j; continue; }
        if(i+1<e){ string two=new string(b,i,2);
          if(two=="&&"||two=="||"||two=="=="||two=="!="||two=="<="||two==">="){ t.Add(new Tok{Kind=2,Id=two}); i+=2; continue; } }
        if("!()<>+-*/%".IndexOf(c)>=0){ t.Add(new Tok{Kind=2,Id=c.ToString()}); i++; continue; }
        i++;
      }
      return t;
    }
    class Pr {
      List<Tok> t; int pos; Dictionary<string,string> d;
      public Pr(List<Tok> toks,Dictionary<string,string> defs){ t=toks; pos=0; d=defs; }
      Tok Peek(){ return pos<t.Count? t[pos]:null; }
      Tok Adv(){ return t[pos++]; }
      bool IsOp(Tok x,string o){ return x!=null && x.Kind==2 && x.Id==o; }
      long MacroInt(string name,HashSet<string> seen){
        if(!d.ContainsKey(name)) return 0; if(seen.Contains(name)) return 0;
        string v=d[name]; if(string.IsNullOrEmpty(v)) return 1; v=v.Trim();
        long val; if(long.TryParse(v,out val)) return val;
        if(v.Length>2 && v[0]=='0' && (v[1]=='x'||v[1]=='X')){ try { return Convert.ToInt64(v,16); } catch {} }
        bool isId=v.Length>0 && IdStart(v[0]); for(int k=1; isId && k<v.Length; k++) if(!IdChar(v[k])) isId=false;
        if(isId){ seen.Add(name); return MacroInt(v,seen); }
        return 0;
      }
      long Ap(string op,long a,long b){ switch(op){
        case "*":return a*b; case "/":return b!=0?a/b:0; case "%":return b!=0?a%b:0;
        case "+":return a+b; case "-":return a-b; case "<":return a<b?1:0; case ">":return a>b?1:0;
        case "<=":return a<=b?1:0; case ">=":return a>=b?1:0; case "==":return a==b?1:0; case "!=":return a!=b?1:0;
        case "&&":return (a!=0&&b!=0)?1:0; case "||":return (a!=0||b!=0)?1:0; } return 0; }
      long Primary(){ Tok x=Peek(); if(x==null) return 0;
        if(IsOp(x,"(")){ Adv(); long v=Or(); if(IsOp(Peek(),")")) Adv(); return v; }
        if(x.Kind==1 && x.Id=="defined"){ Adv(); string nm=null; Tok p=Peek();
          if(IsOp(p,"(")){ Adv(); Tok q=Peek(); if(q!=null&&q.Kind==1) nm=Adv().Id; if(IsOp(Peek(),")")) Adv(); }
          else if(p!=null&&p.Kind==1) nm=Adv().Id;
          return (nm!=null && d.ContainsKey(nm))?1:0; }
        if(x.Kind==1){ Adv(); return MacroInt(x.Id,new HashSet<string>()); }
        if(x.Kind==0){ Adv(); return x.Num; }
        Adv(); return 0; }
      long Unary(){ Tok x=Peek(); if(x!=null&&x.Kind==2&&(x.Id=="!"||x.Id=="-"||x.Id=="+")){ Adv(); long v=Unary(); if(x.Id=="!") return v!=0?0:1; if(x.Id=="-") return -v; return v; } return Primary(); }
      long Mul(){ long v=Unary(); while(true){ Tok x=Peek(); if(x!=null&&x.Kind==2&&(x.Id=="*"||x.Id=="/"||x.Id=="%")){ Adv(); v=Ap(x.Id,v,Unary()); } else break; } return v; }
      long Add(){ long v=Mul(); while(true){ Tok x=Peek(); if(x!=null&&x.Kind==2&&(x.Id=="+"||x.Id=="-")){ Adv(); v=Ap(x.Id,v,Mul()); } else break; } return v; }
      long Rel(){ long v=Add(); while(true){ Tok x=Peek(); if(x!=null&&x.Kind==2&&(x.Id=="<"||x.Id==">"||x.Id=="<="||x.Id==">=")){ Adv(); v=Ap(x.Id,v,Add()); } else break; } return v; }
      long Eq(){ long v=Rel(); while(true){ Tok x=Peek(); if(x!=null&&x.Kind==2&&(x.Id=="=="||x.Id=="!=")){ Adv(); v=Ap(x.Id,v,Rel()); } else break; } return v; }
      long AndE(){ long v=Eq(); while(true){ Tok x=Peek(); if(IsOp(x,"&&")){ Adv(); v=Ap("&&",v,Eq()); } else break; } return v; }
      public long Or(){ long v=AndE(); while(true){ Tok x=Peek(); if(IsOp(x,"||")){ Adv(); v=Ap("||",v,AndE()); } else break; } return v; }
    }
    static long EvalIf(char[] b,int s,int e,Dictionary<string,string> defs){
      var p=new Pr(Tokenize(b,s,e),defs); try { return p.Or()!=0?1:0; } catch { return 0; } }

    public static string Preprocess(string clean,Dictionary<string,string> defs,HashSet<string> pinned,bool external,HashSet<string> valConsts){
      char[] b=clean.ToCharArray(); int n=b.Length;
      var par=new List<bool>(); var tak=new List<bool>(); var act=new List<bool>();
      int ls=0;
      while(ls<=n){
        int le=ls; while(le<n && b[le]!='\n') le++;
        bool emit=true; for(int k=0;k<act.Count;k++){ if(!act[k]){emit=false;break;} }
        int rest; int kind=ParseDirective(b,ls,le,out rest); bool blank=false;
        if(kind!=0){ blank=true;
          if(kind==1){ string nm=FirstIdent(b,rest,le); bool cond=nm!=null && defs.ContainsKey(nm); par.Add(emit); tak.Add(emit&&cond); act.Add(emit&&cond); }
          else if(kind==2){ string nm=FirstIdent(b,rest,le); bool cond=(nm==null)||!defs.ContainsKey(nm); par.Add(emit); tak.Add(emit&&cond); act.Add(emit&&cond); }
          else if(kind==3){ bool cond=emit && (EvalIf(b,rest,le,defs)!=0); par.Add(emit); tak.Add(emit&&cond); act.Add(emit&&cond); }
          else if(kind==4){ int idx=act.Count-1; if(idx>=0){ if(par[idx] && !tak[idx]){ bool cond=EvalIf(b,rest,le,defs)!=0; act[idx]=cond; if(cond)tak[idx]=true; } else act[idx]=false; } }
          else if(kind==5){ int idx=act.Count-1; if(idx>=0){ if(par[idx] && !tak[idx]){ act[idx]=true; tak[idx]=true; } else act[idx]=false; } }
          else if(kind==6){ int idx=act.Count-1; if(idx>=0){ par.RemoveAt(idx); tak.RemoveAt(idx); act.RemoveAt(idx); } }
          else if(kind==7){ if(emit){ int after; string nm=FirstIdentAfter(b,rest,le,out after); if(nm!=null && !pinned.Contains(nm) && (!external || valConsts.Contains(nm))){ int vs=after; while(vs<le && (b[vs]==' '||b[vs]=='\t')) vs++; int ve=le; while(ve>vs && (b[ve-1]==' '||b[ve-1]=='\t'||b[ve-1]=='\r')) ve--; string val= ve>vs? new string(b,vs,ve-vs) : "1"; defs[nm]=val; } } }
          else if(kind==8){ if(emit){ string nm=FirstIdent(b,rest,le); if(nm!=null && !pinned.Contains(nm) && (!external || valConsts.Contains(nm)) && defs.ContainsKey(nm)) defs.Remove(nm); } }
        } else { if(!emit) blank=true; }
        if(blank){ for(int p=ls;p<le;p++) b[p]=' '; }
        if(le>=n) break; ls=le+1;
      }
      return new string(b);
    }

    static bool MemberAccess(string s,int idx){ int j=idx-1; while(j>=0 && (s[j]==' '||s[j]=='\t'||s[j]=='\r'||s[j]=='\n')) j--; if(j<0) return false; if(s[j]=='.') return true; if(s[j]=='>' && j-1>=0 && s[j-1]=='-') return true; return false; }
    static int LineOf(int[] st,int idx){ int lo=0,hi=st.Length; while(lo<hi){ int mid=(lo+hi)/2; if(st[mid]<=idx) lo=mid+1; else hi=mid; } return lo; }
    static int CountSteps(string[] lines,int l1,int l2){ int cnt=0; for(int k=l1;k<=l2;k++){ if(k<1||k>lines.Length) continue; string s=lines[k-1]; bool nb=false; for(int p=0;p<s.Length;p++){ char ch=s[p]; if(char.IsWhiteSpace(ch)) continue; if(ch!='{'&&ch!='}'){ nb=true; break; } } if(nb) cnt++; } return cnt; }

    public static List<Row> Scan(string path,string clean){
      int n=clean.Length;
      var starts=new List<int>(); starts.Add(0);
      for(int i=0;i<n;i++) if(clean[i]=='\n') starts.Add(i+1);
      int[] st=starts.ToArray(); string[] lines=clean.Split('\n');
      var res=new List<Row>(); int q2=0;
      while(q2<n){ char c=clean[q2];
        if(IdStart(c)){
          int j=q2; while(j<n && IdChar(clean[j])) j++; string name=clean.Substring(q2,j-q2);
          int k=j; while(k<n && (clean[k]==' '||clean[k]=='\t'||clean[k]=='\r'||clean[k]=='\n')) k++;
          if(k<n && clean[k]=='(' && !KW.Contains(name)){
            int depth=0; int p=k;
            while(p<n){ if(clean[p]=='(') depth++; else if(clean[p]==')'){ depth--; if(depth==0){ p++; break; } } p++; }
            int q=p; while(q<n && (clean[q]==' '||clean[q]=='\t'||clean[q]=='\r'||clean[q]=='\n')) q++;
            if(q<n && clean[q]=='{' && !MemberAccess(clean,q2)){
              int d2=0; int r=q; int close=n-1;
              while(r<n){ if(clean[r]=='{') d2++; else if(clean[r]=='}'){ d2--; if(d2==0){ close=r; break; } } r++; }
              int steps=CountSteps(lines,LineOf(st,q),LineOf(st,close));
              res.Add(new Row{File=path,Line=LineOf(st,q2),Function=name,Steps=steps});
              q2=close+1; continue;
            }
            q2=p; continue;
          } else { q2=j; continue; }
        } else q2++;
      }
      return res;
    }

    public static List<Row> Analyze(string path,string src,Dictionary<string,string> defs,bool ignore,HashSet<string> pinned,bool external){
      string clean=Strip(src);
      if(!ignore){ var d=new Dictionary<string,string>(defs); HashSet<string> vc = external ? ValueConsts(ClassifyClean(clean)) : new HashSet<string>(); clean=Preprocess(clean,d,pinned,external,vc); }
      return Scan(path,clean);
    }
    class SwInfo { public int Count; public int Line; public List<string> Vals=new List<string>(); public bool SwRole; public bool ValRole; }
    static void AddVal2(SwInfo s,string v){ if(string.IsNullOrEmpty(v)) return; if(!s.Vals.Contains(v)) s.Vals.Add(v); }
    static SwInfo Ensure(Dictionary<string,SwInfo> map,string name,int line){ SwInfo s; if(!map.TryGetValue(name,out s)){ s=new SwInfo{Count=0,Line=line}; map[name]=s; } return s; }
    static bool TokIsId(Tok t){ return t!=null && t.Kind==1 && t.Id!="defined"; }
    static bool IsCmp(Tok t){ return t.Kind==2 && (t.Id=="=="||t.Id=="!="||t.Id=="<"||t.Id==">"||t.Id=="<="||t.Id==">="); }
    static Dictionary<string,SwInfo> ClassifyClean(string clean){
      char[] b=clean.ToCharArray(); int n=b.Length;
      var map=new Dictionary<string,SwInfo>(); int ls=0; int lineno=0;
      while(ls<=n){ lineno++; int le=ls; while(le<n && b[le]!='\n') le++;
        int rest; int kind=ParseDirective(b,ls,le,out rest);
        if(kind==1||kind==2){ string nm=FirstIdent(b,rest,le); if(nm!=null){ var s=Ensure(map,nm,lineno); s.Count++; s.SwRole=true; AddVal2(s,"1"); } }
        else if(kind==3||kind==4){
          var toks=Tokenize(b,rest,le); var handled=new HashSet<int>();
          for(int i=0;i<toks.Count;i++){ if(!IsCmp(toks[i])) continue;
            Tok L=i-1>=0?toks[i-1]:null; Tok R=i+1<toks.Count?toks[i+1]:null;
            bool Lid=TokIsId(L), Rid=TokIsId(R);
            if(Lid && R!=null && R.Kind==0){ var s=Ensure(map,L.Id,lineno); s.Count++; s.SwRole=true; AddVal2(s,R.Num.ToString()); handled.Add(i-1); }
            else if(Rid && L!=null && L.Kind==0){ var s=Ensure(map,R.Id,lineno); s.Count++; s.SwRole=true; AddVal2(s,L.Num.ToString()); handled.Add(i+1); }
            else if(Lid && Rid){ var s=Ensure(map,L.Id,lineno); s.Count++; s.SwRole=true; AddVal2(s,R.Id); Ensure(map,R.Id,lineno).ValRole=true; handled.Add(i-1); handled.Add(i+1); }
          }
          for(int i=0;i<toks.Count;i++){ if(toks[i].Kind==1 && toks[i].Id=="defined"){ for(int j=i+1;j<toks.Count && j<i+3;j++){ if(toks[j].Kind==1){ var s=Ensure(map,toks[j].Id,lineno); s.Count++; s.SwRole=true; AddVal2(s,"1"); handled.Add(j); break; } } } }
          for(int i=0;i<toks.Count;i++){ if(toks[i].Kind==1 && toks[i].Id!="defined" && !handled.Contains(i)){ var s=Ensure(map,toks[i].Id,lineno); s.Count++; s.SwRole=true; AddVal2(s,"1"); } }
        }
        if(le>=n) break; ls=le+1;
      }
      return map;
    }
    static HashSet<string> ValueConsts(Dictionary<string,SwInfo> map){ var h=new HashSet<string>(); foreach(var kv in map) if(kv.Value.ValRole && !kv.Value.SwRole) h.Add(kv.Key); return h; }
    public static List<Sw> CollectSwitches(string src){
      var map=ClassifyClean(Strip(src)); var vc=ValueConsts(map); var list=new List<Sw>();
      foreach(var kv in map){ if(vc.Contains(kv.Key)) continue; var s=new Sw{Name=kv.Key,Count=kv.Value.Count,Line=kv.Value.Line}; s.Vals.AddRange(kv.Value.Vals); list.Add(s); }
      return list;
    }

    // ---- include 追従 (スイッチ追跡モード) ----
    static string StripComments(string src){
      int n=src.Length; var o=new System.Text.StringBuilder(n); int i=0;
      while(i<n){ char c=src[i];
        if(c=='/' && i+1<n && src[i+1]=='/'){ while(i<n && src[i]!='\n'){o.Append(' ');i++;} }
        else if(c=='/' && i+1<n && src[i+1]=='*'){ o.Append("  "); i+=2; while(i<n && !(src[i]=='*'&&i+1<n&&src[i+1]=='/')){ o.Append(src[i]=='\n'?'\n':' '); i++; } if(i<n){o.Append("  ");i+=2;} }
        else if(c=='"'||c=='\''){ char q=c; o.Append(c); i++; while(i<n && src[i]!=q){ if(src[i]=='\\'&&i+1<n){o.Append(src[i]);o.Append(src[i+1]);i+=2;} else {o.Append(src[i]);i++;} } if(i<n){o.Append(src[i]);i++;} }
        else { o.Append(c); i++; }
      }
      return o.ToString();
    }
    // コメント除去済みソースのキャッシュ (プロセス内で永続=GUIの再スキャンを高速化)。
    // path + 更新時刻 + サイズ で検証。ファイルが変わったら自動で再読込。
    class Src { public long Mtime; public long Size; public string Text; }
    static readonly Dictionary<string,Src> _srcCache = new Dictionary<string,Src>();
    static readonly object _cacheLock = new object();
    static string ReadStripped(string path){
      try{
        var fi = new System.IO.FileInfo(path);
        long mt = fi.LastWriteTimeUtc.Ticks; long sz = fi.Length;
        lock(_cacheLock){ Src s; if(_srcCache.TryGetValue(path, out s) && s.Mtime==mt && s.Size==sz) return s.Text; }
        string stripped = StripComments(System.IO.File.ReadAllText(path));
        lock(_cacheLock){ _srcCache[path] = new Src{ Mtime=mt, Size=sz, Text=stripped }; }
        return stripped;
      } catch { return null; }
    }
    public static void ClearCache(){ lock(_cacheLock){ _srcCache.Clear(); } }
    static string ResolveInclude(string name, string baseDir, string[] incDirs){
      try{ string cand=System.IO.Path.Combine(baseDir,name); if(System.IO.File.Exists(cand)) return System.IO.Path.GetFullPath(cand); }catch{}
      if(incDirs!=null) foreach(var dd in incDirs){ try{ string cand=System.IO.Path.Combine(dd,name); if(System.IO.File.Exists(cand)) return System.IO.Path.GetFullPath(cand); }catch{} }
      return null;
    }
    static string ParseInclude(char[] b,int ls,int le){
      int p=ls; while(p<le && (b[p]==' '||b[p]=='\t')) p++;
      if(p>=le || b[p]!='#') return null; p++;
      while(p<le && (b[p]==' '||b[p]=='\t')) p++;
      if(le-p<7) return null; string kw="include"; for(int k=0;k<7;k++) if(b[p+k]!=kw[k]) return null; p+=7;
      while(p<le && (b[p]==' '||b[p]=='\t')) p++;
      if(p>=le || b[p]!='"') return null; p++;
      int s=p; while(p<le && b[p]!='"') p++;
      return new string(b,s,p-s);
    }
    static void PpProcess(char[] b, Dictionary<string,string> d, HashSet<string> pinned, string baseDir, bool collect, int depth, string[] incDirs, HashSet<string> seen){
      int n=b.Length; var par=new List<bool>(); var tak=new List<bool>(); var act=new List<bool>(); int ls=0;
      while(ls<=n){ int le=ls; while(le<n && b[le]!='\n') le++;
        bool emit=true; for(int k=0;k<act.Count;k++){ if(!act[k]){emit=false;break;} }
        int rest; int kind=ParseDirective(b,ls,le,out rest); bool blank=false;
        if(kind!=0){ blank=true;
          if(kind==1){ string nm=FirstIdent(b,rest,le); bool cond=nm!=null && d.ContainsKey(nm); par.Add(emit); tak.Add(emit&&cond); act.Add(emit&&cond); }
          else if(kind==2){ string nm=FirstIdent(b,rest,le); bool cond=(nm==null)||!d.ContainsKey(nm); par.Add(emit); tak.Add(emit&&cond); act.Add(emit&&cond); }
          else if(kind==3){ bool cond=emit && (EvalIf(b,rest,le,d)!=0); par.Add(emit); tak.Add(emit&&cond); act.Add(emit&&cond); }
          else if(kind==4){ int idx=act.Count-1; if(idx>=0){ if(par[idx]&&!tak[idx]){ bool cond=EvalIf(b,rest,le,d)!=0; act[idx]=cond; if(cond)tak[idx]=true; } else act[idx]=false; } }
          else if(kind==5){ int idx=act.Count-1; if(idx>=0){ if(par[idx]&&!tak[idx]){act[idx]=true;tak[idx]=true;} else act[idx]=false; } }
          else if(kind==6){ int idx=act.Count-1; if(idx>=0){ par.RemoveAt(idx);tak.RemoveAt(idx);act.RemoveAt(idx); } }
          else if(kind==7){ if(emit){ int after; string nm=FirstIdentAfter(b,rest,le,out after); if(nm!=null && !pinned.Contains(nm)){ int vs=after; while(vs<le&&(b[vs]==' '||b[vs]=='\t'))vs++; int ve=le; while(ve>vs&&(b[ve-1]==' '||b[ve-1]=='\t'||b[ve-1]=='\r'))ve--; string val=ve>vs?new string(b,vs,ve-vs):"1"; d[nm]=val; /* 完全cpp準拠: 値なしフラグも定義 */ } } }
          else if(kind==8){ if(emit){ string nm=FirstIdent(b,rest,le); if(nm!=null && !pinned.Contains(nm) && d.ContainsKey(nm)) d.Remove(nm); } }
        } else {
          string inc = (emit && depth<40) ? ParseInclude(b,ls,le) : null;
          if(inc!=null){ blank=true;
            string hp=ResolveInclude(inc,baseDir,incDirs);
            if(hp!=null && !seen.Contains(hp)){
              string hc=ReadStripped(hp);
              if(hc!=null){ char[] hb=hc.ToCharArray(); seen.Add(hp);
                PpProcess(hb, d, pinned, System.IO.Path.GetDirectoryName(hp), false, depth+1, incDirs, seen); seen.Remove(hp); }
            }
          } else { if(!emit) blank=true; }
        }
        if(collect && blank) for(int p=ls;p<le;p++) b[p]=' ';
        if(le>=n) break; ls=le+1;
      }
    }
    public static List<Row> AnalyzeResolve(string path, Dictionary<string,string> defs, HashSet<string> pinned, string[] incDirs){
      string cc = ReadStripped(path); if(cc==null) return new List<Row>();
      char[] b = cc.ToCharArray();
      var d = new Dictionary<string,string>(defs);
      string baseDir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
      var seen = new HashSet<string>(); seen.Add(System.IO.Path.GetFullPath(path));
      PpProcess(b, d, pinned, baseDir, true, 0, incDirs, seen);
      string outc = Strip(new string(b));   // 走査前に文字列を空白化 (コメントは除去済み)
      return Scan(path, outc);
    }
    // include 解決後に「定義されている」マクロ表を返す (GUI: 有効スイッチの自動チェック用)
    public static Dictionary<string,string> ResolveDefines(string path, Dictionary<string,string> defs, HashSet<string> pinned, string[] incDirs){
      string cc = ReadStripped(path); if(cc==null) return new Dictionary<string,string>();
      char[] b = cc.ToCharArray();
      var d = new Dictionary<string,string>(defs);
      string baseDir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
      var seen = new HashSet<string>(); seen.Add(System.IO.Path.GetFullPath(path));
      PpProcess(b, d, pinned, baseDir, false, 0, incDirs, seen);
      return d;
    }
  }
}
'@
    try {
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
        $script:FiNativeType = [FuncInspectorNativeV10.Engine]
        return $true
    }
    catch { Write-Verbose "FiNative コンパイル失敗 (純PSにフォールバック): $_"; return $false }
}

function Open-FiLocation {
    <# ファイルの該当行を開く (VS Code 優先、無ければ OS 既定アプリ)。 #>
    param([string]$File, [int]$Line)
    $code = Get-Command code -ErrorAction SilentlyContinue
    if ($code) {
        try { & $code.Source -g ("{0}:{1}" -f $File, $Line); return } catch {}
    }
    try { Invoke-Item -LiteralPath $File } catch { Write-Warning "開けませんでした: $File" }
}

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
    param([string]$Clean, [hashtable]$Defines, [hashtable]$Pinned = @{}, [switch]$External, [hashtable]$ValConsts = @{})
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
                        if ($idm.Success -and -not $Pinned.ContainsKey($idm.Value) -and (-not $External -or $ValConsts.ContainsKey($idm.Value))) {
                            $after = $rest.Substring($idm.Index + $idm.Length).Trim()
                            if ($after -eq '') { $after = '1' }
                            $Defines[$idm.Value] = $after
                        }
                    }
                }
                'undef' {
                    if (Test-FiEmitting $stack) {
                        $idm = $script:FiRxId.Match($rest)
                        if ($idm.Success -and -not $Pinned.ContainsKey($idm.Value) -and (-not $External -or $ValConsts.ContainsKey($idm.Value)) -and $Defines.ContainsKey($idm.Value)) { $Defines.Remove($idm.Value) }
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

# --- include 追従 (純PSフォールバック) ---
function Remove-FICommentsOnly([string]$Src) {
    $n = $Src.Length; $sb = New-Object System.Text.StringBuilder $n; $i = 0
    while ($i -lt $n) {
        $c = $Src[$i]
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Src[$i + 1] -eq '/') { while ($i -lt $n -and $Src[$i] -ne "`n") { [void]$sb.Append(' '); $i++ } }
        elseif ($c -eq '/' -and ($i + 1) -lt $n -and $Src[$i + 1] -eq '*') {
            [void]$sb.Append('  '); $i += 2
            while ($i -lt $n -and -not ($Src[$i] -eq '*' -and ($i + 1) -lt $n -and $Src[$i + 1] -eq '/')) { if ($Src[$i] -eq "`n") { [void]$sb.Append("`n") } else { [void]$sb.Append(' ') }; $i++ }
            if ($i -lt $n) { [void]$sb.Append('  '); $i += 2 }
        }
        elseif ($c -eq '"' -or $c -eq "'") {
            $q = $c; [void]$sb.Append($c); $i++
            while ($i -lt $n -and $Src[$i] -ne $q) { if ($Src[$i] -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Src[$i]); [void]$sb.Append($Src[$i + 1]); $i += 2 } else { [void]$sb.Append($Src[$i]); $i++ } }
            if ($i -lt $n) { [void]$sb.Append($Src[$i]); $i++ }
        }
        else { [void]$sb.Append($c); $i++ }
    }
    return $sb.ToString()
}
function Get-FiReachCondition([string]$File, [int]$Line) {
    # File の Line(初出=その #if 行)に到達するための「囲み条件」を文字列で返す。
    # 評価はせず、入れ子の各 #if/#ifdef/#elif/#else の枝条件を && で連結して表示する。
    try { $src = Remove-FICommentsOnly ([IO.File]::ReadAllText($File)) } catch { return '(取得不可)' }
    $stack = New-Object System.Collections.Generic.List[object]
    $ln = 0
    foreach ($l in ($src -split "`n")) {
        $ln++
        if ($ln -ge $Line) { break }   # 目的行の手前までの状態を見る
        $m = $script:FiRxDir.Match($l); if (-not $m.Success) { continue }
        $kind = $m.Groups[1].Value; $rest = $m.Groups[2].Value.Trim()
        switch ($kind) {
            'ifdef' { $c = "defined($($script:FiRxId.Match($rest).Value))"; $stack.Add(@{ If = $c; Cur = $c }) }
            'ifndef' { $c = "!defined($($script:FiRxId.Match($rest).Value))"; $stack.Add(@{ If = $c; Cur = $c }) }
            'if' { $stack.Add(@{ If = $rest; Cur = $rest }) }
            'elif' { if ($stack.Count) { $stack[$stack.Count - 1].Cur = $rest } }
            'else' { if ($stack.Count) { $stack[$stack.Count - 1].Cur = "!($($stack[$stack.Count - 1].If))" } }
            'endif' { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) } }
        }
    }
    if ($stack.Count -eq 0) { return '(無条件)' }
    return (($stack | ForEach-Object { $_.Cur }) -join ' && ')
}

function Get-FiResolvedDefines([string]$FilePath, [string[]]$IncludeDirs) {
    # include 解決後に「定義されている」マクロ表(name->value)を返す。GUIの有効スイッチ自動チェック用。
    if (Initialize-FiNative) {
        $nd = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $np = New-Object 'System.Collections.Generic.HashSet[string]'
        $h = @{}
        try {
            $r = $script:FiNativeType::ResolveDefines($FilePath, $nd, $np, [string[]]$IncludeDirs)
            foreach ($k in $r.Keys) { $h[$k] = [string]$r[$k] }
        }
        catch {}
        return $h
    }
    # 純PSフォールバック
    try { $cc = Remove-FICommentsOnly ([IO.File]::ReadAllText($FilePath)) } catch { return @{} }
    $d = @{}
    $base = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($FilePath))
    $seen = @{}; $seen[[IO.Path]::GetFullPath($FilePath)] = $true
    Invoke-FiPpProcess $cc $d @{} $base $false 0 $IncludeDirs $seen $null
    return $d
}

function Get-FiAutoIncludeDirs([string[]]$Paths) {
    # スキャン対象ツリーの全ディレクトリを自動 include 検索パスにする (-I 不要化)
    $dirs = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($p in ($Paths | Where-Object { $_ })) {
        try {
            if ([IO.Directory]::Exists($p)) {
                $all = @($p) + @([IO.Directory]::GetDirectories($p, '*', [IO.SearchOption]::AllDirectories))
                foreach ($d in $all) { $ap = [IO.Path]::GetFullPath($d); if (-not $seen.ContainsKey($ap)) { $seen[$ap] = $true; $dirs.Add($ap) } }
            }
            elseif ([IO.File]::Exists($p)) {
                $ap = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($p)); if (-not $seen.ContainsKey($ap)) { $seen[$ap] = $true; $dirs.Add($ap) }
            }
        }
        catch {}
    }
    return $dirs.ToArray()
}
function Resolve-FiInclude([string]$Name, [string]$BaseDir, [string[]]$IncludeDirs) {
    try { $cand = [IO.Path]::Combine($BaseDir, $Name); if ([IO.File]::Exists($cand)) { return [IO.Path]::GetFullPath($cand) } } catch {}
    foreach ($d in ($IncludeDirs | Where-Object { $_ })) { try { $cand = [IO.Path]::Combine($d, $Name); if ([IO.File]::Exists($cand)) { return [IO.Path]::GetFullPath($cand) } } catch {} }
    return $null
}
function Invoke-FiPpProcess([string]$Clean, [hashtable]$Defines, [hashtable]$Pinned, [string]$BaseDir, [bool]$Collect, [int]$Depth, [string[]]$IncludeDirs, [hashtable]$Seen, $Out) {
    $stack = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($Clean -split "`n")) {
        $m = $script:FiRxDir.Match($line)
        if ($m.Success) {
            $kind = $m.Groups[1].Value; $rest = $m.Groups[2].Value.Trim()
            switch ($kind) {
                'ifdef' { $parent = Test-FiEmitting $stack; $idm = $script:FiRxId.Match($rest); $cond = $idm.Success -and $Defines.ContainsKey($idm.Value); $stack.Add(@{ parent = $parent; taken = ($parent -and $cond); active = ($parent -and $cond) }) }
                'ifndef' { $parent = Test-FiEmitting $stack; $idm = $script:FiRxId.Match($rest); $cond = (-not $idm.Success) -or (-not $Defines.ContainsKey($idm.Value)); $stack.Add(@{ parent = $parent; taken = ($parent -and $cond); active = ($parent -and $cond) }) }
                'if' { $parent = Test-FiEmitting $stack; $cond = if ($parent) { Get-FiIfValue $rest $Defines } else { $false }; $stack.Add(@{ parent = $parent; taken = ($parent -and $cond); active = ($parent -and $cond) }) }
                'elif' { if ($stack.Count) { $f = $stack[$stack.Count - 1]; if ($f.parent -and -not $f.taken) { $cond = Get-FiIfValue $rest $Defines; $f.active = $cond; $f.taken = ($f.taken -or $cond) } else { $f.active = $false } } }
                'else' { if ($stack.Count) { $f = $stack[$stack.Count - 1]; if ($f.parent -and -not $f.taken) { $f.active = $true; $f.taken = $true } else { $f.active = $false } } }
                'endif' { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) } }
                'define' { if (Test-FiEmitting $stack) { $idm = $script:FiRxId.Match($rest); if ($idm.Success -and -not $Pinned.ContainsKey($idm.Value)) { $after = $rest.Substring($idm.Index + $idm.Length).Trim(); if ($after -eq '') { $after = '1' }; $Defines[$idm.Value] = $after } } }
                'undef' { if (Test-FiEmitting $stack) { $idm = $script:FiRxId.Match($rest); if ($idm.Success -and -not $Pinned.ContainsKey($idm.Value) -and $Defines.ContainsKey($idm.Value)) { $Defines.Remove($idm.Value) } } }
            }
            if ($Collect) { [void]$Out.Add('') }
        }
        else {
            $emit = Test-FiEmitting $stack
            $im = if ($emit -and $Depth -lt 40) { $script:FiRxInc.Match($line) } else { $null }
            if ($im -and $im.Success) {
                if ($Collect) { [void]$Out.Add('') }
                $hp = Resolve-FiInclude $im.Groups[1].Value $BaseDir $IncludeDirs
                if ($hp -and -not $Seen.ContainsKey($hp)) {
                    try { $hsrc = [IO.File]::ReadAllText($hp) } catch { $hsrc = $null }
                    if ($null -ne $hsrc) { $hc = Remove-FICommentsOnly $hsrc; $Seen[$hp] = $true; Invoke-FiPpProcess $hc $Defines $Pinned ([IO.Path]::GetDirectoryName($hp)) $false ($Depth + 1) $IncludeDirs $Seen $null; $Seen.Remove($hp) }
                }
            }
            else {
                if ($Collect) { if ($emit) { [void]$Out.Add($line) } else { [void]$Out.Add('') } }
            }
        }
    }
}
function Invoke-FiResolve([string]$FilePath, [hashtable]$Defines, [hashtable]$Pinned, [string[]]$IncludeDirs) {
    try { $src = [IO.File]::ReadAllText($FilePath) } catch { return '' }
    $cc = Remove-FICommentsOnly $src
    $d = if ($Defines) { $Defines.Clone() } else { @{} }
    $base = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($FilePath))
    $seen = @{}; $seen[[IO.Path]::GetFullPath($FilePath)] = $true
    $out = New-Object System.Collections.Generic.List[string]
    Invoke-FiPpProcess $cc $d $Pinned $base $true 0 $IncludeDirs $seen $out
    return (Remove-FICommentsStrings ($out -join "`n"))
}

function Get-FiTokVal($t) {
    if ($t.K -eq 'num') { return [string]$t.V }
    if ($t.K -eq 'id' -and $t.V -ne 'defined') { return [string]$t.V }
    return $null
}
function Get-FiSortedValues($values) {
    $nums = @($values | Where-Object { $_ -match '^-?\d+$' } | Sort-Object { [int]$_ })
    $ids = @($values | Where-Object { $_ -notmatch '^-?\d+$' } | Sort-Object)
    return ((@($nums) + @($ids)) -join ';')
}

# 役割付きでスイッチを分類 (純PSフォールバック用)。name -> @{Count;Line;Values;SwRole;ValRole}
function Get-FiClassify([string]$Clean) {
    $info = @{}
    $cmps = @('==', '!=', '<', '>', '<=', '>=')
    $ens = {
        param($name, $ln)
        if (-not $info.ContainsKey($name)) { $info[$name] = @{ Count = 0; Line = $ln; Values = (New-Object System.Collections.Generic.List[string]); SwRole = $false; ValRole = $false } }
        $info[$name]
    }
    $addv = { param($e, $v) if ($null -ne $v -and -not $e.Values.Contains([string]$v)) { $e.Values.Add([string]$v) } }
    $ln = 0
    foreach ($line in ($Clean -split "`n")) {
        $ln++
        $m = $script:FiRxDir.Match($line); if (-not $m.Success) { continue }
        $kind = $m.Groups[1].Value; $rest = $m.Groups[2].Value
        if ($kind -eq 'ifdef' -or $kind -eq 'ifndef') {
            $idm = $script:FiRxId.Match($rest)
            if ($idm.Success) { $e = & $ens $idm.Value $ln; $e.Count++; $e.SwRole = $true; & $addv $e '1' }
        }
        elseif ($kind -eq 'if' -or $kind -eq 'elif') {
            $toks = ConvertTo-FiTokens $rest
            $handled = @{}
            for ($i = 0; $i -lt $toks.Count; $i++) {
                $t = $toks[$i]
                if ($t.K -eq 'op' -and $cmps -contains $t.V) {
                    $L = if ($i - 1 -ge 0) { $toks[$i - 1] } else { $null }
                    $R = if ($i + 1 -lt $toks.Count) { $toks[$i + 1] } else { $null }
                    $Lid = $L -and $L.K -eq 'id' -and $L.V -ne 'defined'
                    $Rid = $R -and $R.K -eq 'id' -and $R.V -ne 'defined'
                    if ($Lid -and $R -and $R.K -eq 'num') { $e = & $ens $L.V $ln; $e.Count++; $e.SwRole = $true; & $addv $e ([string]$R.V); $handled[$i - 1] = $true }
                    elseif ($Rid -and $L -and $L.K -eq 'num') { $e = & $ens $R.V $ln; $e.Count++; $e.SwRole = $true; & $addv $e ([string]$L.V); $handled[$i + 1] = $true }
                    elseif ($Lid -and $Rid) { $e = & $ens $L.V $ln; $e.Count++; $e.SwRole = $true; & $addv $e ([string]$R.V); (& $ens $R.V $ln).ValRole = $true; $handled[$i - 1] = $true; $handled[$i + 1] = $true }
                }
            }
            for ($i = 0; $i -lt $toks.Count; $i++) {
                if ($toks[$i].K -eq 'id' -and $toks[$i].V -eq 'defined') {
                    for ($j = $i + 1; $j -lt $toks.Count -and $j -lt $i + 3; $j++) {
                        if ($toks[$j].K -eq 'id') { $e = & $ens $toks[$j].V $ln; $e.Count++; $e.SwRole = $true; & $addv $e '1'; $handled[$j] = $true; break }
                    }
                }
            }
            for ($i = 0; $i -lt $toks.Count; $i++) {
                if ($toks[$i].K -eq 'id' -and $toks[$i].V -ne 'defined' -and -not $handled.ContainsKey($i)) { $e = & $ens $toks[$i].V $ln; $e.Count++; $e.SwRole = $true; & $addv $e '1' }
            }
        }
    }
    return $info
}
function Get-FiValueConsts([string]$Clean) {
    $vc = @{}
    $info = Get-FiClassify $Clean
    foreach ($k in $info.Keys) { if ($info[$k].ValRole -and -not $info[$k].SwRole) { $vc[$k] = $true } }
    return $vc
}

function Get-FiFileSwitches {
    <# 1ファイルのスイッチ名 -> @{Count;Line(初出);Values(List)} を返す。 #>
    param([string]$FilePath)
    $res = @{}
    try { $src = [System.IO.File]::ReadAllText($FilePath) } catch { return $res }
    if (Initialize-FiNative) {
        foreach ($s in $script:FiNativeType::CollectSwitches($src)) {
            $vals = New-Object System.Collections.Generic.List[string]
            foreach ($v in $s.Vals) { $vals.Add([string]$v) }
            $res[$s.Name] = @{ Count = $s.Count; Line = $s.Line; Values = $vals }
        }
        return $res
    }
    # --- 純 PowerShell フォールバック ---
    $info = Get-FiClassify (Remove-FICommentsStrings $src)
    foreach ($k in $info.Keys) {
        $e = $info[$k]
        if ($e.ValRole -and -not $e.SwRole) { continue }   # 値定数は除外
        $res[$k] = @{ Count = $e.Count; Line = $e.Line; Values = $e.Values }
    }
    return $res
}

function Get-CSwitch {
    <# 指定パスのスイッチ名 -> @{Count;File;Line}。File/Line は最初の出現箇所。 #>
    param([string[]]$Path, [string[]]$Extensions = @('.c', '.h'))
    $agg = @{}
    $files = Get-FITargetFiles -Paths $Path -Exts $Extensions
    $total = $files.Count; $i = 0
    foreach ($f in $files) {
        $i++
        Write-Progress -Activity 'FuncInspector' -Status ("スイッチ検出 {0}/{1} {2}" -f $i, $total, $f) -PercentComplete ($(if ($total) { $i * 100 / $total } else { 100 }))
        $fs = Get-FiFileSwitches -FilePath $f
        foreach ($name in $fs.Keys) {
            if (-not $agg.ContainsKey($name)) {
                $agg[$name] = [pscustomobject]@{ Count = 0; File = $f; Line = $fs[$name].Line; Values = (New-Object System.Collections.Generic.List[string]) }
            }
            $agg[$name].Count += $fs[$name].Count
            foreach ($v in $fs[$name].Values) { if (-not $agg[$name].Values.Contains([string]$v)) { $agg[$name].Values.Add([string]$v) } }
        }
    }
    Write-Progress -Activity 'FuncInspector' -Completed
    return $agg
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
                    $i = $close + 1   # 本体は再走査しない
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
        [string[]]$Pinned,
        [switch]$IgnoreSwitches,
        [switch]$External,
        [switch]$Resolve,
        [string[]]$IncludeDirs
    )
    try { $src = [System.IO.File]::ReadAllText($FilePath) }
    catch { Write-Warning "読み込み失敗: $FilePath"; return @() }

    if (Initialize-FiNative) {
        $nd = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        if ($Defines) { foreach ($k in $Defines.Keys) { $nd[[string]$k] = [string]$Defines[$k] } }
        $np = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($p in ($Pinned | Where-Object { $_ })) { [void]$np.Add([string]$p) }
        if ($Resolve -and -not $IgnoreSwitches) {
            return $script:FiNativeType::AnalyzeResolve($FilePath, $nd, $np, [string[]]($IncludeDirs))
        }
        return $script:FiNativeType::Analyze($FilePath, $src, $nd, [bool]$IgnoreSwitches, $np, [bool]$External)
    }

    # --- 純 PowerShell フォールバック ---
    if ($Resolve -and -not $IgnoreSwitches) {
        $pin = @{}
        foreach ($p in ($Pinned | Where-Object { $_ })) { $pin[[string]$p] = $true }
        $clean = Invoke-FiResolve $FilePath ($Defines) $pin $IncludeDirs
        return Get-FiScan $FilePath $clean
    }
    $clean = Remove-FICommentsStrings $src
    if (-not $IgnoreSwitches) {
        $d = if ($Defines) { $Defines.Clone() } else { @{} }
        $pin = @{}
        foreach ($p in ($Pinned | Where-Object { $_ })) { $pin[[string]$p] = $true }
        $vc = if ($External) { Get-FiValueConsts $clean } else { @{} }
        $clean = Invoke-FiPreprocess $clean $d $pin -External:$External -ValConsts $vc
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
    $form.Size = New-Object System.Drawing.Size(920, 650)
    $form.StartPosition = 'CenterScreen'

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'フォルダ/ファイル:'; $lbl.Location = '10,15'; $lbl.AutoSize = $true
    $form.Controls.Add($lbl)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = '120,12'; $tb.Size = '560,24'; $tb.Anchor = 'Top,Left,Right'
    $form.Controls.Add($tb)
    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'フォルダ...'; $btnFolder.Location = '690,11'; $btnFolder.Size = '90,25'; $btnFolder.Anchor = 'Top,Right'
    $btnFolder.Add_Click({ $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.SelectedPath } })
    $form.Controls.Add($btnFolder)
    $btnFile = New-Object System.Windows.Forms.Button
    $btnFile.Text = 'ファイル...'; $btnFile.Location = '785,11'; $btnFile.Size = '90,25'; $btnFile.Anchor = 'Top,Right'
    $btnFile.Add_Click({ $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter = 'C source|*.c;*.h|All|*.*'; if ($dlg.ShowDialog() -eq 'OK') { $tb.Text = $dlg.FileName } })
    $form.Controls.Add($btnFile)

    $lblExt = New-Object System.Windows.Forms.Label
    $lblExt.Text = '拡張子:'; $lblExt.Location = '10,48'; $lblExt.AutoSize = $true
    $form.Controls.Add($lblExt)
    $tbExt = New-Object System.Windows.Forms.TextBox
    $tbExt.Location = '120,45'; $tbExt.Size = '120,24'; $tbExt.Text = '.c,.h'
    $form.Controls.Add($tbExt)
    # スイッチ表で選んだものだけを有効化 (ソース内 #define は常に無視)。
    # 全部見たいときだけ「全コード有効」を使う。
    $cbIgnore = New-Object System.Windows.Forms.CheckBox
    $cbIgnore.Text = '全コード有効(スイッチ無視)'; $cbIgnore.Location = '260,46'; $cbIgnore.AutoSize = $true
    $form.Controls.Add($cbIgnore)
    # include 解決 (スイッチ追跡/重い)。別ファイルの #define まで反映。
    $cbResolve = New-Object System.Windows.Forms.CheckBox
    $cbResolve.Text = '実設定で解決 (別ファイルの #define も反映・重い)'; $cbResolve.Location = '440,46'; $cbResolve.AutoSize = $true
    $form.Controls.Add($cbResolve)
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($cbResolve, '別ファイル(config.h 等)の #define まで解決して実ビルド準拠で判定 (対象ツリーは自動検索)')

    # --- スイッチ ペイン (左) ---
    $lblSw = New-Object System.Windows.Forms.Label
    $lblSw.Text = 'スイッチ (ON=有効 / 値=プルダウン / 初出をダブルクリックで開く)'; $lblSw.Location = '10,78'; $lblSw.AutoSize = $true
    $form.Controls.Add($lblSw)
    $lblSwFil = New-Object System.Windows.Forms.Label
    $lblSwFil.Text = '絞り込み:'; $lblSwFil.Location = '10,101'; $lblSwFil.AutoSize = $true
    $form.Controls.Add($lblSwFil)
    $tbSwFilter = New-Object System.Windows.Forms.TextBox
    $tbSwFilter.Location = '75,98'; $tbSwFilter.Size = '235,22'; $tbSwFilter.Anchor = 'Top,Left'
    $form.Controls.Add($tbSwFilter)

    $swlv = New-Object System.Windows.Forms.DataGridView
    $swlv.Location = '10,126'; $swlv.Size = '300,404'; $swlv.Anchor = 'Top,Bottom,Left'
    $swlv.AllowUserToAddRows = $false; $swlv.AllowUserToDeleteRows = $false; $swlv.AllowUserToResizeRows = $false
    $swlv.RowHeadersVisible = $false; $swlv.AutoSizeColumnsMode = 'None'
    $swlv.SelectionMode = 'CellSelect'; $swlv.EditMode = 'EditOnEnter'
    $swlv.AllowUserToResizeColumns = $true   # 列境界をドラッグして幅変更可
    $swlv.ScrollBars = 'Both'
    # 右の一覧と見た目を揃える: 白背景・テーマ準拠ヘッダ・沈みボーダー・薄いグリッド線・青選択
    $swlv.BackgroundColor = [System.Drawing.Color]::White
    $swlv.BorderStyle = 'Fixed3D'
    $swlv.EnableHeadersVisualStyles = $true
    $swlv.ColumnHeadersHeightSizeMode = 'DisableResizing'; $swlv.ColumnHeadersHeight = 22
    $swlv.GridColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
    $swlv.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
    $swlv.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(51, 153, 255)
    $swlv.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $colOn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colOn.HeaderText = 'ON'; $colOn.Name = 'On'; $colOn.Width = 34
    $colSw = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSw.HeaderText = 'Switch'; $colSw.Name = 'Sw'; $colSw.Width = 112; $colSw.ReadOnly = $true
    $colVal = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colVal.HeaderText = '値'; $colVal.Name = 'Val'; $colVal.Width = 70; $colVal.FlatStyle = 'Flat'
    $colLoc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLoc.HeaderText = '初出'; $colLoc.Name = 'Loc'; $colLoc.Width = 78; $colLoc.ReadOnly = $true
    [void]$swlv.Columns.Add($colOn)
    [void]$swlv.Columns.Add($colSw)
    [void]$swlv.Columns.Add($colVal)
    [void]$swlv.Columns.Add($colLoc)
    $swlv.Add_DataError({ param($eSender, $e) $e.ThrowException = $false })  # 値が候補外でも例外にしない
    $swlv.Add_CellDoubleClick({
            param($eSender, $e)
            if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) {
                $info = $swlv.Rows[$e.RowIndex].Tag
                if ($info) { Open-FiLocation $info.File ([int]$info.Line) }
            }
        })
    # 行クリックで「到達条件」(初出に達するための囲み条件) をステータスに表示
    $swlv.Add_CellClick({
            param($eSender, $e)
            if ($e.RowIndex -ge 0) {
                $row = $swlv.Rows[$e.RowIndex]
                if ($row.Tag) {
                    $cond = Get-FiReachCondition $row.Tag.File ([int]$row.Tag.Line)
                    $status.Text = ("{0} の到達条件: {1}" -f $row.Cells['Sw'].Value, $cond)
                }
            }
        })
    # チェック/コンボの編集を即確定
    $swlv.Add_CurrentCellDirtyStateChanged({ if ($swlv.IsCurrentCellDirty) { $swlv.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) } })
    $form.Controls.Add($swlv)

    $btnDetect = New-Object System.Windows.Forms.Button
    $btnDetect.Text = 'スイッチ検出'; $btnDetect.Location = '10,535'; $btnDetect.Size = '230,26'; $btnDetect.Anchor = 'Bottom,Left'
    $form.Controls.Add($btnDetect)
    $btnHelp = New-Object System.Windows.Forms.Button
    $btnHelp.Text = '説明'; $btnHelp.Location = '246,535'; $btnHelp.Size = '64,26'; $btnHelp.Anchor = 'Bottom,Left'
    $form.Controls.Add($btnHelp)

    # --- 関数 ペイン (右) ---
    $lblFn = New-Object System.Windows.Forms.Label
    $lblFn.Text = '関数 (ダブルクリックで開く)'; $lblFn.Location = '322,78'; $lblFn.AutoSize = $true
    $form.Controls.Add($lblFn)
    $lblFnFil = New-Object System.Windows.Forms.Label
    $lblFnFil.Text = '関数名で絞り込み:'; $lblFnFil.Location = '322,101'; $lblFnFil.AutoSize = $true
    $form.Controls.Add($lblFnFil)
    $tbFnFilter = New-Object System.Windows.Forms.TextBox
    $tbFnFilter.Location = '440,98'; $tbFnFilter.Size = '454,22'; $tbFnFilter.Anchor = 'Top,Left,Right'
    $form.Controls.Add($tbFnFilter)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = '322,126'; $lv.Size = '572,404'; $lv.Anchor = 'Top,Bottom,Left,Right'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
    [void]$lv.Columns.Add('File', 300)
    [void]$lv.Columns.Add('Line', 55)
    [void]$lv.Columns.Add('Function', 150)
    [void]$lv.Columns.Add('Steps', 55)
    $lv.Add_DoubleClick({
            if ($lv.SelectedItems.Count -gt 0) { $r = $lv.SelectedItems[0]; Open-FiLocation $r.Text ([int]$r.SubItems[1].Text) }
        })
    $form.Controls.Add($lv)

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Location = '322,540'; $pb.Size = '330,18'; $pb.Anchor = 'Bottom,Left'; $pb.Minimum = 0; $pb.Maximum = 1
    $form.Controls.Add($pb)
    $status = New-Object System.Windows.Forms.Label
    $status.Location = '322,565'; $status.Size = '470,20'; $status.Text = '準備完了'; $status.Anchor = 'Bottom,Left'
    $form.Controls.Add($status)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = 'スキャン'; $btnScan.Location = '672,535'; $btnScan.Size = '95,28'; $btnScan.Anchor = 'Bottom,Right'
    $form.Controls.Add($btnScan)
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'CSV 保存'; $btnSave.Location = '775,535'; $btnSave.Size = '100,28'; $btnSave.Anchor = 'Bottom,Right'
    $form.Controls.Add($btnSave)

    $script:FIguiRows = @()
    $script:FiSync = $null; $script:FiPS = $null; $script:FiRS = $null; $script:FiHandle = $null

    # バックグラウンド実行用スクリプト
    $sbScan = {
        param($sync, $corePath, $pathArg, $exts, $defines, $ignore, $external, $resolve, $incdirs)
        try {
            . $corePath
            $files = Get-FITargetFiles -Paths @($pathArg) -Exts $exts
            $sync.Total = $files.Count
            $rows = New-Object System.Collections.Generic.List[object]
            $i = 0
            $pinned = [string[]]$defines.Keys
            $searchdirs = $incdirs
            if ($resolve) { $searchdirs = @($incdirs) + (Get-FiAutoIncludeDirs @($pathArg)) }
            foreach ($f in $files) {
                $i++; $sync.Progress = $i; $sync.Current = $f
                foreach ($r in (Find-CFunctions -FilePath $f -Defines $defines -Pinned $pinned -IgnoreSwitches:$ignore -External:$external -Resolve:$resolve -IncludeDirs $searchdirs)) { $rows.Add($r) }
            }
            $sync.Result = $rows
        } catch { $sync.Error = $_.Exception.Message }
        finally { $sync.Done = $true }
    }
    $sbSwitch = {
        param($sync, $corePath, $pathArg, $exts, $resolve, $incdirs)
        try {
            . $corePath
            $files = Get-FITargetFiles -Paths @($pathArg) -Exts $exts
            $sync.Total = $files.Count
            $agg = @{}
            $resolved = @{}   # include解決時: 実際に定義されたスイッチ name->value (有効スイッチ)
            $searchdirs = if ($resolve) { @($incdirs) + (Get-FiAutoIncludeDirs @($pathArg)) } else { $incdirs }
            $i = 0
            foreach ($f in $files) {
                $i++; $sync.Progress = $i; $sync.Current = $f
                $fs = Get-FiFileSwitches -FilePath $f
                foreach ($name in $fs.Keys) {
                    if (-not $agg.ContainsKey($name)) {
                        $agg[$name] = [pscustomobject]@{ Count = 0; File = $f; Line = $fs[$name].Line; Values = (New-Object System.Collections.Generic.List[string]) }
                    }
                    $agg[$name].Count += $fs[$name].Count
                    foreach ($v in $fs[$name].Values) { if (-not $agg[$name].Values.Contains([string]$v)) { $agg[$name].Values.Add([string]$v) } }
                }
                if ($resolve) {
                    $rd = Get-FiResolvedDefines -FilePath $f -IncludeDirs $searchdirs
                    foreach ($k in $rd.Keys) { $resolved[$k] = $rd[$k] }
                }
            }
            $sync.Result = $agg
            $sync.Resolved = $resolved
        } catch { $sync.Error = $_.Exception.Message }
        finally { $sync.Done = $true }
    }

    function StartBg([string]$mode) {
        if (-not $tb.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('フォルダかファイルを指定してください。') | Out-Null; return }
        if (-not $script:FiScriptPath) { [System.Windows.Forms.MessageBox]::Show('コアスクリプトのパスが取得できませんでした。') | Out-Null; return }
        $exts = $tbExt.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if (-not $exts) { $exts = @('.c', '.h') }
        $script:FiSync = [hashtable]::Synchronized(@{ Progress = 0; Total = 0; Current = ''; Done = $false; Result = $null; Error = $null; Mode = $mode })
        $btnScan.Enabled = $false; $btnDetect.Enabled = $false; $btnSave.Enabled = $false
        $pb.Value = 0; $status.Text = '開始...'
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        if ($mode -eq 'switch') {
            # include解決時は「実際に有効なスイッチ」を算出して自動チェックする
            [void]$ps.AddScript($sbSwitch.ToString()).AddArgument($script:FiSync).AddArgument($script:FiScriptPath).AddArgument($tb.Text.Trim()).AddArgument($exts).AddArgument([bool]$cbResolve.Checked).AddArgument(@())
        }
        else {
            $defines = @{}
            # DataGridView の ON 行: 値コンボの選択値で定義 (空なら 1)
            foreach ($row in $swlv.Rows) {
                if ($row.Cells['On'].Value -eq $true) {
                    $nm = [string]$row.Cells['Sw'].Value
                    if (-not $nm) { continue }
                    $val = [string]$row.Cells['Val'].Value
                    if (-not $val) { $val = '1' }
                    $defines[$nm] = $val
                }
            }
            $resolve = [bool]$cbResolve.Checked
            $incdirs = @()   # GUI は対象ツリーを自動検索 (-I 指定欄は廃止)
            # include 解決時は cpp 準拠 (external は使わない)。非解決時は選択スイッチのみ有効。
            [void]$ps.AddScript($sbScan.ToString()).AddArgument($script:FiSync).AddArgument($script:FiScriptPath).AddArgument($tb.Text.Trim()).AddArgument($exts).AddArgument($defines).AddArgument([bool]$cbIgnore.Checked).AddArgument(-not $resolve).AddArgument($resolve).AddArgument($incdirs)
        }
        $script:FiPS = $ps; $script:FiRS = $rs; $script:FiHandle = $ps.BeginInvoke()
        $timer.Start()
    }

    # 関数一覧の絞り込み表示 (関数名に部分一致)
    function Update-FnView {
        $q = $tbFnFilter.Text.Trim()
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $shown = 0; $tot = 0
        foreach ($r in $script:FIguiRows) {
            $tot += $r.Steps
            if ($q) {
                $fn = [string]$r.Function
                if ($fn.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            }
            $it = New-Object System.Windows.Forms.ListViewItem([string]$r.File)
            [void]$it.SubItems.Add([string]$r.Line)
            [void]$it.SubItems.Add([string]$r.Function)
            [void]$it.SubItems.Add([string]$r.Steps)
            [void]$lv.Items.Add($it)
            $shown++
        }
        $lv.EndUpdate()
        if ($q) { $status.Text = ("{0}/{1} 関数 (絞り込み '{2}') / 合計 {3} ステップ" -f $shown, $script:FIguiRows.Count, $q, $tot) }
        else { $status.Text = ("{0} 関数 / 合計 {1} ステップ (ダブルクリックで開く)" -f $script:FIguiRows.Count, $tot) }
    }
    # スイッチ表の絞り込み (Switch 名に部分一致)。ON/値の状態は保持 (行の表示を切替)。
    function Update-SwView {
        $q = $tbSwFilter.Text.Trim()
        try { $swlv.EndEdit() } catch {}
        try { $swlv.CurrentCell = $null } catch {}
        foreach ($row in $swlv.Rows) {
            $nm = [string]$row.Cells['Sw'].Value
            $vis = $true
            if ($q -and $nm.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $vis = $false }
            if ($row.Visible -ne $vis) { $row.Visible = $vis }
        }
    }
    $tbFnFilter.Add_TextChanged({ if ($script:FIguiRows) { Update-FnView } })
    $tbSwFilter.Add_TextChanged({ Update-SwView })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
            $s = $script:FiSync
            if ($null -eq $s) { return }
            if ([int]$s.Total -gt 0) { $pb.Maximum = [int]$s.Total; $pb.Value = [Math]::Min([int]$s.Progress, [int]$s.Total) }
            $cur = if ($s.Current) { [System.IO.Path]::GetFileName([string]$s.Current) } else { '' }
            $status.Text = ("処理中... {0}/{1}  {2}" -f $s.Progress, $s.Total, $cur)
            if ($s.Done) {
                $timer.Stop()
                try { $script:FiPS.EndInvoke($script:FiHandle) } catch {}
                if ($script:FiPS) { $script:FiPS.Dispose() }
                if ($script:FiRS) { $script:FiRS.Dispose() }
                if ($s.Error) {
                    [System.Windows.Forms.MessageBox]::Show([string]$s.Error) | Out-Null
                    $status.Text = 'エラー'
                }
                elseif ($s.Mode -eq 'switch') {
                    $agg = $s.Result
                    $swlv.Rows.Clear()
                    foreach ($name in ($agg.Keys | Sort-Object)) {
                        $info = $agg[$name]
                        $vals = @((Get-FiSortedValues $info.Values) -split ';' | Where-Object { $_ })
                        if (-not $vals) { $vals = @('1') }
                        $loc = ("{0}:{1}" -f [System.IO.Path]::GetFileName([string]$info.File), $info.Line)
                        $idx = $swlv.Rows.Add($false, [string]$name, $null, $loc)
                        $cell = $swlv.Rows[$idx].Cells['Val']
                        foreach ($v in $vals) { [void]$cell.Items.Add([string]$v) }
                        $cell.Value = $vals[0]
                        # 値候補が1つだけ (#ifdef / ブール / ==単一値) はプルダウン不要 → グレーアウト
                        if ($vals.Count -le 1) {
                            $cell.ReadOnly = $true
                            $cell.Style.BackColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
                            $cell.Style.ForeColor = [System.Drawing.Color]::Gray
                        }
                        $swlv.Rows[$idx].Tag = $info
                    }
                    # include解決時: 実際に有効だったスイッチを ON にし、値も反映
                    $resolved = $s.Resolved
                    if ($resolved -and $resolved.Count) {
                        foreach ($row in $swlv.Rows) {
                            $nm = [string]$row.Cells['Sw'].Value
                            if ($resolved.ContainsKey($nm)) {
                                $row.Cells['On'].Value = $true
                                $rv = [string]$resolved[$nm]
                                if ($rv) {
                                    $vc = $row.Cells['Val']
                                    if (-not $vc.Items.Contains($rv)) { [void]$vc.Items.Add($rv) }
                                    $vc.Value = $rv
                                }
                            }
                        }
                    }
                    # Switch 列を内容に合わせて自動フィット (以降も列境界ドラッグで変更可)
                    try { $swlv.AutoResizeColumn(1); if ($swlv.Columns[1].Width -gt 260) { $swlv.Columns[1].Width = 260 } } catch {}
                    Update-SwView   # 現在の絞り込みを反映
                    $msg = if ($resolved -and $resolved.Count) { "完了: {0} 個 (include解決: 有効スイッチを自動チェック)" } else { "完了: {0} 個のスイッチ (行クリックで到達条件を表示)" }
                    $status.Text = ($msg -f $agg.Count)
                }
                else {
                    $script:FIguiRows = $s.Result
                    Update-FnView   # 現在の絞り込みを反映して一覧表示
                }
                $pb.Value = 0
                $btnScan.Enabled = $true; $btnDetect.Enabled = $true; $btnSave.Enabled = $true
            }
        })

    $btnDetect.Add_Click({ StartBg 'switch' })
    $btnScan.Add_Click({ StartBg 'scan' })
    $btnSave.Add_Click({
            if (-not $script:FIguiRows -or $script:FIguiRows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('先にスキャンしてください。') | Out-Null; return }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'CSV|*.csv|All|*.*'; $dlg.DefaultExt = 'csv'
            if ($dlg.ShowDialog() -eq 'OK') {
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine('filepath,line,funcname,steps')
                foreach ($r in $script:FIguiRows) { [void]$sb.AppendLine(("{0},{1},{2},{3}" -f $r.File, $r.Line, $r.Function, $r.Steps)) }
                [System.IO.File]::WriteAllText($dlg.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
                $status.Text = ("保存しました: {0}" -f $dlg.FileName)
            }
        })

    $script:FiHelpText = @'
FuncInspector の使い方 — 「何をすると何が検出対象になるか」

■ 基本
  関数定義 ( ... ) { ... } の関数名を抽出します。
  プロトタイプ宣言・関数呼び出し・コメント/文字列内は対象外。
  WINAMS などのマクロが関数名の前に付いていても対応します。

■ 画面
  左 = スイッチ表 / 右 = 検出された関数一覧。
  上の「フォルダ...」「ファイル...」で対象を指定 →「スキャン」。
  「スイッチ検出」で左の表にスイッチと値候補が出ます。

■ スイッチ表（左）の使い方
  ・ON   … そのスイッチを「定義された」状態にする。
  ・値   … プルダウンで値を選ぶ（例 TOOL_TEST = 1 / 2）。
           候補が1つだけ（#ifdef など）はグレー＝値選択は不要。
  ・初出 … セルをダブルクリックでソースの該当箇所を開く。
  ・行クリック … その関数群に到達するための条件(囲みの #if)をステータス表示。
  ・列幅 … Switch 列は内容に自動フィット。列境界のドラッグでも変更可。
  ・絞り込み … スイッチ名で表示を絞る（ON/値の選択は保持）。

■ 検出対象の決まり方（重要）
  (1) 何も選択しない【既定＝選択スイッチのみ有効】
      → #if 条件を評価。未選択のスイッチは OFF（未定義）。
      → #ifdef や #if X==1 の中の関数は出ない。
        #else 側・無条件の関数だけが出る。
      → ソース内の #define は無視（選択がすべて）。

  (2) スイッチを ON にして値を選ぶ
      → そのスイッチが定義され、対応する #if 枝の関数が出る。
        例: TOOL_TEST=1 → #if TOOL_TEST==1 の関数。

  (3)「全コード有効(スイッチ無視)」にチェック
      → #if を一切評価せず、すべての枝の関数を出す。
        排他の枝（#if と #else）も両方出るので最大集合。
        実際には同時にコンパイルされない関数も含む＝多めに出る。

  (4)「実設定で解決」にチェック ＝ 別ファイルの #define も反映(実ビルド準拠/重い)
      → #include "..." をたどり config.h 等の #define を反映。対象フォルダは自動検索。
        ・値あり #define X 10＝その値 / フラグ(値なし #define X)＝ON。連鎖も自動。
        ・「スイッチ検出」すると、ソースで実際に有効なスイッチが自動でON＋値が入る。
        ・実値と違う枝（CFG_NUM=10 で #if CFG_NUM==5）は出ない。
        ・外す=-U / 値変更=-D（常に優先）。全部OFFから足すなら通常(軽量)モード。

■ 「関数数が違う」のはなぜ？
  ・全コード有効   … すべての枝（多い／上限）
  ・何も選択しない … スイッチ全OFFのときに有効な枝だけ（少ない）
  ・ON選択/実設定で解決 … その構成で実際に有効な関数（実ビルド寄り）

■ 関数一覧（右）
  ・絞り込み … 関数名で絞る。
  ・行をダブルクリックでソースの該当行を開く。
  ・「CSV 保存」で filepath,line,funcname,steps を保存。

■ ステップ数
  関数本体の実行行数（空行・コメント・波括弧だけの行は除く）。
'@
    $btnHelp.Add_Click({
            $hf = New-Object System.Windows.Forms.Form
            $hf.Text = 'FuncInspector の説明'
            $hf.Size = New-Object System.Drawing.Size(660, 600)
            $hf.StartPosition = 'CenterParent'
            $hf.MinimizeBox = $false; $hf.MaximizeBox = $true
            $tbh = New-Object System.Windows.Forms.TextBox
            $tbh.Multiline = $true; $tbh.ReadOnly = $true; $tbh.ScrollBars = 'Vertical'
            $tbh.WordWrap = $true; $tbh.Dock = 'Fill'
            $tbh.BackColor = [System.Drawing.Color]::White
            try { $tbh.Font = New-Object System.Drawing.Font('Yu Gothic UI', 10) } catch {}
            $tbh.Text = ($script:FiHelpText -replace "`r?`n", "`r`n")
            $tbh.Select(0, 0)
            $hf.Controls.Add($tbh)
            $btnClose = New-Object System.Windows.Forms.Button
            $btnClose.Text = '閉じる'; $btnClose.Dock = 'Bottom'; $btnClose.Height = 30
            $btnClose.Add_Click({ $hf.Close() })
            $hf.Controls.Add($btnClose)
            [void]$hf.ShowDialog($form)
            $hf.Dispose()
        })

    $form.Add_FormClosed({ if ($script:FiTimer) { $script:FiTimer.Stop() } })
    $script:FiTimer = $timer
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
        [switch]$NoHeader,
        [switch]$Gui,
        [switch]$ListSwitches,
        [Alias('D')][string[]]$Define,
        [Alias('U')][string[]]$Undef,
        [switch]$IgnoreSwitches,
        [switch]$ExternalSwitches,
        [switch]$ResolveIncludes,
        [Alias('I')][string[]]$IncludeDirs,
        [switch]$AsObject
    )

    if ($Gui -or (-not $Path -or $Path.Count -eq 0)) { Show-FuncInspectorGui; return }

    # defines 構築 (+ pinned: -D/-U で固定する名前)
    $defines = @{}
    $pinned = New-Object System.Collections.Generic.List[string]
    foreach ($d in ($Define | Where-Object { $_ })) {
        if ($d.Contains('=')) { $kv = $d.Split('=', 2); $n = $kv[0].Trim(); $defines[$n] = $kv[1] }
        else { $n = $d.Trim(); $defines[$n] = '1' }
        $pinned.Add($n)
    }
    foreach ($u in ($Undef | Where-Object { $_ })) { $n = $u.Trim(); $defines.Remove($n); $pinned.Add($n) }

    # スイッチ一覧モード
    if ($ListSwitches) {
        $agg = Get-CSwitch -Path $Path -Extensions $Extensions
        $rows = foreach ($name in ($agg.Keys | Sort-Object)) {
            $st = if ($defines.ContainsKey($name)) { 'ON' } else { 'OFF' }
            [pscustomobject]@{ Switch = $name; Occurrences = $agg[$name].Count; State = $st; File = $agg[$name].File; Line = $agg[$name].Line; Values = (Get-FiSortedValues $agg[$name].Values) }
        }
        if ($AsObject) { return $rows }
        $lines = New-Object System.Collections.Generic.List[string]
        if (-not $NoHeader) { $lines.Add('switch,occurrences,state,filepath,line,values') }
        foreach ($r in $rows) { $lines.Add(("{0},{1},{2},{3},{4},{5}" -f $r.Switch, $r.Occurrences, $r.State, $r.File, $r.Line, $r.Values)) }
        $text = [string]::Join("`r`n", $lines)
        if ($Out) { [System.IO.File]::WriteAllText($Out, $text + "`r`n", [System.Text.Encoding]::UTF8); Write-Host ("{0} に書き出しました" -f $Out) }
        elseif ($text) { Write-Output $text }
        Write-Host ("{0} 個のスイッチ" -f $agg.Count) -ForegroundColor DarkGray
        return
    }

    # 関数抽出モード
    $rows = New-Object System.Collections.Generic.List[object]
    $files = Get-FITargetFiles -Paths $Path -Exts $Extensions
    # resolve モード: 明示 -I (優先) + スキャン対象ツリーの自動検索
    $resolveDirs = $IncludeDirs
    if ($ResolveIncludes) { $resolveDirs = @($IncludeDirs) + (Get-FiAutoIncludeDirs $Path) }
    $total = $files.Count; $i = 0
    foreach ($f in $files) {
        $i++
        Write-Progress -Activity 'FuncInspector' -Status ("解析 {0}/{1} {2}" -f $i, $total, $f) -PercentComplete ($(if ($total) { $i * 100 / $total } else { 100 }))
        foreach ($r in (Find-CFunctions -FilePath $f -Defines $defines -Pinned $pinned.ToArray() -IgnoreSwitches:$IgnoreSwitches -External:$ExternalSwitches -Resolve:$ResolveIncludes -IncludeDirs $resolveDirs)) { $rows.Add($r) }
    }
    Write-Progress -Activity 'FuncInspector' -Completed
    if ($AsObject) { return $rows }

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not $NoHeader) { $lines.Add('filepath,line,funcname,steps') }
    foreach ($r in $rows) { $lines.Add(("{0},{1},{2},{3}" -f $r.File, $r.Line, $r.Function, $r.Steps)) }
    $text = [string]::Join("`r`n", $lines)
    $tot = ($rows | Measure-Object -Property Steps -Sum).Sum
    if ($Out) { [System.IO.File]::WriteAllText($Out, $text + "`r`n", [System.Text.Encoding]::UTF8); Write-Host ("{0} に書き出しました" -f $Out) }
    elseif ($text) { Write-Output $text }
    Write-Host ("{0} 関数 / 合計 {1} ステップ" -f $rows.Count, ([int]$tot)) -ForegroundColor DarkGray
}

Set-Alias -Name funcinspect -Value Invoke-FuncInspector -Scope Global -ErrorAction SilentlyContinue
