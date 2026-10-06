unit ai.sqlextract;

// Takes the SQL out of a model's answer, and flags SQL that may change data or schema, so the UI
// can warn before the user runs it. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TSqlEffect = (seModifiesData, seModifiesSchema);
  TSqlEffects = set of TSqlEffect;

// The SQL to insert into the editor: the body of the first fence tagged sql or an SQL dialect,
// else of the first untagged fence, else the whole answer if it is bare SQL (starts with an SQL
// keyword, ends with ";" and contains no prose). Empty if there is no recognizable SQL.
function ExtractSql(const Answer: String): String;

// All fenced code blocks tagged sql (or a dialect) or untagged, in order. The UI offers each one,
// as answers often contain a query and separate CREATE INDEX statements.
function ExtractSqlBlocks(const Answer: String): TStringArray;

// Deny by default: a statement counts as read-only only if it starts with SELECT, WITH, SHOW,
// EXPLAIN, DESCRIBE, DESC, VALUES or TABLE and contains no data- or schema-changing keyword and
// no INTO. Everything else may modify data. Comments, strings and quoted identifiers are ignored,
// and as dialects disagree on what is a comment or string (backslash escapes, "#" comments,
// "--" without a space), every reading is checked and the results are combined. MySQL
// executable comments /*! */ and optimizer hints /*+ */ count as code.
function SqlEffects(const Sql: String): TSqlEffects;

implementation

uses
  ai.text;

type
  TMaskOption = (moBackslashEscapes, moHashComments, moDashNeedsSpace);
  TMaskOptions = set of TMaskOption;

const
  SQLFENCETAGS: array[0..8] of String = ('sql', 'mysql', 'mariadb', 'postgresql', 'postgres',
    'pgsql', 'sqlite', 'tsql', 'plpgsql');
  BARESTARTKEYWORDS: array[0..11] of String = ('SELECT', 'WITH', 'INSERT', 'UPDATE', 'DELETE',
    'CREATE', 'ALTER', 'DROP', 'SHOW', 'EXPLAIN', 'REPLACE', 'TRUNCATE');
  READONLYSTARTS: array[0..7] of String = ('SELECT', 'WITH', 'SHOW', 'EXPLAIN', 'DESCRIBE',
    'DESC', 'VALUES', 'TABLE');
  DATAKEYWORDS: array[0..23] of String = ('INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'MERGE',
    'UPSERT', 'TRUNCATE', 'CALL', 'EXEC', 'EXECUTE', 'LOAD', 'COPY', 'HANDLER', 'DO', 'LOCK',
    'UNLOCK', 'KILL', 'FLUSH', 'SHUTDOWN', 'VACUUM', 'OPTIMIZE', 'REPAIR', 'PRAGMA', 'INTO');
  // COMMENT is left out on purpose: it is a common column name. A statement starting with
  // COMMENT ON is still flagged, as it is not a read-only start.
  SCHEMAKEYWORDS: array[0..7] of String = ('CREATE', 'ALTER', 'DROP', 'RENAME', 'GRANT',
    'REVOKE', 'ATTACH', 'DETACH');

function InList(const Word: String; const List: array of String): Boolean;
var
  Item: String;
begin
  for Item in List do begin
    if SameText(Word, Item) then
      Exit(True);
  end;
  Result := False;
end;

function SplitLines(const Text: String): TStringArray;
begin
  Result := Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
end;

function BacktickRun(const Line: String): Integer;
begin
  Result := 0;
  while (Result < Length(Line)) and (Line[Result + 1] = '`') do
    Inc(Result);
end;

function FenceTag(const Line: String; Run: Integer): String;
begin
  // Info string, e.g. "sql" or "sql title=x": only the first word is the language
  Result := LowerCase(Copy(Line, Run + 1, MaxInt).Trim);
  if Pos(' ', Result) > 0 then
    Result := Copy(Result, 1, Pos(' ', Result) - 1);
end;

type
  TFence = record
    Tag: String;
    Body: String;
  end;

// All fenced blocks of at least three backticks; a block closes with a run at least as long
function Fences(const Text: String): TArray<TFence>;
var
  Lines: TStringArray;
  i, j, Run: Integer;
  Line: String;
  Body: TStringArray;
  Fence: TFence;
