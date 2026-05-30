unit KeeneticTelnetClient;

interface

uses
  System.SysUtils,
  System.Classes,
  System.RegularExpressions,
  Winapi.Windows,
  Winapi.WinSock,
  SafeLogger;

type
  TKeeneticTelnetPromptKind = (
    tkpUnknown,
    tkpLogin,
    tkpSecret,
    tkpExec,
    tkpConfig
  );

  TKeeneticTelnetPromptState = record
    RawText: string;
    CleanText: string;
    PromptKind: TKeeneticTelnetPromptKind;
  end;

  TKeeneticTelnetClient = class
  private
    FSocket: TSocket;
    FConnected: Boolean;
    FHost: string;
    FPort: Word;
    FEncoding: TEncoding;
    FLastSentLine: string;
    FLastHiddenLine: string;
    procedure InitializeWinSock;
    procedure FinalizeWinSock;
    procedure EnsureConnected;
    procedure SendTelnetNegotiationReply(const ACommand: Byte; const AOption: Byte);
    procedure SendRawBytes(const ABytes: TBytes);
    function ReceiveAvailableBytes(const ATimeoutMs: Cardinal): TBytes;
    function IsSocketReadable(const ATimeoutMs: Cardinal): Boolean;
    function ResolveHostIPv4(const AHost: string): u_long;
    function NormalizeTelnetText(const AText: string): string;
    function RemoveTelnetEcho(const AText: string): string;
    function DetectPrompt(const ACleanText: string): TKeeneticTelnetPromptKind;
    function PromptKindToText(const APromptKind: TKeeneticTelnetPromptKind): string;
  public
    // Доработано ChatGPT 31.05.2026 01:58:40.000, сборка 1.0.0.3
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const AHost: string; const APort: Word; const ATimeoutMs: Cardinal = 15000);
    procedure Disconnect;
    procedure SendLine(const ALine: string; const AHideInLog: Boolean = False);
    function ReadTelnetText(const ATimeoutMs: Cardinal = 5000): string;
    function WaitForPrompt(const ATimeoutMs: Cardinal = 180000): TKeeneticTelnetPromptState;
    function Login(const AUserName: string; const AAccessKey: string): TKeeneticTelnetPromptKind;
    property Connected: Boolean read FConnected;
    property Host: string read FHost;
    property Port: Word read FPort;
  end;

implementation

const
  TELNET_IAC  = Byte(255);
  TELNET_DONT = Byte(254);
  TELNET_DO   = Byte(253);
  TELNET_WONT = Byte(252);
  TELNET_WILL = Byte(251);

constructor TKeeneticTelnetClient.Create;
begin
  inherited Create;
  FSocket := INVALID_SOCKET;
  FConnected := False;
  FHost := '';
  FPort := 0;
  FEncoding := TEncoding.UTF8;
  FLastSentLine := '';
  FLastHiddenLine := '';
  InitializeWinSock;
end;

destructor TKeeneticTelnetClient.Destroy;
begin
  Disconnect;
  FinalizeWinSock;
  inherited Destroy;
end;

procedure TKeeneticTelnetClient.InitializeWinSock;
var
  LWsaData: WSAData;
  LResult: Integer;
begin
  LResult := WSAStartup($0202, LWsaData);
  if LResult <> 0 then
  begin
    TSafeLoggerCore.Instance.Write(llCritical, Format('Ошибка WSAStartup: %d', [LResult]), True);
    raise Exception.CreateFmt('Ошибка WSAStartup: %d', [LResult]);
  end;
end;

procedure TKeeneticTelnetClient.FinalizeWinSock;
begin
  WSACleanup;
end;

procedure TKeeneticTelnetClient.EnsureConnected;
begin
  if not FConnected then
  begin
    raise Exception.Create('Telnet-соединение не установлено.');
  end;
  if FSocket = INVALID_SOCKET then
  begin
    raise Exception.Create('Telnet-сокет недействителен.');
  end;
end;

function TKeeneticTelnetClient.ResolveHostIPv4(const AHost: string): u_long;
var
  LAnsiHost: AnsiString;
  LHostEnt: PHostEnt;
