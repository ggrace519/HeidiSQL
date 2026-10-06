unit test_ai_sqlextract;

{$mode delphi}{$H+}

interface

uses
  fpcunit, testregistry, ai.sqlextract;

type
  TSqlExtractTest = class(TTestCase)
  published
    procedure ThinkBlocksRemoved;
    procedure UnclosedThinkBlockRemovedToEnd;
    procedure SqlFenceWins;
    procedure DialectTaggedFence;
    procedure FenceInfoStringWithExtraWords;
    procedure UntaggedFenceAsFallback;
    procedure ForeignFenceSkipped;
    procedure CrLfAnswer;
    procedure BareSqlAnswer;
    procedure ProseOnlyGivesEmpty;
    procedure ReadOnlyStatements;
    procedure DataModifyingStatements;
    procedure SchemaModifyingStatements;
    procedure KeywordsInLiteralsAndCommentsIgnored;
    procedure KeywordsAsPartOfIdentifiersIgnored;
    procedure DollarQuotedBodyIgnored;
    procedure SelectForUpdateIsConservative;
  end;

implementation

procedure TSqlExtractTest.ThinkBlocksRemoved;
begin
  AssertEquals('Answer', StripThinking('<think>reasoning'#10'more</think>'#10'Answer'));
  AssertEquals('a b', StripThinking('a <THINK>x</THINK>b'));
end;

procedure TSqlExtractTest.UnclosedThinkBlockRemovedToEnd;
begin
  AssertEquals('Intro', StripThinking('Intro <think>still thinking...'));
end;

procedure TSqlExtractTest.SqlFenceWins;
const
  Answer = 'Here you go:'#10'```text'#10'not this'#10'```'#10'```sql'#10 +
    'SELECT COUNT(*) FROM orders;'#10'```'#10'```sql'#10'SELECT 2;'#10'```';
begin
  AssertEquals('SELECT COUNT(*) FROM orders;', ExtractSql(Answer));
end;

procedure TSqlExtractTest.DialectTaggedFence;
begin
  AssertEquals('SELECT 1', ExtractSql('```PostgreSQL'#10'SELECT 1'#10'```'));
  AssertEquals('SELECT 1', ExtractSql('```mysql'#10'SELECT 1'#10'```'));
end;

procedure TSqlExtractTest.FenceInfoStringWithExtraWords;
begin
  AssertEquals('SELECT 1', ExtractSql('```sql title="q"'#10'SELECT 1'#10'```'));
end;

procedure TSqlExtractTest.UntaggedFenceAsFallback;
begin
  AssertEquals('SELECT a,'#10'  b'#10'FROM t', ExtractSql('Try:'#10'```'#10'SELECT a,'#10'  b'#10'FROM t'#10'```'));
end;

procedure TSqlExtractTest.ForeignFenceSkipped;
const
  // The closing ``` of the python fence must not be taken as an opening untagged fence
  Answer = '```python'#10'print(1)'#10'```'#10'Then:'#10'```'#10'SELECT 3'#10'```';
begin
  AssertEquals('SELECT 3', ExtractSql(Answer));
end;

procedure TSqlExtractTest.CrLfAnswer;
begin
  AssertEquals('SELECT 1', ExtractSql('```sql'#13#10'SELECT 1'#13#10'```'#13#10));
end;

procedure TSqlExtractTest.BareSqlAnswer;
begin
  AssertEquals('with x as (select 1) select * from x',
    ExtractSql('  with x as (select 1) select * from x  '));
  AssertEquals('after thinking', 'SELECT 1', ExtractSql('<think>hmm</think>SELECT 1'));
end;

procedure TSqlExtractTest.ProseOnlyGivesEmpty;
begin
  AssertEquals('', ExtractSql('I cannot answer that without the table name.'));
  AssertEquals('', ExtractSql(''));
end;

procedure TSqlExtractTest.ReadOnlyStatements;
begin
  AssertTrue('select', SqlEffects('SELECT a FROM t WHERE b = 1') = []);
  AssertTrue('show', SqlEffects('SHOW TABLES') = []);
  AssertTrue('explain', SqlEffects('EXPLAIN SELECT 1') = []);
end;

procedure TSqlExtractTest.DataModifyingStatements;
begin
  AssertTrue('insert', SqlEffects('INSERT INTO t VALUES (1)') = [seModifiesData]);
  AssertTrue('lowercase update', SqlEffects('update t set a=1') = [seModifiesData]);
  AssertTrue('delete in CTE', SqlEffects('WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d') = [seModifiesData]);
  AssertTrue('second statement', SqlEffects('SELECT 1; TRUNCATE t') = [seModifiesData]);
end;

procedure TSqlExtractTest.SchemaModifyingStatements;
begin
  AssertTrue('drop', SqlEffects('DROP TABLE t') = [seModifiesSchema]);
  AssertTrue('create index', SqlEffects('create index i on t(a)') = [seModifiesSchema]);
  AssertTrue('grant', SqlEffects('GRANT SELECT ON t TO u') = [seModifiesSchema]);
  AssertTrue('both', SqlEffects('ALTER TABLE t ADD c INT; UPDATE t SET c=1') = [seModifiesData, seModifiesSchema]);
end;

procedure TSqlExtractTest.KeywordsInLiteralsAndCommentsIgnored;
begin
  AssertTrue('string', SqlEffects('SELECT ''DROP TABLE x'' AS s') = []);
  AssertTrue('escaped quote', SqlEffects('SELECT ''it''''s; DELETE'' FROM t') = []);
  AssertTrue('backslash escape', SqlEffects('SELECT ''a\'' DELETE'' FROM t') = []);
  AssertTrue('line comment', SqlEffects('SELECT 1 -- DELETE FROM t'#10'FROM dual') = []);
  AssertTrue('hash comment', SqlEffects('SELECT 1 # drop'#10) = []);
  AssertTrue('block comment', SqlEffects('SELECT /* UPDATE t */ 1') = []);
  AssertTrue('quoted identifiers', SqlEffects('SELECT `delete`, "update", [drop] FROM t') = []);
  AssertTrue('code after comment still checked', SqlEffects('/* x */ DELETE FROM t') = [seModifiesData]);
end;

procedure TSqlExtractTest.KeywordsAsPartOfIdentifiersIgnored;
begin
  AssertTrue(SqlEffects('SELECT update_time, created_by, t.deleted, comment FROM posts') = []);
end;

procedure TSqlExtractTest.DollarQuotedBodyIgnored;
begin
  AssertTrue('body masked', SqlEffects('SELECT $body$ DELETE FROM t $body$') = []);
  AssertTrue('function', SqlEffects('CREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql') = [seModifiesSchema]);
end;

procedure TSqlExtractTest.SelectForUpdateIsConservative;
begin
  AssertTrue(SqlEffects('SELECT * FROM t FOR UPDATE') = [seModifiesData]);
end;

initialization
  RegisterTest(TSqlExtractTest);

end.
