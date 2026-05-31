unit KeeneticTelnetClient;

{
  Доработано ChatGPT 31.05.2026 13:02:00.000, сборка 1.0.0.9
  Назначение: чистый Telnet-клиент для Keenetic без CLI-команд.
  Исправлено: русские сообщения, тихий режим лога, очистка echo login/password.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.RegularExpressions,
  Winapi.Windows,
  Winapi.WinSock,
  SafeLogger;

type
  TKeeneticTelnetLoginResult = record
    RawText: string;
    CleanText: string;
    IsAuthorized: Boolean;
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
    FQuietPeriodMs: Cardinal;
    FVerboseLog: Boolean;
    class var FWinSockStarted: Boolean;
    class var FWinSockStartCount: Integer;
    class procedure InitializeWinSock; static;
    class procedure FinalizeWinSock; static;
    procedure EnsureConnected;
    procedure WriteDebugLog(const AText: string);
    procedure SendRawBytes(const ABytes: TBytes);
    procedure SendTelnetNegotiationReply(const ACommand: Byte; const AOption: Byte);
    function ResolveHostIPv4(const AHost: string): u_long;
    function IsSocketReadable(const ATimeoutMs: Cardinal): Boolean;
    function ReceiveAvailableBytes(const ATimeoutMs: Cardinal): TBytes;
    function FilterTelnetBytes(const ARawBytes: TBytes): TBytes;
    function NormalizeText(const AText: string): string;
    function RemoveEchoFromText(const AText: string): string;
    function ContainsLoginRequest(const AText: string): Boolean;
    function ContainsPasswordRequest(const AText: string): Boolean;
    function ContainsAuthorizedPrompt(const AText: string): Boolean;
    function ContainsDeniedText(const AText: string): Boolean;
    function WaitForText(const ATimeoutMs: Cardinal): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const AHost: string; const APort: Word = 23; const ATimeoutMs: Cardinal = 15000);
    procedure Disconnect;
    procedure SendLine(const ALine: string; const AHideInLog: Boolean = False);
    function ReadResponse(const ATimeoutMs: Cardinal = 15000): string;
    function Login(const AUserName: string; const APassword: string; const ATimeoutMs: Cardinal = 30000): TKeeneticTelnetLoginResult;
    property Connected: Boolean read FConnected;
    property Host: string read FHost;
    property Port: Word read FPort;
    property QuietPeriodMs: Cardinal read FQuietPeriodMs write FQuietPeriodMs;
    property VerboseLog: Boolean read FVerboseLog write FVerboseLog;
  end;

implementation

const
  TELNET_IAC  = Byte(255);
  TELNET_DONT = Byte(254);
  TELNET_DO   = Byte(253);
  TELNET_WONT = Byte(252);
  TELNET_WILL = Byte(251);
  TELNET_SB   = Byte(250);
  TELNET_SE   = Byte(240);

var
  Logger: TSafeLoggerCore;

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
  FQuietPeriodMs := 350;
  FVerboseLog := False;
  InitializeWinSock;
end;

destructor TKeeneticTelnetClient.Destroy;
begin
  Disconnect;
  FinalizeWinSock;
  inherited Destroy;
end;

procedure TKeeneticTelnetClient.WriteDebugLog(const AText: string);
begin
  if FVerboseLog then
  begin
    Logger.Write(llDebug, AText);
  end;
end;

class procedure TKeeneticTelnetClient.InitializeWinSock;
var
  LWsaData: WSAData;
  LResult: Integer;
begin
  if FWinSockStarted then
  begin
    Inc(FWinSockStartCount);
    Exit;
  end;
  LResult := WSAStartup($0202, LWsaData);
  if LResult <> 0 then
  begin
    Logger.Write(llCritical, Format('Ошибка WSAStartup: %d', [LResult]), True);
    raise Exception.CreateFmt('Ошибка WSAStartup: %d', [LResult]);
  end;
  FWinSockStarted := True;
  FWinSockStartCount := 1;
end;