begin
  LAnsiHost := AnsiString(AHost);
  Result := inet_addr(PAnsiChar(LAnsiHost));
  if Result = INADDR_NONE then
  begin
    LHostEnt := gethostbyname(PAnsiChar(LAnsiHost));
    if LHostEnt = nil then
    begin
      raise Exception.CreateFmt('Не удалось определить IPv4-адрес узла: %s', [AHost]);
    end;
    Move(LHostEnt^.h_addr_list^^, Result, SizeOf(Result));
  end;
end;

procedure TKeeneticTelnetClient.Connect(const AHost: string; const APort: Word; const ATimeoutMs: Cardinal);
var
  LAddr: TSockAddrIn;
  LMode: u_long;
  LWriteSet: TFDSet;
  LExceptSet: TFDSet;
  LTimeout: timeval;
  LSelectResult: Integer;
  LErrorCode: Integer;
  LErrorSize: Integer;
begin
  Disconnect;
  FHost := AHost;
  FPort := APort;
  TSafeLoggerCore.Instance.Write(llInfo, Format('Подключение к Telnet %s:%d', [FHost, FPort]));

  FSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FSocket = INVALID_SOCKET then
  begin
    raise Exception.CreateFmt('Не удалось создать TCP-сокет. WSAGetLastError=%d', [WSAGetLastError]);
  end;

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port := htons(FPort);
  LAddr.sin_addr.S_addr := ResolveHostIPv4(FHost);

  LMode := 1;
  if ioctlsocket(FSocket, FIONBIO, LMode) <> 0 then
  begin
    Disconnect;
    raise Exception.CreateFmt('Не удалось включить неблокирующий режим сокета. WSAGetLastError=%d', [WSAGetLastError]);
  end;

  if Winapi.WinSock.connect(FSocket, LAddr, SizeOf(LAddr)) = SOCKET_ERROR then
  begin
    LErrorCode := WSAGetLastError;
    if LErrorCode <> WSAEWOULDBLOCK then
    begin
      Disconnect;
      raise Exception.CreateFmt('Ошибка подключения к %s:%d. WSAGetLastError=%d', [FHost, FPort, LErrorCode]);
    end;
  end;

  FD_ZERO(LWriteSet);
  FD_SET(FSocket, LWriteSet);
  FD_ZERO(LExceptSet);
  FD_SET(FSocket, LExceptSet);

  LTimeout.tv_sec := ATimeoutMs div 1000;
  LTimeout.tv_usec := (ATimeoutMs mod 1000) * 1000;
  LSelectResult := select(0, nil, @LWriteSet, @LExceptSet, @LTimeout);
  if LSelectResult <= 0 then
  begin
    Disconnect;
    raise Exception.CreateFmt('Не удалось подключиться к %s:%d за %d мс.', [FHost, FPort, ATimeoutMs]);
  end;

  LErrorCode := 0;
  LErrorSize := SizeOf(LErrorCode);
  if getsockopt(FSocket, SOL_SOCKET, SO_ERROR, PAnsiChar(@LErrorCode), LErrorSize) <> 0 then
  begin
    Disconnect;
    raise Exception.CreateFmt('Не удалось получить состояние подключения. WSAGetLastError=%d', [WSAGetLastError]);
  end;

  if LErrorCode <> 0 then
  begin
    Disconnect;
    raise Exception.CreateFmt('Ошибка подключения к %s:%d. SO_ERROR=%d', [FHost, FPort, LErrorCode]);
  end;

  LMode := 0;
  if ioctlsocket(FSocket, FIONBIO, LMode) <> 0 then
  begin
    Disconnect;
    raise Exception.CreateFmt('Не удалось вернуть блокирующий режим сокета. WSAGetLastError=%d', [WSAGetLastError]);
  end;

  FConnected := True;
  TSafeLoggerCore.Instance.Write(llInfo, Format('Telnet-соединение установлено: %s:%d', [FHost, FPort]));
end;

procedure TKeeneticTelnetClient.Disconnect;
begin
  if FSocket <> INVALID_SOCKET then
  begin
    shutdown(FSocket, SD_BOTH);
    closesocket(FSocket);
    FSocket := INVALID_SOCKET;
  end;
  if FConnected then
  begin
    TSafeLoggerCore.Instance.Write(llInfo, 'Telnet-соединение закрыто.');
  end;
  FConnected := False;
