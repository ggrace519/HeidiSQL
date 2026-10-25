unit test_ai_profilechoice;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.profiles, ai.profilechoice;

type
  TAiProfileChoiceTest = class(TTestCase)
  private
    FList: TAiProfileList;
    FA, FB: TAiProfile;
    function Build(const StoredId: String; out Selected: Integer): TAiProfileChoices;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DefaultFirstWithName;
    procedure EmptyIdSelectsDefault;
    procedure ExistingIdSelected;
    procedure RemovedIdGetsOwnEntry;
    procedure DefaultStaysSelectableWhenRemoved;
    procedure NoProfilesAtAll;
  end;

implementation

function TAiProfileChoiceTest.Build(const StoredId: String; out Selected: Integer): TAiProfileChoices;
begin
  Result := BuildProfileChoices(FList, StoredId, 'Default (%s)', 'Default (none)', 'Removed', Selected);
end;

procedure TAiProfileChoiceTest.SetUp;
begin
  FList := TAiProfileList.Create;
  FA := NewAiProfile('Alpha');
  FB := NewAiProfile('Beta');
  FList.Add(FA);
  FList.Add(FB);
end;

procedure TAiProfileChoiceTest.TearDown;
begin
  FList.Free;
end;

procedure TAiProfileChoiceTest.DefaultFirstWithName;
var
  C: TAiProfileChoices;
  Sel: Integer;
begin
  C := Build('', Sel);
  AssertEquals(3, Length(C));
  AssertEquals('Default (Alpha)', C[0].Caption);
  AssertEquals('default has no id', '', C[0].ProfileId);
  AssertEquals('Beta', C[2].Caption);
  AssertEquals(FB.Id, C[2].ProfileId);
end;

procedure TAiProfileChoiceTest.EmptyIdSelectsDefault;
var
  Sel: Integer;
begin
  Build('', Sel);
  AssertEquals(0, Sel);
end;

procedure TAiProfileChoiceTest.ExistingIdSelected;
var
  C: TAiProfileChoices;
  Sel: Integer;
begin
  C := Build(FB.Id, Sel);
  AssertEquals(2, Sel);
  AssertEquals('no removed entry', 3, Length(C));
end;

procedure TAiProfileChoiceTest.RemovedIdGetsOwnEntry;
var
  C: TAiProfileChoices;
  Sel: Integer;
begin
  C := Build('{gone}', Sel);
  AssertEquals(4, Length(C));
  AssertEquals('removed entry selected', 3, Sel);
  AssertEquals('Removed', C[Sel].Caption);
  AssertEquals('keeps the stored id', '{gone}', C[Sel].ProfileId);
end;

procedure TAiProfileChoiceTest.DefaultStaysSelectableWhenRemoved;
var
  C: TAiProfileChoices;
  Sel: Integer;
begin
  // The regression from review: with a removed provider, choosing "Default" must store ''
  C := Build('{gone}', Sel);
  AssertFalse('default is a different entry', Sel = 0);
  AssertEquals('', C[0].ProfileId);
end;

procedure TAiProfileChoiceTest.NoProfilesAtAll;
var
  C: TAiProfileChoices;
  Sel: Integer;
begin
  FList.Clear;
  C := Build('', Sel);
  AssertEquals(1, Length(C));
  AssertEquals('Default (none)', C[0].Caption);
end;

initialization
  RegisterTest(TAiProfileChoiceTest);

end.
