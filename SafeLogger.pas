unit SafeLogger;

(*
  ==============================================================================
  МОДУЛЬ УНИВЕРСАЛЬНОГО ЛОГИРОВАНИЯ (SAFE LOGGER) - Версия 6.3
  ==============================================================================

  Назначение
  ----------
  SafeLogger - единый логгер приложения. Внутри модуля всегда работает один
  экземпляр ядра TSafeLoggerCore.Instance. Все вызовы Log(...), все экземпляры
  компонента TSafeLogger и прямые настройки через Instance пишут в одно ядро и
  одну очередь фонового writer-потока.

  Быстрое использование без компонента
  ------------------------------------
    uses SafeLogger;

    begin
      Log('Программа запущена');
      Log('Подробное сообщение', llDebug);
      try
        ...
      except
        on E: Exception do
          LogException(E);
      end;
      FlushLog;
    end;

  По умолчанию Log уже полностью работоспособен: пишет в файл рядом с EXE,
  выводит в консоль при наличии консоли, фильтр уровня - llDebug, формат строки
  - "{TIME} [{LEVEL}] {MESSAGE}", имя файла - "{APPNAME}-{DATETIME}.log".

  Использование как визуального компонента
  ----------------------------------------
  1. Положите TSafeLogger на форму.
  2. Настройте свойства в Object Inspector: FilePath, FileNamePattern, Outputs,
     форматы времени/строки, цвета уровней, RotationMode, MaxBackupFiles.
  3. Если нужен вывод в GUI, назначьте MemoTarget или обработчик OnLogNotify.
     Для цветного GUI лучше использовать OnLogNotify и рисовать строки в
     TRichEdit, TListView или TStringGrid на стороне формы.

  Компонент не является отдельным логгером. Он только применяет визуальные
  настройки к единственному ядру. Если в приложении случайно создано несколько
  TSafeLogger, активным конфигуратором считается последний загруженный/созданный
  активный компонент; при уничтожении он освобождает привязку к GUI.

  Прямая настройка через ядро
  ---------------------------
    var S: TSafeLoggerSettings;
    S := TSafeLoggerSettings.Default;
    S.FilePath := 'C:\Logs';
    S.Outputs := [loConsole, loEvent];
    TSafeLoggerCore.Instance.Configure(S);

  Порядок uses
  ------------
  Модуль не требует быть первым в uses. Ядро создаётся лениво при первом
  обращении к TSafeLoggerCore.Instance/Log, а компонент применяет настройки в
  Loaded. Поэтому порядок подключения модулей не должен влиять на работу лога.

  Примечания по потокам
  ---------------------
  Запись асинхронная: сообщения попадают в очередь и сбрасываются writer-потоком.
  LogException сбрасывается сразу. Обычные сообщения, включая llCritical,
  записываются через очередь; для ручного немедленного сброса используйте
  FlushLog. GUI-вывод выполняется через Synchronize, поэтому обработчики
  OnLogNotify вызываются в главном потоке.

  История
  -------
  6.2.0.1: цвета уровней и property editors для Object Inspector.
  6.2.0.2: исправления design-time uses/property editors.
  6.3.0.0: единое ядро с TSafeLoggerSettings, компонент как визуальный
           конфигуратор, устранение дублей настроек, подробная инструкция.
*)

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  Vcl.StdCtrls,
  Vcl.Graphics,
  System.Generics.Collections,
  System.Generics.Defaults,
  {$IFDEF DESIGNTIME}
  DesignEditors,
  DesignIntf,
  {$ENDIF}
  System.TypInfo,
  System.DateUtils;

