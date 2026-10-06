unit test_ai_sqlextract;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.text, ai.sqlextract;

type
  TAiTextTest = class(TTestCase)
  published
    procedure ThinkBlocksRemoved;
    procedure UnclosedThinkBlockRemovedToEnd;
    procedure LoneClosingThinkTag;
    procedure TruncateKeepsUtf8Intact;
    procedure TruncateShortTextUnchanged;
  end;

  TSqlExtractTest = class(TTestCase)
  published
    procedure SqlFenceWins;
    procedure DialectTaggedFence;
    procedure FenceInfoStringWithExtraWords;
    procedure UntaggedFenceAsFallback;
    procedure ForeignFenceSkipped;
    procedure LongerFenceContainingBackticks;
    procedure CrLfAnswer;
    procedure BareSqlAnswer;
    procedure ProseIsNotSql;
    procedure AllSqlBlocks;
  end;

  TSqlEffectsTest = class(TTestCase)
  published
    procedure ReadOnlyStatements;
    procedure DataModifyingStatements;
    procedure SchemaModifyingStatements;
    procedure UnknownStatementsMayModify;
    procedure KeywordsInLiteralsAndCommentsIgnored;
    procedure KeywordsAsPartOfIdentifiersIgnored;
    procedure DollarQuotedBodyIgnored;
    procedure SelectForUpdateIsConservative;
    // Bypasses found in review: each must be flagged
    procedure MySqlExecutableComment;
    procedure OptimizerHintComment;
    procedure PostgresDoBlock;
    procedure BackslashInStandardSqlString;
    procedure DashDashWithoutSpace;
    procedure HashOperatorInPostgres;
    procedure SelectInto;
    procedure MaintenanceStatements;
  end;

implementation

{ TAiTextTest }

