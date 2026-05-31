program KeeneticTelnetTest;

{
  Написано ChatGPT 31.05.2026 09:55:00.000, сборка 1.0.0.1
  Минимальный VCL-проект для проверки KeeneticTelnetClient.pas в RAD Studio 12.2.
}

uses
  Vcl.Forms,
  MainForm in 'MainForm.pas' {frmMain},
  KeeneticTelnetClient in 'KeeneticTelnetClient.pas',
  SafeLogger in 'SafeLogger.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