type
  TLogLevel = (
    llDebug,
    llHint,
    llInfo,
    llWarning,
    llError,
    llCritical
  );

  TLogOutput = (loConsole, loMemo, loEvent);
  TLogOutputs = set of TLogOutput;

  TRotationMode = (rmNone, rmHourly, rmDaily, rmWeekly, rmMonthly);

  TTimeFormatPreset = (tfFull, tfShort, tfISO, tfCustom);
  TLineFormatPreset = (lfSimple, lfDetailed, lfCSV, lfCustom);

  TLogNotifyEvent = procedure(Sender: TObject; Level: TLogLevel; const Msg: string; Color: TColor) of object;

  TLogColors = array[TLogLevel] of TColor;

  TSafeLogger = class;

  TSafeLoggerSettings = record
    Active: Boolean;
    LogLevelFilter: TLogLevel;
    FileNamePattern: string;
    FilePath: string;
    TimeFormat: string;
    LineFormat: string;
    Outputs: TLogOutputs;
    MemoTarget: TMemo;
    OnLogNotify: TLogNotifyEvent;
    Colors: TLogColors;
    RotationMode: TRotationMode;
    MaxBackupFiles: Integer;

    /// <summary>
    /// Возвращает полный набор рабочих настроек, с которыми глобальный Log
    /// должен писать сразу после подключения модуля без компонента на форме.
    /// </summary>
    class function Default: TSafeLoggerSettings; static;
  end;

  TSafeLoggerCore = class
  private
    class var FInstance: TSafeLoggerCore;
    class var FLock: TRTLCriticalSection;
    FWriterThread: TObject;
    FConfigCS: TRTLCriticalSection;
    FSettings: TSafeLoggerSettings;
    FVisualOwner: TSafeLogger;

    /// <summary>Создаёт ядро, дефолтные настройки и writer-поток.</summary>
    constructor Create;
    /// <summary>Возвращает потокобезопасный снимок текущих настроек.</summary>
    function GetSettings: TSafeLoggerSettings;
    /// <summary>Форматирует текущую дату/время по активному TimeFormat.</summary>
    function GetTimeStr: string;
    /// <summary>Собирает итоговую строку лога из шаблона LineFormat.</summary>
    function FormatLine(Level: TLogLevel; const Msg: string): string;
    /// <summary>Преобразует уровень лога в текстовую метку DEBUG/INFO/etc.</summary>
    function GetLevelString(Level: TLogLevel): string;
  public
    /// <summary>Освобождает writer-поток, сбрасывая очередь перед закрытием.</summary>
    destructor Destroy; override;

    /// <summary>
    /// Возвращает единственный экземпляр ядра логгера. Создаётся лениво при
    /// первом обращении из Log, компонента TSafeLogger или пользовательского кода.
    /// </summary>
    class function Instance: TSafeLoggerCore;

    /// <summary>
    /// Применяет полный набор настроек к единственному ядру и writer-потоку.
    /// Используйте этот метод, если нужно настроить логгер без визуального
    /// компонента.
    /// </summary>
    procedure Configure(const Settings: TSafeLoggerSettings); overload;

    /// <summary>
    /// Удобная перегрузка для старого стиля настройки. Все параметры собираются
    /// в TSafeLoggerSettings и затем применяются через основную Configure.
    /// </summary>
    procedure Configure(const FilePath, FileNamePattern, TimeFmt, LineFmt: string;
      Outputs: TLogOutputs; Memo: TMemo; Notify: TLogNotifyEvent;
      const Colors: TLogColors; LevelFilter: TLogLevel;
      RotationMode: TRotationMode; MaxBackupFiles: Integer); overload;

    /// <summary>
    /// Применяет настройки компонента как визуального конфигуратора. В ядре
    /// запоминается последний активный компонент, чтобы GUI-привязка была одна.
    /// </summary>
    procedure ConfigureFromComponent(Component: TSafeLogger; const Settings: TSafeLoggerSettings);

    /// <summary>
    /// Отвязывает компонент от GUI-настроек ядра, если именно он был текущим
    /// визуальным конфигуратором.
    /// </summary>
    procedure DetachComponent(Component: TSafeLogger);

    /// <summary>
    /// Пишет сообщение указанного уровня. Метод потокобезопасно форматирует
    /// строку по текущим настройкам и передаёт её writer-потоку. Сам уровень
    /// llCritical не заставляет метод сбрасывать очередь; немедленный сброс
    /// включается только параметром IsCritical.
    /// </summary>
    procedure Write(Level: TLogLevel; const Msg: string; IsCritical: Boolean = False);

    /// <summary>
    /// Принудительно сбрасывает очередь сообщений в файл/консоль/GUI.
    /// </summary>
    procedure Flush;

    /// <summary>
    /// Принудительно закрывает текущий файл лога, переносит его в backup и
    /// открывает новый файл по текущим настройкам ротации.
    /// </summary>
    procedure RotateLog;

    /// <summary>
    /// Текущий снимок настроек единственного ядра логгера.
    /// </summary>
    property Settings: TSafeLoggerSettings read GetSettings write Configure;
  end;

  TSafeLogger = class(TComponent)
  private
    FActive: Boolean;
    FLogLevelFilter: TLogLevel;
    FFileNamePattern: string;
    FFilePath: string;
    FTimeFormatPreset: TTimeFormatPreset;
    FTimeFormatCustom: string;
    FLineFormatPreset: TLineFormatPreset;
    FLineFormatCustom: string;
    FOutputs: TLogOutputs;
    FMemoTarget: TMemo;
    FOnLogNotify: TLogNotifyEvent;
    FColors: TLogColors;
    FRotationMode: TRotationMode;
    FMaxBackupFiles: Integer;

    /// <summary>Включает или отключает применение настроек этого компонента к единственному ядру.</summary>
    procedure SetActive(const Value: Boolean);
    /// <summary>Меняет минимальный уровень сообщений, которые будут попадать в лог.</summary>
    procedure SetLogLevelFilter(Value: TLogLevel);
    /// <summary>Меняет шаблон имени файла и переоткрывает файл в ядре при необходимости.</summary>
    procedure SetFileNamePattern(const Value: string);
    /// <summary>Меняет каталог логов и переоткрывает файл в ядре при необходимости.</summary>
    procedure SetFilePath(const Value: string);
    /// <summary>Выбирает один из предустановленных форматов времени.</summary>
    procedure SetTimeFormatPreset(Value: TTimeFormatPreset);
    /// <summary>Задаёт пользовательский формат времени для TimeFormatPreset=tfCustom.</summary>
    procedure SetTimeFormatCustom(const Value: string);
    /// <summary>Выбирает один из предустановленных форматов строки лога.</summary>
    procedure SetLineFormatPreset(Value: TLineFormatPreset);
    /// <summary>Задаёт пользовательский формат строки для LineFormatPreset=lfCustom.</summary>
    procedure SetLineFormatCustom(const Value: string);
    /// <summary>Выбирает каналы вывода: консоль, Memo и/или событие.</summary>
    procedure SetOutputs(Value: TLogOutputs);
    /// <summary>Привязывает TMemo для простого текстового GUI-вывода.</summary>
    procedure SetMemoTarget(Value: TMemo);
    /// <summary>Привязывает обработчик для пользовательского GUI-вывода, включая цветные компоненты.</summary>
    procedure SetOnLogNotify(Value: TLogNotifyEvent);
    /// <summary>Меняет режим ротации файлов лога.</summary>
    procedure SetRotationMode(Value: TRotationMode);
    /// <summary>Ограничивает количество backup-файлов; отрицательные значения приводятся к нулю.</summary>
    procedure SetMaxBackupFiles(Value: Integer);
    /// <summary>Собирает все свойства компонента в единый settings-record для ядра.</summary>
    function BuildSettings: TSafeLoggerSettings;
    /// <summary>Возвращает фактический формат времени по выбранному preset.</summary>
    function GetTimeFormat: string;
    /// <summary>Возвращает фактический формат строки по выбранному preset.</summary>
    function GetLineFormat: string;

    /// <summary>Возвращает цвет сообщений llDebug.</summary>
    function GetColorDebug: TColor;
    /// <summary>Задаёт цвет сообщений llDebug.</summary>
    procedure SetColorDebug(Value: TColor);
    /// <summary>Возвращает цвет сообщений llHint.</summary>
    function GetColorHint: TColor;
    /// <summary>Задаёт цвет сообщений llHint.</summary>
    procedure SetColorHint(Value: TColor);
    /// <summary>Возвращает цвет сообщений llInfo.</summary>
    function GetColorInfo: TColor;
    /// <summary>Задаёт цвет сообщений llInfo.</summary>
    procedure SetColorInfo(Value: TColor);
    /// <summary>Возвращает цвет сообщений llWarning.</summary>
    function GetColorWarning: TColor;
    /// <summary>Задаёт цвет сообщений llWarning.</summary>
    procedure SetColorWarning(Value: TColor);
    /// <summary>Возвращает цвет сообщений llError.</summary>
    function GetColorError: TColor;
    /// <summary>Задаёт цвет сообщений llError.</summary>
    procedure SetColorError(Value: TColor);
    /// <summary>Возвращает цвет сообщений llCritical.</summary>
    function GetColorCritical: TColor;
    /// <summary>Задаёт цвет сообщений llCritical.</summary>
    procedure SetColorCritical(Value: TColor);
  protected
    /// <summary>После загрузки DFM применяет настройки компонента к единственному ядру.</summary>
    procedure Loaded; override;
  public
    /// <summary>Создаёт визуальный конфигуратор и заполняет свойства дефолтами ядра.</summary>
    constructor Create(AOwner: TComponent); override;
    /// <summary>Отвязывает компонент от ядра, если он был текущим визуальным конфигуратором.</summary>
    destructor Destroy; override;
    /// <summary>Пишет сообщение через единое ядро, если компонент активен.</summary>
    procedure WriteLog(Level: TLogLevel; const Msg: string);
    /// <summary>Принудительно сбрасывает очередь единственного ядра.</summary>
    procedure Flush;
    /// <summary>Принудительно выполняет ротацию файла единственного ядра.</summary>
    procedure RotateLog;
    /// <summary>Повторно применяет текущие свойства компонента к единственному ядру.</summary>
    procedure UpdateCoreSettings;

    property Colors: TLogColors read FColors write FColors;
  published
    property Active: Boolean read FActive write SetActive default True;
    property LogLevelFilter: TLogLevel read FLogLevelFilter write SetLogLevelFilter default llDebug;
    property FileNamePattern: string read FFileNamePattern write SetFileNamePattern;
    property FilePath: string read FFilePath write SetFilePath;
    property TimeFormatPreset: TTimeFormatPreset read FTimeFormatPreset write SetTimeFormatPreset default tfFull;
    property TimeFormatCustom: string read FTimeFormatCustom write SetTimeFormatCustom;
    property LineFormatPreset: TLineFormatPreset read FLineFormatPreset write SetLineFormatPreset default lfDetailed;
    property LineFormatCustom: string read FLineFormatCustom write SetLineFormatCustom;
    property Outputs: TLogOutputs read FOutputs write SetOutputs default [loConsole, loMemo, loEvent];
    property MemoTarget: TMemo read FMemoTarget write SetMemoTarget;
    property OnLogNotify: TLogNotifyEvent read FOnLogNotify write SetOnLogNotify;
    property RotationMode: TRotationMode read FRotationMode write SetRotationMode default rmNone;
    property MaxBackupFiles: Integer read FMaxBackupFiles write SetMaxBackupFiles default 5;

    property ColorDebug: TColor read GetColorDebug write SetColorDebug default clGray;
    property ColorHint: TColor read GetColorHint write SetColorHint default clSkyBlue;
    property ColorInfo: TColor read GetColorInfo write SetColorInfo default clBlack;
    property ColorWarning: TColor read GetColorWarning write SetColorWarning default clOlive;
    property ColorError: TColor read GetColorError write SetColorError default clRed;
    property ColorCritical: TColor read GetColorCritical write SetColorCritical default clMaroon;
  end;

