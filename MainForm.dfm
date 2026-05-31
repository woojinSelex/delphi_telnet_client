object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Keenetic Telnet Test'
  ClientHeight = 600
  ClientWidth = 900
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object lblHost: TLabel
    Left = 8
    Top = 10
    Width = 10
    Height = 15
    Caption = 'IP'
  end
  object lblPort: TLabel
    Left = 190
    Top = 10
    Width = 22
    Height = 15
    Caption = 'Port'
  end
  object lblLogin: TLabel
    Left = 279
    Top = 10
    Width = 30
    Height = 15
    Caption = 'Login'
  end
  object lblPassword: TLabel
    Left = 430
    Top = 10
    Width = 19
    Height = 15
    Caption = 'Key'
  end
  object edtHost: TEdit
    Left = 27
    Top = 7
    Width = 150
    Height = 23
    TabOrder = 0
    Text = '10.10.0.1'
  end
  object edtPort: TEdit
    Left = 225
    Top = 7
    Width = 45
    Height = 23
    TabOrder = 1
    Text = '23'
  end
  object edtLogin: TEdit
    Left = 316
    Top = 7
    Width = 105
    Height = 23
    TabOrder = 2
    Text = 'admin'
  end
  object edtPassword: TEdit
    Left = 486
    Top = 7
    Width = 130
    Height = 23
    PasswordChar = '*'
    TabOrder = 3
  end
  object btnConnect: TButton
    Left = 624
    Top = 6
    Width = 125
    Height = 25
    Caption = 'Connect Login'
    TabOrder = 4
    OnClick = btnConnectClick
  end
  object btnDisconnect: TButton
    Left = 756
    Top = 6
    Width = 125
    Height = 25
    Caption = 'Disconnect'
    TabOrder = 5
    OnClick = btnDisconnectClick
  end
  object MemoLog: TMemo
    Left = 8
    Top = 40
    Width = 884
    Height = 552
    ScrollBars = ssBoth
    TabOrder = 6
    WordWrap = False
  end
end
