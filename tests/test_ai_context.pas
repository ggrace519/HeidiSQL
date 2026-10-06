unit test_ai_context;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.context;

type
  TAiContextTest = class(TTestCase)
  private
    function Shop: TAiSchemaTables;
  published
    procedure MentionsWholeWordsCaseInsensitive;
    procedure MentionsSingularAndPlural;
    procedure MentionsInQuotedSql;
    procedure PlanPriorityOrder;
    procedure PlanAllTablesWhenFew;
    procedure PlanCappedAtMax;
    procedure NeighboursFromForeignKeys;
    procedure FormatDetailedTable;
    procedure FormatCompositeForeignKeyAndIndexes;
    procedure FormatCommentsShortenedToOneLine;
    procedure FormatColumnCap;
    procedure FormatNameOnlyForTablesWithoutDetail;
    procedure LargeSchemaStaysWithinBudget;
    procedure EmptySchema;
    procedure CommentShortenedOnUtf8Boundary;
    procedure RowLabelsRoundToUnits;
    procedure HugeScriptScannedQuickly;
  end;

implementation

function Col(const Name, DataType: String; PK: Boolean = False; NotNull: Boolean = False;
  const Comment: String = ''): TAiSchemaColumn;
begin
  Result.Name := Name;
  Result.DataType := DataType;
  Result.PrimaryKey := PK;
  Result.NotNull := NotNull;
  Result.Comment := Comment;
end;

function Fk(const Columns: array of String; const RefTable: String; const RefColumns: array of String): TAiForeignKey;
var
  i: Integer;
begin
  SetLength(Result.Columns, Length(Columns));
  for i:=0 to High(Columns) do
    Result.Columns[i] := Columns[i];
  Result.RefTable := RefTable;
  SetLength(Result.RefColumns, Length(RefColumns));
  for i:=0 to High(RefColumns) do
    Result.RefColumns[i] := RefColumns[i];
end;

function TAiContextTest.Shop: TAiSchemaTables;
begin
  SetLength(Result, 4);
  Result[0].Name := 'customers';
  Result[0].RowsEstimate := 1200;
  Result[0].DetailLoaded := True;
  Result[0].Columns := [Col('id', 'int', True), Col('email', 'varchar(200)', False, True)];
  Result[1].Name := 'orders';
  Result[1].RowsEstimate := 12345;
  Result[1].Comment := 'Customer orders';
  Result[1].DetailLoaded := True;
  Result[1].Columns := [Col('id', 'int', True), Col('customer_id', 'int', False, True),
    Col('total', 'decimal(10,2)', False, False, 'Gross, in cents')];
  Result[1].ForeignKeys := [Fk(['customer_id'], 'customers', ['id'])];
  Result[2].Name := 'addresses';
  Result[2].RowsEstimate := -1;
  Result[3].Name := 'order_stats';
  Result[3].IsView := True;
  Result[3].RowsEstimate := 3500000;
end;

procedure TAiContextTest.MentionsWholeWordsCaseInsensitive;
var
  Found: TStringArray;
begin
  Found := FindMentionedTables('How many ORDERS per customer_id?', ['orders', 'customer', 'order_stats']);
  AssertEquals('count', 1, Length(Found));
  AssertEquals('orders', Found[0]);
end;

procedure TAiContextTest.MentionsSingularAndPlural;
var
  Found: TStringArray;
begin
  Found := FindMentionedTables('each order with its address and category, list statuses',
    ['orders', 'address', 'categories', 'status', 'users']);
  AssertEquals('count', 4, Length(Found));
  AssertEquals('orders', Found[0]);
  AssertEquals('address', Found[1]);
  AssertEquals('categories', Found[2]);
  AssertEquals('status', Found[3]);
end;

procedure TAiContextTest.MentionsInQuotedSql;
var
  Found: TStringArray;
begin
  Found := FindMentionedTables('SELECT * FROM `shop`.`orders` o JOIN "customers" c ON 1',
    ['customers', 'orders', 'shop_log']);
  AssertEquals('count', 2, Length(Found));
  AssertEquals('table list order kept', 'customers', Found[0]);
end;

procedure TAiContextTest.PlanPriorityOrder;
var
  Plan: TStringArray;
  Names: TStringArray;
  i: Integer;