/// <summary>Пишет информационное сообщение llInfo через единственный глобальный логгер.</summary>
procedure Log(const Msg: string); overload;
/// <summary>Пишет сообщение указанного уровня через единственный глобальный логгер.</summary>
procedure Log(const Msg: string; Level: TLogLevel); overload;
/// <summary>Пишет исключение как llCritical и явно сразу сбрасывает очередь.</summary>
procedure LogException(E: Exception);
/// <summary>Принудительно сбрасывает очередь единственного глобального логгера.</summary>
procedure FlushLog;
/// <summary>Регистрирует компонент TSafeLogger и design-time редакторы свойств.</summary>
procedure Register;

implementation

type
  TLogItem = record
    Level: TLogLevel;
    Message: string;
    Color: TColor;
  end;
  PLogItem = ^TLogItem;

  TLogWriterThread = class(TThread)
  private
    FEvent: THandle;
    FStopFlag: Boolean;
    FQueue: TList<PLogItem>;
    FQueueCS: TRTLCriticalSection;
    FFileHandle: THandle;
    FCurrentFileName: string;
    FCurrentDateTag: string;
    FCurrentPeriodStart: TDateTime;

    FSettings: TSafeLoggerSettings;
    FValidatedOutputs: TLogOutputs;

    FSyncMessage: string;
    FSyncLevel: TLogLevel;
    FSyncColor: TColor;

    /// <summary>Добавляет одну строку в TMemo в главном VCL-потоке.</summary>
    procedure SyncMemoUpdate;
    /// <summary>Вызывает OnLogNotify в главном VCL-потоке.</summary>
    procedure SyncEventUpdate;
    /// <summary>Забирает очередь сообщений, пишет файл и отправляет данные в выбранные каналы вывода.</summary>
    procedure FlushQueue;
    /// <summary>Открывает текущий файл лога по FilePath/FileNamePattern, если он ещё не открыт.</summary>
    procedure OpenLogFile;
    /// <summary>Закрывает текущий файл, переносит его в backup и открывает новый файл.</summary>
    procedure RotateFile;
    /// <summary>Подставляет {APPNAME} и {DATETIME} в шаблон имени файла.</summary>
    function ExpandFileNamePattern(const Pattern: string; const DateTimeTag: string): string;
    /// <summary>Возвращает начало периода ротации для заданной даты.</summary>
    function GetPeriodStart(DT: TDateTime): TDateTime;
    /// <summary>Форматирует дату для безопасной вставки в имя файла.</summary>
    function FormatDateTimeForFilename(const DT: TDateTime): string;
    /// <summary>Удаляет старые backup-файлы сверх MaxBackupFiles.</summary>
    procedure DeleteOldBackups;
    /// <summary>Проверяет, пора ли переходить на новый файл по текущему режиму ротации.</summary>
    function ShouldRotate(const NowDT: TDateTime): Boolean;
    /// <summary>Преобразует TColor в ближайший атрибут цвета Windows-консоли.</summary>
    function ColorToConsoleAttr(Color: TColor): Word;
  protected
    /// <summary>Ожидает новые сообщения и периодически сбрасывает очередь writer-потока.</summary>
    procedure Execute; override;
  public
    /// <summary>Создаёт остановленный writer-поток, очередь и событие пробуждения.</summary>
    constructor Create;
    /// <summary>Останавливает поток, сбрасывает остаток очереди и закрывает файл.</summary>
    destructor Destroy; override;
    /// <summary>Добавляет готовую строку лога в очередь; IsCritical=True сбрасывает очередь сразу.</summary>
    procedure Push(const Item: TLogItem; IsCritical: Boolean);
    /// <summary>Принимает снимок настроек ядра и переоткрывает файл при изменении файловых параметров.</summary>
    procedure Configure(const Settings: TSafeLoggerSettings);
    /// <summary>Принудительно сбрасывает очередь writer-потока.</summary>
    procedure ForceFlush;
    /// <summary>Принудительно выполняет ротацию текущего файла.</summary>
    procedure DoRotation;
  end;

  {$IFDEF DESIGNTIME}
  TTimeFormatPresetEditor = class(TEnumProperty)
  public
    /// <summary>Показывает в Object Inspector имя preset времени вместе с примером формата.</summary>
    function GetValue: string; override;
  end;

  TLineFormatPresetEditor = class(TEnumProperty)
  public
    /// <summary>Показывает в Object Inspector имя preset строки вместе с примером шаблона.</summary>
    function GetValue: string; override;
  end;
  {$ENDIF}

