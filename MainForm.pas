unit MainForm;

{
  Написано ChatGPT 31.05.2026 10:03:00.000, сборка 1.0.0.1
  Минимальная форма проверки KeeneticTelnetClient.pas в RAD Studio 12.2.
}

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.StdCtrls,
  SafeLogger,
  KeeneticTelnetClient;

type
  TfrmMain = class(TForm)
    edtHost: TEdit;
    edtPort: TEdit;
    edtLogin: TEdit;
    edtPassword: TEdit;
    btnConnect: TButton;
    btnDisconnect: TButton;
    MemoLog: TMemo;
    lblHost: TLabel;
    lblPort: TLabel;
    lblLogin: TLabel;
    lblPassword: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
  private
    FClient: TKeeneticTelnetClient;
    FLogger: TSafeLoggerCore;
    procedure ConfigureLogger;
    procedure SetControlsState(const AConnected: Boolean);
  public
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

procedure TfrmMain.ConfigureLogger;
var
  LSettings: TSafeLoggerSettings;
begin
  FLogger := TSafeLoggerCore.Instance;
  LSettings := TSafeLoggerSettings.Default;
  LSettings.Outputs := [loMemo, loConsole];
  LSettings.MemoTarget := MemoLog;
  LSettings.LogLevelFilter := llDebug;
  FLogger.Configure(LSettings);
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  ConfigureLogger;
  FClient := TKeeneticTelnetClient.Create;
  SetControlsState(False);
  FLogger.Write(llInfo, 'Тестовый проект Keenetic Telnet запущен.');
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  if FClient <> nil then
  begin
    FClient.Free;
    FClient := nil;
  end;
  if FLogger <> nil then
  begin
    FLogger.Flush;
  end;
  FLogger := nil;
end;

procedure TfrmMain.SetControlsState(const AConnected: Boolean);
begin
  edtHost.Enabled := not AConnected;
  edtPort.Enabled := not AConnected;
  edtLogin.Enabled := not AConnected;
  edtPassword.Enabled := not AConnected;
  btnConnect.Enabled := not AConnected;
  btnDisconnect.Enabled := AConnected;
end;

procedure TfrmMain.btnConnectClick(Sender: TObject);
var
  LPort: Integer;
  LPrompt: TKeeneticTelnetPromptKind;
begin
  LPort := StrToIntDef(Trim(edtPort.Text), 23);
  try
    FLogger.Write(llInfo, 'Начало проверки Telnet-подключения.');
    FClient.Connect(Trim(edtHost.Text), Word(LPort), 15000);
    LPrompt := FClient.Login(Trim(edtLogin.Text), edtPassword.Text);
    FLogger.Write(llInfo, Format('Авторизация выполнена. Prompt=%d', [Ord(LPrompt)]));
    SetControlsState(True);
  except
    on E: Exception do
    begin
      FLogger.Write(llCritical, 'Ошибка подключения или авторизации: ' + E.Message, True);
      if FClient <> nil then
      begin
        FClient.Disconnect;
      end;
      SetControlsState(False);
    end;
  end;
end;

procedure TfrmMain.btnDisconnectClick(Sender: TObject);
begin
  if FClient <> nil then
  begin
    FClient.Disconnect;
  end;
  SetControlsState(False);
end;

end.
