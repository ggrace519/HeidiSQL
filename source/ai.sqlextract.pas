unit ai.sqlextract;

// Takes the SQL out of a model's answer, and flags statements that would change data or schema,
// so the UI can warn before the user runs them. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TSqlEffect = (seModifiesData, seModifiesSchema);
  TSqlEffects = set of TSqlEffect;

// Removes <think>...</think> blocks some models emit inside the answer text.
// An unclosed block at the start (answer still streaming, or cut off) is removed to the end.
function StripThinking(const Answer: String): String;

// The SQL to insert into the editor: the body of the first ```sql fence (or a fence tagged with
// a SQL dialect), else of the first untagged fence, else the whole answer if it starts with an
// SQL keyword. Empty if the answer contains no recognizable SQL.
function ExtractSql(const Answer: String): String;

// Statement kinds in Sql that write data (INSERT, UPDATE, DELETE, ...) or change schema or
// privileges (CREATE, ALTER, DROP, GRANT, ...). Comments, string literals and quoted identifiers
// are ignored. Conservative: "SELECT ... FOR UPDATE" counts as modifying data.
function SqlEffects(const Sql: String): TSqlEffects;

implementation

const
  SQLFENCETAGS: array[0..8] of String = ('sql', 'mysql', 'mariadb', 'postgresql', 'postgres',
    'pgsql', 'sqlite', 'tsql', 'plpgsql');
  STARTKEYWORDS: array[0..14] of String = ('SELECT', 'WITH', 'INSERT', 'UPDATE', 'DELETE',
    'CREATE', 'ALTER', 'DROP', 'SHOW', 'EXPLAIN', 'DESCRIBE', 'REPLACE', 'TRUNCATE', 'CALL', 'SET');
  DATAKEYWORDS: array[0..12] of String = ('INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'MERGE',
    'UPSERT', 'TRUNCATE', 'CALL', 'EXEC', 'EXECUTE', 'LOAD', 'COPY', 'HANDLER');
  // COMMENT is left out on purpose: it is a common column name
  SCHEMAKEYWORDS: array[0..6] of String = ('CREATE', 'ALTER', 'DROP', 'RENAME', 'GRANT',
    'REVOKE', 'ATTACH');

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

function StripThinking(const Answer: String): String;
const
  OPENTAG = '<think>';
  CLOSETAG = '</think>';
var
  OpenPos, ClosePos: Integer;
begin
  Result := Answer;
  repeat
    OpenPos := Pos(OPENTAG, LowerCase(Result));
    if OpenPos = 0 then
      Break;
    ClosePos := Pos(CLOSETAG, LowerCase(Result), OpenPos);
    if ClosePos = 0 then begin
      SetLength(Result, OpenPos - 1);
      Break;
    end;
    Delete(Result, OpenPos, ClosePos + Length(CLOSETAG) - OpenPos);
  until False;
  Result := Result.Trim;
end;

// Body of the first fence whose info string satisfies the filter, or '' if none
function FenceBody(const Text: String; WantSqlTag: Boolean; out Found: Boolean): String;
var
  Lines: TStringArray;
  i, j: Integer;
  Line, Tag: String;
  Body: TStringArray;