var
  AppStartTime: TDateTime;

{ TSafeLoggerSettings }

class function TSafeLoggerSettings.Default: TSafeLoggerSettings;
begin
  Result.Active := True;
  Result.LogLevelFilter := llDebug;
  Result.FileNamePattern := '{APPNAME}-{DATETIME}.log';
  Result.FilePath := '';
  Result.TimeFormat := 'dd.mm.yyyy hh:nn:ss.zzz';
  Result.LineFormat := '{TIME} [{LEVEL}] {MESSAGE}';
  Result.Outputs := [loConsole, loEvent];
  Result.MemoTarget := nil;
  Result.OnLogNotify := nil;
  Result.RotationMode := rmNone;
  Result.MaxBackupFiles := 5;
  Result.Colors[llDebug]    := clGray;
  Result.Colors[llHint]     := clSkyBlue;
  Result.Colors[llInfo]     := clBlack;
  Result.Colors[llWarning]  := clOlive;
  Result.Colors[llError]    := clRed;
  Result.Colors[llCritical] := clMaroon;
end;

{ TLogWriterThread }

function TLogWriterThread.GetPeriodStart(DT: TDateTime): TDateTime;
var
  Year, Month, Day: Word;
begin
  DecodeDate(DT, Year, Month, Day);
  case FSettings.RotationMode of
    rmHourly:
      Result := EncodeDateTime(Year, Month, Day, HourOf(DT), 0, 0, 0);
    rmDaily:
      Result := EncodeDate(Year, Month, Day);
    rmWeekly:
      Result := Trunc(DT) - (DayOfTheWeek(DT) - 1);
    rmMonthly:
      Result := EncodeDate(Year, Month, 1);
  else
    Result := AppStartTime;
  end;
end;

function TLogWriterThread.FormatDateTimeForFilename(const DT: TDateTime): string;
begin
  Result := FormatDateTime('dd.mm.yyyy-hh_nn_ss_zzz', DT);
end;

function TLogWriterThread.ColorToConsoleAttr(Color: TColor): Word;
var
  RGB: Integer;
begin
  RGB := ColorToRGB(Color) and $00FFFFFF;
  case RGB of
    $000000: Result := 0;
    $800000: Result := 4;
    $008000: Result := 2;
    $808000: Result := 6;
    $000080: Result := 1;
    $800080: Result := 5;
    $008080: Result := 3;
    $C0C0C0: Result := 7;
    $808080: Result := 8;
    $FF0000: Result := 12;
    $00FF00: Result := 10;
    $FFFF00: Result := 14;
    $0000FF: Result := 9;
    $FF00FF: Result := 13;
    $00FFFF: Result := 11;
    $FFFFFF: Result := 15;
  else
    Result := 7;
  end;
end;

constructor TLogWriterThread.Create;
begin
  inherited Create(True);
  FQueue := TList<PLogItem>.Create;
  FStopFlag := False;
  FEvent := CreateEvent(nil, False, False, nil);
  InitializeCriticalSection(FQueueCS);
  FFileHandle := INVALID_HANDLE_VALUE;
  FreeOnTerminate := False;
end;

destructor TLogWriterThread.Destroy;
begin
  FStopFlag := True;
  SetEvent(FEvent);
  Terminate;
  WaitFor;
  FlushQueue;
  if FFileHandle <> INVALID_HANDLE_VALUE then
  begin
    FlushFileBuffers(FFileHandle);
    CloseHandle(FFileHandle);
  end;
  CloseHandle(FEvent);
  DeleteCriticalSection(FQueueCS);
  FQueue.Free;
  inherited Destroy;
end;

procedure TLogWriterThread.SyncMemoUpdate;
begin
  if Assigned(FSettings.MemoTarget) and
    not (csDestroying in FSettings.MemoTarget.ComponentState) then
    FSettings.MemoTarget.Lines.Add(FSyncMessage);
end;

procedure TLogWriterThread.SyncEventUpdate;
begin
  if Assigned(FSettings.OnLogNotify) then
    FSettings.OnLogNotify(nil, FSyncLevel, FSyncMessage, FSyncColor);
end;

procedure TLogWriterThread.FlushQueue;
var
  I: Integer;
  P: PLogItem;
  LocalQueue: TList<PLogItem>;
  WrittenText: string;
  FullMsg: AnsiString;
  BytesWritten: DWORD;
  ConsoleHandle: THandle;
  ValidatedOutputs: TLogOutputs;
