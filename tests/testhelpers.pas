unit testhelpers;

// Shared helpers for the test units.

{$mode delphi}{$H+}

interface

// Absolute path of a file in tests/fixtures, independent of the working directory
function FixturePath(const Name: String): String;
// Content of a fixture file, byte for byte
function ReadFixture(const Name: String): String;

implementation

uses
  SysUtils, Classes;

function FixturePath(const Name: String): String;
begin
  // The test binary lives in out/tests/, fixtures in tests/fixtures/
  Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../../tests/fixtures/' + Name);
end;

function ReadFixture(const Name: String): String;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FixturePath(Name), fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

end.