class procedure TKeeneticTelnetClient.FinalizeWinSock;
begin
  if not FWinSockStarted then
  begin
    Exit;
  end;
  Dec(FWinSockStartCount);
  if FWinSockStartCount <= 0 then
  begin
    WSACleanup;
    FWinSockStarted := False;
    FWinSockStartCount := 0;
  end;
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
  LAddressText: string;
begin
  LAddressText := Trim(AHost);
  if LAddressText = '' then
  begin
    raise Exception.Create('Не указан IPv4-адрес или имя узла.');
  end;
  LAnsiHost := AnsiString(LAddressText);
  Result := inet_addr(PAnsiChar(LAnsiHost));
  if SameText(LAddressText, '255.255.255.255') then
  begin
    Exit;
  end;
  if Result = u_long($FFFFFFFF) then
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
  FLastSentLine := '';
  FLastHiddenLine := '';
  Logger.Write(llInfo, Format('Подключение к Telnet %s:%d', [FHost, FPort]));
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
  Logger.Write(llInfo, Format('Telnet-соединение установлено: %s:%d', [FHost, FPort]));
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
    Logger.Write(llInfo, 'Telnet-соединение закрыто.');
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
  LBuffer: array[0..8191] of Byte;
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
  until not IsSocketReadable(25);
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

function TKeeneticTelnetClient.FilterTelnetBytes(const ARawBytes: TBytes): TBytes;
var
  LIndex: Integer;
  LOutputIndex: Integer;
  LCommand: Byte;
  LOption: Byte;
  LInSubNegotiation: Boolean;
begin
  SetLength(Result, Length(ARawBytes));
  LIndex := 0;
  LOutputIndex := 0;
  LInSubNegotiation := False;
  while LIndex < Length(ARawBytes) do
  begin
    if LInSubNegotiation then
    begin
      if ARawBytes[LIndex] = TELNET_IAC then
      begin
        if (LIndex + 1) < Length(ARawBytes) then
        begin
          if ARawBytes[LIndex + 1] = TELNET_SE then
          begin
            Inc(LIndex, 2);
            LInSubNegotiation := False;
            Continue;
          end;
        end;
      end;
      Inc(LIndex);
      Continue;
    end;
    if ARawBytes[LIndex] = TELNET_IAC then
    begin
      if (LIndex + 1) >= Length(ARawBytes) then
      begin
        Break;
      end;
      LCommand := ARawBytes[LIndex + 1];
      if LCommand = TELNET_IAC then
      begin
        Result[LOutputIndex] := TELNET_IAC;
        Inc(LOutputIndex);
        Inc(LIndex, 2);
        Continue;
      end;
      if LCommand = TELNET_SB then
      begin
        LInSubNegotiation := True;
        Inc(LIndex, 2);
        Continue;
      end;
      if (LCommand = TELNET_WILL) or (LCommand = TELNET_WONT) or (LCommand = TELNET_DO) or (LCommand = TELNET_DONT) then
      begin
        if (LIndex + 2) < Length(ARawBytes) then
        begin
          LOption := ARawBytes[LIndex + 2];
          SendTelnetNegotiationReply(LCommand, LOption);
          Inc(LIndex, 3);
          Continue;
        end;
        Break;
      end;
      Inc(LIndex, 2);
      Continue;
    end;
    Result[LOutputIndex] := ARawBytes[LIndex];
    Inc(LOutputIndex);
    Inc(LIndex);
  end;
  SetLength(Result, LOutputIndex);
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
    WriteDebugLog('TELNET SEND: <скрыто>');
  end
  else
  begin
    FLastSentLine := Trim(ALine);
    FLastHiddenLine := '';
    WriteDebugLog('TELNET SEND: ' + ALine);
  end;
end;

function TKeeneticTelnetClient.WaitForText(const ATimeoutMs: Cardinal): string;
var
  LDeadline: UInt64;
  LLastDataAt: UInt64;
  LReceivedAny: Boolean;
  LRawBytes: TBytes;
  LTextBytes: TBytes;
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
      LTextBytes := FilterTelnetBytes(LRawBytes);
      if Length(LTextBytes) > 0 then
      begin
        Result := Result + FEncoding.GetString(LTextBytes);
      end;
    end
    else
    begin
      if LReceivedAny and ((GetTickCount64 - LLastDataAt) >= FQuietPeriodMs) then
      begin
        Break;
      end;
      Sleep(20);
    end;
  end;