begin
  LocalQueue := TList<PLogItem>.Create;
  try
    EnterCriticalSection(FQueueCS);
    try
      if FQueue.Count = 0 then Exit;

      if (FSettings.RotationMode <> rmNone) and ShouldRotate(Now) then
        RotateFile;

      if FFileHandle <> INVALID_HANDLE_VALUE then
      begin
        SetFilePointer(FFileHandle, 0, nil, FILE_END);
        for I := 0 to FQueue.Count - 1 do
        begin
          P := FQueue[I];
          WrittenText := P^.Message + #13#10;
          FullMsg := UTF8Encode(WrittenText);
          WriteFile(FFileHandle, PAnsiChar(FullMsg)^, Length(FullMsg), BytesWritten, nil);
        end;
        FlushFileBuffers(FFileHandle);
      end;

      LocalQueue.AddRange(FQueue);
      FQueue.Clear;
      ValidatedOutputs := FValidatedOutputs;
    finally
      LeaveCriticalSection(FQueueCS);
    end;

    if loConsole in ValidatedOutputs then
    begin
      ConsoleHandle := GetStdHandle(STD_OUTPUT_HANDLE);
      if ConsoleHandle <> INVALID_HANDLE_VALUE then
      begin
        for I := 0 to LocalQueue.Count - 1 do
        begin
          P := LocalQueue[I];
          SetConsoleTextAttribute(ConsoleHandle, ColorToConsoleAttr(P^.Color));
          WrittenText := P^.Message + #13#10;
          WriteConsole(ConsoleHandle, PChar(WrittenText), Length(WrittenText), BytesWritten, nil);
        end;
        SetConsoleTextAttribute(ConsoleHandle, 7);
      end;
    end;

    if (loMemo in ValidatedOutputs) and Assigned(FSettings.MemoTarget) then
    begin
      for I := 0 to LocalQueue.Count - 1 do
      begin
        P := LocalQueue[I];
        FSyncMessage := P^.Message;
        Synchronize(SyncMemoUpdate);
      end;
    end;

    if (loEvent in ValidatedOutputs) and Assigned(FSettings.OnLogNotify) then
    begin
      for I := 0 to LocalQueue.Count - 1 do
      begin
        P := LocalQueue[I];
        FSyncMessage := P^.Message;
        FSyncLevel := P^.Level;
        FSyncColor := P^.Color;
        Synchronize(SyncEventUpdate);
      end;
    end;

    for I := 0 to LocalQueue.Count - 1 do
      Dispose(LocalQueue[I]);
    LocalQueue.Clear;
  finally
    LocalQueue.Free;
  end;
end;

function TLogWriterThread.ExpandFileNamePattern(const Pattern: string; const DateTimeTag: string): string;
var
  AppName: string;
begin
  Result := Pattern;
  if Result = '' then Result := '{APPNAME}.log';

  AppName := ChangeFileExt(ExtractFileName(ParamStr(0)), '');
  if AppName = '' then AppName := 'application';

  Result := StringReplace(Result, '{APPNAME}', AppName, [rfReplaceAll]);
  Result := StringReplace(Result, '{DATETIME}', DateTimeTag, [rfReplaceAll]);

  if ExtractFileExt(Result) = '' then Result := Result + '.log';
end;

procedure TLogWriterThread.DeleteOldBackups;
var
  SearchRec: TSearchRec;
  FileList: TList<TSearchRec>;
  I: Integer;
begin
  FileList := TList<TSearchRec>.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(FSettings.FilePath) + '*.bak', faAnyFile, SearchRec) = 0 then
    begin
      repeat
        if (SearchRec.Attr and faDirectory) = 0 then
          FileList.Add(SearchRec);
      until FindNext(SearchRec) <> 0;
      System.SysUtils.FindClose(SearchRec);
    end;

    if FileList.Count <= FSettings.MaxBackupFiles then Exit;

    FileList.Sort(TComparer<TSearchRec>.Construct(
      function(const A, B: TSearchRec): Integer
      var
        timeA, timeB: TDateTime;
      begin
        timeA := A.TimeStamp;
        timeB := B.TimeStamp;
        if timeA < timeB then
          Result := -1
        else if timeA > timeB then
          Result := 1
        else
          Result := 0;
      end));

    for I := 0 to FileList.Count - FSettings.MaxBackupFiles - 1 do
      System.SysUtils.DeleteFile(IncludeTrailingPathDelimiter(FSettings.FilePath) + FileList[I].Name);
  finally
    FileList.Free;
  end;
end;

function TLogWriterThread.ShouldRotate(const NowDT: TDateTime): Boolean;
begin
  Result := False;
  if FSettings.RotationMode = rmNone then Exit;
  if FCurrentPeriodStart = 0 then Exit;

  case FSettings.RotationMode of
    rmHourly,
    rmDaily,
    rmWeekly,
    rmMonthly:  Result := GetPeriodStart(NowDT) <> FCurrentPeriodStart;
  end;
end;

procedure TLogWriterThread.OpenLogFile;
var
  FullPath: string;
  BaseDT: TDateTime;
