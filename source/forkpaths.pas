unit forkpaths;

// Settings folder locations of the AI Edition fork versus a stock HeidiSQL on the same machine.
// No LCL dependencies, so the path logic can be unit tested.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

// Settings folder of a stock HeidiSQL, e.g. ~/.config/heidisql/
function StockConfigDir: String;
// Settings folder of this fork, a sibling of the stock one, e.g. ~/.config/heidisql-ai/
function ForkConfigDir: String;
// Sibling folder of StockDir, named NewName, with trailing path delimiter
function SiblingConfigDir(const StockDir, NewName: String): String;
// Replace absolute paths pointing into OldDir with NewDir, in the text of a settings.json file.
// Handles both plain and JSON-escaped backslashes, as Windows paths are stored escaped.
function RewriteConfigDirPaths(const Json, OldDir, NewDir: String): String;

implementation

{$I const.inc}

function SiblingConfigDir(const StockDir, NewName: String): String;
begin
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(StockDir)) + NewName;
  Result := IncludeTrailingPathDelimiter(Result);
end;

function StockConfigDir: String;
begin
  // GetAppConfigDir's last segment is ApplicationName, which apphelpers pins to "heidisql"
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False));
end;

function ForkConfigDir: String;
begin
  Result := SiblingConfigDir(StockConfigDir, APPCONFIGDIRNAME);
end;

function RewriteConfigDirPaths(const Json, OldDir, NewDir: String): String;
var
  OldDirEsc, NewDirEsc: String;
begin
  Result := Json;
  if (OldDir = '') or (OldDir = NewDir) then
    Exit;
  Result := StringReplace(Result, OldDir, NewDir, [rfReplaceAll]);
  OldDirEsc := StringReplace(OldDir, '\', '\\', [rfReplaceAll]);
  NewDirEsc := StringReplace(NewDir, '\', '\\', [rfReplaceAll]);
  if OldDirEsc <> OldDir then
    Result := StringReplace(Result, OldDirEsc, NewDirEsc, [rfReplaceAll]);
end;

end.
