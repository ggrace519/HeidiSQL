unit ai.context;

// Schema context for the model: which tables get full detail, and a compact text format that
// fits a character budget. Works on plain records filled by the caller, no database access and
// no LCL dependencies.
//
// Format, one block per detailed table, then the remaining table names:
//   orders (~12000 rows) -- Customer orders
//     id int PK
//     customer_id int NOT NULL -> customers.id
//   Other tables: audit_log (~3M rows), settings, ...

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TAiSchemaColumn = record
    Name: String;
    DataType: String;      // As shown to users, e.g. "varchar(100)"
    NotNull: Boolean;
    PrimaryKey: Boolean;
    Comment: String;
  end;

  TAiForeignKey = record
    Columns: TStringArray;
    RefTable: String;
    RefColumns: TStringArray;
  end;

  TAiSchemaTable = record
    Name: String;
    IsView: Boolean;
    RowsEstimate: Int64;   // -1 when unknown
    Comment: String;
    DetailLoaded: Boolean; // Columns, keys and indexes were fetched
    Columns: array of TAiSchemaColumn;
    ForeignKeys: array of TAiForeignKey;
    Indexes: TStringArray; // e.g. "idx_customer (customer_id)", only filled when useful
  end;
  TAiSchemaTables = array of TAiSchemaTable;

  TAiContextBudget = record
    MaxChars: Integer;
    MaxDetailTables: Integer;
    MaxColumnsPerTable: Integer;
    MaxTableNames: Integer;
    MaxCommentLen: Integer;
  end;

// Defaults: schema text costs about 2 characters per token, so 8000 characters are ~4k tokens,
// which fits the context window of small local models.
function DefaultContextBudget: TAiContextBudget;

// Table names occurring in Text as whole words, case-insensitive, in TableNames order.
// A trailing "s"/"es" on either side counts as a match ("order" finds "orders").
function FindMentionedTables(const Text: String; const TableNames: TStringArray): TStringArray;

// Tables to load in detail, by priority: mentioned in Prompt, used in Sql, the active object,
// then all tables if there are no more than MaxDetail. Deduplicated, at most MaxDetail entries.
function PlanDetailTables(const TableNames: TStringArray; const Prompt, Sql, ActiveObject: String;
  MaxDetail: Integer): TStringArray;

// Tables referenced by foreign keys of the given detailed tables, not yet in Detailed
function ForeignKeyNeighbours(const Tables: TAiSchemaTables; const Detailed: TStringArray): TStringArray;

// Formats the context. DetailOrder lists the tables to show in detail, most important first;
// a detailed block that does not fit the remaining budget is shown as a name only.
function FormatSchemaContext(const Tables: TAiSchemaTables; const DetailOrder: TStringArray;
  const Budget: TAiContextBudget): String;

implementation

uses
  Classes, StrUtils;

function DefaultContextBudget: TAiContextBudget;
begin
  Result.MaxChars := 8000;
  Result.MaxDetailTables := 25;
  Result.MaxColumnsPerTable := 50;
  Result.MaxTableNames := 400;
  Result.MaxCommentLen := 80;
end;

function IndexOfText(const List: TStringArray; const Value: String): Integer;
var
  i: Integer;
begin
  for i:=0 to High(List) do begin
    if SameText(List[i], Value) then
      Exit(i);
  end;
  Result := -1;
end;

procedure AddUnique(var List: TStringArray; const Value: String);
begin
  if (Value <> '') and (IndexOfText(List, Value) < 0) then begin
    SetLength(List, Length(List) + 1);
    List[High(List)] := Value;
  end;
end;

function IsWordChar(c: Char): Boolean;
begin
  Result := c in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$', #128..#255];
end;

// Lowercase words of Text, splitting on everything but identifier characters
function WordsOf(const Text: String): TStringArray;
var
  i, Start: Integer;
begin
  Result := nil;
  i := 1;
  while i <= Length(Text) do begin
    if IsWordChar(Text[i]) then begin
      Start := i;
      while (i <= Length(Text)) and IsWordChar(Text[i]) do
        Inc(i);
      AddUnique(Result, LowerCase(Copy(Text, Start, i - Start)));
    end else
      Inc(i);
  end;
end;

