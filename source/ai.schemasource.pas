unit ai.schemasource;

// Reads the schema of the active database into ai.context records and formats it for a prompt.
// Main thread only: TDBConnection is not thread-safe. While a query thread holds the connection,
// only already cached object lists and columns are used, so no server round-trip happens.

{$mode delphi}{$H+}

interface

uses
  SysUtils, dbconnection, dbstructures, ai.context;

type
  TAiSchemaInput = record
    Database: String;
    Prompt: String;        // The user's question, scanned for table names
    Sql: String;           // Current or selected SQL, scanned for table names
    ActiveObject: String;  // Table or view selected in the tree, may be empty
    ConnectionBusy: Boolean; // A query thread uses the connection, see TAiHostState
    Budget: TAiContextBudget;
  end;

  TAiSchemaResult = record
    Context: String;       // Formatted schema, may be empty
    CacheOnly: Boolean;    // The connection was busy, so only cached data was used
    TableCount: Integer;
    DetailCount: Integer;  // Tables whose columns were available
  end;

const
  // No further tables are fetched in detail after this time; the remaining ones are listed by
  // name. A single table's fetch is not interrupted, so a slow server can still exceed it.
  SCHEMAFETCHBUDGETMS = 3000;

function GatherSchemaContext(Conn: TDBConnection; const Input: TAiSchemaInput): TAiSchemaResult;

implementation

uses
  Classes, Math;

function ColumnRecord(Col: TTableColumn; const PrimaryCols: TStringList): TAiSchemaColumn;
begin
  Result.Name := Col.Name;
  Result.DataType := Col.FullDataType;
  Result.NotNull := not Col.AllowNull;
  Result.PrimaryKey := PrimaryCols.IndexOf(Col.Name) >= 0;
  Result.Comment := Col.Comment;
end;

function JoinNames(List: TStringList): String;
var
  i: Integer;
begin
  Result := '';
  for i:=0 to List.Count-1 do begin
    if i > 0 then
      Result := Result + ', ';
    Result := Result + List[i];
  end;
end;

function ToArray(List: TStringList): TStringArray;
var
  i: Integer;
begin
  SetLength(Result, List.Count);
  for i:=0 to List.Count-1 do
    Result[i] := List[i];
end;

// Fills columns, keys and foreign keys of one table. With CacheOnly, only the connection's caches
// are read; returns False when the columns are not cached.
function LoadDetail(Obj: TDBObject; CacheOnly: Boolean; var Table: TAiSchemaTable): Boolean;
var
  Conn: TDBConnection;
  CacheKey: String;
  Columns: TTableColumnList;
  Keys: TTableKeyList;
  ForeignKeys: TForeignKeyList;
  OwnColumns, OwnKeys, OwnForeignKeys: Boolean;
  PrimaryCols: TStringList;
  Key: TTableKey;
  Fk: TForeignKey;
  i: Integer;
begin
  Conn := Obj.Connection;
  CacheKey := Obj.QuotedDbAndTableName;
  Columns := nil;
  Keys := nil;
  ForeignKeys := nil;
  OwnColumns := not CacheOnly;
  OwnKeys := not CacheOnly;
  OwnForeignKeys := not CacheOnly;
  PrimaryCols := TStringList.Create;
  try
    if CacheOnly then begin
      if not Conn.ColumnCache.TryGetValue(CacheKey, Columns) then
        Exit(False);
      Conn.KeyCache.TryGetValue(CacheKey, Keys);
      Conn.ForeignKeyCache.TryGetValue(CacheKey, ForeignKeys);
    end else begin
      // These getters fill the connection's caches and return copies
      Columns := Obj.TableColumns;
      if Obj.NodeType = lntTable then begin
        Keys := Obj.TableKeys;
        ForeignKeys := Obj.TableForeignKeys;
      end;
    end;

    if Assigned(Keys) then begin
      for Key in Keys do begin
        if Key.IndexType = TTableKey.PRIMARY then
          PrimaryCols.AddStrings(Key.Columns)
        else
          Table.Indexes := Table.Indexes + [Key.Name + ' (' + JoinNames(Key.Columns) + ')'];
      end;
    end;

    SetLength(Table.Columns, Columns.Count);
    for i:=0 to Columns.Count-1 do
      Table.Columns[i] := ColumnRecord(Columns[i], PrimaryCols);

    if Assigned(ForeignKeys) then begin
      for Fk in ForeignKeys do begin
        // Only references within this database are useful for joins in the prompt
        if (Fk.ReferenceDb <> '') and (Fk.ReferenceDb <> Obj.Database) then
          Continue;
        SetLength(Table.ForeignKeys, Length(Table.ForeignKeys)+1);
        Table.ForeignKeys[High(Table.ForeignKeys)].Columns := ToArray(Fk.Columns);
        Table.ForeignKeys[High(Table.ForeignKeys)].RefTable := Fk.ReferenceTable;
        Table.ForeignKeys[High(Table.ForeignKeys)].RefColumns := ToArray(Fk.ForeignColumns);
      end;
    end;
    Table.DetailLoaded := True;
    Result := True;
  finally
    PrimaryCols.Free;
    if OwnColumns then Columns.Free;
    if OwnKeys then Keys.Free;
    if OwnForeignKeys then ForeignKeys.Free;
  end;