begin
  Result := '';
  Found := False;
  Lines := Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  i := 0;
  while i < Length(Lines) do begin
    Line := Lines[i].Trim;
    if Line.StartsWith('```') then begin
      // Info string, e.g. "sql" or "sql title=x": only the first word is the language
      Tag := LowerCase(Copy(Line, 4, MaxInt).Trim);
      if Pos(' ', Tag) > 0 then
        Tag := Copy(Tag, 1, Pos(' ', Tag) - 1);
      if (WantSqlTag and InList(Tag, SQLFENCETAGS)) or ((not WantSqlTag) and (Tag = '')) then begin
        Body := nil;
        j := i + 1;
        while (j < Length(Lines)) and (not Lines[j].Trim.StartsWith('```')) do begin
          SetLength(Body, Length(Body) + 1);
          Body[High(Body)] := Lines[j];
          Inc(j);
        end;
        Found := True;
        Exit(String.Join(#10, Body).Trim);
      end;
      // Skip the whole foreign fence, so its closing line is not taken as an opening one
      Inc(i);
      while (i < Length(Lines)) and (not Lines[i].Trim.StartsWith('```')) do
        Inc(i);
    end;
    Inc(i);
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

function ExtractSql(const Answer: String): String;
var
  Text: String;
  Found: Boolean;
begin
  Text := StripThinking(Answer);
  Result := FenceBody(Text, True, Found);
  if Found then
    Exit;
  Result := FenceBody(Text, False, Found);
  if Found then
    Exit;
  if InList(FirstWord(Text), STARTKEYWORDS) then
    Result := Text
  else
    Result := '';
end;

// Replaces comments, string literals and quoted identifiers with spaces
function MaskNonCode(const Sql: String): String;
var
  i, j, Len: Integer;
  Quote: Char;
  Tag: String;
begin
  Result := Sql;
  Len := Length(Result);
  i := 1;
  while i <= Len do begin
    // -- and # line comments
    if ((Result[i] = '-') and (i < Len) and (Result[i+1] = '-')) or (Result[i] = '#') then begin
      while (i <= Len) and (Result[i] <> #10) do begin
        Result[i] := ' ';
        Inc(i);
      end;
    end
    // /* block comments */
    else if (Result[i] = '/') and (i < Len) and (Result[i+1] = '*') then begin
      while (i <= Len) and not ((Result[i] = '*') and (i < Len) and (Result[i+1] = '/')) do begin
        Result[i] := ' ';
        Inc(i);
      end;
      if i <= Len then begin
        Result[i] := ' ';
        if i < Len then
          Result[i+1] := ' ';
        Inc(i, 2);
      end;
    end
    // 'string', "identifier", `identifier`, [identifier]
    else if Result[i] in ['''', '"', '`', '['] then begin
      Quote := Result[i];
      if Quote = '[' then
        Quote := ']';
      Result[i] := ' ';
      Inc(i);
      while i <= Len do begin
        if (Quote = '''') and (Result[i] = '\') and (i < Len) then begin
          Result[i] := ' ';
          Result[i+1] := ' ';
          Inc(i, 2);
          Continue;
        end;
        if Result[i] = Quote then begin
          // Doubled quote is an escaped quote
          if (i < Len) and (Result[i+1] = Quote) and (Quote <> ']') then begin
            Result[i] := ' ';
            Result[i+1] := ' ';
            Inc(i, 2);
            Continue;
          end;
          Result[i] := ' ';
          Inc(i);
          Break;
        end;
        Result[i] := ' ';
        Inc(i);
      end;
    end
    // PostgreSQL $tag$ ... $tag$ string
    else if Result[i] = '$' then begin
      j := i + 1;
      while (j <= Len) and (Result[j] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
        Inc(j);
      if (j <= Len) and (Result[j] = '$') then begin
        Tag := Copy(Result, i, j - i + 1);
        j := Pos(Tag, Result, j + 1);
        if j = 0 then
          j := Len + 1
        else
          j := j + Length(Tag);
        while i < j do begin
          Result[i] := ' ';
          Inc(i);
        end;
      end else
        Inc(i);
    end
    else
      Inc(i);
  end;
end;

function SqlEffects(const Sql: String): TSqlEffects;
var
  Code, Word: String;
  i, Start: Integer;
begin
  Result := [];
  Code := MaskNonCode(Sql);
  i := 1;
  while i <= Length(Code) do begin
    if Code[i] in ['A'..'Z', 'a'..'z', '_'] then begin
      Start := i;
      while (i <= Length(Code)) and (Code[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$', '.']) do
        Inc(i);
      Word := Copy(Code, Start, i - Start);
      if InList(Word, DATAKEYWORDS) then
        Include(Result, seModifiesData)
      else if InList(Word, SCHEMAKEYWORDS) then
        Include(Result, seModifiesSchema);
    end else
      Inc(i);
  end;
end;

end.
