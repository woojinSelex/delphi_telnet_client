unit KeeneticTelnetCredentialsTest;

interface

uses
  System.SysUtils,
  System.Classes;

const
  // Доработано ChatGPT 31.05.2026 01:43:12.000, сборка 1.0.0.1
  CBuildVersion = '1.0.0.1';
  CBuildDateTime = '31.05.2026 01:43:12.000';
  CTestRouterHost = '10.10.0.1';
  CTestRouterPort = 23;
  CTestLogin = 'test_admin';
  CTestPassword = 'test_password_12345';

 type
  TKeeneticTelnetCredentials = record
    RouterHost: string;
    RouterPort: Integer;
    Login: string;
    Password: string;
  end;

  TKeeneticTelnetTestLogger = class
  private
    FLogFileName: string;
    FWriteToFile: Boolean;
  public
    constructor Create(const ALogFileName: string);
    procedure AddLine(const AMessage: string);
    property LogFileName: string read FLogFileName write FLogFileName;
    property WriteToFile: Boolean read FWriteToFile write FWriteToFile;
  end;

function CreateTestCredentials: TKeeneticTelnetCredentials;
function CredentialsToSafeText(const ACredentials: TKeeneticTelnetCredentials): string;

implementation

constructor TKeeneticTelnetTestLogger.Create(const ALogFileName: string);
begin
  inherited Create;
  FLogFileName := ALogFileName;
  FWriteToFile := True;
end;

procedure TKeeneticTelnetTestLogger.AddLine(const AMessage: string);
var
  LLines: TStringList;
  LLine: string;
begin
  LLine := Format('[%s] %s', [FormatDateTime('dd.mm.yyyy hh:nn:ss.zzz', Now), AMessage]);

  if not FWriteToFile then
  begin
    Exit;
  end;

  if Trim(FLogFileName) = '' then
  begin
    Exit;
  end;

  LLines := TStringList.Create;
  try
    if FileExists(FLogFileName) then
    begin
      LLines.LoadFromFile(FLogFileName, TEncoding.UTF8);
    end;

    LLines.Add(LLine);
    LLines.SaveToFile(FLogFileName, TEncoding.UTF8);
  finally
    LLines.Free;
  end;
end;

function CreateTestCredentials: TKeeneticTelnetCredentials;
begin
  Result.RouterHost := CTestRouterHost;
  Result.RouterPort := CTestRouterPort;
  Result.Login := CTestLogin;
  Result.Password := CTestPassword;
end;

function CredentialsToSafeText(const ACredentials: TKeeneticTelnetCredentials): string;
begin
  Result := 'RouterHost=' + ACredentials.RouterHost + sLineBreak +
            'RouterPort=' + ACredentials.RouterPort.ToString + sLineBreak +
            'Login=' + ACredentials.Login + sLineBreak +
            'Password=<masked-test-password>';
end;

end.