end;

function IndexOfName(const Tables: TAiSchemaTables; const Name: String): Integer;
var
  i: Integer;
begin
  for i:=0 to High(Tables) do begin
    if SameText(Tables[i].Name, Name) then
      Exit(i);
  end;
  Result := -1;
end;

function GatherSchemaContext(Conn: TDBConnection; const Input: TAiSchemaInput): TAiSchemaResult;
var
  Objects: TDBObjectList;
  Objs: array of TDBObject;
  Tables: TAiSchemaTables;
  Names, Planned, Neighbours, Order: TStringArray;
  Obj: TDBObject;
  Started: QWord;
  Name: String;
  t: Integer;

  procedure LoadPlanned(const List: TStringArray);
  var
    Name: String;
    t: Integer;
  begin
    for Name in List do begin
      t := IndexOfName(Tables, Name);
      if (t < 0) or Tables[t].DetailLoaded then
        Continue;
      if GetTickCount64 - Started > SCHEMAFETCHBUDGETMS then
        Break;
      try
        if LoadDetail(Objs[t], Result.CacheOnly, Tables[t]) then
          Inc(Result.DetailCount);
      except
        // A table the user cannot read, or dropped meanwhile: keep it as a name only
        on E:EDbError do
          Tables[t].DetailLoaded := False;
      end;
    end;
  end;

begin
  Result := Default(TAiSchemaResult);
  if (Conn = nil) or (Input.Database = '') then
    Exit;
  Result.CacheOnly := Conn.IsLockedByThread or Input.ConnectionBusy;
  if Result.CacheOnly and (not Conn.DbObjectsCached(Input.Database)) then
    Exit;

  Objects := Conn.GetDBObjects(Input.Database);
  Tables := nil;
  Objs := nil;
  for Obj in Objects do begin
    if not (Obj.NodeType in [lntTable, lntView]) then
      Continue;
    SetLength(Tables, Length(Tables)+1);
    SetLength(Objs, Length(Objs)+1);
    t := High(Tables);
    Objs[t] := Obj;
    Tables[t] := Default(TAiSchemaTable);
    Tables[t].Name := Obj.Name;
    Tables[t].IsView := Obj.NodeType = lntView;
    Tables[t].Comment := Obj.Comment;
    if Tables[t].IsView or (Obj.Rows < 0) then
      Tables[t].RowsEstimate := -1
    else
      Tables[t].RowsEstimate := Obj.Rows;
  end;
  Result.TableCount := Length(Tables);
  if Result.TableCount = 0 then
    Exit;

  SetLength(Names, Length(Tables));
  for t:=0 to High(Tables) do
    Names[t] := Tables[t].Name;

  Started := GetTickCount64;
  Planned := PlanDetailTables(Names, Input.Prompt, Input.Sql, Input.ActiveObject,
    Input.Budget.MaxDetailTables);
  LoadPlanned(Planned);
  Neighbours := ForeignKeyNeighbours(Tables, Planned);
  if Length(Planned) + Length(Neighbours) > Input.Budget.MaxDetailTables then
    SetLength(Neighbours, Max(0, Input.Budget.MaxDetailTables - Length(Planned)));
  LoadPlanned(Neighbours);

  Order := nil;
  for Name in Planned do
    Order := Order + [Name];
  for Name in Neighbours do
    Order := Order + [Name];
  Result.Context := FormatSchemaContext(Tables, Order, Input.Budget);
end;

end.