procedure TAiTextTest.ThinkBlocksRemoved;
begin
  AssertEquals('Answer', StripThinking('<think>reasoning'#10'more</think>'#10'Answer'));
  AssertEquals('a b', StripThinking('a <THINK>x</THINK>b'));
end;

procedure TAiTextTest.UnclosedThinkBlockRemovedToEnd;
begin
  AssertEquals('Intro', StripThinking('Intro <think>still thinking...'));
end;

procedure TAiTextTest.LoneClosingThinkTag;
begin
  AssertEquals('SELECT 1;', StripThinking('reasoning opened by the template'#10'</think>'#10'SELECT 1;'));
end;

procedure TAiTextTest.TruncateKeepsUtf8Intact;
const
  // "aé✓" = 61 C3A9 E29C93
  Text = 'a'#$C3#$A9#$E2#$9C#$93;
begin
  AssertEquals('cut inside é', 'a...', Utf8Truncate(Text, 2));
  AssertEquals('after é', 'a'#$C3#$A9'...', Utf8Truncate(Text, 3));
  AssertEquals('cut inside ✓', 'a'#$C3#$A9'...', Utf8Truncate(Text, 5));
  AssertEquals('no suffix', 'a'#$C3#$A9, Utf8Truncate(Text, 4, ''));
end;

procedure TAiTextTest.TruncateShortTextUnchanged;
begin
  AssertEquals('abc', Utf8Truncate('abc', 3));
  AssertEquals('abc', Utf8Truncate('abc', -1));
end;

{ TSqlExtractTest }

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
  Answer = '```python'#10'print(1)'#10'```'#10'Then:'#10'```'#10'SELECT 3'#10'```';
begin
  AssertEquals('SELECT 3', ExtractSql(Answer));
end;

procedure TSqlExtractTest.LongerFenceContainingBackticks;
begin
  AssertEquals('SELECT 1 -- see ```x```'#10'```', ExtractSql('````sql'#10'SELECT 1 -- see ```x```'#10'```'#10'````'));
end;

procedure TSqlExtractTest.CrLfAnswer;
begin
  AssertEquals('SELECT 1', ExtractSql('```sql'#13#10'SELECT 1'#13#10'```'#13#10));
end;

procedure TSqlExtractTest.BareSqlAnswer;
begin
  AssertEquals('with x as (select 1) select * from x;',
    ExtractSql('  with x as (select 1) select * from x;  '));
  AssertEquals('after thinking', 'SELECT 1;', ExtractSql('<think>hmm</think>SELECT 1;'));
end;

procedure TSqlExtractTest.ProseIsNotSql;
begin
  AssertEquals('prose', '', ExtractSql('I cannot answer that without the table name.'));
  AssertEquals('empty', '', ExtractSql(''));
  AssertEquals('starts with SQL word', '', ExtractSql('With these columns you can count orders.'));
  AssertEquals('sentences', '', ExtractSql('Show me. Then SELECT 1;'));
  AssertEquals('no semicolon', '', ExtractSql('Select the orders table first'));
end;

procedure TSqlExtractTest.AllSqlBlocks;
var
  Blocks: TStringArray;
begin
  Blocks := ExtractSqlBlocks('```sql'#10'SELECT 1;'#10'```'#10'text'#10'```python'#10'x'#10'```'#10 +
    '```'#10'CREATE INDEX i ON t(a);'#10'```'#10'```sql'#10'```');
  AssertEquals('python and empty blocks skipped', 2, Length(Blocks));
  AssertEquals('SELECT 1;', Blocks[0]);
  AssertEquals('CREATE INDEX i ON t(a);', Blocks[1]);
end;

{ TSqlEffectsTest }

procedure TSqlEffectsTest.ReadOnlyStatements;
begin
  AssertTrue('select', SqlEffects('SELECT a FROM t WHERE b = 1') = []);
  AssertTrue('show', SqlEffects('SHOW TABLES') = []);
  AssertTrue('explain', SqlEffects('EXPLAIN SELECT 1') = []);
  AssertTrue('with', SqlEffects('WITH x AS (SELECT 1) SELECT * FROM x;') = []);
  AssertTrue('describe', SqlEffects('DESCRIBE t; desc t') = []);
  AssertTrue('order by desc', SqlEffects('SELECT a FROM t ORDER BY a DESC') = []);
  AssertTrue('empty', SqlEffects('') = []);
  AssertTrue('only comments', SqlEffects('-- nothing'#10'/* here */') = []);
end;

procedure TSqlEffectsTest.DataModifyingStatements;
begin
  AssertTrue('insert', SqlEffects('INSERT INTO t VALUES (1)') = [seModifiesData]);
  AssertTrue('lowercase update', SqlEffects('update t set a=1') = [seModifiesData]);
  AssertTrue('delete in CTE', SqlEffects('WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d') = [seModifiesData]);
  AssertTrue('second statement', SqlEffects('SELECT 1; TRUNCATE t') = [seModifiesData]);
end;

procedure TSqlEffectsTest.SchemaModifyingStatements;
begin
  AssertTrue('drop', SqlEffects('DROP TABLE t') = [seModifiesSchema]);
  AssertTrue('create index', SqlEffects('create index i on t(a)') = [seModifiesSchema]);
  AssertTrue('grant', SqlEffects('GRANT SELECT ON t TO u') = [seModifiesSchema]);
  AssertTrue('both', SqlEffects('ALTER TABLE t ADD c INT; UPDATE t SET c=1') = [seModifiesData, seModifiesSchema]);
end;

procedure TSqlEffectsTest.UnknownStatementsMayModify;
begin
  AssertTrue('set', seModifiesData in SqlEffects('SET GLOBAL max_connections = 1'));
  AssertTrue('comment on', seModifiesData in SqlEffects('COMMENT ON TABLE t IS ''x'''));
  AssertTrue('begin', seModifiesData in SqlEffects('BEGIN'));
end;

procedure TSqlEffectsTest.KeywordsInLiteralsAndCommentsIgnored;
begin
  AssertTrue('string', SqlEffects('SELECT ''DROP TABLE x'' AS s') = []);
  AssertTrue('escaped quote', SqlEffects('SELECT ''it''''s DELETE'' FROM t') = []);
  AssertTrue('line comment', SqlEffects('SELECT 1 -- DELETE FROM t'#10'FROM dual') = []);
  AssertTrue('block comment', SqlEffects('SELECT /* UPDATE t */ 1') = []);
  AssertTrue('quoted identifiers', SqlEffects('SELECT `delete`, "update", [drop] FROM t') = []);
  AssertTrue('code after comment still checked', SqlEffects('/* x */ DELETE FROM t') = [seModifiesData]);
end;

procedure TSqlEffectsTest.KeywordsAsPartOfIdentifiersIgnored;
begin
  AssertTrue(SqlEffects('SELECT update_time, created_by, t.deleted, comment FROM posts') = []);
end;

procedure TSqlEffectsTest.DollarQuotedBodyIgnored;
begin
  AssertTrue('body masked', SqlEffects('SELECT $body$ DELETE FROM t $body$') = []);
  AssertTrue('function', SqlEffects('CREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql') = [seModifiesSchema]);
end;

procedure TSqlEffectsTest.SelectForUpdateIsConservative;
begin
  AssertTrue(SqlEffects('SELECT * FROM t FOR UPDATE') = [seModifiesData]);
end;

procedure TSqlEffectsTest.MySqlExecutableComment;
begin
  AssertTrue(seModifiesData in SqlEffects('SELECT 1 /*! ; DELETE FROM t */'));
  AssertTrue('versioned', seModifiesData in SqlEffects('/*!50000 DELETE FROM t */'));
end;

procedure TSqlEffectsTest.OptimizerHintComment;
begin
  AssertTrue(seModifiesData in SqlEffects('SELECT /*+ x */ 1; /*+ DELETE FROM t */'));
end;

procedure TSqlEffectsTest.PostgresDoBlock;
begin
  AssertTrue(seModifiesData in SqlEffects('DO $$ BEGIN DELETE FROM t; END $$'));
end;

procedure TSqlEffectsTest.BackslashInStandardSqlString;
begin
  // PostgreSQL and SQLite end the string at \' and run the DELETE
  AssertTrue(seModifiesData in SqlEffects('SELECT ''a\''; DELETE FROM t; --'''));
end;

procedure TSqlEffectsTest.DashDashWithoutSpace;
begin
  // MySQL does not treat --1 as a comment
  AssertTrue(seModifiesData in SqlEffects('SELECT 1 --1; DELETE FROM t'));
end;

procedure TSqlEffectsTest.HashOperatorInPostgres;
begin
  AssertTrue(seModifiesData in SqlEffects('SELECT a #> ''{x}'' FROM j; DELETE FROM t'));
end;

procedure TSqlEffectsTest.SelectInto;
begin
  AssertTrue('outfile', seModifiesData in SqlEffects('SELECT * INTO OUTFILE ''/tmp/x'' FROM t'));
  AssertTrue('new table', seModifiesData in SqlEffects('SELECT * INTO backup FROM t'));
end;

procedure TSqlEffectsTest.MaintenanceStatements;
begin
  AssertTrue('vacuum', seModifiesData in SqlEffects('VACUUM FULL t'));
  AssertTrue('optimize', seModifiesData in SqlEffects('OPTIMIZE TABLE t'));
  AssertTrue('lock', seModifiesData in SqlEffects('LOCK TABLES t WRITE'));
  AssertTrue('kill', seModifiesData in SqlEffects('KILL 42'));
  AssertTrue('pragma', seModifiesData in SqlEffects('PRAGMA journal_mode = DELETE'));
  AssertTrue('detach', seModifiesSchema in SqlEffects('DETACH DATABASE x'));
end;

initialization
  RegisterTest(TAiTextTest);
  RegisterTest(TSqlExtractTest);
  RegisterTest(TSqlEffectsTest);

end.
