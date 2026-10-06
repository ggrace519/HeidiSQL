unit ai.text;

// Small text helpers for model input and output. Strings are UTF-8. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

// Shortens Text to at most MaxBytes bytes without cutting a UTF-8 sequence in half, and appends
// Suffix when shortened. Suffix is not counted in MaxBytes.
function Utf8Truncate(const Text: String; MaxBytes: Integer; const Suffix: String = '...'): String;

// Removes reasoning that some models emit inside the answer text:
// - <think>...</think> blocks,
// - an unclosed <think> block (answer still streaming or cut off), removed to the end,
// - text before a lone </think>, when the server opened the block in the prompt template.
function StripThinking(const Answer: String): String;

implementation

const
  OPENTAG = '<think>';
  CLOSETAG = '</think>';

function Utf8Truncate(const Text: String; MaxBytes: Integer; const Suffix: String = '...'): String;
var
  Len: Integer;
begin
  if (MaxBytes < 0) or (Length(Text) <= MaxBytes) then
    Exit(Text);
  Len := MaxBytes;
  // If the byte after the cut is a continuation byte (10xxxxxx), the cut is inside a sequence:
  // move it back to the sequence's lead byte, so the whole character is left out
  while (Len > 0) and ((Ord(Text[Len + 1]) and $C0) = $80) do
    Dec(Len);
  Result := Copy(Text, 1, Len) + Suffix;
end;

function StripThinking(const Answer: String): String;
var
  Lower: String;
  OpenPos, ClosePos: Integer;
begin
  Result := Answer;
  Lower := LowerCase(Result);
  // Lone closing tag: everything before it is reasoning
  ClosePos := Pos(CLOSETAG, Lower);
  OpenPos := Pos(OPENTAG, Lower);
  if (ClosePos > 0) and ((OpenPos = 0) or (OpenPos > ClosePos)) then
    Delete(Result, 1, ClosePos + Length(CLOSETAG) - 1);
  repeat
    Lower := LowerCase(Result);
    OpenPos := Pos(OPENTAG, Lower);
    if OpenPos = 0 then
      Break;
    ClosePos := Pos(CLOSETAG, Lower, OpenPos);
    if ClosePos = 0 then begin
      SetLength(Result, OpenPos - 1);
      Break;
    end;
    Delete(Result, OpenPos, ClosePos + Length(CLOSETAG) - OpenPos);
  until False;
  Result := Result.Trim;
end;

end.