begin
  if FFileHandle <> INVALID_HANDLE_VALUE then Exit;

  if FSettings.FilePath = '' then
    FSettings.FilePath := ExtractFilePath(ParamStr(0));

  ForceDirectories(FSettings.FilePath);
  BaseDT := GetPeriodStart(Now);
  FCurrentPeriodStart := BaseDT;
  FCurrentDateTag := FormatDateTimeForFilename(BaseDT);
  FCurrentFileName := ExpandFileNamePattern(FSettings.FileNamePattern, FCurrentDateTag);
  FullPath := IncludeTrailingPathDelimiter(FSettings.FilePath) + FCurrentFileName;

  FFileHandle := CreateFile(PChar(FullPath), GENERIC_WRITE, FILE_SHARE_READ, nil,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FFileHandle = INVALID_HANDLE_VALUE then Exit;

  SetFilePointer(FFileHandle, 0, nil, FILE_END);
end;

procedure TLogWriterThread.RotateFile;
var
  BackupName: string;
  BackupPath: string;
begin
  if FFileHandle = INVALID_HANDLE_VALUE then Exit;

  FlushFileBuffers(FFileHandle);
  CloseHandle(FFileHandle);
  FFileHandle := INVALID_HANDLE_VALUE;

  BackupName := ChangeFileExt(FCurrentFileName, '.bak');
  BackupPath := IncludeTrailingPathDelimiter(FSettings.FilePath) + BackupName;
  if FileExists(BackupPath) then
  begin
    BackupName := ChangeFileExt(FCurrentFileName,
      '.' + FormatDateTimeForFilename(Now) + '.bak');
    BackupPath := IncludeTrailingPathDelimiter(FSettings.FilePath) + BackupName;
  end;

  RenameFile(IncludeTrailingPathDelimiter(FSettings.FilePath) + FCurrentFileName, BackupPath);

  DeleteOldBackups;
  OpenLogFile;
end;

procedure TLogWriterThread.Push(const Item: TLogItem; IsCritical: Boolean);
var
  P: PLogItem;
begin
  New(P);
  P^ := Item;

  EnterCriticalSection(FQueueCS);
  try
    OpenLogFile;
    FQueue.Add(P);
  finally
    LeaveCriticalSection(FQueueCS);
  end;

  if Suspended then
    Start;

  if IsCritical then
    ForceFlush
  else
    SetEvent(FEvent);
end;

procedure TLogWriterThread.Configure(const Settings: TSafeLoggerSettings);
var
  NeedReopen: Boolean;
  NewSettings: TSafeLoggerSettings;
begin
  FlushQueue;

  NewSettings := Settings;
  if NewSettings.MaxBackupFiles < 0 then
    NewSettings.MaxBackupFiles := 0;

  EnterCriticalSection(FQueueCS);
  try
    NeedReopen := (FSettings.FilePath <> NewSettings.FilePath) or
      (FSettings.FileNamePattern <> NewSettings.FileNamePattern) or
      (FSettings.RotationMode <> NewSettings.RotationMode);
    if NeedReopen and (FFileHandle <> INVALID_HANDLE_VALUE) then
    begin
      FlushFileBuffers(FFileHandle);
      CloseHandle(FFileHandle);
      FFileHandle := INVALID_HANDLE_VALUE;
      FCurrentFileName := '';
      FCurrentDateTag := '';
      FCurrentPeriodStart := 0;
    end;

    FSettings := NewSettings;
    FValidatedOutputs := FSettings.Outputs;
    if not Assigned(FSettings.MemoTarget) then
      Exclude(FValidatedOutputs, loMemo);
    if not Assigned(FSettings.OnLogNotify) then
      Exclude(FValidatedOutputs, loEvent);

    if FFileHandle = INVALID_HANDLE_VALUE then
      OpenLogFile;
  finally
    LeaveCriticalSection(FQueueCS);
  end;
end;

procedure TLogWriterThread.ForceFlush;
begin
  FlushQueue;
end;

procedure TLogWriterThread.DoRotation;
begin
  FlushQueue;
  EnterCriticalSection(FQueueCS);
  try
    RotateFile;
  finally
    LeaveCriticalSection(FQueueCS);
  end;
end;

procedure TLogWriterThread.Execute;
begin
  while not FStopFlag do
  begin
    if WaitForSingleObject(FEvent, 500) = WAIT_OBJECT_0 then
      FlushQueue
    else
    begin
      if (FSettings.RotationMode <> rmNone) and ShouldRotate(Now) then
      begin
        EnterCriticalSection(FQueueCS);
        try
          RotateFile;
        finally
          LeaveCriticalSection(FQueueCS);
        end;
      end;
      FlushQueue;
    end;
  end;
end;

{ TSafeLoggerCore }

class function TSafeLoggerCore.Instance: TSafeLoggerCore;
begin
  if FInstance = nil then
  begin
    EnterCriticalSection(FLock);
    try
      if FInstance = nil then
        FInstance := TSafeLoggerCore.Create;
    finally
      LeaveCriticalSection(FLock);
    end;
  end;
  Result := FInstance;
end;

constructor TSafeLoggerCore.Create;
begin
  inherited Create;
  InitializeCriticalSection(FConfigCS);
  FWriterThread := TLogWriterThread.Create;
  FSettings := TSafeLoggerSettings.Default;
  TLogWriterThread(FWriterThread).Configure(FSettings);
end;

destructor TSafeLoggerCore.Destroy;
begin
  TLogWriterThread(FWriterThread).ForceFlush;
  FWriterThread.Free;
  DeleteCriticalSection(FConfigCS);
  inherited Destroy;
end;

function TSafeLoggerCore.GetSettings: TSafeLoggerSettings;
begin
  EnterCriticalSection(FConfigCS);
  try
    Result := FSettings;
  finally
    LeaveCriticalSection(FConfigCS);
  end;
end;

function TSafeLoggerCore.GetTimeStr: string;
begin
  Result := FormatDateTime(FSettings.TimeFormat, Now);
end;

function TSafeLoggerCore.GetLevelString(Level: TLogLevel): string;
const
  Names: array[TLogLevel] of string = ('DEBUG', 'HINT', 'INFO', 'WARNING', 'ERROR', 'CRITICAL');
begin
  Result := Names[Level];
end;

function TSafeLoggerCore.FormatLine(Level: TLogLevel; const Msg: string): string;
begin
  Result := FSettings.LineFormat;
  Result := StringReplace(Result, '{TIME}',    GetTimeStr,               [rfReplaceAll]);
  Result := StringReplace(Result, '{LEVEL}',   GetLevelString(Level),    [rfReplaceAll]);
  Result := StringReplace(Result, '{MESSAGE}', Msg,                      [rfReplaceAll]);
end;

procedure TSafeLoggerCore.Configure(const Settings: TSafeLoggerSettings);
var
  NewSettings: TSafeLoggerSettings;
begin
  NewSettings := Settings;
  if NewSettings.TimeFormat = '' then
    NewSettings.TimeFormat := 'dd.mm.yyyy hh:nn:ss.zzz';
  if NewSettings.LineFormat = '' then
    NewSettings.LineFormat := '{TIME} [{LEVEL}] {MESSAGE}';
  if NewSettings.FileNamePattern = '' then
    NewSettings.FileNamePattern := '{APPNAME}-{DATETIME}.log';
  if NewSettings.MaxBackupFiles < 0 then
    NewSettings.MaxBackupFiles := 0;

  EnterCriticalSection(FConfigCS);
  try
    FSettings := NewSettings;
    FVisualOwner := nil;
  finally
    LeaveCriticalSection(FConfigCS);
  end;

  TLogWriterThread(FWriterThread).Configure(NewSettings);
end;

procedure TSafeLoggerCore.Configure(const FilePath, FileNamePattern, TimeFmt, LineFmt: string;
  Outputs: TLogOutputs; Memo: TMemo; Notify: TLogNotifyEvent;
  const Colors: TLogColors; LevelFilter: TLogLevel;
  RotationMode: TRotationMode; MaxBackupFiles: Integer);
var
  Settings: TSafeLoggerSettings;
begin
  Settings := TSafeLoggerSettings.Default;
  Settings.FilePath := FilePath;
  Settings.FileNamePattern := FileNamePattern;
  Settings.TimeFormat := TimeFmt;
  Settings.LineFormat := LineFmt;
  Settings.Outputs := Outputs;
  Settings.MemoTarget := Memo;
  Settings.OnLogNotify := Notify;
  Settings.Colors := Colors;
  Settings.LogLevelFilter := LevelFilter;
  Settings.RotationMode := RotationMode;
  Settings.MaxBackupFiles := MaxBackupFiles;
  Configure(Settings);
end;

procedure TSafeLoggerCore.ConfigureFromComponent(Component: TSafeLogger;
  const Settings: TSafeLoggerSettings);
begin
  Configure(Settings);
  EnterCriticalSection(FConfigCS);
  try
    FVisualOwner := Component;
  finally
    LeaveCriticalSection(FConfigCS);
  end;
end;

procedure TSafeLoggerCore.DetachComponent(Component: TSafeLogger);
var
  Settings: TSafeLoggerSettings;
begin
  EnterCriticalSection(FConfigCS);
  try
    if FVisualOwner <> Component then Exit;
  finally
    LeaveCriticalSection(FConfigCS);
  end;

  Settings := GetSettings;
  Settings.MemoTarget := nil;
  Settings.OnLogNotify := nil;
  Exclude(Settings.Outputs, loMemo);
  Exclude(Settings.Outputs, loEvent);
  FVisualOwner := nil;
  Configure(Settings);
end;

procedure TSafeLoggerCore.Write(Level: TLogLevel; const Msg: string; IsCritical: Boolean);
var
  Item: TLogItem;
  Settings: TSafeLoggerSettings;
begin
  Settings := GetSettings;
  if (not Settings.Active) or (Level < Settings.LogLevelFilter) then Exit;

  Item.Level   := Level;
  Item.Message := FormatLine(Level, Msg);
  Item.Color   := Settings.Colors[Level];

  TLogWriterThread(FWriterThread).Push(Item, IsCritical);
end;

procedure TSafeLoggerCore.Flush;
begin
  TLogWriterThread(FWriterThread).ForceFlush;
end;

procedure TSafeLoggerCore.RotateLog;
begin
  TLogWriterThread(FWriterThread).DoRotation;
end;

{$IFDEF DESIGNTIME}
{ TTimeFormatPresetEditor }

function TTimeFormatPresetEditor.GetValue: string;
var
  OrdValue: Integer;
begin
  OrdValue := GetOrdValue;
  Result := GetEnumName(TypeInfo(TTimeFormatPreset), OrdValue);

  case TTimeFormatPreset(OrdValue) of
    tfFull:    Result := Result + ' (dd.mm.yyyy hh:nn:ss.zzz)';
    tfShort:   Result := Result + ' (hh:nn:ss.zzz)';
    tfISO:     Result := Result + ' (yyyy-mm-dd hh:nn:ss.zzz)';
    tfCustom:  Result := Result + ' (пользовательский)';
  end;
end;

{ TLineFormatPresetEditor }

function TLineFormatPresetEditor.GetValue: string;
var
  OrdValue: Integer;
begin
  OrdValue := GetOrdValue;
  Result := GetEnumName(TypeInfo(TLineFormatPreset), OrdValue);

  case TLineFormatPreset(OrdValue) of
    lfSimple:    Result := Result + ' ({TIME} {MESSAGE})';
    lfDetailed:  Result := Result + ' ({TIME} [{LEVEL}] {MESSAGE})';
    lfCSV:       Result := Result + ' ({TIME};{LEVEL};{MESSAGE})';
    lfCustom:    Result := Result + ' (пользовательский)';
  end;
end;
{$ENDIF}

{ TSafeLogger }

constructor TSafeLogger.Create(AOwner: TComponent);
var
  Settings: TSafeLoggerSettings;
begin
  inherited Create(AOwner);
  Settings := TSafeLoggerSettings.Default;
  FActive := Settings.Active;
  FLogLevelFilter := Settings.LogLevelFilter;
  FFileNamePattern := Settings.FileNamePattern;
  FFilePath := Settings.FilePath;
  FTimeFormatPreset := tfFull;
  FLineFormatPreset := lfDetailed;
  FOutputs := Settings.Outputs + [loMemo];
  FRotationMode := Settings.RotationMode;
  FMaxBackupFiles := Settings.MaxBackupFiles;
  FColors := Settings.Colors;

  UpdateCoreSettings;
end;

destructor TSafeLogger.Destroy;
begin
  TSafeLoggerCore.Instance.DetachComponent(Self);
  inherited Destroy;
end;

function TSafeLogger.BuildSettings: TSafeLoggerSettings;
begin
  Result := TSafeLoggerSettings.Default;
  Result.Active := FActive;
  Result.LogLevelFilter := FLogLevelFilter;
  Result.FileNamePattern := FFileNamePattern;
  Result.FilePath := FFilePath;
  Result.TimeFormat := GetTimeFormat;
  Result.LineFormat := GetLineFormat;
  Result.Outputs := FOutputs;
  Result.MemoTarget := FMemoTarget;
  Result.OnLogNotify := FOnLogNotify;
  Result.Colors := FColors;
  Result.RotationMode := FRotationMode;
  Result.MaxBackupFiles := FMaxBackupFiles;
end;

function TSafeLogger.GetTimeFormat: string;
begin
  case FTimeFormatPreset of
    tfFull:    Result := 'dd.mm.yyyy hh:nn:ss.zzz';
    tfShort:   Result := 'hh:nn:ss.zzz';
    tfISO:     Result := 'yyyy-mm-dd hh:nn:ss.zzz';
    tfCustom:  Result := FTimeFormatCustom;
  else
    Result := 'dd.mm.yyyy hh:nn:ss.zzz';
  end;
end;

function TSafeLogger.GetLineFormat: string;
begin
  case FLineFormatPreset of
    lfSimple:    Result := '{TIME} {MESSAGE}';
    lfDetailed:  Result := '{TIME} [{LEVEL}] {MESSAGE}';
    lfCSV:       Result := '{TIME};{LEVEL};{MESSAGE}';
    lfCustom:    Result := FLineFormatCustom;
  else
    Result := '{TIME} [{LEVEL}] {MESSAGE}';
  end;
end;

procedure TSafeLogger.UpdateCoreSettings;
begin
  if FActive then
    TSafeLoggerCore.Instance.ConfigureFromComponent(Self, BuildSettings)
  else
    TSafeLoggerCore.Instance.DetachComponent(Self);
end;

procedure TSafeLogger.Loaded;
begin
  inherited Loaded;
  UpdateCoreSettings;
end;

procedure TSafeLogger.SetActive(const Value: Boolean);
begin
  FActive := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetLogLevelFilter(Value: TLogLevel);
begin
  FLogLevelFilter := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetFileNamePattern(const Value: string);
begin
  FFileNamePattern := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetFilePath(const Value: string);
begin
  FFilePath := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetTimeFormatPreset(Value: TTimeFormatPreset);
begin
  FTimeFormatPreset := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetTimeFormatCustom(const Value: string);
begin
  FTimeFormatCustom := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetLineFormatPreset(Value: TLineFormatPreset);
begin
  FLineFormatPreset := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetLineFormatCustom(const Value: string);
begin
  FLineFormatCustom := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetOutputs(Value: TLogOutputs);
begin
  FOutputs := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetMemoTarget(Value: TMemo);
begin
  FMemoTarget := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetOnLogNotify(Value: TLogNotifyEvent);
begin
  FOnLogNotify := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetRotationMode(Value: TRotationMode);
begin
  FRotationMode := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.SetMaxBackupFiles(Value: Integer);
begin
  if Value < 0 then
    FMaxBackupFiles := 0
  else
    FMaxBackupFiles := Value;
  if FActive then UpdateCoreSettings;
end;

function TSafeLogger.GetColorDebug: TColor;
begin
  Result := FColors[llDebug];
end;

procedure TSafeLogger.SetColorDebug(Value: TColor);
begin
  FColors[llDebug] := Value;
  if FActive then UpdateCoreSettings;
end;

function TSafeLogger.GetColorHint: TColor;
begin
  Result := FColors[llHint];
end;

procedure TSafeLogger.SetColorHint(Value: TColor);
begin
  FColors[llHint] := Value;
  if FActive then UpdateCoreSettings;
end;

function TSafeLogger.GetColorInfo: TColor;
begin
  Result := FColors[llInfo];
end;

procedure TSafeLogger.SetColorInfo(Value: TColor);
begin
  FColors[llInfo] := Value;
  if FActive then UpdateCoreSettings;
end;

function TSafeLogger.GetColorWarning: TColor;
begin
  Result := FColors[llWarning];
end;

procedure TSafeLogger.SetColorWarning(Value: TColor);
begin
  FColors[llWarning] := Value;
  if FActive then UpdateCoreSettings;
end;

function TSafeLogger.GetColorError: TColor;
begin
  Result := FColors[llError];
end;

procedure TSafeLogger.SetColorError(Value: TColor);
begin
  FColors[llError] := Value;
  if FActive then UpdateCoreSettings;
end;

function TSafeLogger.GetColorCritical: TColor;
begin
  Result := FColors[llCritical];
end;

procedure TSafeLogger.SetColorCritical(Value: TColor);
begin
  FColors[llCritical] := Value;
  if FActive then UpdateCoreSettings;
end;

procedure TSafeLogger.WriteLog(Level: TLogLevel; const Msg: string);
begin
  if FActive then
    TSafeLoggerCore.Instance.Write(Level, Msg);
end;

procedure TSafeLogger.Flush;
begin
  TSafeLoggerCore.Instance.Flush;
end;

procedure TSafeLogger.RotateLog;
begin
  TSafeLoggerCore.Instance.RotateLog;
end;

procedure Log(const Msg: string);
begin
  Log(Msg, llInfo);
end;

procedure Log(const Msg: string; Level: TLogLevel);
begin
  try
    TSafeLoggerCore.Instance.Write(Level, Msg);
  except
  end;
end;

procedure LogException(E: Exception);
var
  Core: TSafeLoggerCore;
begin
  try
    Core := TSafeLoggerCore.Instance;
    Core.Write(llCritical, 'Exception: ' + E.ClassName + ' - ' + E.Message);
    Core.Flush;
  except
  end;
end;

procedure FlushLog;
begin
  try
    TSafeLoggerCore.Instance.Flush;
  except
  end;
end;

procedure Register;
begin
  {$IFDEF DESIGNTIME}
  RegisterComponents('Extended Components', [TSafeLogger]);
  RegisterPropertyEditor(TypeInfo(TTimeFormatPreset), TSafeLogger, 'TimeFormatPreset', TTimeFormatPresetEditor);
  RegisterPropertyEditor(TypeInfo(TLineFormatPreset), TSafeLogger, 'LineFormatPreset', TLineFormatPresetEditor);
  {$ENDIF}
end;

initialization
  AppStartTime := Now;
  InitializeCriticalSection(TSafeLoggerCore.FLock);

finalization
  if Assigned(TSafeLoggerCore.FInstance) then
  begin
    TSafeLoggerCore.FInstance.Write(llInfo, '=== SafeLogger завершает работу ===', True);
    TSafeLoggerCore.FInstance.Flush;
    FreeAndNil(TSafeLoggerCore.FInstance);
  end;
  DeleteCriticalSection(TSafeLoggerCore.FLock);

end.