begin
  SetLength(Names, 40);
  for i:=0 to High(Names) do
    Names[i] := 't' + IntToStr(i);
  Plan := PlanDetailTables(Names, 'compare t5 and t3', 'SELECT * FROM t9', 't7', 25);
  AssertEquals('only prioritised tables when many', 4, Length(Plan));
  AssertEquals('t3', Plan[0]);
  AssertEquals('t5', Plan[1]);
  AssertEquals('t9', Plan[2]);
  AssertEquals('t7', Plan[3]);
end;

procedure TAiContextTest.PlanAllTablesWhenFew;
var
  Plan: TStringArray;
begin
  Plan := PlanDetailTables(['a', 'b', 'c'], 'about c', '', '', 25);
  AssertEquals(3, Length(Plan));
  AssertEquals('mentioned first', 'c', Plan[0]);
end;

procedure TAiContextTest.PlanCappedAtMax;
var
  Names: TStringArray;
  i: Integer;
  Prompt: String;
begin
  SetLength(Names, 60);
  Prompt := '';
  for i:=0 to High(Names) do begin
    Names[i] := 'tab' + IntToStr(i);
    Prompt := Prompt + ' ' + Names[i];
  end;
  AssertEquals(25, Length(PlanDetailTables(Names, Prompt, '', '', 25)));
end;

procedure TAiContextTest.NeighboursFromForeignKeys;
var
  N: TStringArray;
begin
  N := ForeignKeyNeighbours(Shop, ['orders']);
  AssertEquals(1, Length(N));
  AssertEquals('customers', N[0]);
  AssertEquals('already detailed', 0, Length(ForeignKeyNeighbours(Shop, ['orders', 'customers'])));
end;

procedure TAiContextTest.FormatDetailedTable;
var
  Text: String;