begin
  Result := nil;
  Lines := SplitLines(Text);
  i := 0;
  while i < Length(Lines) do begin
    Line := Lines[i].Trim;
    Run := BacktickRun(Line);
    if Run >= 3 then begin
      Fence.Tag := FenceTag(Line, Run);
      Body := nil;
      j := i + 1;
      while (j < Length(Lines)) and (BacktickRun(Lines[j].Trim) < Run) do begin
        SetLength(Body, Length(Body) + 1);
        Body[High(Body)] := Lines[j];
        Inc(j);
      end;
      Fence.Body := String.Join(#10, Body).Trim;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Fence;
      i := j;
    end;
    Inc(i);
  end;
end;

function ExtractSqlBlocks(const Answer: String): TStringArray;
var
  Fence: TFence;
begin
  Result := nil;
  for Fence in Fences(StripThinking(Answer)) do begin
    if ((Fence.Tag = '') or InList(Fence.Tag, SQLFENCETAGS)) and (Fence.Body <> '') then begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Fence.Body;
    end;
  end;
end;

function FirstWord(const Text: String): String;
var
  i: Integer;
begin
  i := 1;
  while (i <= Length(Text)) and (Text[i] in ['A'..'Z', 'a'..'z', '_']) do
    Inc(i);
  Result := Copy(Text, 1, i - 1);
end;

// A sentence boundary, e.g. "table. Then", marks an answer as prose
function HasSentenceBoundary(const Text: String): Boolean;
var
  i: Integer;
begin
  for i:=2 to Length(Text) - 2 do begin
    if (Text[i] in ['.', '?', '!', ':']) and (Text[i-1] in ['a'..'z', 'A'..'Z', ')'])
      and (Text[i+1] = ' ') and (Text[i+2] in ['A'..'Z']) then
      Exit(True);
  end;
  Result := False;
end;

function ExtractSql(const Answer: String): String;
var
  Text: String;
  Fence: TFence;
  All: TArray<TFence>;
begin
  Text := StripThinking(Answer);
  All := Fences(Text);
  for Fence in All do begin
    if InList(Fence.Tag, SQLFENCETAGS) and (Fence.Body <> '') then
      Exit(Fence.Body);
  end;
  for Fence in All do begin
    if (Fence.Tag = '') and (Fence.Body <> '') then
      Exit(Fence.Body);
  end;
  if (Length(All) = 0) and InList(FirstWord(Text), BARESTARTKEYWORDS)
    and Text.EndsWith(';') and not HasSentenceBoundary(Text) then
    Result := Text
  else
    Result := '';
end;

// Replaces comments, string literals and quoted identifiers with spaces, under one dialect
// reading. Executable comments /*! */ and hints /*+ */ keep their content as code.
function MaskNonCode(const Sql: String; Options: TMaskOptions): String;
var
  Code: String;
  i, j, Len: Integer;
  Quote: Char;
  Tag: String;

  procedure Blank(FromPos, ToPos: Integer);
  var
    k: Integer;
  begin
    for k:=FromPos to ToPos do begin
      if (k >= 1) and (k <= Len) then
        Code[k] := ' ';
    end;
  end;

  function IsDashComment(p: Integer): Boolean;
  begin
    Result := (Code[p] = '-') and (p < Len) and (Code[p+1] = '-');
    if Result and (moDashNeedsSpace in Options) then
      Result := (p + 1 = Len) or (Code[p+2] in [' ', #9, #10, #13]);
  end;

begin
  Code := Sql;
  Len := Length(Code);
  i := 1;
  while i <= Len do begin
    if IsDashComment(i) or ((Code[i] = '#') and (moHashComments in Options)) then begin
      j := i;
      while (j <= Len) and (Code[j] <> #10) do
        Inc(j);
      Blank(i, j - 1);
      i := j;
    end
    else if (Code[i] = '/') and (i < Len) and (Code[i+1] = '*') then begin
      j := Pos('*/', Code, i + 2);
      if j = 0 then
        j := Len + 1;
      if (i + 2 <= Len) and (Code[i+2] in ['!', '+']) then begin
        // Executable comment: hide only the delimiters and an optional version number
        Blank(i, i + 2);
        i := i + 3;
        while (i <= Len) and (Code[i] in ['0'..'9']) do begin
          Code[i] := ' ';
          Inc(i);
        end;
        if j <= Len then
          Blank(j, j + 1);
      end else begin
        Blank(i, j + 1);
        i := j + 2;
      end;
    end
    else if Code[i] in ['''', '"', '`', '['] then begin
      Quote := Code[i];
      if Quote = '[' then
        Quote := ']';
      j := i + 1;
      while j <= Len do begin
        if (Quote = '''') and (moBackslashEscapes in Options) and (Code[j] = '\') then begin
          Inc(j, 2);
          Continue;
        end;
        if Code[j] = Quote then begin
          if (j < Len) and (Code[j+1] = Quote) and (Quote <> ']') then begin
            Inc(j, 2);
            Continue;
          end;
          Break;
        end;
        Inc(j);
      end;
      Blank(i, j);
      i := j + 1;
    end
    else if Code[i] = '$' then begin
      // PostgreSQL $tag$ ... $tag$ string
      j := i + 1;
      while (j <= Len) and (Code[j] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
        Inc(j);
      if (j <= Len) and (Code[j] = '$') then begin
        Tag := Copy(Code, i, j - i + 1);
        j := Pos(Tag, Code, j + 1);
        if j = 0 then
          j := Len + 1
        else
          j := j + Length(Tag) - 1;
        Blank(i, j);
        i := j + 1;
      end else
        Inc(i);
    end
    else
      Inc(i);
  end;
  Result := Code;
end;

function StatementEffects(const Statement: String): TSqlEffects;
var
  i, Start: Integer;
  Word, First: String;
begin
  Result := [];
  First := '';
  i := 1;
  while i <= Length(Statement) do begin
    if Statement[i] in ['A'..'Z', 'a'..'z', '_'] then begin
      Start := i;
      while (i <= Length(Statement)) and (Statement[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$', '.']) do
        Inc(i);
      Word := Copy(Statement, Start, i - Start);
      if First = '' then
        First := Word;
      if InList(Word, DATAKEYWORDS) then
        Include(Result, seModifiesData)
      else if InList(Word, SCHEMAKEYWORDS) then
        Include(Result, seModifiesSchema);
    end else
      Inc(i);
  end;
  // Unknown statement kinds may modify data
  if (First <> '') and (Result = []) and not InList(First, READONLYSTARTS) then
    Include(Result, seModifiesData);
end;

function SqlEffects(const Sql: String): TSqlEffects;
var
  Combo: Integer;
  Options: TMaskOptions;
  Statement: String;
begin
  Result := [];
  for Combo:=0 to 7 do begin
    Options := [];
    if (Combo and 1) <> 0 then
      Include(Options, moBackslashEscapes);
    if (Combo and 2) <> 0 then
      Include(Options, moHashComments);
    if (Combo and 4) <> 0 then
      Include(Options, moDashNeedsSpace);
    for Statement in MaskNonCode(Sql, Options).Split([';']) do
      Result := Result + StatementEffects(Statement);
  end;
end;

end.