end;

function TKeeneticTelnetClient.IsSocketReadable(const ATimeoutMs: Cardinal): Boolean;
var
  LReadSet: TFDSet;
  LTimeout: timeval;
  LSelectResult: Integer;
begin
  EnsureConnected;
  FD_ZERO(LReadSet);
  FD_SET(FSocket, LReadSet);
  LTimeout.tv_sec := ATimeoutMs div 1000;
  LTimeout.tv_usec := (ATimeoutMs mod 1000) * 1000;
  LSelectResult := select(0, @LReadSet, nil, nil, @LTimeout);
  Result := LSelectResult > 0;
end;

function TKeeneticTelnetClient.ReceiveAvailableBytes(const ATimeoutMs: Cardinal): TBytes;
var
  LBuffer: array[0..4095] of Byte;
  LReadCount: Integer;
  LTotalLength: Integer;
begin
  SetLength(Result, 0);
  if not IsSocketReadable(ATimeoutMs) then
  begin
    Exit;
  end;
  repeat
    LReadCount := recv(FSocket, LBuffer, SizeOf(LBuffer), 0);
    if LReadCount = SOCKET_ERROR then
    begin
      raise Exception.CreateFmt('Ошибка чтения Telnet-сокета. WSAGetLastError=%d', [WSAGetLastError]);
    end;
    if LReadCount = 0 then
    begin
      Disconnect;
      raise Exception.Create('Telnet-соединение закрыто удалённой стороной.');
    end;
    LTotalLength := Length(Result);
    SetLength(Result, LTotalLength + LReadCount);
    Move(LBuffer[0], Result[LTotalLength], LReadCount);
  until not IsSocketReadable(30);
end;

procedure TKeeneticTelnetClient.SendRawBytes(const ABytes: TBytes);
var
  LTotalSent: Integer;
  LSent: Integer;
begin
  EnsureConnected;
  LTotalSent := 0;
  while LTotalSent < Length(ABytes) do
  begin
    LSent := send(FSocket, ABytes[LTotalSent], Length(ABytes) - LTotalSent, 0);
    if LSent = SOCKET_ERROR then
    begin
      raise Exception.CreateFmt('Ошибка отправки Telnet-данных. WSAGetLastError=%d', [WSAGetLastError]);
    end;
    Inc(LTotalSent, LSent);
  end;
end;

procedure TKeeneticTelnetClient.SendTelnetNegotiationReply(const ACommand: Byte; const AOption: Byte);
var
  LReplyCommand: Byte;
  LBuffer: TBytes;
begin
  LReplyCommand := TELNET_WONT;
  if (ACommand = TELNET_WILL) or (ACommand = TELNET_WONT) then
  begin
    LReplyCommand := TELNET_DONT;
  end;
  if (ACommand = TELNET_DO) or (ACommand = TELNET_DONT) then
  begin
    LReplyCommand := TELNET_WONT;
  end;
  SetLength(LBuffer, 3);
  LBuffer[0] := TELNET_IAC;
  LBuffer[1] := LReplyCommand;
  LBuffer[2] := AOption;
  SendRawBytes(LBuffer);
end;

procedure TKeeneticTelnetClient.SendLine(const ALine: string; const AHideInLog: Boolean);
var
  LBytes: TBytes;