// Rough English singular, only used to match words against table names
function Singular(const Word: String): String;
begin
  Result := Word;
  if Length(Result) <= 3 then
    Exit;
  if Result.EndsWith('ies') then
    Result := Copy(Result, 1, Length(Result) - 3) + 'y'                  // categories
  else if Result.EndsWith('sses') or Result.EndsWith('uses') or Result.EndsWith('xes')
    or Result.EndsWith('ches') or Result.EndsWith('shes') then
    SetLength(Result, Length(Result) - 2)                                // addresses, statuses, boxes
  else if Result.EndsWith('s') and not (Result.EndsWith('ss') or Result.EndsWith('us')) then
    SetLength(Result, Length(Result) - 1);                               // orders
end;

function FindMentionedTables(const Text: String; const TableNames: TStringArray): TStringArray;
var
  Words, Singulars: TStringArray;
  i: Integer;
  Name: String;
begin
  Result := nil;
  Words := WordsOf(Text);
  Singulars := nil;
  for i:=0 to High(Words) do
    AddUnique(Singulars, Singular(Words[i]));
  for i:=0 to High(TableNames) do begin
    Name := LowerCase(TableNames[i]);
    if (IndexOfText(Words, Name) >= 0) or (IndexOfText(Singulars, Singular(Name)) >= 0) then
      AddUnique(Result, TableNames[i]);
  end;
end;

function PlanDetailTables(const TableNames: TStringArray; const Prompt, Sql, ActiveObject: String;
  MaxDetail: Integer): TStringArray;
var
  Name: String;
begin
  Result := nil;
  for Name in FindMentionedTables(Prompt, TableNames) do
    AddUnique(Result, Name);
  for Name in FindMentionedTables(Sql, TableNames) do
    AddUnique(Result, Name);
  if IndexOfText(TableNames, ActiveObject) >= 0 then
    AddUnique(Result, TableNames[IndexOfText(TableNames, ActiveObject)]);
  if Length(TableNames) <= MaxDetail then begin
    for Name in TableNames do
      AddUnique(Result, Name);
  end;
  if Length(Result) > MaxDetail then
    SetLength(Result, MaxDetail);
end;

function FindTable(const Tables: TAiSchemaTables; const Name: String): Integer;
var
  i: Integer;
begin
  for i:=0 to High(Tables) do begin
    if SameText(Tables[i].Name, Name) then
      Exit(i);
  end;
  Result := -1;
end;

function ForeignKeyNeighbours(const Tables: TAiSchemaTables; const Detailed: TStringArray): TStringArray;
var
  Name: String;
  t, f: Integer;
begin
  Result := nil;
  for Name in Detailed do begin
    t := FindTable(Tables, Name);
    if t < 0 then
      Continue;
    for f:=0 to High(Tables[t].ForeignKeys) do begin
      if (IndexOfText(Detailed, Tables[t].ForeignKeys[f].RefTable) < 0)
        and (FindTable(Tables, Tables[t].ForeignKeys[f].RefTable) >= 0) then
        AddUnique(Result, Tables[FindTable(Tables, Tables[t].ForeignKeys[f].RefTable)].Name);
    end;
  end;
end;

