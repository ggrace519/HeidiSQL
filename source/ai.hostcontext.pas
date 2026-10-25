unit ai.hostcontext;

// The AI assistant's only view into the main window: what the active query tab, connection and
// database are, and putting generated SQL into a query editor. Keeps main.pas details out of the
// other ai.* units. Main thread only.

{$mode delphi}{$H+}

interface

uses
  SysUtils, dbconnection, apphelpers;

type
  TAiHostState = record
    HasQueryTab: Boolean;
    TabNumber: Integer;        // Stable while the tab exists; the tab's Uid is blanked by "Clear"
    ConversationKey: String;   // Tab and session, see ai.conversations
    Connection: TDBConnection; // nil when not connected
    SessionName: String;
    SessionPath: String;       // Empty for sessions which are not saved
    Database: String;
    ActiveObject: String;      // Selected table or view in the database tree
    Sql: String;               // Selected text or the whole editor text, only with WithSql
    Dialect: String;           // e.g. "MySQL 8.0.35"
  end;

// WithSql also reads the editor text, which can be large; only needed when sending
function CaptureHostState(WithSql: Boolean): TAiHostState;
function QueryTabExists(TabNumber: Integer): Boolean;
// Puts Sql into the editor of the given tab, at the cursor (replacing a selection) or replacing
// the whole text. Never runs it. Returns False when the tab no longer exists.
function PutSqlIntoQueryTab(TabNumber: Integer; const Sql: String; ReplaceAll: Boolean): Boolean;
// SQL of the statement that failed in a finished query thread, '' without an error. With "send
// batch in one go", the server ran a whole packet, so all of its statements are returned.
function FailedStatementSql(Thread: TQueryThread): String;

implementation

uses
  Classes, Math, SynEdit, main, ai.conversations;

const
  // Only the start of a huge editor text is scanned for table names
  MAXSQLCHARS = 100000;

function FindTab(TabNumber: Integer): TQueryTab;
begin
  Result := nil;
  if (TabNumber > 0) and Assigned(MainForm) then
    Result := MainForm.QueryTabs.TabByNumber(TabNumber);
end;

function SessionSaved(const Path: String): Boolean;
begin
  Result := (Path <> '') and AppSettings.SessionPathExists(Path);
end;

function CaptureHostState(WithSql: Boolean): TAiHostState;
var
  Tab: TQueryTab;
  Conn: TDBConnection;
  Obj: TDBObject;
begin
  Result := Default(TAiHostState);
  if (MainForm = nil) or (csDestroying in MainForm.ComponentState) then
    Exit;
  Result.HasQueryTab := MainForm.QueryTabs.HasActiveTab;
  if Result.HasQueryTab then begin
    Tab := MainForm.QueryTabs.ActiveTab;
    Result.TabNumber := Tab.Number;
    if WithSql then begin
      if Tab.Memo.SelAvail then
        Result.Sql := Tab.Memo.SelText
      else
        Result.Sql := Tab.Memo.Text;
      Result.Sql := Copy(Result.Sql, 1, MAXSQLCHARS);
    end;
  end;

  Conn := MainForm.ActiveConnection;
  if Conn = nil then
    Exit;
  Result.Connection := Conn;
  Result.SessionName := Conn.Parameters.SessionName;
  if SessionSaved(Conn.Parameters.SessionPath) then
    Result.SessionPath := Conn.Parameters.SessionPath;
  if Result.HasQueryTab then
    Result.ConversationKey := ConversationKey(Result.TabNumber, Conn.Parameters.SessionPath);
  Result.Database := MainForm.ActiveDatabase;
  Result.Dialect := Conn.Parameters.NetTypeName(False) + ' ' + Conn.ServerVersionStr;
  Obj := MainForm.ActiveDbObj;
  if Assigned(Obj) and (Obj.Connection = Conn) and (Obj.NodeType in [lntTable, lntView]) then
    Result.ActiveObject := Obj.Name;
end;

function QueryTabExists(TabNumber: Integer): Boolean;
begin
  Result := FindTab(TabNumber) <> nil;
end;

function PutSqlIntoQueryTab(TabNumber: Integer; const Sql: String; ReplaceAll: Boolean): Boolean;
var
  Tab: TQueryTab;
  Memo: TSynEdit;
begin
  Tab := FindTab(TabNumber);
  Result := Assigned(Tab);
  if not Result then
    Exit;
  Memo := Tab.Memo;
  // One undo step, so Ctrl+Z restores the previous text
  Memo.BeginUndoBlock;
  try
    if ReplaceAll then
      Memo.SelectAll;
    Memo.SelText := Sql;
  finally
    Memo.EndUndoBlock;
  end;
  Memo.Modified := True;
  if Memo.CanFocus then
    Memo.SetFocus;
end;

function FailedStatementSql(Thread: TQueryThread): String;
var
  i, Last: Integer;
begin
  Result := '';
  if (Thread.ErrorMessage = '') or (Thread.BatchPosition >= Thread.Batch.Count) then
    Exit;
  Last := Thread.BatchPosition;
  if Thread.BatchInOneGo then
    Last := Min(Thread.Batch.Count, Thread.BatchPosition + Max(1, Thread.QueriesInPacket)) - 1;
  for i:=Thread.BatchPosition to Last do begin
    if Result <> '' then
      Result := Result + ';' + sLineBreak;
    Result := Result + Thread.Batch[i].SQL;
  end;
  Result := Copy(Result, 1, MAXSQLCHARS);
end;

end.
