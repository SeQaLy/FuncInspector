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
    try { $script:FiNativeType = [FuncInspectorNativeV4.Engine]; return $true } catch {}
    $code = @'
using System;
using System.Collections.Generic;
namespace FuncInspectorNativeV4 {
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

    public static string Preprocess(string clean,Dictionary<string,string> defs,HashSet<string> pinned,bool external){
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
          else if(kind==7){ if(emit && !external){ int after; string nm=FirstIdentAfter(b,rest,le,out after); if(nm!=null && !pinned.Contains(nm)){ int vs=after; while(vs<le && (b[vs]==' '||b[vs]=='\t')) vs++; int ve=le; while(ve>vs && (b[ve-1]==' '||b[ve-1]=='\t'||b[ve-1]=='\r')) ve--; string val= ve>vs? new string(b,vs,ve-vs) : "1"; defs[nm]=val; } } }
          else if(kind==8){ if(emit && !external){ string nm=FirstIdent(b,rest,le); if(nm!=null && !pinned.Contains(nm) && defs.ContainsKey(nm)) defs.Remove(nm); } }
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
      if(!ignore){ var d=new Dictionary<string,string>(defs); clean=Preprocess(clean,d,pinned,external); }
      return Scan(path,clean);
    }
    static Sw GetOrAdd(Dictionary<string,Sw> map,string name,int line){ Sw s; if(!map.TryGetValue(name,out s)){ s=new Sw{Name=name,Count=0,Line=line}; map[name]=s; } s.Count++; return s; }
    static void AddVal(Sw s,string v){ if(string.IsNullOrEmpty(v)) return; if(!s.Vals.Contains(v)) s.Vals.Add(v); }
    static string TokVal(Tok t){ if(t.Kind==0) return t.Num.ToString(); if(t.Kind==1 && t.Id!="defined") return t.Id; return null; }
    static bool IsCmp(Tok t){ return t.Kind==2 && (t.Id=="=="||t.Id=="!="||t.Id=="<"||t.Id==">"||t.Id=="<="||t.Id==">="); }
    public static List<Sw> CollectSwitches(string src){
      string clean=Strip(src); char[] b=clean.ToCharArray(); int n=b.Length;
      var map=new Dictionary<string,Sw>(); int ls=0; int lineno=0;
      while(ls<=n){ lineno++; int le=ls; while(le<n && b[le]!='\n') le++;
        int rest; int kind=ParseDirective(b,ls,le,out rest);
        if(kind==1||kind==2){ string nm=FirstIdent(b,rest,le); if(nm!=null) AddVal(GetOrAdd(map,nm,lineno),"1"); }
        else if(kind==3||kind==4){
          var toks=Tokenize(b,rest,le); var compared=new HashSet<string>();
          for(int i=0;i<toks.Count;i++){ if(IsCmp(toks[i])){
            Tok L=i-1>=0?toks[i-1]:null; Tok R=i+1<toks.Count?toks[i+1]:null;
            if(L!=null && L.Kind==1 && L.Id!="defined" && R!=null){ string v=TokVal(R); if(v!=null){ AddVal(GetOrAdd(map,L.Id,lineno),v); compared.Add(L.Id); } }
            if(R!=null && R.Kind==1 && R.Id!="defined" && L!=null){ string v=TokVal(L); if(v!=null){ AddVal(GetOrAdd(map,R.Id,lineno),v); compared.Add(R.Id); } }
          } }
          for(int i=0;i<toks.Count;i++){ if(toks[i].Kind==1 && toks[i].Id=="defined"){ for(int j=i+1;j<toks.Count && j<i+3;j++){ if(toks[j].Kind==1){ AddVal(GetOrAdd(map,toks[j].Id,lineno),"1"); compared.Add(toks[j].Id); break; } } } }
          for(int i=0;i<toks.Count;i++){ if(toks[i].Kind==1 && toks[i].Id!="defined" && !compared.Contains(toks[i].Id)){ AddVal(GetOrAdd(map,toks[i].Id,lineno),"1"); } }
        }
        if(le>=n) break; ls=le+1;
      }
      return new List<Sw>(map.Values);
    }
  }
}
'@
    try {
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
        $script:FiNativeType = [FuncInspectorNativeV4.Engine]
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
    param([string]$Clean, [hashtable]$Defines, [hashtable]$Pinned = @{}, [switch]$External)
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
                    if ((Test-FiEmitting $stack) -and -not $External) {
                        $idm = $script:FiRxId.Match($rest)
                        if ($idm.Success -and -not $Pinned.ContainsKey($idm.Value)) {
                            $after = $rest.Substring($idm.Index + $idm.Length).Trim()
                            if ($after -eq '') { $after = '1' }
                            $Defines[$idm.Value] = $after
                        }
                    }
                }
                'undef' {
                    if ((Test-FiEmitting $stack) -and -not $External) {
                        $idm = $script:FiRxId.Match($rest)
                        if ($idm.Success -and -not $Pinned.ContainsKey($idm.Value) -and $Defines.ContainsKey($idm.Value)) { $Defines.Remove($idm.Value) }
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
    $clean = Remove-FICommentsStrings $src
    $cmps = @('==', '!=', '<', '>', '<=', '>=')
    $addsw = {
        param($name, $ln, $val)
        if (-not $res.ContainsKey($name)) { $res[$name] = @{ Count = 0; Line = $ln; Values = (New-Object System.Collections.Generic.List[string]) } }
        $res[$name].Count++
        if ($null -ne $val -and -not $res[$name].Values.Contains($val)) { $res[$name].Values.Add($val) }
    }
    $ln = 0
    foreach ($line in ($clean -split "`n")) {
        $ln++
        $m = $script:FiRxDir.Match($line)
        if (-not $m.Success) { continue }
        $kind = $m.Groups[1].Value; $rest = $m.Groups[2].Value
        if ($kind -eq 'ifdef' -or $kind -eq 'ifndef') {
            $idm = $script:FiRxId.Match($rest)
            if ($idm.Success) { & $addsw $idm.Value $ln '1' }
        }
        elseif ($kind -eq 'if' -or $kind -eq 'elif') {
            $toks = ConvertTo-FiTokens $rest
            $compared = @{}
            for ($i = 0; $i -lt $toks.Count; $i++) {
                $t = $toks[$i]
                if ($t.K -eq 'op' -and $cmps -contains $t.V) {
                    $L = if ($i - 1 -ge 0) { $toks[$i - 1] } else { $null }
                    $R = if ($i + 1 -lt $toks.Count) { $toks[$i + 1] } else { $null }
                    if ($L -and $L.K -eq 'id' -and $L.V -ne 'defined' -and $R) { $v = Get-FiTokVal $R; if ($null -ne $v) { & $addsw $L.V $ln $v; $compared[$L.V] = $true } }
                    if ($R -and $R.K -eq 'id' -and $R.V -ne 'defined' -and $L) { $v = Get-FiTokVal $L; if ($null -ne $v) { & $addsw $R.V $ln $v; $compared[$R.V] = $true } }
                }
            }
            for ($i = 0; $i -lt $toks.Count; $i++) {
                if ($toks[$i].K -eq 'id' -and $toks[$i].V -eq 'defined') {
                    for ($j = $i + 1; $j -lt $toks.Count -and $j -lt $i + 3; $j++) {
                        if ($toks[$j].K -eq 'id') { & $addsw $toks[$j].V $ln '1'; $compared[$toks[$j].V] = $true; break }
                    }
                }
            }
            foreach ($t in $toks) {
                if ($t.K -eq 'id' -and $t.V -ne 'defined' -and -not $compared.ContainsKey($t.V)) { & $addsw $t.V $ln '1' }
            }
        }
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
        [switch]$External
    )
    try { $src = [System.IO.File]::ReadAllText($FilePath) }
    catch { Write-Warning "読み込み失敗: $FilePath"; return @() }

    if (Initialize-FiNative) {
        $nd = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        if ($Defines) { foreach ($k in $Defines.Keys) { $nd[[string]$k] = [string]$Defines[$k] } }
        $np = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($p in ($Pinned | Where-Object { $_ })) { [void]$np.Add([string]$p) }
        return $script:FiNativeType::Analyze($FilePath, $src, $nd, [bool]$IgnoreSwitches, $np, [bool]$External)
    }

    $clean = Remove-FICommentsStrings $src
    if (-not $IgnoreSwitches) {
        $d = if ($Defines) { $Defines.Clone() } else { @{} }
        $pin = @{}
        foreach ($p in ($Pinned | Where-Object { $_ })) { $pin[[string]$p] = $true }
        $clean = Invoke-FiPreprocess $clean $d $pin -External:$External
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
    $cbExternal = New-Object System.Windows.Forms.CheckBox
    $cbExternal.Text = '選択スイッチのみ有効(ソース内#defineを無視)'; $cbExternal.Location = '260,46'; $cbExternal.AutoSize = $true; $cbExternal.Checked = $true
    $form.Controls.Add($cbExternal)
    $cbIgnore = New-Object System.Windows.Forms.CheckBox
    $cbIgnore.Text = '全コード有効(スイッチ無視)'; $cbIgnore.Location = '560,46'; $cbIgnore.AutoSize = $true
    $form.Controls.Add($cbIgnore)

    $lblXd = New-Object System.Windows.Forms.Label
    $lblXd.Text = '追加 -D:'; $lblXd.Location = '10,72'; $lblXd.AutoSize = $true
    $form.Controls.Add($lblXd)
    $tbXd = New-Object System.Windows.Forms.TextBox
    $tbXd.Location = '120,69'; $tbXd.Size = '300,24'; $tbXd.Anchor = 'Top,Left'
    $tbXd.Text = ''
    $form.Controls.Add($tbXd)
    $lblXdHint = New-Object System.Windows.Forms.Label
    $lblXdHint.Text = '(値指定。例 TOOL_TEST=2,FOO)'; $lblXdHint.Location = '430,72'; $lblXdHint.AutoSize = $true
    $form.Controls.Add($lblXdHint)

    $lblSw = New-Object System.Windows.Forms.Label
    $lblSw.Text = 'スイッチ (チェック=ON / ダブルクリックで箇所を開く)'; $lblSw.Location = '10,100'; $lblSw.AutoSize = $true
    $form.Controls.Add($lblSw)
    $swlv = New-Object System.Windows.Forms.ListView
    $swlv.Location = '10,120'; $swlv.Size = '270,410'; $swlv.Anchor = 'Top,Bottom,Left'
    $swlv.View = 'Details'; $swlv.CheckBoxes = $true; $swlv.FullRowSelect = $true; $swlv.GridLines = $true
    [void]$swlv.Columns.Add('Switch', 110)
    [void]$swlv.Columns.Add('件', 35)
    [void]$swlv.Columns.Add('初出', 105)
    $swlv.Add_DoubleClick({
            if ($swlv.SelectedItems.Count -gt 0) { $info = $swlv.SelectedItems[0].Tag; if ($info) { Open-FiLocation $info.File ([int]$info.Line) } }
        })
    $form.Controls.Add($swlv)

    $btnDetect = New-Object System.Windows.Forms.Button
    $btnDetect.Text = 'スイッチ検出'; $btnDetect.Location = '10,535'; $btnDetect.Size = '270,26'; $btnDetect.Anchor = 'Bottom,Left'
    $form.Controls.Add($btnDetect)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = '290,120'; $lv.Size = '600,410'; $lv.Anchor = 'Top,Bottom,Left,Right'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
    [void]$lv.Columns.Add('File', 330)
    [void]$lv.Columns.Add('Line', 55)
    [void]$lv.Columns.Add('Function', 150)
    [void]$lv.Columns.Add('Steps', 55)
    $lv.Add_DoubleClick({
            if ($lv.SelectedItems.Count -gt 0) { $r = $lv.SelectedItems[0]; Open-FiLocation $r.Text ([int]$r.SubItems[1].Text) }
        })
    $form.Controls.Add($lv)

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Location = '290,538'; $pb.Size = '360,18'; $pb.Anchor = 'Bottom,Left'; $pb.Minimum = 0; $pb.Maximum = 1
    $form.Controls.Add($pb)
    $status = New-Object System.Windows.Forms.Label
    $status.Location = '290,560'; $status.Size = '520,20'; $status.Text = '準備完了'; $status.Anchor = 'Bottom,Left'
    $form.Controls.Add($status)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = 'スキャン'; $btnScan.Location = '670,535'; $btnScan.Size = '95,28'; $btnScan.Anchor = 'Bottom,Right'
    $form.Controls.Add($btnScan)
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'CSV 保存'; $btnSave.Location = '775,535'; $btnSave.Size = '100,28'; $btnSave.Anchor = 'Bottom,Right'
    $form.Controls.Add($btnSave)

    $script:FIguiRows = @()
    $script:FiSync = $null; $script:FiPS = $null; $script:FiRS = $null; $script:FiHandle = $null

    # バックグラウンド実行用スクリプト
    $sbScan = {
        param($sync, $corePath, $pathArg, $exts, $defines, $ignore, $external)
        try {
            . $corePath
            $files = Get-FITargetFiles -Paths @($pathArg) -Exts $exts
            $sync.Total = $files.Count
            $rows = New-Object System.Collections.Generic.List[object]
            $i = 0
            $pinned = [string[]]$defines.Keys
            foreach ($f in $files) {
                $i++; $sync.Progress = $i; $sync.Current = $f
                foreach ($r in (Find-CFunctions -FilePath $f -Defines $defines -Pinned $pinned -IgnoreSwitches:$ignore -External:$external)) { $rows.Add($r) }
            }
            $sync.Result = $rows
        } catch { $sync.Error = $_.Exception.Message }
        finally { $sync.Done = $true }
    }
    $sbSwitch = {
        param($sync, $corePath, $pathArg, $exts)
        try {
            . $corePath
            $files = Get-FITargetFiles -Paths @($pathArg) -Exts $exts
            $sync.Total = $files.Count
            $agg = @{}
            $i = 0
            foreach ($f in $files) {
                $i++; $sync.Progress = $i; $sync.Current = $f
                $fs = Get-FiFileSwitches -FilePath $f
                foreach ($name in $fs.Keys) {
                    if ($agg.ContainsKey($name)) { $agg[$name].Count += $fs[$name].Count }
                    else { $agg[$name] = [pscustomobject]@{ Count = $fs[$name].Count; File = $f; Line = $fs[$name].Line } }
                }
            }
            $sync.Result = $agg
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
            [void]$ps.AddScript($sbSwitch.ToString()).AddArgument($script:FiSync).AddArgument($script:FiScriptPath).AddArgument($tb.Text.Trim()).AddArgument($exts)
        }
        else {
            $defines = @{}
            foreach ($it in $swlv.CheckedItems) { $defines[[string]$it.Text] = '1' }
            # 追加 -D (値指定。例: TOOL_TEST=2,FOO)
            foreach ($tok in ($tbXd.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if ($tok.Contains('=')) { $kv = $tok.Split('=', 2); $defines[$kv[0].Trim()] = $kv[1] }
                else { $defines[$tok] = '1' }
            }
            [void]$ps.AddScript($sbScan.ToString()).AddArgument($script:FiSync).AddArgument($script:FiScriptPath).AddArgument($tb.Text.Trim()).AddArgument($exts).AddArgument($defines).AddArgument([bool]$cbIgnore.Checked).AddArgument([bool]$cbExternal.Checked)
        }
        $script:FiPS = $ps; $script:FiRS = $rs; $script:FiHandle = $ps.BeginInvoke()
        $timer.Start()
    }

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
                    $swlv.Items.Clear()
                    foreach ($name in ($agg.Keys | Sort-Object)) {
                        $info = $agg[$name]
                        $it = New-Object System.Windows.Forms.ListViewItem([string]$name)
                        [void]$it.SubItems.Add([string]$info.Count)
                        [void]$it.SubItems.Add(("{0}:{1}" -f [System.IO.Path]::GetFileName([string]$info.File), $info.Line))
                        $it.Tag = $info
                        [void]$swlv.Items.Add($it)
                    }
                    $status.Text = ("完了: {0} 個のスイッチ (ダブルクリックで箇所を開く)" -f $agg.Count)
                }
                else {
                    $rows = $s.Result
                    $script:FIguiRows = $rows
                    $lv.Items.Clear(); $tot = 0
                    foreach ($r in $rows) {
                        $it = New-Object System.Windows.Forms.ListViewItem([string]$r.File)
                        [void]$it.SubItems.Add([string]$r.Line)
                        [void]$it.SubItems.Add([string]$r.Function)
                        [void]$it.SubItems.Add([string]$r.Steps)
                        [void]$lv.Items.Add($it)
                        $tot += $r.Steps
                    }
                    $status.Text = ("完了: {0} 関数 / 合計 {1} ステップ (ダブルクリックで開く)" -f $rows.Count, $tot)
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
    $total = $files.Count; $i = 0
    foreach ($f in $files) {
        $i++
        Write-Progress -Activity 'FuncInspector' -Status ("解析 {0}/{1} {2}" -f $i, $total, $f) -PercentComplete ($(if ($total) { $i * 100 / $total } else { 100 }))
        foreach ($r in (Find-CFunctions -FilePath $f -Defines $defines -Pinned $pinned.ToArray() -IgnoreSwitches:$IgnoreSwitches -External:$ExternalSwitches)) { $rows.Add($r) }
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
