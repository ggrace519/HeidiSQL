unit ai.hostcontext;

// The AI assistant's only view into the main window: what the active query tab, connection and
// database are, and putting generated SQL into a query editor. Keeps main.pas details out of the
// other ai.* units. Main thread only.

{$mode delphi}{$H+}

interface

uses
  SysUtils, dbconnection;

type
  TAiHostState = record
    HasQueryTab: Boolean;
    TabUid: String;
    Connection: TDBConnection; // nil when not connected
    SessionName: String;
    SessionPath: String;       // Empty for sessions which are not saved
    Database: String;
    ActiveObject: String;      // Selected table or view in the database tree
    Sql: String;               // Selected text in the editor, or the whole editor text
    Dialect: String;           // e.g. "MySQL 8.0.35"
  end;

function CaptureHostState: TAiHostState;
function QueryTabExists(const TabUid: String): Boolean;
// Puts Sql into the editor of the given tab, at the cursor (replacing a selection) or replacing
// the whole text. Never runs it. Returns False when the tab no longer exists.
function PutSqlIntoQueryTab(const TabUid, Sql: String; ReplaceAll: Boolean): Boolean;

implementation

uses
  Classes, SynEdit, main, apphelpers;

const
  // Only the start of a huge editor text is scanned for table names
  MAXSQLCHARS = 100000;

function FindTab(const TabUid: String): TQueryTab;
var
  Tab: TQueryTab;
begin
  Result := nil;
  if (TabUid = '') or (MainForm = nil) then
    Exit;
  for Tab in MainForm.QueryTabs do begin
    if Tab.Uid = TabUid then
      Exit(Tab);
  end;
end;

function SessionSaved(const Path: String): Boolean;
begin
  Result := (Path <> '') and AppSettings.SessionPathExists(Path);
end;

function CaptureHostState: TAiHostState;
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
    Result.TabUid := Tab.Uid;
    if Tab.Memo.SelAvail then
      Result.Sql := Tab.Memo.SelText
    else
      Result.Sql := Tab.Memo.Text;
    Result.Sql := Copy(Result.Sql, 1, MAXSQLCHARS);
  end;

  Conn := MainForm.ActiveConnection;
  if Conn = nil then
    Exit;
  Result.Connection := Conn;
  Result.SessionName := Conn.Parameters.SessionName;
  if SessionSaved(Conn.Parameters.SessionPath) then
    Result.SessionPath := Conn.Parameters.SessionPath;
  Result.Database := MainForm.ActiveDatabase;
  Result.Dialect := Conn.Parameters.NetTypeName(False) + ' ' + Conn.ServerVersionStr;
  Obj := MainForm.ActiveDbObj;
  if Assigned(Obj) and (Obj.Connection = Conn) and (Obj.NodeType in [lntTable, lntView]) then
    Result.ActiveObject := Obj.Name;
end;

function QueryTabExists(const TabUid: String): Boolean;
begin
  Result := FindTab(TabUid) <> nil;
end;

function PutSqlIntoQueryTab(const TabUid, Sql: String; ReplaceAll: Boolean): Boolean;
var
  Tab: TQueryTab;
  Memo: TSynEdit;
begin
  Tab := FindTab(TabUid);
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

end.
