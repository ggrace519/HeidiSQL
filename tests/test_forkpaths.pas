unit test_forkpaths;

{$mode delphi}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TForkPathsTest = class(TTestCase)
  published
    procedure SiblingFolderWithTrailingDelimiter;
    procedure SiblingFolderWithoutTrailingDelimiter;
    procedure ForkDirIsSiblingOfStockDir;
    procedure RewriteReplacesOnlyExactFolder;
    procedure RewriteHandlesJsonEscapedWindowsPaths;
    procedure RewriteKeepsUtf8AndLineEndings;
    procedure RewriteWithEmptyOldDirIsNoop;
  end;

implementation

uses
  SysUtils, forkpaths;

procedure TForkPathsTest.SiblingFolderWithTrailingDelimiter;
begin
  AssertEquals('/home/u/.config/heidisql-ai' + PathDelim,
    SiblingConfigDir('/home/u/.config/heidisql/', 'heidisql-ai'));
end;

procedure TForkPathsTest.SiblingFolderWithoutTrailingDelimiter;
begin
  AssertEquals('/home/u/.config/heidisql-ai' + PathDelim,
    SiblingConfigDir('/home/u/.config/heidisql', 'heidisql-ai'));
end;

procedure TForkPathsTest.ForkDirIsSiblingOfStockDir;
begin
  // Both derive from GetAppConfigDir; the fork folder must differ but share the parent
  AssertEquals('same parent', ExtractFilePath(ExcludeTrailingPathDelimiter(StockConfigDir)),
    ExtractFilePath(ExcludeTrailingPathDelimiter(ForkConfigDir)));
  AssertFalse('different folder', StockConfigDir = ForkConfigDir);
  AssertTrue('ends with heidisql-ai', ForkConfigDir.EndsWith('heidisql-ai' + PathDelim));
end;

procedure TForkPathsTest.RewriteReplacesOnlyExactFolder;
const
  Input = '{"a":"/h/.config/heidisql/Backups/x.sql","b":"/h/.config/heidisql-other/y"}';
begin
  AssertEquals('{"a":"/h/.config/heidisql-ai/Backups/x.sql","b":"/h/.config/heidisql-other/y"}',
    RewriteConfigDirPaths(Input, '/h/.config/heidisql/', '/h/.config/heidisql-ai/'));
end;

procedure TForkPathsTest.RewriteHandlesJsonEscapedWindowsPaths;
const
  Input = '{"a":"C:\\Users\\u\\AppData\\Local\\heidisql\\Snippets"}';
begin
  AssertEquals('{"a":"C:\\Users\\u\\AppData\\Local\\heidisql-ai\\Snippets"}',
    RewriteConfigDirPaths(Input, 'C:\Users\u\AppData\Local\heidisql\',
      'C:\Users\u\AppData\Local\heidisql-ai\'));
end;

procedure TForkPathsTest.RewriteKeepsUtf8AndLineEndings;
const
  Input = '{'#13#10'"n":"Café ✓",'#10'"p":"/c/heidisql/x"'#13#10'}';
begin
  AssertEquals('{'#13#10'"n":"Café ✓",'#10'"p":"/c/heidisql-ai/x"'#13#10'}',
    RewriteConfigDirPaths(Input, '/c/heidisql/', '/c/heidisql-ai/'));
end;

procedure TForkPathsTest.RewriteWithEmptyOldDirIsNoop;
begin
  AssertEquals('unchanged', 'abc', RewriteConfigDirPaths('abc', '', '/x/'));
end;

initialization
  RegisterTest(TForkPathsTest);

end.