begin
  Text := FormatSchemaContext(Shop, ['orders'], DefaultContextBudget);
  AssertTrue('header', Pos('orders (~12k rows) -- Customer orders'#10, Text) = 1);
  AssertTrue('pk', Pos('  id int PK'#10, Text) > 0);
  AssertTrue('fk on column', Pos('  customer_id int NOT NULL -> customers.id'#10, Text) > 0);
  AssertTrue('column comment', Pos('  total decimal(10,2) -- Gross, in cents'#10, Text) > 0);
  AssertTrue('others', Pos('Other tables: customers (~1200 rows), addresses, order_stats [view] (~4M rows)'#10, Text) > 0);
end;

procedure TAiContextTest.FormatCompositeForeignKeyAndIndexes;
var
  Tables: TAiSchemaTables;
  Text: String;
begin
  SetLength(Tables, 1);
  Tables[0].Name := 'lines';
  Tables[0].RowsEstimate := -1;
  Tables[0].DetailLoaded := True;
  Tables[0].Columns := [Col('order_id', 'int', True), Col('pos', 'int', True)];
  Tables[0].ForeignKeys := [Fk(['order_id', 'pos'], 'plan', ['a', 'b'])];
  Tables[0].Indexes := ['idx_pos (pos)'];
  Text := FormatSchemaContext(Tables, ['lines'], DefaultContextBudget);
  AssertTrue('composite fk', Pos('  FK (order_id, pos) -> plan (a, b)'#10, Text) > 0);
  AssertTrue('index', Pos('  INDEX idx_pos (pos)'#10, Text) > 0);
  AssertTrue('no names line when all detailed', Pos('tables:', LowerCase(Text)) = 0);
end;

procedure TAiContextTest.FormatCommentsShortenedToOneLine;
var
  Tables: TAiSchemaTables;
  Text: String;
begin
  SetLength(Tables, 1);
  Tables[0].Name := 't';
  Tables[0].RowsEstimate := -1;
  Tables[0].DetailLoaded := True;
  Tables[0].Comment := 'line1'#13#10'line2 ' + StringOfChar('x', 200);
  Text := FormatSchemaContext(Tables, ['t'], DefaultContextBudget);
  AssertEquals('one header line, shortened', 't -- line1 line2 ' + StringOfChar('x', 80 - 15) + '...'#10, Text);
end;

procedure TAiContextTest.FormatColumnCap;
var
  Tables: TAiSchemaTables;
  i: Integer;
  Budget: TAiContextBudget;
  Text: String;
begin
  SetLength(Tables, 1);
  Tables[0].Name := 'wide';
  Tables[0].RowsEstimate := -1;
  Tables[0].DetailLoaded := True;
  SetLength(Tables[0].Columns, 70);
  for i:=0 to 69 do
    Tables[0].Columns[i] := Col('c' + IntToStr(i), 'int');
  Budget := DefaultContextBudget;
  Text := FormatSchemaContext(Tables, ['wide'], Budget);
  AssertTrue('last shown', Pos('  c49 int'#10, Text) > 0);
  AssertTrue('not shown', Pos('  c50 int', Text) = 0);
  AssertTrue('marker', Pos('  ... +20 columns'#10, Text) > 0);
end;

procedure TAiContextTest.FormatNameOnlyForTablesWithoutDetail;
var
  Text: String;
begin
  // addresses is requested in detail but has no loaded detail: listed by name only
  Text := FormatSchemaContext(Shop, ['addresses'], DefaultContextBudget);
  AssertTrue(Pos('Tables: customers (~1200 rows), orders (~12k rows), addresses, order_stats', Text) = 1);
end;

procedure TAiContextTest.LargeSchemaStaysWithinBudget;
var
  Tables: TAiSchemaTables;
  Order: TStringArray;
  i, c: Integer;
  Budget: TAiContextBudget;
  Text: String;
begin
  SetLength(Tables, 2000);
  SetLength(Order, 2000);
  for i:=0 to High(Tables) do begin
    Tables[i].Name := 'table_with_a_long_name_' + IntToStr(i);
    Tables[i].RowsEstimate := i * 100;
    Tables[i].DetailLoaded := True;
    SetLength(Tables[i].Columns, 30);
    for c:=0 to 29 do
      Tables[i].Columns[c] := Col('column_' + IntToStr(c), 'varchar(255)', c = 0, c < 5);
    Order[i] := Tables[i].Name;
  end;
  Budget := DefaultContextBudget;
  Text := FormatSchemaContext(Tables, Order, Budget);
  AssertTrue('within budget: ' + IntToStr(Length(Text)), Length(Text) <= Budget.MaxChars);
  AssertTrue('first table detailed', Pos('table_with_a_long_name_0 (~0 rows)'#10'  column_0 varchar(255) PK'#10, Text) = 1);
  AssertTrue('omission marker', Pos(' more'#10, Text) > 0);
end;

procedure TAiContextTest.EmptySchema;
begin
  AssertEquals('', FormatSchemaContext(nil, nil, DefaultContextBudget));
end;

procedure TAiContextTest.CommentShortenedOnUtf8Boundary;
var
  Tables: TAiSchemaTables;
  Text, Header: String;
begin
  SetLength(Tables, 1);
  Tables[0].Name := 't';
  Tables[0].RowsEstimate := -1;
  Tables[0].DetailLoaded := True;
  // 76 ASCII characters, then "ü" (2 bytes) across the cut at byte 77
  Tables[0].Comment := StringOfChar('x', 76) + #$C3#$BC + StringOfChar('y', 20);
  Text := FormatSchemaContext(Tables, ['t'], DefaultContextBudget);
  Header := Copy(Text, 1, Pos(#10, Text) - 1);
  AssertEquals('t -- ' + StringOfChar('x', 76) + '...', Header);
end;

procedure TAiContextTest.RowLabelsRoundToUnits;
var
  Tables: TAiSchemaTables;
  Text: String;
begin
  SetLength(Tables, 2);
  Tables[0].Name := 'a';
  Tables[0].RowsEstimate := 999999;
  Tables[1].Name := 'b';
  Tables[1].RowsEstimate := 999499;
  Text := FormatSchemaContext(Tables, nil, DefaultContextBudget);
  AssertEquals('Tables: a (~1M rows), b (~999k rows)'#10, Text);
end;

procedure TAiContextTest.HugeScriptScannedQuickly;
var
  Names: TStringArray;
  Script: String;
  i: Integer;
  Started: QWord;
begin
  SetLength(Names, 2000);
  for i:=0 to High(Names) do
    Names[i] := 'table_' + IntToStr(i);
  Script := '';
  for i:=1 to 20000 do
    Script := Script + 'SELECT col_' + IntToStr(i) + ' FROM table_' + IntToStr(i mod 3000) + ';'#10;
  Started := GetTickCount64;
  AssertTrue('found some', Length(PlanDetailTables(Names, 'q', Script, '', 25)) = 25);
  AssertTrue('took ' + IntToStr(GetTickCount64 - Started) + ' ms', GetTickCount64 - Started < 1000);
end;

initialization
  RegisterTest(TAiContextTest);

end.
