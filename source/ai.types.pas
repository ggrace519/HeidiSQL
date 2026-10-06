unit ai.types;

// Plain types shared by the AI assistant units. No LCL dependencies.

{$mode delphi}{$H+}

interface

type
  TAiChatRole = (crSystem, crUser, crAssistant);

  TAiChatMessage = record
    Role: TAiChatRole;
    Content: String;
  end;
  TAiChatMessages = array of TAiChatMessage;

  // Token counts reported by the server, when it reports them
  TAiUsage = record
    Known: Boolean;
    PromptTokens: Integer;
    CompletionTokens: Integer;
  end;

  // Why a request failed. Mapped to user-facing messages by the UI.
  TAiErrorKind = (
    ekNone,
    ekAuth,          // 401, 403: missing or wrong API key
    ekNotFound,      // 404: wrong base URL or unknown model
    ekBadRequest,    // 400, 422: e.g. context too long, unsupported parameter
    ekRateLimit,     // 429
    ekServer,        // 5xx
    ekConnect,       // DNS, refused connection, TLS failure
    ekTimeout,       // no data within the configured time
    ekCancelled,     // stopped by the user
    ekProtocol       // response could not be understood
  );

function AiChatMessage(Role: TAiChatRole; const Content: String): TAiChatMessage;

implementation

function AiChatMessage(Role: TAiChatRole; const Content: String): TAiChatMessage;
begin
  Result.Role := Role;
  Result.Content := Content;
end;

end.