end;

function TKeeneticTelnetClient.NormalizeText(const AText: string): string;
var
  LValue: string;
  LLines: TArray<string>;
  LSourceLine: string;
  LCleanLine: string;
  LBuilder: TStringBuilder;
begin
  if AText = '' then
  begin
    Result := '';
    Exit;
  end;
  LValue := AText.Replace(#0, '');
  LValue := TRegEx.Replace(LValue, '\x1B\[[0-9;?]*[ -/]*[@-~]', '');
  LValue := TRegEx.Replace(LValue, '\x1B\][^\x07]*(\x07|\x1B\\)', '');
  LValue := TRegEx.Replace(LValue, '\x1B[@-Z\\-_]', '');
  LValue := LValue.Replace(#13, '');
  while TRegEx.IsMatch(LValue, '.\x08') do
  begin
    LValue := TRegEx.Replace(LValue, '.\x08', '');
  end;
  LLines := LValue.Split([#10], TStringSplitOptions.None);
  LBuilder := TStringBuilder.Create;
  try
    for LSourceLine in LLines do
    begin
      LCleanLine := LSourceLine.TrimRight;
      if LCleanLine.Trim <> '' then
      begin
        if LBuilder.Length > 0 then
        begin
          LBuilder.AppendLine;
        end;
        LBuilder.Append(LCleanLine);
      end;
    end;
    Result := LBuilder.ToString.Trim;
  finally
    LBuilder.Free;
  end;
end;

function TKeeneticTelnetClient.RemoveEchoFromText(const AText: string): string;
var
  LClean: string;
  LLines: TArray<string>;
  LLine: string;
  LTrimmed: string;
  LBuilder: TStringBuilder;
begin
  LClean := NormalizeText(AText);
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
      if LTrimmed = '' then
      begin
        Continue;
      end;
      if TRegEx.IsMatch(LTrimmed, '(?i)^login\s*:\s*$') then
      begin
        Continue;
      end;
      if TRegEx.IsMatch(LTrimmed, '(?i)^login\s*:.*$') then
      begin
        Continue;
      end;
      if TRegEx.IsMatch(LTrimmed, '(?i)^password\s*:\s*$') then
      begin
        Continue;
      end;
      if TRegEx.IsMatch(LTrimmed, '(?i)^password\s*:.*$') then
      begin
        Continue;
      end;
      if TRegEx.IsMatch(LTrimmed, '^\*+$') then
      begin
        Continue;
      end;
      if (FLastSentLine <> '') and (LTrimmed = FLastSentLine) then
      begin
        Continue;
      end;
      if (FLastHiddenLine <> '') and (LTrimmed = FLastHiddenLine) then
      begin
        Continue;
      end;
      if LBuilder.Length > 0 then
      begin
        LBuilder.AppendLine;
      end;
      LBuilder.Append(LLine);
    end;
    Result := LBuilder.ToString.Trim;
  finally
    LBuilder.Free;
  end;
end;

function TKeeneticTelnetClient.ContainsLoginRequest(const AText: string): Boolean;
begin
  Result := TRegEx.IsMatch(AText, '(?im)(^|\s|\n)login\s*:\s*$');
end;

function TKeeneticTelnetClient.ContainsPasswordRequest(const AText: string): Boolean;
begin
  Result := TRegEx.IsMatch(AText, '(?im)(^|\s|\n)password\s*:\s*$');
end;

function TKeeneticTelnetClient.ContainsAuthorizedPrompt(const AText: string): Boolean;
begin
  Result := False;
  if TRegEx.IsMatch(AText, '(?m)^\s*>\s*$') then
  begin
    Result := True;
    Exit;
  end;
  if TRegEx.IsMatch(AText, '(?m)^\s*\([^)]+\)>\s*$') then
  begin
    Result := True;
    Exit;
  end;
end;

function TKeeneticTelnetClient.ContainsDeniedText(const AText: string): Boolean;
begin
  Result := TRegEx.IsMatch(AText, '(?im)(authentication failed|authorization failed|login incorrect|access denied|invalid password|wrong password|неверный пароль|доступ запрещен|доступ запрещён)');
end;

function TKeeneticTelnetClient.ReadResponse(const ATimeoutMs: Cardinal): string;
var
  LRawText: string;
begin
  EnsureConnected;
  LRawText := WaitForText(ATimeoutMs);
  Result := RemoveEchoFromText(LRawText);
  if Result <> '' then
  begin
    WriteDebugLog('TELNET RECV: ' + Result);
  end;
end;

function TKeeneticTelnetClient.Login(const AUserName: string; const APassword: string; const ATimeoutMs: Cardinal): TKeeneticTelnetLoginResult;
var
  LDeadline: UInt64;
  LChunk: string;
  LCleanChunk: string;
  LCleanAll: string;
  LUserSent: Boolean;
  LPasswordSent: Boolean;
begin
  EnsureConnected;
  Result.RawText := '';
  Result.CleanText := '';
  Result.IsAuthorized := False;
  LDeadline := GetTickCount64 + ATimeoutMs;
  LUserSent := False;
  LPasswordSent := False;
  Logger.Write(llInfo, 'Ожидание Telnet-авторизации.');
  while GetTickCount64 < LDeadline do
  begin
    LChunk := WaitForText(1200);
    if LChunk <> '' then
    begin
      Result.RawText := Result.RawText + LChunk;
      LCleanChunk := RemoveEchoFromText(LChunk);
      LCleanAll := NormalizeText(Result.RawText);
      if LCleanChunk <> '' then
      begin
        WriteDebugLog('TELNET AUTH RECV: ' + LCleanChunk);
      end;
      if ContainsDeniedText(LCleanAll) then
      begin
        Result.CleanText := RemoveEchoFromText(Result.RawText);
        Logger.Write(llCritical, 'Telnet-авторизация отклонена.', True);
        raise Exception.Create('Telnet-авторизация отклонена.');
      end;
      if ContainsLoginRequest(LCleanAll) and not LUserSent then
      begin
        Logger.Write(llInfo, 'Отправка имени пользователя Telnet.');
        SendLine(AUserName, True);
        LUserSent := True;
        Continue;
      end;
      if ContainsPasswordRequest(LCleanAll) and not LPasswordSent then
      begin
        Logger.Write(llInfo, 'Отправка пароля Telnet.');
        SendLine(APassword, True);
        LPasswordSent := True;
        Continue;
      end;
      if LUserSent and LPasswordSent and ContainsLoginRequest(LCleanAll) then
      begin
        Result.CleanText := RemoveEchoFromText(Result.RawText);
        Logger.Write(llCritical, 'Telnet-авторизация не выполнена: устройство снова запросило логин.', True);
        raise Exception.Create('Telnet-авторизация не выполнена: устройство снова запросило логин.');
      end;
      if ContainsAuthorizedPrompt(LCleanAll) then
      begin
        Result.IsAuthorized := True;
        Result.CleanText := RemoveEchoFromText(Result.RawText);
        Logger.Write(llInfo, 'Telnet-авторизация выполнена успешно.');
        Exit;
      end;
    end
    else
    begin
      Sleep(50);
    end;
  end;
  Result.CleanText := RemoveEchoFromText(Result.RawText);
  Logger.Write(llCritical, 'Не удалось выполнить Telnet-авторизацию за заданный тайм-аут.', True);
  raise Exception.Create('Не удалось выполнить Telnet-авторизацию за заданный тайм-аут.');
end;

initialization
  Logger := TSafeLoggerCore.Instance;
  TKeeneticTelnetClient.FWinSockStarted := False;
  TKeeneticTelnetClient.FWinSockStartCount := 0;

finalization
  Logger := nil;

end.
