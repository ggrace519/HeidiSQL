unit test_ai_keychain;

// The platform keychain backend against the real keychain: store, read, resolve and remove a
// dummy entry. Only with HEIDISQL_TEST_KEYCHAIN=1, so a normal test run never touches the
// user's keychain (CI sets it on Windows, where the Credential Manager is always usable).

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.profiles, ai.keystore,
  ai.keystore.libsecret, ai.keystore.windows, ai.keystore.macos;

type
  TAiKeychainTest = class(TTestCase)
  published
    procedure MacStoreCommandQuotesAccount;
    procedure RoundTripWithDummyEntry;
  end;

implementation

const
  PROBEACCOUNT = 'heidisql-ai-test-probe';
  PROBESECRET = 'dummy-value Café ✓';

procedure TAiKeychainTest.MacStoreCommandQuotesAccount;
begin
  AssertEquals('security add-generic-password -U -s heidisql-ai -a ''it''\''''s'' -w',
    MacStoreCommand('it''s'));
end;

procedure TAiKeychainTest.RoundTripWithDummyEntry;
var
  Problem, Secret, Key: String;
  Profile: TAiProfile;
begin
  if GetEnvironmentVariable('HEIDISQL_TEST_KEYCHAIN') <> '1' then
    Ignore('set HEIDISQL_TEST_KEYCHAIN=1 to test against the real keychain');
  if Keychain = nil then
    Ignore('no keychain backend on this platform');
  if not Keychain.Available(Problem) then
    Fail('keychain not available: ' + Problem);
  {$IFDEF DARWIN}
  Ignore('storing is done in Terminal on macOS');
  {$ENDIF}
  try
    AssertTrue('store: ' + Problem, Keychain.Store(PROBEACCOUNT, PROBESECRET, Problem));
    AssertTrue('lookup', Keychain.Lookup(PROBEACCOUNT, Secret, Problem) = krFound);
    AssertEquals('same secret, UTF-8 intact', PROBESECRET, Secret);
    Profile := NewAiProfile('probe');
    Profile.KeySource := ksKeychain;
    Profile.KeyName := PROBEACCOUNT;
    AssertTrue('resolve', ResolveApiKey(Profile, Key, Problem) = krFound);
    AssertEquals(PROBESECRET, Key);
  finally
    Keychain.Remove(PROBEACCOUNT, Problem);
  end;
  AssertTrue('removed', Keychain.Lookup(PROBEACCOUNT, Secret, Problem) = krKeychainNotFound);
  AssertTrue('removing a missing entry is fine', Keychain.Remove(PROBEACCOUNT, Problem));
end;

initialization
  RegisterTest(TAiKeychainTest);

end.
