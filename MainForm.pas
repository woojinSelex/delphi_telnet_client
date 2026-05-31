unit MainForm;

{
  Доработано ChatGPT 31.05.2026 12:49:00.000, сборка 1.0.0.3
  Добавлено: загрузка и сохранение настроек подключения в ini-файл по имени программы.
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
  KeeneticTelnetClient,
  RoutesConfig;

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
    FConfig: TRoutesConfig;
    FSettings: TRoutesConnectionSettings;
    procedure ConfigureLogger;
    procedure SetControlsState(const AConnected: Boolean);
    function GetIniFileName: string;
    procedure LoadSettingsToControls;
    procedure SaveSettingsFromControls;
  public
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

function TfrmMain.GetIniFileName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

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

procedure TfrmMain.LoadSettingsToControls;
begin
  FSettings := FConfig.Load;
  edtHost.Text := FSettings.Host;
  edtPort.Text := IntToStr(FSettings.Port);
  edtLogin.Text := FSettings.Username;
  edtPassword.Text := FSettings.Password;
  FLogger.Write(llInfo, 'Настройки подключения загружены из файла: ' + FConfig.FileName);
end;

procedure TfrmMain.SaveSettingsFromControls;
var
  LPort: Integer;
begin
  LPort := StrToIntDef(Trim(edtPort.Text), 23);
  if (LPort < 1) or (LPort > 65535) then
  begin
    LPort := 23;
  end;

  FSettings.Host := Trim(edtHost.Text);
  FSettings.Port := Word(LPort);
  FSettings.Username := Trim(edtLogin.Text);
  FSettings.Password := edtPassword.Text;
  FConfig.Save(FSettings);
  FLogger.Write(llInfo, 'Настройки подключения сохранены в файл: ' + FConfig.FileName);
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  ConfigureLogger;
  FConfig := TRoutesConfig.Create(GetIniFileName);
  FConfig.EnsureExists;
  LoadSettingsToControls;
  FClient := TKeeneticTelnetClient.Create;
  SetControlsState(False);
  FLogger.Write(llInfo, 'Тестовый проект Keenetic Telnet запущен.');
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  try
    if FConfig <> nil then
    begin
      SaveSettingsFromControls;
    end;
  except
    on E: Exception do
    begin
      if FLogger <> nil then
      begin
        FLogger.Write(llWarning, 'Не удалось сохранить настройки при выходе: ' + E.Message);
      end;
    end;
  end;

  if FClient <> nil then
  begin
    FClient.Free;
    FClient := nil;
  end;

  if FConfig <> nil then
  begin
    FConfig.Free;
    FConfig := nil;
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
  LLoginResult: TKeeneticTelnetLoginResult;
begin
  LPort := StrToIntDef(Trim(edtPort.Text), 23);
  try
    SaveSettingsFromControls;
    FLogger.Write(llInfo, 'Начало проверки Telnet-подключения.');
    FClient.Connect(Trim(edtHost.Text), Word(LPort), 15000);
    LLoginResult := FClient.Login(Trim(edtLogin.Text), edtPassword.Text);
    if LLoginResult.IsAuthorized then
    begin
      SaveSettingsFromControls;
      FLogger.Write(llInfo, 'Авторизация выполнена успешно.');
    end
    else
    begin
      FLogger.Write(llWarning, 'Метод Login завершился без признака успешной авторизации.');
    end;
    if LLoginResult.CleanText <> '' then
    begin
      FLogger.Write(llDebug, 'Очищенный ответ авторизации: ' + LLoginResult.CleanText);
    end;
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
  SaveSettingsFromControls;
  SetControlsState(False);
end;

end.
