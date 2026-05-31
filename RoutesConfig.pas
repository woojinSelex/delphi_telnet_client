unit RoutesConfig;

{
  Написано ChatGPT 31.05.2026 12:31:00.000, сборка 1.0.0.1
  Назначение: чтение и создание routes.ini для тестового Telnet-проекта.
  Пароль хранится в зашифрованном виде через Windows DPAPI CurrentUser.
}

interface

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  System.IniFiles,
  System.NetEncoding;

type
  TRoutesConnectionSettings = record
    Host: string;
    Port: Word;
    Username: string;
    Password: string;
    SaveCredentials: Boolean;
    SaveLog: Boolean;
    VerboseTelnetLog: Boolean;
  end;

  TRoutesConfig = class
  private
    FFileName: string;
    function BoolToIniValue(const AValue: Boolean): string;
    function IniValueToBool(const AValue: string; const ADefault: Boolean): Boolean;
    function ProtectText(const AText: string): string;
    function UnprotectText(const AProtectedText: string): string;
  public
    constructor Create(const AFileName: string);
    procedure EnsureExists;
    function Load: TRoutesConnectionSettings;
    procedure Save(const ASettings: TRoutesConnectionSettings);
    property FileName: string read FFileName;
  end;

implementation

type
  PDataBlob = ^TDataBlob;
  TDataBlob = record
    cbData: DWORD;
    pbData: PByte;
  end;

function CryptProtectData(
  pDataIn: PDataBlob;
  szDataDescr: PWideChar;
  pOptionalEntropy: PDataBlob;
  pvReserved: Pointer;
  pPromptStruct: Pointer;
  dwFlags: DWORD;
  pDataOut: PDataBlob): BOOL; stdcall; external 'Crypt32.dll';

function CryptUnprotectData(
  pDataIn: PDataBlob;
  ppszDataDescr: PPWideChar;
  pOptionalEntropy: PDataBlob;
  pvReserved: Pointer;
  pPromptStruct: Pointer;
  dwFlags: DWORD;
  pDataOut: PDataBlob): BOOL; stdcall; external 'Crypt32.dll';

constructor TRoutesConfig.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
end;

function TRoutesConfig.BoolToIniValue(const AValue: Boolean): string;
begin
  if AValue then
  begin
    Result := '1';
  end
  else
  begin
    Result := '0';
  end;
end;

function TRoutesConfig.IniValueToBool(const AValue: string; const ADefault: Boolean): Boolean;
var
  LValue: string;
begin
  LValue := Trim(LowerCase(AValue));
  if (LValue = '1') or (LValue = 'true') or (LValue = 'yes') or (LValue = 'да') then
  begin
    Result := True;
    Exit;
  end;
  if (LValue = '0') or (LValue = 'false') or (LValue = 'no') or (LValue = 'нет') then
  begin
    Result := False;
    Exit;
  end;
  Result := ADefault;
end;

function TRoutesConfig.ProtectText(const AText: string): string;
var
  LBytes: TBytes;
  LInput: TDataBlob;
  LOutput: TDataBlob;
  LProtectedBytes: TBytes;
begin
  Result := '';
  if AText = '' then
  begin
    Exit;
  end;

  LBytes := TEncoding.UTF8.GetBytes(AText);
  FillChar(LInput, SizeOf(LInput), 0);
  FillChar(LOutput, SizeOf(LOutput), 0);
  LInput.cbData := Length(LBytes);
  LInput.pbData := @LBytes[0];

  if not CryptProtectData(@LInput, nil, nil, nil, nil, 0, @LOutput) then
  begin
    RaiseLastOSError;
  end;

  try
    SetLength(LProtectedBytes, LOutput.cbData);
    Move(LOutput.pbData^, LProtectedBytes[0], LOutput.cbData);
    Result := TNetEncoding.Base64.EncodeBytesToString(LProtectedBytes);
  finally
    if LOutput.pbData <> nil then
    begin
      CoTaskMemFree(LOutput.pbData);
    end;
  end;
end;

function TRoutesConfig.UnprotectText(const AProtectedText: string): string;
var
  LProtectedBytes: TBytes;
  LInput: TDataBlob;
  LOutput: TDataBlob;
  LTextBytes: TBytes;
