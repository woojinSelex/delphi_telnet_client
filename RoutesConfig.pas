unit RoutesConfig;

{
  Доработано ChatGPT 31.05.2026 13:22:00.000, сборка 1.0.0.4
  Назначение: чтение и создание ini-файла программы.
  Пароль хранится в единственном поле Password как короткая Base64-строка с XOR-маскировкой.
}

interface

uses
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
    function MaskText(const AText: string): string;
    function UnmaskText(const APasswordValue: string): string;
    function LooksLikeBase64Password(const APasswordValue: string): Boolean;
  public
    constructor Create(const AFileName: string);
    procedure EnsureExists;
    function Load: TRoutesConnectionSettings;
    procedure Save(const ASettings: TRoutesConnectionSettings);
    property FileName: string read FFileName;
  end;

implementation

const
  MASK_KEY: array[0..7] of Byte = ($4B, $65, $65, $6E, $65, $74, $69, $63);

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

function TRoutesConfig.LooksLikeBase64Password(const APasswordValue: string): Boolean;
var
  LValue: string;
  LIndex: Integer;
begin
  LValue := Trim(APasswordValue);
  Result := False;
  if LValue = '' then
  begin
    Exit;
  end;
  if (Length(LValue) mod 4) <> 0 then
  begin
    Exit;
  end;
  for LIndex := 1 to Length(LValue) do
  begin
    if not CharInSet(LValue[LIndex], ['A'..'Z', 'a'..'z', '0'..'9', '+', '/', '=']) then
    begin
      Exit;
    end;
  end;
  Result := True;
end;

function TRoutesConfig.MaskText(const AText: string): string;
var
  LBytes: TBytes;
  LIndex: Integer;
begin
  Result := '';
  if AText = '' then
  begin
    Exit;
  end;
  LBytes := TEncoding.UTF8.GetBytes(AText);
  for LIndex := 0 to Length(LBytes) - 1 do
  begin
    LBytes[LIndex] := LBytes[LIndex] xor MASK_KEY[LIndex mod Length(MASK_KEY)];
  end;
  Result := TNetEncoding.Base64.EncodeBytesToString(LBytes);
end;

function TRoutesConfig.UnmaskText(const APasswordValue: string): string;
var
  LValue: string;
  LBytes: TBytes;
  LIndex: Integer;
begin
  Result := '';
  LValue := Trim(APasswordValue);
  if LValue = '' then
  begin
    Exit;
  end;
  if SameText(Copy(LValue, 1, 6), 'DPAPI:') then
  begin
    Result := '';
    Exit;
  end;
  if SameText(Copy(LValue, 1, 5), 'MASK:') then
  begin
    Delete(LValue, 1, 5);
  end;
  if not LooksLikeBase64Password(LValue) then
  begin
    Result := LValue;
    Exit;
  end;
  try
    LBytes := TNetEncoding.Base64.DecodeStringToBytes(LValue);
    for LIndex := 0 to Length(LBytes) - 1 do
    begin
      LBytes[LIndex] := LBytes[LIndex] xor MASK_KEY[LIndex mod Length(MASK_KEY)];
    end;
    Result := TEncoding.UTF8.GetString(LBytes);
  except
    Result := LValue;
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
  LPasswordValue: string;
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
    LPasswordValue := LIni.ReadString('Host', 'Password', '');
    Result.Password := UnmaskText(LPasswordValue);
    if Result.SaveCredentials and (Result.Password <> '') and (LPasswordValue <> MaskText(Result.Password)) then
    begin
      LIni.WriteString('Host', 'Password', MaskText(Result.Password));
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
      LIni.WriteString('Host', 'Password', MaskText(ASettings.Password));
    end
    else
    begin
      LIni.WriteString('Host', 'Password', '');
    end;
  finally
    LIni.Free;
  end;
end;

end.