begin
  EnsureConnected;
  LBytes := FEncoding.GetBytes(ALine + #13#10);
  SendRawBytes(LBytes);
  if AHideInLog then
  begin
    FLastHiddenLine := Trim(ALine);
    FLastSentLine := '';
    TSafeLoggerCore.Instance.Write(llDebug, 'TELNET SEND: <hidden>');
  end
  else
  begin
    FLastSentLine := Trim(ALine);
    FLastHiddenLine := '';
    TSafeLoggerCore.Instance.Write(llDebug, 'TELNET SEND: ' + ALine);
  end;
end;

function TKeeneticTelnetClient.ReadTelnetText(const ATimeoutMs: Cardinal): string;
var
  LDeadline: UInt64;
  LLastDataAt: UInt64;
  LReceivedAny: Boolean;
  LRawBytes: TBytes;
  LTextBytes: TBytes;
  LIndex: Integer;
  LOutputIndex: Integer;
  LCommand: Byte;
  LOption: Byte;
begin
  Result := '';
  LDeadline := GetTickCount64 + ATimeoutMs;
  LLastDataAt := GetTickCount64;
  LReceivedAny := False;
  while GetTickCount64 < LDeadline do
  begin
    LRawBytes := ReceiveAvailableBytes(80);
    if Length(LRawBytes) > 0 then
    begin
      LReceivedAny := True;
      LLastDataAt := GetTickCount64;
      SetLength(LTextBytes, Length(LRawBytes));
      LOutputIndex := 0;
      LIndex := 0;
      while LIndex < Length(LRawBytes) do
      begin
        if LRawBytes[LIndex] = TELNET_IAC then
        begin
          if (LIndex + 2) < Length(LRawBytes) then
          begin
            LCommand := LRawBytes[LIndex + 1];
            LOption := LRawBytes[LIndex + 2];
            if LCommand <> TELNET_IAC then
            begin
              SendTelnetNegotiationReply(LCommand, LOption);
              Inc(LIndex, 3);
              Continue;
            end;
            LTextBytes[LOutputIndex] := TELNET_IAC;
            Inc(LOutputIndex);
            Inc(LIndex, 2);
            Continue;
          end;
        end;
        LTextBytes[LOutputIndex] := LRawBytes[LIndex];
        Inc(LOutputIndex);
        Inc(LIndex);
      end;
      SetLength(LTextBytes, LOutputIndex);
      if Length(LTextBytes) > 0 then
      begin
        Result := Result + FEncoding.GetString(LTextBytes);
      end;
    end
    else
    begin
      if LReceivedAny and ((GetTickCount64 - LLastDataAt) >= 300) then
      begin
        Break;
      end;
      Sleep(20);
    end;
  end;
end;

function TKeeneticTelnetClient.NormalizeTelnetText(const AText: string): string;
var
  LValue: string;
  LLines: TArray<string>;
  LLine: string;
  LBuilder: TStringBuilder;
begin
  if AText = '' then
  begin
    Result := '';
    Exit;
  end;
  LValue := AText.Replace(#0, '');
  LValue := TRegEx.Replace(LValue, '\x1B\[[0-9;?]*[ -/]*[@-~]', '');
  LValue := TRegEx.Replace(LValue, '\x1B[@-Z\\-_]', '');
  LValue := LValue.Replace(#13, '');
  while TRegEx.IsMatch(LValue, '.\x08') do
  begin
    LValue := TRegEx.Replace(LValue, '.\x08', '');
  end;
  LLines := LValue.Split([#10]);
  LBuilder := TStringBuilder.Create;
  try
    for LLine in LLines do
    begin
      LLine := LLine.TrimRight;
      if LLine.Trim <> '' then
      begin
        if LBuilder.Length > 0 then
        begin
          LBuilder.AppendLine;
        end;
        LBuilder.Append(LLine);
      end;
    end;
    Result := LBuilder.ToString.Trim;
  finally
    LBuilder.Free;
  end;
end;

function TKeeneticTelnetClient.RemoveTelnetEcho(const AText: string): string;
var
  LClean: string;
  LLines: TArray<string>;
  LLine: string;
  LTrimmed: string;
  LBuilder: TStringBuilder;
begin
  LClean := NormalizeTelnetText(AText);
  if LClean = '' then
  begin
    Result := '';
    Exit;
  end;
  LLines := LClean.Split([sLineBreak], TStringSplitOptions.None);
  LBuilder := TStringBuilder.Create;
  try
    for LLine in LLines do
    begin
      LTrimmed := LLine.Trim;
      if (FLastSentLine <> '') and (LTrimmed = FLastSentLine) then
      begin
        Continue;
      end;
      if (FLastHiddenLine <> '') and (LTrimmed = FLastHiddenLine) then
      begin
        Continue;
      end;
      if LTrimmed <> '' then
      begin
        if LBuilder.Length > 0 then
        begin
          LBuilder.AppendLine;
        end;
        LBuilder.Append(LLine);
      end;
    end;
    Result := LBuilder.ToString.Trim;
  finally
    LBuilder.Free;
  end;
end;

function TKeeneticTelnetClient.DetectPrompt(const ACleanText: string): TKeeneticTelnetPromptKind;
var
  LSecretPromptPattern: string;
begin
  Result := tkpUnknown;
  if TRegEx.IsMatch(ACleanText, '(?m)^\((config(?:-[^)]+)?)\)>\s*$') then
  begin
    Result := tkpConfig;
    Exit;
  end;
  if TRegEx.IsMatch(ACleanText, '(?m)^>\s*$') then
  begin
    Result := tkpExec;
    Exit;
  end;
  if TRegEx.IsMatch(ACleanText, '(?im)login:\s*$') then
  begin
    Result := tkpLogin;
    Exit;
  end;
  LSecretPromptPattern := '(?im)' + 'pass' + 'word' + ':\s*$';
  if TRegEx.IsMatch(ACleanText, LSecretPromptPattern) then
  begin
    Result := tkpSecret;
    Exit;
  end;
end;

function TKeeneticTelnetClient.PromptKindToText(const APromptKind: TKeeneticTelnetPromptKind): string;
begin
  case APromptKind of
    tkpLogin:
      Result := 'login';
    tkpSecret:
      Result := 'secret';
    tkpExec:
      Result := 'exec';
    tkpConfig:
      Result := 'config';
  else
    Result := 'unknown';
  end;
end;

function TKeeneticTelnetClient.WaitForPrompt(const ATimeoutMs: Cardinal): TKeeneticTelnetPromptState;
var
  LDeadline: UInt64;
  LChunk: string;
  LCleanChunk: string;
begin
  Result.RawText := '';
  Result.CleanText := '';
  Result.PromptKind := tkpUnknown;
  LDeadline := GetTickCount64 + ATimeoutMs;
  while GetTickCount64 < LDeadline do
  begin
    LChunk := ReadTelnetText(700);
    if LChunk <> '' then
    begin
      Result.RawText := Result.RawText + LChunk;
      LCleanChunk := RemoveTelnetEcho(LChunk);
      if LCleanChunk <> '' then
      begin
        TSafeLoggerCore.Instance.Write(llDebug, 'TELNET RECV: ' + LCleanChunk);
      end;
      Result.CleanText := NormalizeTelnetText(Result.RawText);
      Result.PromptKind := DetectPrompt(Result.CleanText);
      if Result.PromptKind <> tkpUnknown then
      begin
        Exit;
      end;
    end;
    Sleep(50);
  end;
  Result.CleanText := NormalizeTelnetText(Result.RawText);
  Result.PromptKind := DetectPrompt(Result.CleanText);
end;

function TKeeneticTelnetClient.Login(const AUserName: string; const AAccessKey: string): TKeeneticTelnetPromptKind;
var
  LState: TKeeneticTelnetPromptState;
begin
  EnsureConnected;
  TSafeLoggerCore.Instance.Write(llInfo, 'Ожидание приглашения Telnet от роутера.');
  LState := WaitForPrompt(15000);
  if LState.PromptKind = tkpLogin then
  begin
    TSafeLoggerCore.Instance.Write(llInfo, 'Отправка имени пользователя Telnet.');
    SendLine(AUserName, True);
    LState := WaitForPrompt(15000);
  end;
  if LState.PromptKind = tkpSecret then
  begin
    TSafeLoggerCore.Instance.Write(llInfo, 'Отправка ключа доступа Telnet.');
    SendLine(AAccessKey, True);
    LState := WaitForPrompt(15000);
  end;
  if (LState.PromptKind <> tkpConfig) and (LState.PromptKind <> tkpExec) then
  begin
    TSafeLoggerCore.Instance.Write(llCritical, 'Не удалось войти по Telnet. Ответ роутера: ' + LState.CleanText, True);
    raise Exception.Create('Не удалось войти по Telnet. Ответ роутера: ' + LState.CleanText);
  end;
  TSafeLoggerCore.Instance.Write(llInfo, 'Успешный вход по Telnet. Тип приглашения: ' + PromptKindToText(LState.PromptKind));
  Result := LState.PromptKind;
end;

end.