function OneLine(const Text: String; MaxLen: Integer): String;
begin
  Result := Text.Replace(#13#10, ' ').Replace(#10, ' ').Replace(#13, ' ').Trim;
  if (MaxLen > 0) and (Length(Result) > MaxLen) then
    Result := Copy(Result, 1, MaxLen - 3) + '...';
end;

function RowsLabel(Rows: Int64): String;
begin
  if Rows < 0 then
    Result := ''
  else if Rows >= 1000000 then
    Result := ' (~' + IntToStr(Round(Rows / 1000000)) + 'M rows)'
  else if Rows >= 10000 then
    Result := ' (~' + IntToStr(Round(Rows / 1000)) + 'k rows)'
  else
    Result := ' (~' + IntToStr(Rows) + ' rows)';
end;

function NameLabel(const Table: TAiSchemaTable): String;
begin
  Result := Table.Name;
  if Table.IsView then
    Result := Result + ' [view]';
  Result := Result + RowsLabel(Table.RowsEstimate);
end;

function FormatTableBlock(const Table: TAiSchemaTable; const Budget: TAiContextBudget): String;
var
  Lines: TStringList;
  c, f: Integer;
  Col: TAiSchemaColumn;
  Line: String;
  SingleFkTarget: array of String;
begin
  Lines := TStringList.Create;
  try
    Line := NameLabel(Table);
    if Table.Comment <> '' then
      Line := Line + ' -- ' + OneLine(Table.Comment, Budget.MaxCommentLen);
    Lines.Add(Line);
    // Single-column foreign keys are shown on their column, others on their own line
    SetLength(SingleFkTarget, Length(Table.Columns));
    for f:=0 to High(Table.ForeignKeys) do begin
      if Length(Table.ForeignKeys[f].Columns) <> 1 then
        Continue;
      for c:=0 to High(Table.Columns) do begin
        if SameText(Table.Columns[c].Name, Table.ForeignKeys[f].Columns[0]) then
          SingleFkTarget[c] := Table.ForeignKeys[f].RefTable + '.'
            + IfThen(Length(Table.ForeignKeys[f].RefColumns) > 0, Table.ForeignKeys[f].RefColumns[0], '?');
      end;
    end;
    for c:=0 to High(Table.Columns) do begin
      if c >= Budget.MaxColumnsPerTable then begin
        Lines.Add('  ... +' + IntToStr(Length(Table.Columns) - c) + ' columns');
        Break;
      end;
      Col := Table.Columns[c];
      Line := '  ' + Col.Name + ' ' + Col.DataType;
      if Col.PrimaryKey then
        Line := Line + ' PK'
      else if Col.NotNull then
        Line := Line + ' NOT NULL';
      if SingleFkTarget[c] <> '' then
        Line := Line + ' -> ' + SingleFkTarget[c];
      if Col.Comment <> '' then
        Line := Line + ' -- ' + OneLine(Col.Comment, Budget.MaxCommentLen);
      Lines.Add(Line);
    end;
    for f:=0 to High(Table.ForeignKeys) do begin
      if Length(Table.ForeignKeys[f].Columns) > 1 then
        Lines.Add('  FK (' + String.Join(', ', Table.ForeignKeys[f].Columns) + ') -> '
          + Table.ForeignKeys[f].RefTable + ' (' + String.Join(', ', Table.ForeignKeys[f].RefColumns) + ')');
    end;
    for Line in Table.Indexes do
      Lines.Add('  INDEX ' + Line);
    Lines.LineBreak := #10;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function FormatSchemaContext(const Tables: TAiSchemaTables; const DetailOrder: TStringArray;
  const Budget: TAiContextBudget): String;
var
  Detailed, NameOnly: TStringArray;
  Name, Block, NamesLine, Item: String;
  t, i, Listed: Integer;
begin
  Result := '';
  Detailed := nil;
  NameOnly := nil;
  for Name in DetailOrder do begin
    t := FindTable(Tables, Name);
    if (t < 0) or (not Tables[t].DetailLoaded) or (Length(Detailed) >= Budget.MaxDetailTables) then
      Continue;
    Block := FormatTableBlock(Tables[t], Budget);
    // Leave room for a short names line
    if Length(Result) + Length(Block) > Budget.MaxChars - 200 then
      Continue;
    Result := Result + Block;
    AddUnique(Detailed, Tables[t].Name);
  end;

  for i:=0 to High(Tables) do begin
    if IndexOfText(Detailed, Tables[i].Name) < 0 then
      AddUnique(NameOnly, Tables[i].Name);
  end;
  if Length(NameOnly) = 0 then
    Exit;

  NamesLine := IfThen(Length(Detailed) > 0, 'Other tables: ', 'Tables: ');
  Listed := 0;
  for Name in NameOnly do begin
    Item := NameLabel(Tables[FindTable(Tables, Name)]);
    if (Listed >= Budget.MaxTableNames)
      or (Length(Result) + Length(NamesLine) + Length(Item) + 40 > Budget.MaxChars) then
      Break;
    if Listed > 0 then
      NamesLine := NamesLine + ', ';
    NamesLine := NamesLine + Item;
    Inc(Listed);
  end;
  if Listed < Length(NameOnly) then
    NamesLine := NamesLine + IfThen(Listed > 0, ', ', '') + '... ' + IntToStr(Length(NameOnly) - Listed) + ' more';
  Result := Result + NamesLine + #10;
end;

end.