begin
  Result := '';
  if Trim(AProtectedText) = '' then
  begin
    Exit;
  end;

  LProtectedBytes := TNetEncoding.Base64.DecodeStringToBytes(AProtectedText);
  if Length(LProtectedBytes) = 0 then
  begin
    Exit;
  end;

  FillChar(LInput, SizeOf(LInput), 0);
  FillChar(LOutput, SizeOf(LOutput), 0);
  LInput.cbData := Length(LProtectedBytes);
  LInput.pbData := @LProtectedBytes[0];

  if not CryptUnprotectData(@LInput, nil, nil, nil, nil, 0, @LOutput) then
  begin
    Exit;
  end;

  try
    SetLength(LTextBytes, LOutput.cbData);
    Move(LOutput.pbData^, LTextBytes[0], LOutput.cbData);
    Result := TEncoding.UTF8.GetString(LTextBytes);
  finally
    if LOutput.pbData <> nil then
    begin
      CoTaskMemFree(LOutput.pbData);
    end;
  end;
end;

procedure TRoutesConfig.EnsureExists;
var
  LIni: TIniFile;
begin
  if FileExists(FFileName) then
  begin
    Exit;
  end;

  ForceDirectories(ExtractFilePath(FFileName));
  LIni := TIniFile.Create(FFileName);
  try
    LIni.WriteString('Host', 'IP', '10.10.0.1');
    LIni.WriteInteger('Host', 'Port', 23);
    LIni.WriteString('Host', 'Username', 'admin');
    LIni.WriteString('Host', 'Password', '');
    LIni.WriteString('Host', 'PasswordProtected', '');
    LIni.WriteInteger('Settings', 'SaveCredentials', 1);
    LIni.WriteInteger('Settings', 'SaveLog', 1);
    LIni.WriteInteger('Settings', 'VerboseTelnetLog', 0);
    LIni.WriteString('Routes', 'Default', '');
  finally
    LIni.Free;
  end;
end;

function TRoutesConfig.Load: TRoutesConnectionSettings;
var
  LIni: TIniFile;
  LPlainPassword: string;
  LProtectedPassword: string;
  LPort: Integer;
begin
  EnsureExists;
  LIni := TIniFile.Create(FFileName);
  try
    Result.Host := LIni.ReadString('Host', 'IP', '10.10.0.1');
    LPort := LIni.ReadInteger('Host', 'Port', 23);
    if (LPort < 1) or (LPort > 65535) then
    begin
      LPort := 23;
    end;
    Result.Port := Word(LPort);
    Result.Username := LIni.ReadString('Host', 'Username', 'admin');
    Result.SaveCredentials := IniValueToBool(LIni.ReadString('Settings', 'SaveCredentials', '1'), True);
    Result.SaveLog := IniValueToBool(LIni.ReadString('Settings', 'SaveLog', '1'), True);
    Result.VerboseTelnetLog := IniValueToBool(LIni.ReadString('Settings', 'VerboseTelnetLog', '0'), False);

    LProtectedPassword := LIni.ReadString('Host', 'PasswordProtected', '');
    Result.Password := UnprotectText(LProtectedPassword);

    LPlainPassword := LIni.ReadString('Host', 'Password', '');
    if (Result.Password = '') and (LPlainPassword <> '') then
    begin
      Result.Password := LPlainPassword;
      if Result.SaveCredentials then
      begin
        LIni.WriteString('Host', 'PasswordProtected', ProtectText(LPlainPassword));
        LIni.WriteString('Host', 'Password', '');
      end;
    end;
  finally
    LIni.Free;
  end;
end;

procedure TRoutesConfig.Save(const ASettings: TRoutesConnectionSettings);
var
  LIni: TIniFile;
begin
  EnsureExists;
  LIni := TIniFile.Create(FFileName);
  try
    LIni.WriteString('Host', 'IP', Trim(ASettings.Host));
    LIni.WriteInteger('Host', 'Port', ASettings.Port);
    LIni.WriteString('Host', 'Username', Trim(ASettings.Username));
    LIni.WriteString('Settings', 'SaveCredentials', BoolToIniValue(ASettings.SaveCredentials));
    LIni.WriteString('Settings', 'SaveLog', BoolToIniValue(ASettings.SaveLog));
    LIni.WriteString('Settings', 'VerboseTelnetLog', BoolToIniValue(ASettings.VerboseTelnetLog));

    if ASettings.SaveCredentials then
    begin
      LIni.WriteString('Host', 'PasswordProtected', ProtectText(ASettings.Password));
      LIni.WriteString('Host', 'Password', '');
    end
    else
    begin
      LIni.WriteString('Host', 'PasswordProtected', '');
      LIni.WriteString('Host', 'Password', '');
    end;
  finally
    LIni.Free;
  end;
end;

end.
